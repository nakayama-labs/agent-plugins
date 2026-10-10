#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

WT_REL=.claude/worktrees/feat/17-x

# origin 役の bare リポジトリに main を push し、feat/17-x のワークツリーで1つコミットして push しておく
setup_branch() {
  setup_fake_gh
  git add .claude/dev-workflow/config.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  echo '.claude/worktrees/' >>.git/info/exclude

  WT="$REPO/$WT_REL"
  git worktree add -q -b feat/17-x "$WT" main
  echo work >"$WT/work.txt"
  git -C "$WT" add work.txt
  git -C "$WT" commit -q -m "feat: work"
  git -C "$WT" push -q origin feat/17-x
}

# サブモジュール lib/sub（$TMP/sub）を main にコミットしておく。setup_branch より前に呼ぶ
add_submodule() {
  # 手元のパスのサブモジュールは、git の既定では取得を禁止されている（CVE-2022-39253）ので、テストの中だけ許す
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  git init -q -b main "$TMP/sub"
  echo sub >"$TMP/sub/README"
  git -C "$TMP/sub" add README
  git -C "$TMP/sub" commit -q -m sub
  git submodule add -q "$TMP/sub" lib/sub
  git commit -q -m submodule
}

# origin の main にスカッシュマージしたことにする（手元の main は1つ遅れたまま）
squash_merge() {
  git merge -q --squash feat/17-x
  git commit -q -m "feat: 作業 17 (#5)"
  git push -q origin main
  git reset -q --hard HEAD~1
  git push -q origin --delete feat/17-x
}

# 使い方: fake_pr <状態> [PR の最後のコミット（既定: feat/17-x の今のコミット）]
# PR が閉じる Issue は FAKE_CLOSING（JSON の配列。既定: []）で指定する
fake_pr() {
  jq -n --arg s "$1" --arg oid "${2:-$(git rev-parse feat/17-x)}" '[{number: 5, url: "https://github.com/me/demo/pull/5",
    state: $s, mergedAt: (if $s == "MERGED" then "2026-09-27T00:00:00Z" else null end), headRefOid: $oid, baseRefName: "main",
    closingIssuesReferences: $closing}]' --argjson closing "${FAKE_CLOSING:-[]}" \
    >"$FIX/pr-list.json"
}

run_cleanup() {
  run_script cleanup.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "マージを確かめ、ワークツリーとブランチを削除し、main を最新にする" {
  setup_branch
  squash_merge
  fake_pr MERGED
  before="$(git rev-parse main)"
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -c '[.pr.number, .worktree, .removed.worktree, .removed.branch, .switched]' <<<"$json")" \
    "[5,\"$WT\",true,true,false]"
  assert_equal "$(jq -c '[.base.from, .base.to]' <<<"$json")" "[\"$before\",\"$(git rev-parse origin/main)\"]"
  # 削除された origin/feat/17-x の追跡ブランチも片付ける
  run git show-ref --verify --quiet refs/remotes/origin/feat/17-x
  assert_failure
  assert_equal "$(args pr-list)" "--head feat/17-x --state all --json number,url,state,mergedAt,headRefOid,baseRefName,closingIssuesReferences,isCrossRepository"
}

@test "base_branch がダッシュで始まれば、何も消さずに止まる（git fetch のオプションとして扱わせない）" {
  setup_branch
  squash_merge
  fake_pr MERGED
  jq '.base_branch = "-v"' .claude/dev-workflow/config.json >"$TMP/config.json"
  mv "$TMP/config.json" .claude/dev-workflow/config.json
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -v"
  [ -e "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "--branch を省略すると、今のブランチを片付ける（ワークツリーの中から実行できる）" {
  setup_branch
  squash_merge
  fake_pr MERGED
  cd "$WT"
  run_cleanup
  assert_success
  assert_equal "$(jq -r .branch <<<"$json")" feat/17-x
  assert_equal "$(jq -r .main_root <<<"$json")" "$REPO"
  [ ! -e "$WT" ]
}

@test "dry-run では何も変えず、予定だけを出す" {
  setup_branch
  squash_merge
  fake_pr MERGED
  before="$(git rev-parse main)"
  run_cleanup --branch feat/17-x --dry-run
  assert_success
  [ -d "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
  assert_equal "$(git rev-parse main)" "$before"
  assert_equal "$(jq -c '.actions' <<<"$json")" \
    "[\"ワークツリー $WT を削除する\",\"ローカルのブランチ feat/17-x を削除する\",\"$REPO の main に origin/main を早送りで取り込む（git pull --ff-only）\"]"
}

@test "2回目は既に無いワークツリーとブランチを飛ばし、main だけ最新にする" {
  setup_branch
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c '[.worktree, .removed.worktree, .removed.branch]' <<<"$json")" '[null,false,false]'
}

@test "PR がまだマージされていなければ止まる" {
  setup_branch
  fake_pr OPEN
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "PR #5 はまだマージされていません"
  [ -d "$WT" ]
}

@test "PR が無ければ止まる" {
  setup_branch
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "feat/17-x のマージされた PR がありません"
}

@test "PR に入っていないコミットがあれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo more >"$WT/more.txt"
  git -C "$WT" add more.txt
  git -C "$WT" commit -q -m "feat: more"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "feat/17-x に PR #5 に入っていないコミットがあります"
  [ -d "$WT" ]
}

@test "手元のブランチが PR の最後のコミットより古いだけなら片付ける" {
  setup_branch
  git -C "$WT" commit -q --allow-empty -m "feat: pushed from elsewhere"
  head="$(git rev-parse feat/17-x)"
  git -C "$WT" reset -q --hard HEAD~1
  squash_merge
  fake_pr MERGED "$head"
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
}

@test "ワークツリーに未コミットの変更があれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo dirty >"$WT/dirty.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  [ -f "$WT/dirty.txt" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "ワークツリーに git が無視するファイルがあれば、何も消さずに止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  printf '%s\n' .env 'build/' >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  mkdir "$WT/build"
  echo out >"$WT/build/out.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（.env, build/）があります"
  assert_output --partial "--remove-ignored"
  [ -f "$WT/.env" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "git が無視するファイルが6つ以上あれば、5つまで出して残りの数を添える" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo '*.log' >>.git/info/exclude
  for i in 1 2 3 4 5 6 7; do echo x >"$WT/$i.log"; done
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "（1.log, 2.log, 3.log, 4.log, 5.log ほか 2 件）"
}

@test "--remove-ignored を付ければ、git が無視するファイルごと削除する" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo .env >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  run_cleanup --branch feat/17-x --remove-ignored
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
}

@test "status.showUntrackedFiles=no でも、追跡していないファイルや git が無視するファイルがあれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  git config status.showUntrackedFiles no
  echo new >"$WT/new.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  rm "$WT/new.txt"
  echo .env >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（.env）があります"
  [ -f "$WT/.env" ]
}

@test "status.showUntrackedFiles=no でも、サブモジュールの中の git が無視するファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  # サブモジュールの中にも効くよう、環境変数で設定する（add_submodule が GIT_CONFIG_KEY_0 を使っている）
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=status.showUntrackedFiles GIT_CONFIG_VALUE_1=no
  echo .env >>"$(git -C "$WT/lib/sub" rev-parse --git-path info/exclude)"
  echo SECRET=1 >"$WT/lib/sub/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（lib/sub/.env）があります"
}

@test "サブモジュールを初期化したワークツリーも削除する" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
}

@test "サブモジュールの中に未コミットの変更があれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo dirty >>"$WT/lib/sub/README"
  # 設定でサブモジュールの変更を隠していても見つける
  git config submodule.lib/sub.ignore all
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  assert_equal "$(cat "$WT/lib/sub/README")" "$(printf 'sub\ndirty')"
}

@test "サブモジュールの中に追跡していないファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo new >"$WT/lib/sub/new.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  [ -f "$WT/lib/sub/new.txt" ]
}

@test "サブモジュールの中に git が無視するファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo .env >>"$(git -C "$WT/lib/sub" rev-parse --git-path info/exclude)"
  echo SECRET=1 >"$WT/lib/sub/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（lib/sub/.env）があります"
  [ -f "$WT/lib/sub/.env" ]
}

@test "サブモジュールにリモートに無いコミットがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  # サブモジュールのコミットを親に記録して親だけ push し、サブモジュールのリモートには push していない
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  git -C "$WT" add lib/sub
  git -C "$WT" commit -q -m "feat: bump sub"
  git -C "$WT" push -q origin feat/17-x
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
  [ -d "$WT" ]
}

@test "サブモジュールがタグからだけ届くコミットを指していても削除する" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  # サブモジュールのリモートで、どのブランチにも無くタグだけが指すコミットを作る
  git -C "$TMP/sub" commit -q --allow-empty -m tagged
  git -C "$TMP/sub" tag v1
  git -C "$TMP/sub" reset -q --hard HEAD~1
  git -C "$WT/lib/sub" fetch -q --tags origin
  git -C "$WT/lib/sub" switch -q --detach v1
  git -C "$WT" add lib/sub
  git -C "$WT" commit -q -m "feat: sub v1"
  git -C "$WT" push -q origin feat/17-x
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
}

@test "サブモジュールのローカルのブランチにだけリモートに無いコミットがあっても止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  git -C "$WT/lib/sub" switch -q -c wip
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  git -C "$WT/lib/sub" switch -q --detach HEAD~1
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
}

@test "サブモジュールに stash があれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo dirty >>"$WT/lib/sub/README"
  git -C "$WT/lib/sub" stash -q
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
}

@test "メインのワークツリーでブランチを使っていたら、main に切り替えてから削除する" {
  setup_branch
  git worktree remove "$WT"
  squash_merge
  git switch -q feat/17-x
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(git symbolic-ref --short HEAD)" main
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -c '[.switched, .removed.worktree, .removed.branch]' <<<"$json")" '[true,false,true]'
}

@test "main をどのワークツリーでも使っていなければ、ref だけ早送りする" {
  setup_branch
  squash_merge
  git switch -q --detach
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -r '.actions[-1]' <<<"$json")" "main を origin/main まで早送りする"
}

@test "main に origin に無いコミットがあれば、早送りできずに止まる" {
  setup_branch
  squash_merge
  git commit -q --allow-empty -m "local only"
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_failure 1
  assert_output --partial "main を早送りで最新にできません"
}

@test "ワークツリーのディレクトリが手で消されていたら、記録を片付ける" {
  setup_branch
  squash_merge
  fake_pr MERGED
  rm -rf "$WT"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "消えたワークツリー $WT の記録を片付ける（git worktree prune）"
  assert_equal "$(git worktree list --porcelain | grep -c '^worktree ')" 1
}

@test "main は片付けられない" {
  setup_branch
  run_cleanup --branch main
  assert_failure 64
  assert_output --partial "main は片付けられません"
  git switch -q main
  run_cleanup
  assert_failure 64
}

@test "--abandon ではマージを確かめず、ワークツリーとブランチを削除し、main は変えない" {
  setup_branch
  git commit -q --allow-empty -m "main だけのコミット"
  before="$(git rev-parse main)"
  sha="$(git rev-parse --short feat/17-x)"
  run_cleanup --branch feat/17-x --abandon
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
  assert_equal "$(git rev-parse main)" "$before"
  # PR を見ない
  assert_equal "$(called pr-list)" 0
  assert_equal "$(jq -c '[.abandon, .pr, .removed.worktree, .removed.branch, .lost.commits]' <<<"$json")" \
    "[true,null,true,true,[\"$sha feat: work\"]]"
  assert_equal "$(jq -c '.actions' <<<"$json")" "[\"ワークツリー $WT を削除する\",\"ローカルのブランチ feat/17-x を削除する\"]"
}

@test "--abandon --dry-run で、失うもの（コミット・未コミットの変更・git が無視するファイル）を一覧にする" {
  setup_branch
  sha="$(git rev-parse --short feat/17-x)"
  echo more >>"$WT/work.txt"
  echo new >"$WT/new.txt"
  echo 'secret' >"$WT/.env"
  echo '.env' >>"$WT/.gitignore"
  git -C "$WT" add .gitignore
  git -C "$WT" commit -q -m "chore: ignore .env"
  sha2="$(git rev-parse --short feat/17-x)"
  run_cleanup --branch feat/17-x --abandon --dry-run
  assert_success
  [ -d "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
  assert_equal "$(jq -c '.lost' <<<"$json")" \
    "{\"commits\":[\"$sha2 chore: ignore .env\",\"$sha feat: work\"],\"uncommitted\":[\"work.txt\",\"new.txt\"],\"ignored\":[\".env\"],\"submodules\":[]}"
}

@test "--abandon では、未コミットの変更や git が無視するファイルがあっても削除する" {
  setup_branch
  echo more >>"$WT/work.txt"
  echo 'secret' >"$WT/.env"
  # info/exclude はワークツリーで共有される
  echo '.env' >>.git/info/exclude
  run_cleanup --branch feat/17-x --abandon
  assert_success
  [ ! -e "$WT" ]
}

@test "--abandon では、サブモジュールのリモートに無いコミットも失うものに出して削除する" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  run_cleanup --branch feat/17-x --abandon --dry-run
  assert_success
  assert_equal "$(jq -c '.lost.submodules' <<<"$json")" '["lib/sub"]'
  run_cleanup --branch feat/17-x --abandon
  assert_success
  [ ! -e "$WT" ]
}

@test "--abandon でも、メインのワークツリーに未コミットの変更があれば止まる" {
  setup_branch
  git worktree remove "$WT"
  git switch -q feat/17-x
  echo more >>work.txt
  run_cleanup --branch feat/17-x --abandon
  assert_failure 2
  assert_output --partial "$REPO に未コミットの変更があります"
  assert_equal "$(git symbolic-ref --short HEAD)" feat/17-x
}

@test "--abandon で、メインのワークツリーでブランチを使っていたら、main に切り替えてから削除する" {
  setup_branch
  git worktree remove "$WT"
  git switch -q feat/17-x
  run_cleanup --branch feat/17-x --abandon
  assert_success
  assert_equal "$(git symbolic-ref --short HEAD)" main
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
}

@test "--abandon の2回目は、既に無いワークツリーとブランチを飛ばして成功する" {
  setup_branch
  run_cleanup --branch feat/17-x --abandon
  assert_success
  run_cleanup --branch feat/17-x --abandon
  assert_success
  assert_equal "$(jq -c '[.removed, .actions, .lost.commits]' <<<"$json")" '[{"worktree":false,"branch":false},[],[]]'
}

@test "PR が閉じる Issue が閉じたかを issues に出す" {
  setup_branch
  squash_merge
  FAKE_CLOSING='[{"number": 17}, {"number": 18}]' fake_pr MERGED
  echo '{"state": "CLOSED"}' >"$FIX/issue-17.json"
  echo '{"state": "OPEN"}' >"$FIX/issue-18.json"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c .issues <<<"$json")" '[{"number":17,"repo":null,"state":"CLOSED"},{"number":18,"repo":null,"state":"OPEN"}]'
}

@test "Issue の状態を取得できなくても、片付けは続けて state を null にする" {
  setup_branch
  squash_merge
  FAKE_CLOSING='[{"number": 17}]' fake_pr MERGED
  FAKE_FAIL=issue-view run_cleanup --branch feat/17-x
  assert_success
  assert_output --partial "warn: Issue #17 の状態を取得できませんでした"
  [ ! -e "$WT" ]
  assert_equal "$(jq -c .issues <<<"$json")" '[{"number":17,"repo":null,"state":null}]'
}

@test "別のリポジトリの Issue は、そのリポジトリで状態を調べる" {
  setup_branch
  squash_merge
  FAKE_CLOSING='[{"number": 17, "repository": {"name": "repo", "owner": {"login": "other"}}}]' fake_pr MERGED
  echo '{"state": "CLOSED"}' >"$FIX/issue-17.json"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c .issues <<<"$json")" '[{"number":17,"repo":"other/repo","state":"CLOSED"}]'
  assert_equal "$(args issue-view)" "17 --repo other/repo --json state -q .state"
}

@test "PR が閉じる Issue が無ければ、issues は空" {
  setup_branch
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c .issues <<<"$json")" '[]'
}

@test "--abandon では Issue の状態を調べない" {
  setup_branch
  run_cleanup --branch feat/17-x --abandon
  assert_success
  assert_equal "$(jq -c .issues <<<"$json")" '[]'
  run grep '^issue-view' "$CALLS"
  assert_failure
}

@test "フォークの同じ名前のブランチからのマージ済みの PR を、自分の PR と取り違えない（自分の PR が開いていれば止まる）" {
  setup_branch
  jq -n --arg oid "$(git rev-parse feat/17-x)" '[
    {number: 5, url: "https://github.com/me/demo/pull/5", state: "OPEN", mergedAt: null, headRefOid: $oid,
     baseRefName: "main", closingIssuesReferences: [], isCrossRepository: false},
    {number: 3, url: "https://github.com/me/demo/pull/3", state: "MERGED", mergedAt: "2026-09-27T00:00:00Z", headRefOid: $oid,
     baseRefName: "main", closingIssuesReferences: [{number: 99}], isCrossRepository: true}]' >"$FIX/pr-list.json"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "PR #5 はまだマージされていません"
  [ -d "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "--abandon で、署名を表示する設定（log.showSignature）でも、署名の検証の行を失うコミットに数えない" {
  setup_branch
  use_fake_gpg "$WT"
  echo signed >"$WT/signed.txt"
  git -C "$WT" add signed.txt
  git -C "$WT" commit -q -S -m "feat: signed"
  git config log.showSignature true
  run_cleanup --branch feat/17-x --abandon --dry-run
  assert_success
  assert_equal "$(jq -r '.lost.commits | map(sub("^[0-9a-f]+ "; "")) | join(",")' <<<"$json")" "feat: signed,feat: work"
}

@test "--abandon で、失うコミットが多くても（一覧が jq の引数の長さの上限を超えても）止まらない" {
  setup_branch
  # 件名の長いコミットを 2000 件作る（一覧は 128 KiB を超える）
  make_commits feat/17-x 2000
  run_cleanup --branch feat/17-x --abandon --dry-run
  assert_success
  assert_equal "$(jq '.lost.commits | length' <<<"$json")" "2001"
}

@test "--abandon で、失うコミットを調べる git が失敗したら、失うものが無いと伝えたまま削除せずに止まる" {
  setup_branch
  make_failing_git
  PATH="$TMP/failgit:$PATH" FAIL_GIT='* log --no-show-signature *' run_cleanup --branch feat/17-x --abandon
  assert_failure
  assert_output --partial "feat/17-x の失うコミットを調べられませんでした"
  [ -d "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "サブモジュールの push していないコミットを調べる git が失敗したら、無いとみなさず、削除せずに止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  # サブモジュールの手元だけのブランチの先のコミットのオブジェクトを消して、git log を本当に失敗させる
  # （foreach の中では git が自分の場所を PATH の先頭に足すので、偽の git では差し替えられない）
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  git -C "$WT/lib/sub" branch -q local-only
  sha="$(git -C "$WT/lib/sub" rev-parse HEAD)"
  git -C "$WT/lib/sub" checkout -q --detach HEAD~1
  rm -f "$(git -C "$WT/lib/sub" rev-parse --git-path objects)/${sha:0:2}/${sha:2}"
  run git -C "$WT/lib/sub" log -1 --format=%h HEAD --branches --not --remotes --tags
  assert_failure
  run_cleanup --branch feat/17-x --abandon
  assert_failure
  assert_output --partial "のサブモジュールを確かめられませんでした"
  [ -d "$WT" ]
}

@test "マージキューでマージされた PR（先に別の PR がマージされ、キューの一時的なブランチが origin に残っている）も片付ける（#178）" {
  setup_branch
  # 先に並んだ別の PR が main に入る
  git switch -q -c other main
  echo other >other.txt
  git add other.txt
  git commit -q -m "feat: other (#4)"
  git push -q origin other:main
  git switch -q main
  git branch -q -D other
  # キューは、最新の main に PR を重ねた一時的なブランチで CI を動かし、スカッシュで main にマージする。
  # feat/17-x は main を取り込み直していない（PR の最後のコミットのまま）
  git fetch -q origin main
  git switch -q --detach origin/main
  git merge -q --squash feat/17-x
  git commit -q -m "feat: 作業 17 (#5)"
  queue_ref="refs/heads/gh-readonly-queue/main/pr-5-$(git rev-parse feat/17-x)"
  git push -q origin "HEAD:$queue_ref"
  git push -q origin HEAD:main
  git switch -q main
  git push -q origin --delete feat/17-x
  git fetch -q origin
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(git log -1 --format=%s main)" "feat: 作業 17 (#5)"
  # キューの一時的なブランチは GitHub が片付けるもので、作業のブランチではないので、消さずに残し、出力にも出さない
  run git ls-remote --exit-code origin "$queue_ref"
  assert_success
  run jq -r '.. | strings' <<<"$json"
  refute_output --partial gh-readonly-queue
}

# bare リポジトリ＋ワークツリーの配置（<ルート>/.bare と、それを指す <ルート>/.git のファイル）を $TMP/proj に作る。
# main と feat/17-x のワークツリーを作る。setup_branch の後、squash_merge の前に呼ぶ（origin の main は後で進む）
make_bare_layout() {
  PROJ="$TMP/proj"
  git clone -q --bare "$TMP/origin.git" "$PROJ/.bare"
  git -C "$PROJ/.bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$PROJ/.bare" fetch -q origin
  echo 'gitdir: ./.bare' >"$PROJ/.git"
  git -C "$PROJ" worktree add -q "$PROJ/main" main
  git -C "$PROJ" worktree add -q "$PROJ/feat" feat/17-x
}

@test "bare リポジトリ＋ワークツリーの配置で、main-root.sh が求めた場所（作業ツリーの無いルート）から片付けられる（#233）" {
  setup_branch
  make_bare_layout
  squash_merge
  fake_pr MERGED
  cd "$PROJ/feat"
  run_script main-root.sh
  assert_success
  assert_equal "$(jq -r .main_root <<<"$output")" "$PROJ"
  cd "$(jq -r .main_root <<<"$output")"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c '[.branch, .main_root, .worktree, .removed.worktree, .removed.branch]' <<<"$json")" \
    "[\"feat/17-x\",\"$PROJ\",\"$PROJ/feat\",true,true]"
  [ ! -e "$PROJ/feat" ]
  run git -C "$PROJ" show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
  assert_equal "$(git -C "$PROJ/main" rev-parse main)" "$(git -C "$PROJ/main" rev-parse origin/main)"
}

@test "作業ツリーの無いルートでは、--branch を省略しても、bare リポジトリの HEAD のブランチを今のブランチとみなさない（#233）" {
  setup_branch
  make_bare_layout
  git -C "$PROJ/.bare" symbolic-ref HEAD refs/heads/feat/17-x
  cd "$PROJ"
  run_cleanup
  assert_failure 64
  assert_output --partial "ブランチの上にいません"
}

@test "WORKFLOW_REPO_ROOT が作業ツリーの無いルートを指しても、--branch を省略して bare リポジトリの HEAD のブランチを消さない（#233）" {
  setup_branch
  make_bare_layout
  git -C "$PROJ/.bare" symbolic-ref HEAD refs/heads/feat/17-x
  cd "$PROJ"
  WORKFLOW_REPO_ROOT="$PROJ" run_cleanup --abandon
  assert_failure 64
  assert_output --partial "ブランチの上にいません"
  [ -e "$PROJ/feat" ]
  run git -C "$PROJ" show-ref --verify --quiet refs/heads/feat/17-x
  assert_success
}

@test "リポジトリの外で実行すると、使い方の誤りで止まる" {
  mkdir "$TMP/outside"
  cd "$TMP/outside"
  run_cleanup --branch feat/17-x
  assert_failure 64
  assert_output --partial "リポジトリの外か、メインのワークツリーが分からない配置"
}

@test "サブモジュールのワークツリーでも、main-root.sh が求めたサブモジュールの作業ツリーから片付けられる（#233）" {
  # 上のリポジトリ（super）の中のサブモジュール sm を、cleanup の対象にする（main_root は .git/modules ではなく super/sm）
  git init -q -b main "$TMP/super"
  git -C "$TMP/super" commit -q --allow-empty -m init
  git -C "$TMP/super" -c protocol.file.allow=always submodule add -q "$REPO" sm
  SM="$TMP/super/sm"
  git -C "$SM" remote set-url origin "$TMP/origin.git"
  setup_branch
  git -C "$SM" fetch -q origin
  git -C "$SM" worktree add -q "$TMP/smwt" -b feat/17-x origin/feat/17-x
  squash_merge
  fake_pr MERGED "$(git -C "$TMP/smwt" rev-parse HEAD)"
  cd "$TMP/smwt"
  run_script main-root.sh
  assert_success
  assert_equal "$(jq -r .main_root <<<"$output")" "$SM"
  cd "$(jq -r .main_root <<<"$output")"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c '[.main_root, .worktree, .removed.worktree, .removed.branch]' <<<"$json")" "[\"$SM\",\"$TMP/smwt\",true,true]"
  [ ! -e "$TMP/smwt" ]
}

@test "--abandon で、失うコミットの件名に絵文字があっても（4096 バイトを超える1行でも）壊さずに伝える" {
  # 標準入力の jq -R -s は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  setup_branch
  subject="feat: $(emoji_text 1500)"
  git -C "$WT" commit -q --allow-empty -m "$subject"
  run_cleanup --branch feat/17-x --abandon --dry-run
  assert_success
  assert_equal "$(jq -r '.lost.commits[0] | sub("^[0-9a-f]+ "; "")' <<<"$json")" "$subject"
}

@test "--abandon の失うものの一覧は、複数行・絵文字・空行を含む値でも壊れず、大きな値でも引数の長さの上限で失敗しない" {
  # lose() は、一覧を jq の引数ではなく標準入力で渡す。空行は除き、種類ごとに足す
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '
    set -euo pipefail
    . "$1/lib/common.sh"
    eval "$(sed -n "/^lost=/,/^}/p" "$1/cleanup.sh")"
    lose uncommitted "$(printf "a.txt\n\n😀 b.txt\n")"
    lose uncommitted "c.txt"
    big="$(for i in $(seq 1 6000); do printf "%0100d😀\n" "$i"; done)"
    lose ignored "$big"
    printf "%s" "$lost" | jq -c "[.uncommitted, (.ignored | length), .ignored[-1], .commits]"
  ' _ "$SCRIPTS"
  assert_success
  assert_equal "$(jq -c '[.[0], .[1], .[3]]' <<<"$output")" '[["a.txt","😀 b.txt","c.txt"],6000,[]]'
  assert_equal "$(jq -r '.[2]' <<<"$output")" "$(printf '%0100d😀' 6000)"
}
