#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# origin 役の bare リポジトリに main を push し、作業用のブランチ feat/17-x に1つコミットしておく
setup_branch() {
  setup_fake_gh
  git add .claude/dev-workflow/config.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  git checkout -q -b feat/17-x
  echo work >work.txt
  git add work.txt
  git commit -q -m "feat: work"
  printf '## 概要\n作業した\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n\nCloses #\n' >"$TMP/body.md"
}

# origin に、手元の main と同じ位置のブランチ（PR のマージ先の役）を作り、origin/<名前> を取得しておく
push_base() {
  git push -q origin "main:refs/heads/$1"
  git fetch -q origin
}

run_pr() {
  run_script pr-create.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "push して、Issue のタイトルとラベルで PR を作る" {
  setup_branch
  fake_issue 17 '["feat", "priority: high"]'
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.title, .created, .pr.number, .pr.url, .draft, .status.skipped]' <<<"$json")" \
    '["feat: 作業 17",true,42,"https://github.com/me/demo/pull/42",false,true]'
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
  assert_equal "$(git rev-parse --abbrev-ref '@{upstream}')" origin/feat/17-x
  run args pr-create
  assert_output --partial "--base main --head feat/17-x --title feat: 作業 17 --body-file "
  assert_output --partial "--label feat --label priority: high"
  refute_output --partial --draft
}

@test "base_branch がダッシュで始まれば、取得せずに止まる（git fetch のオプションとして扱わせない）" {
  setup_branch
  fake_issue 17 '["feat"]'
  jq '.base_branch = "-v"' .claude/dev-workflow/config.json >"$TMP/config.json"
  mv "$TMP/config.json" .claude/dev-workflow/config.json
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -v"
  run git ls-remote --heads origin feat/17-x
  assert_output ""
}

@test "本文の空の Closes # の行を消し、Closes #N を末尾に足す" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(cat "$TMP/pr-body")" "$(printf '## 概要\n作業した\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n\nCloses #17')"
  assert_equal "$(jq -r .body <<<"$json")" "$(cat "$TMP/pr-body")"
  # 出力の本文は、末尾に改行を足さない（$( ) では末尾の改行の違いが見えないので、JSON のまま比べる）
  assert_equal "$(jq -c .body <<<"$json")" '"## 概要\n作業した\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n\nCloses #17"'
}

@test "本文に Closes #N があれば足さない（#170 は別の Issue とみなす）" {
  setup_branch
  printf '概要\n\ncloses #17\n' >"$TMP/b1.md"
  run_pr --issue 17 --body-file "$TMP/b1.md" --dry-run
  assert_equal "$(jq -r .body <<<"$json")" "$(printf '概要\n\ncloses #17')"
  printf '概要\n\nCloses #170\n' >"$TMP/b2.md"
  run_pr --issue 17 --body-file "$TMP/b2.md" --dry-run
  assert_equal "$(jq -r .body <<<"$json")" "$(printf '概要\n\nCloses #170\n\nCloses #17')"
}

@test "本文が空ならエラーになる" {
  setup_branch
  printf 'Closes #\n' >"$TMP/empty.md"
  run_pr --issue 17 --body-file "$TMP/empty.md"
  assert_failure 64
  assert_output --partial "本文が空です"
}

@test "--title で指定したタイトルを使う" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "feat(pr): 別のタイトル"
  assert_success
  assert_equal "$(jq -r .title <<<"$json")" "feat(pr): 別のタイトル"
}

@test "タイトルが規約に合わなければ、push せずに止まる" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "作業 17"
  assert_failure 2
  assert_output --partial "タイトルが規約に合いません"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
}

@test "pr.title_pattern が正規表現として正しくない・文字列でないときは、タイトルが合わないではなく設定の誤りとして報告し、push しない" {
  setup_branch
  for p in '"^(feat"' 5 null; do
    echo "{\"pr\": {\"title_pattern\": $p}}" >.claude/dev-workflow/config.local.json
    run_pr --issue 17 --body-file "$TMP/body.md"
    assert_failure 2
    if [ "$p" = '"^(feat"' ]; then
      assert_output --partial 'pr.title_pattern（"^(feat"）が正規表現として正しくありません'
    else
      assert_output --partial "pr.title_pattern（${p}）が文字列ではありません"
    fi
    refute_output --partial "タイトルが規約に合いません"
    run git rev-parse -q --verify origin/feat/17-x
    assert_failure
  done
}

@test "pr.title_pattern の上のキー（pr）がオブジェクトでなければ、null ではなく、読めない理由を報告し、push しない" {
  setup_branch
  echo '{"pr": "x"}' >.claude/dev-workflow/config.local.json
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "pr.title_pattern を読めません"
  refute_output --partial "pr.title_pattern（null）"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
}

@test "タイトルの type が Issue の type ラベルと違えば止まる" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "fix: 作業 17"
  assert_failure 2
  assert_output --partial "タイトルの type（fix）が Issue #17 の type ラベル（feat）と違います"
}

@test "Issue に breaking ラベルがあれば、タイトルを <type>!: にする" {
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  printf '概要\n\nBREAKING CHANGE: 設定の foo を bar に直してください\n' >"$TMP/b.md"
  run_pr --issue 17 --body-file "$TMP/b.md"
  assert_success
  assert_equal "$(jq -c '[.title, .breaking]' <<<"$json")" '["feat!: 作業 17",true]'
  assert_equal "$(cat "$TMP/pr-body")" "$(printf '概要\n\nBREAKING CHANGE: 設定の foo を bar に直してください\n\nCloses #17')"
  run args pr-create
  assert_output --partial "--title feat!: 作業 17 --body-file "
  assert_output --partial "--label feat --label breaking"
}

@test "breaking ラベルが無ければ、タイトルに ! を付けない" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.title, .breaking]' <<<"$json")" '["feat: 作業 17",false]'
}

@test "breaking ラベルの名前は大文字と小文字を区別しない" {
  setup_branch
  fake_issue 17 '["feat", "Breaking"]'
  printf '概要\n\nBREAKING CHANGE: 直す\n' >"$TMP/b.md"
  run_pr --issue 17 --body-file "$TMP/b.md" --dry-run
  assert_success
  assert_equal "$(jq -r .title <<<"$json")" "feat!: 作業 17"
}

@test "breaking ラベルがあるのに --title に ! が無ければ、push せずに止まる" {
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  printf '概要\n\nBREAKING CHANGE: 直す\n' >"$TMP/b.md"
  run_pr --issue 17 --body-file "$TMP/b.md" --title "feat(pr): 別のタイトル"
  assert_failure 2
  assert_output --partial "Issue #17 は破壊的変更（breaking ラベル）なので、タイトルの type の後に ! を付けてください（feat!: …）"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
  run_pr --issue 17 --body-file "$TMP/b.md" --title "feat(pr)!: 別のタイトル" --dry-run
  assert_success
  assert_equal "$(jq -r .title <<<"$json")" "feat(pr)!: 別のタイトル"
}

@test "breaking ラベルがあるのに本文に BREAKING CHANGE: が無ければ、push せずに止まる" {
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  printf '概要に BREAKING CHANGE: と書いただけ\n\nBREAKING CHANGE:\n' >"$TMP/b.md"
  run_pr --issue 17 --body-file "$TMP/b.md"
  assert_failure 64
  assert_output --partial "Issue #17 は破壊的変更（breaking ラベル）なので、本文の最後に「BREAKING CHANGE: <移行のしかた>」を書いてください"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
}

@test "Issue に type ラベルが無ければ止まる" {
  setup_branch
  fake_issue 17 '[]'
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "Issue #17 の type ラベルを1つにしてください（今は なし）"
}

@test "pr.draft が true なら下書きにする" {
  setup_branch
  jq '. + {pr: {draft: true}}' .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
  git commit -q -am "chore: draft"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq .draft <<<"$json")" true
  run args pr-create
  assert_output --partial --draft
}

@test "--draft を付ければ、pr.draft が false でも下書きにする" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --draft --dry-run
  assert_success
  assert_equal "$(jq .draft <<<"$json")" true
  assert_output --partial "（下書き）"
  run_pr --issue 17 --body-file "$TMP/body.md" --draft
  assert_success
  assert_equal "$(jq .draft <<<"$json")" true
  run args pr-create
  assert_output --partial --draft
}

@test "--no-draft を付ければ、pr.draft が true でも下書きにしない（task-auto）" {
  setup_branch
  jq '. + {pr: {draft: true}}' .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
  git commit -q -am "chore: draft"
  run_pr --issue 17 --body-file "$TMP/body.md" --no-draft --dry-run
  assert_success
  assert_equal "$(jq .draft <<<"$json")" false
  refute_output --partial "（下書き）"
  run_pr --issue 17 --body-file "$TMP/body.md" --no-draft
  assert_success
  assert_equal "$(jq .draft <<<"$json")" false
  run args pr-create
  refute_output --partial --draft
}

@test "--draft と --no-draft は同時に指定できない" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --draft --no-draft
  assert_failure 64
  assert_output --partial "--draft と --no-draft は同時に指定できません"
}

# status.pr_opened を Done にする
set_pr_opened() {
  jq '. + {status: {pr_opened: "Done"}}' .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
  git commit -q -am "chore: status"
}

@test "開いた PR が既にあれば、push だけして作り直さず、タイトル・本文・列も変えない" {
  setup_branch
  set_pr_opened
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .title, .body, .labels, .status.skipped]' <<<"$json")" '[false,7,null,null,null,true]'
  assert_equal "$(called pr-create)" 0
  assert_equal "$(called SetField)" 0
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,title,body,isCrossRepository,isDraft,baseRefName"
}

@test "PR を出した後に breaking ラベルを付けたら、既にある PR に ! と BREAKING CHANGE が無いと push せずに止まる" {
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  printf '概要\n\nBREAKING CHANGE: 直す\n' >"$TMP/b.md"
  jq -n '[{number: 7, url: "https://github.com/me/demo/pull/7", isCrossRepository: false,
    title: "feat: 作業 17", body: "概要\n\nBREAKING CHANGE: 直す\n\nCloses #17"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/b.md"
  assert_failure 2
  assert_output --partial "既にある PR #7 のタイトルの type の後に ! がありません（gh pr edit 7 --title で直してから実行してください）"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure

  jq -n '[{number: 7, url: "https://github.com/me/demo/pull/7", isCrossRepository: false,
    title: "feat!: 作業 17", body: "概要\r\n\r\nCloses #17"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/b.md"
  assert_failure 2
  assert_output --partial "既にある PR #7 の本文に「BREAKING CHANGE: <移行のしかた>」がありません"

  jq -n '[{number: 7, url: "https://github.com/me/demo/pull/7", isCrossRepository: false,
    title: "feat!: 作業 17", body: "概要\r\n\r\nBREAKING CHANGE: 直す\r\n\r\nCloses #17"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .breaking]' <<<"$json")" '[false,7,true]'
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
}

@test "fork の同じ名前のブランチからの PR は、既にある PR とみなさない" {
  setup_branch
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number]' <<<"$json")" '[true,42]'
}

@test "status.pr_opened が設定されていれば、その列に移す" {
  setup_branch
  set_pr_opened
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.status.from, .status.to]' <<<"$json")" '["Todo","Done"]'
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O3
}

@test "PR を作った後に列を移せなければ、移し方を伝えて止まる" {
  setup_branch
  set_pr_opened
  FAKE_FAIL=SetField run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "PR #42 は作りましたが、Issue #17 の列を移せませんでした（status-set.sh --issue 17 --to pr_opened で移せます）"
}

@test "dry-run で列の移動の予定を作れなければ、PR を作ったとは言わずに止まる" {
  setup_branch
  set_pr_opened
  FAKE_FAIL=ProjectFields run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_failure 1
  assert_output --partial "Issue #17 を列に移す予定を作れませんでした"
  refute_output --partial "作りましたが"
}

@test "status.pr_opened が既定（null）なら、列を移さない" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(called ProjectView)" 0
}

@test "dry-run では push も PR の作成もせず、予定を出す" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
  assert_equal "$(called pr-create)" 0
  assert_equal "$(jq -c '[.dry_run, .pr, .actions]' <<<"$json")" \
    '[true,null,["feat/17-x を origin に push する（手元の origin/main（取得していない）より 1 個先のコミット。本番は取得し直して確かめる）","main に向けた PR「feat: 作業 17」を作る","PR にラベル feat を付ける"]]'
}

@test "未コミットの変更があれば止まる" {
  setup_branch
  echo more >>work.txt
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "未コミットの変更があります"
}

@test "origin/main より先のコミットが無ければ止まる" {
  setup_branch
  git checkout -q -b feat/17-empty main
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "origin/main に無いコミットがありません"
}

@test "main の上では止まる" {
  setup_branch
  git checkout -q main
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "main からは PR を作りません"
}

@test "push できなければ、PR を作らずに止まる" {
  setup_branch
  git push -q origin feat/17-x
  git reset -q --hard HEAD~1
  echo other >other.txt
  git add other.txt
  git commit -q -m "feat: other"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "feat/17-x を push できませんでした"
  assert_equal "$(called pr-create)" 0
}

@test "PR を作れなければ、push したことを伝えて止まる" {
  setup_branch
  FAKE_FAIL=pr-create run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "feat/17-x は push しましたが、PR を作れませんでした"
}

@test "本文は標準入力からも読める" {
  setup_branch
  run_script pr-create.sh --issue 17 --body-file - --dry-run <"$TMP/body.md"
  assert_success
  json="$(json_of "$output")"
  assert_equal "$(jq -r .body <<<"$json" | tail -n 1)" "Closes #17"
}

# 使い方: set_issue_body <本文>  Issue #17（type は feat）の本文を、指定した文字列にそのまま置き換える
set_issue_body() {
  fake_issue 17 '["feat"]'
  fake_issue_body 17 "$1"
}

# Issue #17 の本文を、チェックリストを含むものにする（改行は \r\n。最後の行の後にも改行を置く）
fake_issue_tasks() {
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  set_issue_body "$(printf '## やること\r\n- [ ] 一つ目 [ ] を含む\r\n- [x] 二つ目\r\n  * [ ] 三つ目（入れ子）\r\n1. [ ] 四つ目\r\n- [ ] ~~五つ目~~\r\n\r\n```md\r\n- [ ] コードブロックの中\r\n```\r\n- [ ]\r\n- [] 項目ではない')"$'\r\n'
}

@test "Issue の本文のチェックリストの項目を、コードブロックの中を除いて出す" {
  setup_branch
  fake_issue_tasks
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[] | [.checked, .text]]' <<<"$json")" \
    '[[false,"一つ目 [ ] を含む"],[true,"二つ目"],[false,"三つ目（入れ子）"],[false,"四つ目"],[false,"~~五つ目~~"],[false,""]]'
  assert_equal "$(jq -c .checked <<<"$json")" '[]'
}

@test "--check で指定した文の項目だけにチェックを付け、ほかの行は変えない" {
  setup_branch
  fake_issue_tasks
  run_pr --issue 17 --body-file "$TMP/body.md" --check "一つ目 [ ] を含む" --check "三つ目（入れ子）" --check 二つ目 --check 四つ目
  assert_success
  # 二つ目は既にチェックがあるので付けない
  assert_equal "$(jq -c .checked <<<"$json")" '["一つ目 [ ] を含む","三つ目（入れ子）","四つ目"]'
  assert_equal "$(args edit)" "17 --body-file -"
  jq -j '.body' "$FIX/issue-17.json" \
    | sed -e 's/^- \[ \] 一つ目/- [x] 一つ目/' -e 's/^  \* \[ \] 三つ目/  * [x] 三つ目/' -e 's/^1\. \[ \] 四つ目/1. [x] 四つ目/' >"$TMP/expected"
  # 改行の \r\n と末尾の改行も含めて、バイト単位で同じか比べる
  run cmp "$TMP/expected" "$TMP/issue-edit-body"
  assert_success
  run grep -c '一つ目 \[ \] を含む' "$TMP/issue-edit-body"
  assert_output 1
}

@test "--check が無ければ Issue の本文を変えない" {
  setup_branch
  fake_issue_tasks
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(called edit)" 0
}

@test "既にある PR に push するときも、--check の項目にチェックを付ける" {
  setup_branch
  fake_issue_tasks
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --check "~~五つ目~~" --dry-run
  assert_success
  assert_equal "$(jq -c '[.created, .checked, .actions[-1]]' <<<"$json")" '[false,["~~五つ目~~"],"Issue #17 のチェックリストの項目「~~五つ目~~」にチェックを付ける"]'
  assert_equal "$(called edit)" 0
  run_pr --issue 17 --body-file "$TMP/body.md" --check "~~五つ目~~"
  assert_success
  assert_equal "$(called pr-create)" 0
  run grep -c '^- \[x\] ~~五つ目~~' "$TMP/issue-edit-body"
  assert_output 1
}

@test "--check の文の項目が無いか複数あれば、push せずに止まる" {
  setup_branch
  fake_issue_tasks
  run_pr --issue 17 --body-file "$TMP/body.md" --check 無い項目 --check 二つ目 --check コードブロックの中
  assert_failure 64
  assert_output --partial "--check の文の項目が Issue #17 のチェックリストに1つだけではありません（無いか、同じ文が複数あります）: コードブロックの中 / 無い項目"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
  set_issue_body "$(printf -- '- [ ] 同じ\n- [ ] 同じ\n- [ ] 別')"
  run_pr --issue 17 --body-file "$TMP/body.md" --check 同じ
  assert_failure 64
  assert_output --partial "1つだけではありません（無いか、同じ文が複数あります）: 同じ"
}

@test "確かめた後に上に項目が足されても、--check は同じ文の項目に付ける" {
  setup_branch
  # dry-run で確かめたときの本文
  set_issue_body "$(printf -- '- [ ] a\n- [ ] b')"
  run_pr --issue 17 --body-file "$TMP/body.md" --check b --dry-run
  assert_success
  # 承認を待つ間に、上に項目が足された
  set_issue_body "$(printf -- '- [ ] 新しい項目\n- [ ] a\n- [ ] b')"
  run_pr --issue 17 --body-file "$TMP/body.md" --check b
  assert_success
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '- [ ] 新しい項目\n- [ ] a\n- [x] b')"
}

@test "チェックを付けられなければ、もう一度実行すれば付けられると伝えて止まる" {
  setup_branch
  fake_issue_tasks
  FAKE_FAIL=edit run_pr --issue 17 --body-file "$TMP/body.md" --check 四つ目
  assert_failure 1
  assert_output --partial "PR #42 はできていますが、Issue #17 のチェックリストを変えられませんでした（もう一度実行すれば変えます）"
}

@test "--add-task で、最初の項目がある節の最後に、同じ改行で項目を足す（コードブロックの中の見出しでは節を終えない）" {
  setup_branch
  fake_issue_tasks
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task "~~判断を ADR に残す~~（不要）" --dry-run
  assert_success
  assert_equal "$(jq -c '[.added, .actions[-1]]' <<<"$json")" \
    '[["~~判断を ADR に残す~~（不要）"],"Issue #17 のチェックリストに項目「~~判断を ADR に残す~~（不要）」を足す"]'
  assert_equal "$(called edit)" 0
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task "~~判断を ADR に残す~~（不要）" --check 四つ目
  assert_success
  # 節（次の見出しまで。無ければ本文の最後まで）の最後の空でない行の後に \r\n で足し、チェックも同じ1回の書き換えで付ける。
  # ほかの行（コードブロックの中・最後の改行を含む）は変えない
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  printf '## やること\r\n- [ ] 一つ目 [ ] を含む\r\n- [x] 二つ目\r\n  * [ ] 三つ目（入れ子）\r\n1. [x] 四つ目\r\n- [ ] ~~五つ目~~\r\n\r\n```md\r\n- [ ] コードブロックの中\r\n```\r\n- [ ]\r\n- [] 項目ではない\r\n- [ ] ~~判断を ADR に残す~~（不要）\r\n' >"$TMP/expected"
  run cmp "$TMP/expected" "$TMP/issue-edit-body"
  assert_success
  assert_equal "$(called edit)" 1
}

@test "--add-task は、項目の下のコードブロックに空行や見出しの形の行があっても、コードブロックの後に足す" {
  setup_branch
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  set_issue_body "$(printf -- '## やること\n- [ ] a\n  ```sh\n  echo 1\n\n  # コメント\n  ```\n- [ ] b\n  ```\n  x\n\n  ```\n\n## 完了条件\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
  assert_success
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  # 直前の行（項目の中のコードブロックの閉じ）はリストの項目ではないので、空行を挟む（同じリストの続きとして表示される）
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n- [ ] a\n  ```sh\n  echo 1\n\n  # コメント\n  ```\n- [ ] b\n  ```\n  x\n\n  ```\n\n- [ ] NEW\n\n## 完了条件\n- [ ] c')"
}

@test "--add-task は、項目の間に空行がある並べ方でも、節の最後に足す" {
  setup_branch
  set_issue_body "$(printf -- '## やること\n- [ ] a\n\n- [ ] b\n\n## 完了条件\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
  assert_success
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n- [ ] a\n\n- [ ] b\n- [ ] NEW\n\n## 完了条件\n- [ ] c')"
}

@test "--add-task は、節の最初の項目の字下げに合わせ、次の見出しの手前に足す" {
  setup_branch
  set_issue_body "$(printf -- '## やること\n  - [ ] a\n    続きの行\n  - [ ] b\n## 完了条件\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task x --add-task y --add-task x
  assert_success
  assert_equal "$(jq -c .added <<<"$json")" '["x","y"]'
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n  - [ ] a\n    続きの行\n  - [ ] b\n  - [ ] x\n  - [ ] y\n## 完了条件\n- [ ] c')"
}

@test "--add-task は、文が同じ項目が既にあれば足さない（もう一度実行しても重ならない）" {
  setup_branch
  set_issue_body "$(printf -- '- [ ] a\n- [ ] ~~x~~（不要）')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task "~~x~~（不要）"
  assert_success
  assert_equal "$(jq -c .added <<<"$json")" '[]'
  assert_equal "$(called edit)" 0
}

@test "--add-task は、チェックリストが無ければ本文の最後に足し、最後の改行は残す" {
  setup_branch
  set_issue_body "$(printf '## 背景\r\n説明')"$'\r\n'
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task x
  assert_success
  assert_equal "$(od -c "$TMP/issue-edit-body" | tail -3)" "$(printf '## 背景\r\n説明\r\n- [ ] x\r\n' | od -c | tail -3)"
  set_issue_body ""
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task x
  assert_success
  assert_equal "$(cat "$TMP/issue-edit-body")" "- [ ] x"
}

@test "既にある PR に push するときも、--add-task の項目を足す" {
  setup_branch
  set_issue_body "$(printf -- '- [ ] a')"
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task b
  assert_success
  assert_equal "$(called pr-create)" 0
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '- [ ] a\n- [ ] b')"
}

@test "--add-task の文に改行（\n・\r）があるか、空白だけなら止まる" {
  setup_branch
  for t in "$(printf 'a\nb')" "$(printf 'a\rb')"; do
    run_pr --issue 17 --body-file "$TMP/body.md" --add-task "$t"
    assert_failure 64
    assert_output --partial "改行は使えません"
  done
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task "  "
  assert_failure 64
  assert_output --partial "--add-task の文が空です"
  assert_equal "$(called edit)" 0
}

@test "--add-task の文の前後の空白は外し、同じ文の項目が既にあるかも外した文で比べる（もう一度実行しても重ならない）" {
  setup_branch
  set_issue_body "$(printf -- '- [ ] a\n- [ ] ~~x~~（不要）')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task " ~~x~~（不要） " --add-task "y "
  assert_success
  assert_equal "$(jq -c .added <<<"$json")" '["y"]'
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '- [ ] a\n- [ ] ~~x~~（不要）\n- [ ] y')"
}

@test "長い囲みのコードブロックは、中の短い囲みや情報文字列付きの囲みでは閉じない" {
  setup_branch
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  set_issue_body "$(printf -- '- [ ] a\n````md\n```\n- [ ] 中1\n```\n````\n- [ ] b\n~~~~\n~~~ js\n- [ ] 中2\n~~~\n~~~~~\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["a","b","c"]'
}

@test "行頭がインラインのコード（3つのバッククォートで囲んだ語）の行は、コードブロックの始まりとみなさない" {
  setup_branch
  # shellcheck disable=SC2016 # ``` はインラインのコードで、展開させない
  set_issue_body "$(printf -- '```npm test``` が通ること\n- [ ] a\n- [ ] b')"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["a","b"]'
}

@test "リストの中で4つ以上字下げしたコードブロックの中の行は、項目とみなさない" {
  setup_branch
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  set_issue_body "$(printf -- '1. a\n   - [ ] b\n     ```\n     - [ ] 中\n     ```\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["b","c"]'
}

@test "複数行の HTML のコメントの中の行は、項目とみなさない" {
  setup_branch
  set_issue_body "$(printf -- '<!-- 例:\n- [ ] テストを足す\n-->\n- [ ] テストを足す\n- [ ] b <!-- 1行のコメント -->\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --check テストを足す
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["テストを足す","b <!-- 1行のコメント -->","c"]'
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '<!-- 例:\n- [ ] テストを足す\n-->\n- [x] テストを足す\n- [ ] b <!-- 1行のコメント -->\n- [ ] c')"
}

@test "行の途中の <!-- は、コメントの始まりとみなさない" {
  setup_branch
  # shellcheck disable=SC2016 # ` はインラインのコードで、展開させない
  set_issue_body "$(printf -- 'テンプレートの `<!--` を消す\n- [ ] a <!-- 補足\n- [ ] b')"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["a <!-- 補足","b"]'
}

@test "入れ子のリストの中で字下げした複数行の HTML のコメントの中の行も、項目とみなさない" {
  setup_branch
  set_issue_body "$(printf -- '- [ ] a\n  - [ ] b\n    <!--\n    - [ ] 隠れた項目\n    -->\n- [ ] c')"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.tasks[].text]' <<<"$json")" '["a","b","c"]'
}

@test "PR の番号を Issue として受け取らず、push も PR の作成もせずに止まる" {
  setup_branch
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "title": "PR", "state": "OPEN", "labels": [], "body": ""}' >"$FIX/issue-21.json"
  run_pr --issue 21 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
  assert_equal "$(called pr-create)" 0
}

@test "--issue 017 は 17 と同じに扱い、Issue #17 を読んで PR を作る" {
  setup_branch
  run_pr --issue 017 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.issue, .title]' <<<"$json")" '[17,"feat: 作業 17"]'
}

@test "確かめた後、読み直すまでの間に同じ項目が足されていたら、足さず、added にも出さない" {
  setup_branch
  set_issue_body "$(printf -- '- [ ] a')"
  # 読み直したときには、同じ項目が既にある
  jq -n --arg b "$(printf -- '- [ ] a\n- [ ] x')" '{body: $b}' >"$FIX/issue-17-body.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task x --add-task y
  assert_success
  assert_equal "$(jq -c .added <<<"$json")" '["y"]'
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '- [ ] a\n- [ ] x\n- [ ] y')"
}

@test "--add-task は、節の最後の行がリストの項目でなければ（HTML・区切り線など）、空行を挟んで足す" {
  setup_branch
  set_issue_body "$(printf -- '## やること\n- [ ] a\n<details>\n<summary>補足</summary>\n</details>\n## 完了条件')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
  assert_success
  assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n- [ ] a\n<details>\n<summary>補足</summary>\n</details>\n\n- [ ] NEW\n## 完了条件')"
  # $( ) は最後の改行を落とすので、本文は ---\r で終わる
  set_issue_body "$(printf -- '## やること\r\n- [ ] a\r\n---\r\n')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
  assert_success
  assert_equal "$(od -c "$TMP/issue-edit-body" | tail -4)" "$(printf -- '## やること\r\n- [ ] a\r\n---\r\n\r\n- [ ] NEW\r' | od -c | tail -4)"
}

@test "--add-task は、節の最後の行がリストの項目（- * + 1. 1)）なら空行を挟まず、それ以外（項目の続きの行・字下げした HTML・区切り線）なら挟む" {
  setup_branch
  for last in '* [ ] a' '+ [ ] a' '1. [ ] a' '2) [ ] a'; do
    set_issue_body "$(printf -- '## やること\n%b\n## 完了条件' "$last")"
    run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
    assert_success
    assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n%b\n- [ ] NEW\n## 完了条件' "$last")"
  done
  # 字下げした行は、項目の続きか HTML の塊かを行の形では見分けられないので、どれも空行を挟む
  # （間の空いたリストになっても、チェックボックスは表示される）
  for hr in '* * *' '- - -' '___' '  補足の続きの行' '  </div>'; do
    set_issue_body "$(printf -- '## やること\n- [ ] a\n%s\n## 完了条件' "$hr")"
    run_pr --issue 17 --body-file "$TMP/body.md" --add-task NEW
    assert_success
    assert_equal "$(cat "$TMP/issue-edit-body")" "$(printf -- '## やること\n- [ ] a\n%s\n\n- [ ] NEW\n## 完了条件' "$hr")"
  done
}

@test "本文が長くても（引数の長さの上限を超える大きさでも）、破壊的変更の確かめと Closes の付け足しをして PR を作る" {
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  # 日本語は UTF-8 で1文字3バイトなので、6万文字で 180KB ほどになる（Linux の引数1つの上限は 128KiB）
  { printf '## 概要\n'; head -c 60000 /dev/zero | tr '\0' x | sed 's/x/あ/g'; printf '\n\nBREAKING CHANGE: 設定を直す\n'; } >"$TMP/body.md"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -r .body <<<"$json" | tail -n 3)" "$(printf 'BREAKING CHANGE: 設定を直す\n\nCloses #17')"
}

@test "--add-task は、CRLF の本文の改行の無い最後の行の後に足しても、改行を CRLF にそろえる（本文の最後には改行を足さない）" {
  # 改行を足す位置の行だけで決めていたので、改行の無い最後の行の後に LF で足し、改行が混ざっていた（issue-depend.sh と同じ原因）
  setup_branch
  set_issue_body "$(printf '## やること\r\n- [ ] a')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task b
  assert_success
  assert_equal "$(od -c "$TMP/issue-edit-body" | tr -s ' ' | tr -d '\n')" "$(printf '## やること\r\n- [ ] a\r\n- [ ] b' | od -c | tr -s ' ' | tr -d '\n')"
  set_issue_body "$(printf '## 背景\r\n説明')"
  run_pr --issue 17 --body-file "$TMP/body.md" --add-task x
  assert_success
  assert_equal "$(od -c "$TMP/issue-edit-body" | tr -s ' ' | tr -d '\n')" "$(printf '## 背景\r\n説明\r\n- [ ] x' | od -c | tr -s ' ' | tr -d '\n')"
}

@test "未コミットの変更を調べる git status が失敗したら、変更が無いとみなさず、push せずに止まる" {
  setup_branch
  fake_issue 17 '["feat"]'
  make_failing_git
  PATH="$TMP/failgit:$PATH" FAIL_GIT='* status --porcelain *' run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "未コミットの変更を調べられませんでした"
  run git rev-parse -q --verify refs/remotes/origin/feat/17-x
  assert_failure
}

@test "type ラベルは大文字と小文字を区別せずに照合し、タイトルの type は設定の書き方にする（Feat と feat は1つと数える）" {
  setup_branch
  for labels in '["Feat"]' '["Feat", "feat"]'; do
    fake_issue 17 "$labels"
    run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
    assert_success
    assert_equal "$(jq -r .title <<<"$json")" "feat: 作業 17"
  done
}

@test "既にある PR を使うときは、--draft や pr.draft があっても下書きかどうかを変えず、出力の draft はその PR の今の状態にする" {
  setup_branch
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "isDraft": false}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --draft
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .draft]' <<<"$json")" '[false,7,false]'
  assert_equal "$(called pr-create)" 0
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "isDraft": true}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -r .draft <<<"$json")" true
}

@test "既にある下書きの PR に --no-draft を付けても、下書きのままにして gh pr ready を呼ばない" {
  setup_branch
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "isDraft": true}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --no-draft
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .draft]' <<<"$json")" '[false,7,true]'
  assert_equal "$(called pr-create)" 0
  assert_equal "$(called pr-ready)" 0
}

@test "PR のマージ先（新しく作る PR では base_branch）へのマージがマージキューを通すかを merge_queue に出す（PR を出した後の案内を切り替えるため。dry-run でも読む）" {
  setup_branch
  fake_issue 17 '["feat"]'
  # ページごとの配列を並べたもの（--paginate）。キューのルールは2ページ目にある
  printf '%s\n' '[{"type": "pull_request"}]' '[{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]' >"$FIX/rules.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq .merge_queue <<<"$json")" true
  # base_branch のルールを、ブランチ名を URL に使える形にして読む
  assert_equal "$(args api-rules)" 'repos/{owner}/{repo}/rules/branches/main?per_page=100'
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .merge_queue]' <<<"$json")" '[true,true]'
}

@test "base_branch にマージキューのルールが無ければ merge_queue は false、ルールを読めなければ null にし、PR は作る" {
  setup_branch
  fake_issue 17 '["feat"]'
  echo '[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true}}]' >"$FIX/rules.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq .merge_queue <<<"$json")" false
  FAKE_FAIL=api-rules run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .merge_queue]' <<<"$json")" '[true,null]'
}

@test "既にある PR を使うときは、設定の base_branch ではなく、その PR のマージ先でマージキューを通すかを見る（#178）" {
  setup_branch
  fake_issue 17 '["feat"]'
  # 設定の base_branch（main）はキューを通すが、PR のマージ先（release/v1）は通さない
  mkdir -p "$FIX/rules/release"
  echo '[{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]' >"$FIX/rules/main.json"
  echo '[{"type": "pull_request"}]' >"$FIX/rules/release/v1.json"
  push_base release/v1
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.created, .base, .pr_base, .merge_queue]' <<<"$json")" '[false,"main","release/v1",false]'
  assert_equal "$(args api-rules)" 'repos/{owner}/{repo}/rules/branches/release%2Fv1?per_page=100'
  # PR が無ければ、作る PR のマージ先（設定の base_branch）で見る
  rm "$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.created, .base, .pr_base, .merge_queue]' <<<"$json")" '[true,"main","main",true]'
}

@test "既にある PR に push するとき（dry-run でない）も、pr_base とマージキューの判定は、その PR のマージ先にする（#178）" {
  setup_branch
  fake_issue 17 '["feat"]'
  mkdir -p "$FIX/rules/release"
  echo '[{"type": "pull_request"}]' >"$FIX/rules/main.json"
  echo '[{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]' >"$FIX/rules/release/v1.json"
  push_base release/v1
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .base, .pr_base, .merge_queue]' <<<"$json")" '[false,7,"main","release/v1",true]'
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
  assert_equal "$(called pr-create)" 0
  assert_equal "$(args api-rules)" 'repos/{owner}/{repo}/rules/branches/release%2Fv1?per_page=100'
}

@test "既にある PR のマージ先が設定の base_branch と違えば、push の前の確認は PR のマージ先で見る（バックポートで main に同じコミットがあっても push する。#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  push_base release/v1
  # ブランチのコミットが、設定の base_branch（main）には既にある（main から release/v1 へのバックポートなど）
  git push -q origin feat/17-x:main
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .pr_base]' <<<"$json")" '[false,7,"release/v1"]'
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "feat/17-x を origin に push する（origin/release/v1 より 1 個先のコミット）"
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
}

@test "既にある PR のマージ先に無いコミットが無ければ、設定の base_branch より先行していても push しない（#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  # PR のマージ先（release/v1）はブランチのコミットを含み、設定の base_branch（main）は含まない
  git push -q origin feat/17-x:refs/heads/release/v1
  git fetch -q origin
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "origin/release/v1 に無いコミットがありません"
  run git ls-remote --heads origin feat/17-x
  assert_output ""
}

@test "dry-run では fetch せず、手元に origin/<マージ先> が無ければ、止めずに先行の確認を飛ばしたことを警告と出力で伝える（#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  # origin に release/v1 を作るが、手元では取得しない（origin/release/v1 が手元に無い）
  git push -q origin main:refs/heads/release/v1
  git update-ref -d refs/remotes/origin/release/v1
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/pr-create.sh' --issue 17 --body-file '$TMP/body.md' --dry-run 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.dry_run, .pr_base, .ahead]' <<<"$output")" '[true,"release/v1",null]'
  assert_equal "$(jq -r '.actions[0]' <<<"$output")" "feat/17-x を origin に push する（origin/release/v1 が手元に無いので、先行するコミットはまだ確かめていない。push の前に取得して確かめる）"
  grep -qF "手元に origin/release/v1 が無いので、dry-run では origin/release/v1 に無いコミットがあるかを確かめていません" "$TMP/err" || fail "$(cat "$TMP/err")"
  # dry-run は fetch しない（手元の remote-tracking ref を変えない）
  run git rev-parse -q --verify refs/remotes/origin/release/v1
  assert_failure
  run git ls-remote --heads origin feat/17-x
  assert_output ""
}

@test "dry-run では fetch せず、手元の origin/<マージ先> で先行を確かめる（origin に届かなくても止まらない。#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  git fetch -q origin
  git remote set-url origin "$TMP/no-such.git"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/pr-create.sh' --issue 17 --body-file '$TMP/body.md' --dry-run 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.pr_base, .ahead]' <<<"$output")" '["main",1]'
  assert_equal "$(cat "$TMP/err")" ""
}

@test "gh pr list が JSON でない応答を返したら、PR を作らずに止まる（既にある PR を見落として二重に作らない。#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  echo 'not json' >"$FIX/pr-list.raw"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure
  assert_output --partial "feat/17-x の PR を取得できませんでした（gh の応答を JSON として読めません）"
  assert_equal "$(called pr-create)" 0
  run git ls-remote --heads origin feat/17-x
  assert_output ""
}

@test "既にある PR のマージ先を取得できなければ、push せずに終了コード 2 で止まる（#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  # origin に release/v1 が無い
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "origin/release/v1 を取得できませんでした"
  run git ls-remote --heads origin feat/17-x
  assert_output ""
}

@test "dry-run の push の案内は、取得していない手元の origin/<マージ先> で数えた値だと書く（#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  git fetch -q origin
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "feat/17-x を origin に push する（手元の origin/main（取得していない）より 1 個先のコミット。本番は取得し直して確かめる）"
}

@test "既にある PR のマージ先を使えない（ブランチ名として使えない・マージ先の違う PR が複数ある）なら、push せずに終了コード 2 で止まる（#284）" {
  setup_branch
  fake_issue 17 '["feat"]'
  for b in -x +x HEAD; do
    jq -nc --arg b "$b" '[{number: 7, url: "https://github.com/me/demo/pull/7", isCrossRepository: false, baseRefName: $b}]' >"$FIX/pr-list.json"
    run_pr --issue 17 --body-file "$TMP/body.md"
    assert_failure 2
    assert_output --partial "PR のマージ先（\"${b}\"）は git のブランチ名として使えません。PR のマージ先を決められないので、push しません"
  done
  echo '[{"number": 7, "url": "u7", "isCrossRepository": false, "baseRefName": "release/v1"}, {"number": 8, "url": "u8", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_failure 2
  assert_output --partial "マージ先の違う開いた PR が複数あります"
  run git ls-remote --heads origin feat/17-x
  assert_output ""
  assert_equal "$(called pr-create)" 0
}

@test "既にある PR の応答にマージ先（baseRefName）が無いか空なら、pr_base とマージキューの判定は設定の base_branch にする（#178）" {
  setup_branch
  fake_issue 17 '["feat"]'
  mkdir -p "$FIX/rules"
  echo '[{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]' >"$FIX/rules/main.json"
  for pr in '{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false}' \
    '{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": ""}'; do
    echo "[$pr]" >"$FIX/pr-list.json"
    : >"$CALLS"
    run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
    assert_success
    assert_equal "$(jq -c '[.created, .base, .pr_base, .merge_queue]' <<<"$json")" '[false,"main","main",true]'
    assert_equal "$(args api-rules)" 'repos/{owner}/{repo}/rules/branches/main?per_page=100'
  done
}

@test "日本語を含むマージ先（feat/日本語）でも、そのブランチのルールでマージキューを通すかを見る（#178）" {
  setup_branch
  fake_issue 17 '["feat"]'
  mkdir -p "$FIX/rules/feat"
  echo '[{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]' >"$FIX/rules/feat/日本語.json"
  push_base feat/日本語
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "feat/日本語"}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.pr_base, .merge_queue]' <<<"$json")" '["feat/日本語",true]'
  assert_equal "$(args api-rules)" 'repos/{owner}/{repo}/rules/branches/feat%2F%E6%97%A5%E6%9C%AC%E8%AA%9E?per_page=100'
}

@test "Issue のチェックリストが長くても（引数の長さの上限の 128 KiB を超えても）、--check と --add-task で本文を直して PR を作る" {
  setup_branch
  long_text "$TMP/long"
  set_issue_body "$(printf -- '## やること\n- [ ] 一つ目\n- [ ] %s\n' "$(cat "$TMP/long")")"
  run_pr --issue 17 --body-file "$TMP/body.md" --check 一つ目 --add-task 足す項目
  assert_success
  assert_equal "$(jq -c '[.checked, .added, (.tasks | length)]' <<<"$json")" '[["一つ目"],["足す項目"],2]'
  assert_equal "$(head -n 2 "$TMP/issue-edit-body")" "$(printf -- '## やること\n- [x] 一つ目')"
  assert_equal "$(tail -n 1 "$TMP/issue-edit-body")" "- [ ] 足す項目"
}

@test "本文に絵文字があっても（128 KiB を超える1行でも）、出力の本文は PR に渡した本文と同じにする" {
  # 標準入力の jq -R は、4096 バイトを超える1行の、読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊すので、
  # 出力の本文は --rawfile で読む（本文を読む他の jq も、同じ原因で直した。下の「4096 バイトを超える1行でも」のテスト）
  setup_branch
  fake_issue 17 '["feat"]'
  { printf '## 概要\n'; for _ in $(seq 1 30000); do printf 'ab😀'; done; printf '\n'; } >"$TMP/body.md"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -r .body <<<"$json")" "$(cat "$TMP/pr-body")"
}

@test "--check と --add-task を多く指定しても（項目の合計が引数の長さの上限の 128 KiB を超えても）、本文を直して PR を作る" {
  setup_branch
  pad="$(printf 'x%.0s' $(seq 1 240))"
  args=()
  body='## やること'
  for i in $(seq 1 600); do
    body="${body}
- [ ] c${i}-${pad}"
    args+=(--check "c${i}-${pad}" --add-task "a${i}-${pad}")
  done
  set_issue_body "$body"
  run_pr --issue 17 --body-file "$TMP/body.md" "${args[@]}"
  assert_success
  assert_equal "$(jq -c '[(.checked | length), (.added | length), .added[0], (.actions | map(select(test("チェックリスト"))) | length)]' <<<"$json")" \
    "[600,600,\"a1-${pad}\",2]"
  assert_equal "$(grep -c '^- \[x\] c' "$TMP/issue-edit-body")" 600
  assert_equal "$(grep -c '^- \[ \] a' "$TMP/issue-edit-body")" 600
}

@test "本文に絵文字があっても（4096 バイトを超える1行でも）壊さずに、破壊的変更の確かめと Closes の付け足しをして PR を作る" {
  # 標準入力の jq -Rs・-Rrs は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  setup_branch
  fake_issue 17 '["feat", "breaking"]'
  { printf '## 概要\n'; emoji_text 3000; printf '\n\nBREAKING CHANGE: 設定を直す\n'; } >"$TMP/body.md"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -r .body <<<"$json")" "$({ cat "$TMP/body.md"; printf '\nCloses #17'; })"
}
