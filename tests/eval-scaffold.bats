#!/usr/bin/env bats
# eval のケースの準備の共通処理（plugins/dev-workflow/evals/lib/scaffold.bash）と、各ケースの準備のスクリプトのテスト

load test_helper

EVALS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/evals"

setup() {
  test_helper_setup
  WS="$TMP/ws"
  mkdir -p "$WS"
  CDPATH='' cd "$WS" || return 1
  # 準備のスクリプトが作るリポジトリで、偽の gh を使えるようにする（tests/eval/run.sh と同じ）
  export PATH="$BATS_TEST_DIRNAME/eval/bin:$PATH"
}

# scaffold.bash を読み込んで、引数の処理を作業用のディレクトリで実行する
scaffold() {
  run "${TEST_BASH:-bash}" -c ". \"$EVALS/lib/scaffold.bash\" && $1"
}

@test "eval_repo は、導入済みの git リポジトリを作り、origin/main を作る" {
  scaffold eval_repo
  assert_success
  assert_equal "$(git branch --show-current)" main
  assert_equal "$(cat .claude/dev-workflow/config.json)" '{}'
  git rev-parse --verify -q origin/main
  assert_equal "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  # 偽の gh の表と bare のリポジトリは、git の対象にしない
  assert_equal "$(git status --porcelain)" ""
}

@test "eval_repo は、PATH の gh が偽物でなければ、何も作らずに失敗する（run.sh を使わずに動かしたとき）" {
  mkdir -p "$TMP/realbin"
  printf '#!/bin/sh\necho real\n' >"$TMP/realbin/gh"
  chmod +x "$TMP/realbin/gh"
  PATH="$TMP/realbin:$PATH" scaffold eval_repo
  assert_failure
  assert_output --partial "tests/eval/run.sh"
  [ ! -e .git ]
}

@test "eval_repo の origin は、ブランチの削除と fast-forward でない push を拒む" {
  scaffold eval_repo
  assert_success
  run git push -q origin --delete main
  assert_failure
  git commit -q --allow-empty -m more
  git push -q origin main
  git reset -q --hard HEAD^
  run git push -q --force origin main
  assert_failure
}

@test "eval_repo に渡した設定を config.json に書く" {
  scaffold "eval_repo '{\"project\": {\"owner\": \"me\", \"number\": 4}}'"
  assert_success
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":4}}'
}

@test "eval_repo の後、gh repo view と gh api user に答える" {
  scaffold eval_repo
  assert_success
  assert_equal "$(gh repo view --json nameWithOwner -q .nameWithOwner)" "me/demo"
  assert_equal "$(gh api user -q .login)" "me"
}

@test "fake_issue の Issue を gh issue view で読める" {
  scaffold "eval_repo && fake_issue 7 'タイトル' fix '## やること'"
  assert_success
  run gh issue view 7 --json number,title,body,labels,state
  assert_success
  assert_equal "$(jq -c '[.number, .title, .labels[0].name, .state, .body]' <<<"$output")" '[7,"タイトル","fix","OPEN","## やること"]'
}

@test "fake_issue の Issue は、番号・#番号・URL のどれで指定しても、オプションの前後どちらでも読める" {
  scaffold "eval_repo && fake_issue 7 'タイトル' fix '## やること' && fake_issue 70 '別' feat ''"
  assert_success
  local args
  for args in "7" "#7" "https://github.com/me/demo/issues/7" "7 --json title" "--json title 7" "-R me/demo 7 --json title"; do
    # shellcheck disable=SC2086 # 引数に分けるため、クォートしない
    run gh issue view $args
    assert_success
    assert_equal "$(jq -r .title <<<"$output")" "タイトル"
  done
}

@test "fake_gh_defaults の後、起票や PR の作成に成功したように答え、書き込みとして記録する" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  assert_equal "$(gh issue create --title t)" "https://github.com/me/demo/issues/99"
  assert_equal "$(gh pr close 2 && echo ok)" ok
  assert_equal "$(gh api -X POST repos/me/demo/issues/99/dependencies/blocked_by -F issue_id=1)" '{}'
  assert_equal "$(wc -l <.fake-gh/writes | tr -d ' ')" 3
}

@test "fake_gh_defaults の後、よく使う読むだけの呼び出しに答え、書き込みとして数えない" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  gh pr status >/dev/null
  gh search issues login >/dev/null
  gh project field-list 4 --owner me --format json >/dev/null
  gh issue list --state open --json number >/dev/null
  assert_equal "$(wc -l <.fake-gh/writes | tr -d ' ')" 0
}

@test "fake_gh_defaults より前にケースで足した行が、既定の行より先に当たる" {
  scaffold "eval_repo && fake_gh_read 'issue list*' '[{\"number\": 5}]' && fake_gh_defaults"
  assert_success
  assert_equal "$(gh issue list --json number -q '.[0].number')" 5
}

@test "fake_gh_defaults の後、issue-create.sh が起票まで進み、書き込みとして記録される" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  printf '本文' >"$TMP/body.md"
  # Project が未設定という警告（標準エラー）は見ない
  run "${TEST_BASH:-bash}" -c "\"\$0\" \"$SCRIPTS/issue-create.sh\" --title t --type feat --body-file \"$TMP/body.md\" 2>/dev/null" "${TEST_BASH:-bash}"
  assert_success
  assert_equal "$(jq -r .number <<<"$output")" 99
  run grep -c '^api -X POST repos/me/demo/issues ' .fake-gh/writes
  assert_output 1
}

@test "各ケースの準備のスクリプトが成功する" {
  local f n=0
  for f in "$EVALS"/*/fixture.sh; do
    rm -rf "$WS" && mkdir -p "$WS" && CDPATH='' cd "$WS"
    run "${TEST_BASH:-bash}" "$f"
    assert_success
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

@test "fix のケースの準備の後、task-start はどの短い説明でもルートを使い回す（別のワークツリーを作らない）" {
  run "${TEST_BASH:-bash}" "$EVALS/fix-same-cause-elsewhere/fixture.sh"
  assert_success
  local slug
  for slug in "quote the name variable" "Fix/Greet Name" "x" "fix name 2 名前"; do
    # Project が未設定という警告（標準エラー）は見ない
    run "${TEST_BASH:-bash}" -c "\"\$0\" \"$SCRIPTS/task-start.sh\" --issue 1 --slug \"\$1\" 2>/dev/null" "${TEST_BASH:-bash}" "$slug"
    assert_success
    assert_equal "$(jq -r .worktree <<<"$output")" "$WS"
    assert_equal "$(jq -r .created.branch <<<"$output")" false
  done
  assert_equal "$(git worktree list | wc -l | tr -d ' ')" 1
}

# 使い方: grader_pattern <ケース> <grader の名前> → grader の pattern（シングルクォートで囲んだ値）
grader_pattern() { sed -n "s/^pattern: '\\(.*\\)'\$/\\1/p" "$EVALS/$1/graders/$2.md"; }

# 改行をまたぐ pattern を、grader と同じ m（行ごとの ^・$）で、記録全体に照らす
# 使い方: grader_matches <ケース> <grader の名前> <記録のパス>
grader_matches() {
  perl -0777 -e 'my $pattern = shift; exit((<> =~ /$pattern/m) ? 0 : 1)' "$(grader_pattern "$1" "$2")" "$3"
}

@test "task-auto の無効のケースの準備の後、auto-check.sh は disabled を返し、何も書き込まない" {
  run "${TEST_BASH:-bash}" "$EVALS/task-auto-disabled-does-nothing/fixture.sh"
  assert_success
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-check.sh" --issue 2
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" disabled
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
}

@test "task-auto の止まるケースの準備の後、auto-check.sh は hold を返し、auto-hold.sh の書き込みが grader に当たる" {
  run "${TEST_BASH:-bash}" "$EVALS/task-auto-stops-on-breaking/fixture.sh"
  assert_success
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-check.sh" --issue '#2'
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["hold",["breaking ラベルが付いています（破壊的変更と移行のしかたは、人が決めます）"]]'
  [ ! -s .fake-gh/writes ] || fail "auto-check.sh が書き込みました: $(cat .fake-gh/writes)"
  printf '止まった理由\n' >"$TMP/reason.md"
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-hold.sh" --issue 2 --run-id eval1 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -c '[.commented, .status.from, .status.to]' <<<"$output")" '[true,"Todo","On Hold"]'
  local c=task-auto-stops-on-breaking
  grep -qE "$(grader_pattern $c comments-on-issue)" .fake-gh/writes || fail "comments-on-issue に当たりません: $(cat .fake-gh/writes)"
  grep -qE "$(grader_pattern $c moves-to-hold)" .fake-gh/writes || fail "moves-to-hold に当たりません: $(cat .fake-gh/writes)"
  if grep -qE "$(grader_pattern $c no-other-writes)" .fake-gh/writes; then fail "no-other-writes に当たります: $(cat .fake-gh/writes)"; fi
}

@test "gh-pr-check の diff の外の指摘のケースの準備の後、pr-feedback.sh はスレッド 0 件で needs_attention を true にし、何も書き込まない" {
  run "${TEST_BASH:-bash}" "$EVALS/gh-pr-check-outside-diff/fixture.sh"
  assert_success
  run "${TEST_BASH:-bash}" "$SCRIPTS/pr-feedback.sh" --pr 5
  assert_success
  assert_equal "$(jq -c '[.counts.threads, .counts.unanswered, .needs_attention, .checks.state, .pr.merge_state]' <<<"$output")" \
    '[0,{"threads":0,"reviews":1,"comments":0},true,"success","CLEAN"]'
  run "${TEST_BASH:-bash}" "$SCRIPTS/pr-feedback.sh"
  assert_success
  assert_equal "$(jq -c .needs_attention <<<"$output")" true
  # gh-pr-check の手順1が使う pr-watch.sh も、準備の表で答えられ、指摘があるので一覧へ進む（respond が true）
  run "${TEST_BASH:-bash}" "$SCRIPTS/pr-watch.sh" --pr 5
  assert_success
  assert_equal "$(jq -c '[.action, .reasons, .respond]' <<<"$output")" '["act",["unanswered_reviews"],true]'
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
}

@test "task-auto の範囲外の指摘のケースの準備の後、着手からレビュー・起票・PR の作成まで、スクリプトが偽の gh で進み、grader に当たる" {
  local c=task-auto-files-out-of-scope
  run "${TEST_BASH:-bash}" "$EVALS/$c/fixture.sh"
  assert_success
  # 範囲外の指摘のもと（前からある誤字）
  grep -qF 'Helo, %s!' bin/greet.sh || fail "bin/greet.sh に誤字がありません"
  # 観点の担当者は差分（git diff）を読むので、差分に無い bin/greet.sh も Read で読むよう、ファイル名を挙げて書く
  # shellcheck disable=SC2016 # バッククォートは観点の本文の文字で、展開させない
  grep -qF '`bin/greet.sh`' .claude/dev-workflow/review/typo.md || fail "誤字の観点に bin/greet.sh がありません"
  grep -qF '差分に無くても必ず Read で読む' .claude/dev-workflow/review/typo.md || fail "誤字の観点に、Read で読むことがありません"
  run_script auto-check.sh --issue 2
  assert_success
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["proceed",null]'
  run_script next-tasks.sh --issue 2
  assert_success
  assert_equal "$(jq -r .issue.overlap <<<"$output")" none
  [ ! -s .fake-gh/writes ] || fail "着手の前に書き込みました: $(cat .fake-gh/writes)"
  run_script task-start.sh --issue 2 --slug add-farewell
  assert_success
  assert_equal "$(jq -c '[.status.to, .status.warnings]' <<<"$output")" '["In Progress",[]]'
  local wt
  wt="$(jq -r .worktree <<<"$output")"
  # 作業役の実装の代わり
  # shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "Goodbye, %%s!\\n" "$1"\n' >"$wt/bin/farewell.sh"
  git -C "$wt" add bin/farewell.sh
  git -C "$wt" commit -q -m "feat: 別れの挨拶のスクリプトを足す"
  CDPATH='' cd "$wt"
  # レビューは、リポジトリの誤字の観点だけを使い、1周で終える
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[[.perspectives[].name], .context.max_rounds, .context.issue]' <<<"$output")" '[["typo"],1,2]'
  printf '## 背景\n#2 の自動のレビューで見つかった指摘\n' >"$TMP/issue.md"
  run_script issue-create.sh --title "greet.sh の挨拶の誤字を直す" --type fix --body-file "$TMP/issue.md"
  assert_success
  assert_equal "$(jq -r .number <<<"$output")" 99
  printf '## 概要\n別れの挨拶\n\nCloses #2\n' >"$TMP/pr.md"
  run_script pr-create.sh --issue 2 --body-file "$TMP/pr.md" --no-draft
  assert_success
  assert_equal "$(jq -c '[.created, .draft, .pr.number]' <<<"$output")" '[true,false,98]'
  CDPATH='' cd "$WS"
  grader_matches "$c" files-issue .fake-gh/writes || fail "files-issue に当たりません: $(cat .fake-gh/writes)"
  grader_matches "$c" opens-pr .fake-gh/writes || fail "opens-pr に当たりません: $(cat .fake-gh/writes)"
  # PR の本文は、偽の gh が残したものを pr-body-lists-filed が採点する
  grep -qF 'Closes #2' .fake-gh/pr-body || fail "PR の本文が .fake-gh/pr-body に残っていません"
}

@test "task-auto の下書きの PR のケースの準備の後、resume で着手し、既にある下書きの PR に push するだけで、新しい PR も ready も書き込まない" {
  local c=task-auto-keeps-existing-draft
  run "${TEST_BASH:-bash}" "$EVALS/$c/fixture.sh"
  assert_success
  # 手元のブランチには、push していないコミットが1つある（リモートは1つ前）
  assert_equal "$(git rev-parse feat/2-add-farewell~1)" "$(git rev-parse origin/feat/2-add-farewell)"
  # push の前は、このブランチの参照のファイルが無い（packed-refs の中にだけある）
  [ ! -e .fake-remote.git/refs/heads/feat/2-add-farewell ] || fail "push の前に、参照のファイルがあります"
  run_script auto-check.sh --issue 2
  assert_success
  assert_equal "$(jq -c '[.action, .resume.branch]' <<<"$output")" '["proceed","feat/2-add-farewell"]'
  run_script task-start.sh --issue 2 --branch feat/2-add-farewell
  assert_success
  local wt
  wt="$(jq -r .worktree <<<"$output")"
  [ -f "$wt/bin/farewell.sh" ] || fail "前の作業のコミットから続けていません"
  CDPATH='' cd "$wt"
  printf '## 概要\n別れの挨拶\n\nCloses #2\n' >"$TMP/pr.md"
  # push の前の時刻を印にして、run 後に作られたリモートのファイルの一覧を作る（eval の files と同じ見方）
  : >"$TMP/before"
  sleep 1
  run_script pr-create.sh --issue 2 --body-file "$TMP/pr.md" --no-draft
  assert_success
  assert_equal "$(jq -c '[.created, .draft, .pr.number]' <<<"$output")" '[false,true,98]'
  CDPATH='' cd "$WS"
  # 既にある PR のブランチに push し、リモートが手元のブランチに追い付いた
  assert_equal "$(git rev-parse feat/2-add-farewell)" "$(git -C .fake-remote.git rev-parse feat/2-add-farewell)"
  find .fake-remote.git -type f -newer "$TMP/before" >"$TMP/files"
  grader_matches "$c" pushes-branch "$TMP/files" || fail "pushes-branch に当たりません: $(cat "$TMP/files")"
  # 既にある PR には push するだけ。新しい PR も、ready にする書き込みも無い
  for g in no-ready no-new-pr; do
    if grader_matches "$c" "$g" .fake-gh/writes; then fail "$g に当たります: $(cat .fake-gh/writes)"; fi
  done
}

@test "task-auto の下書きの PR のケースの pushes-branch は、push していない（リモートにファイルが作られていない）記録には当たらない" {
  local c=task-auto-keeps-existing-draft
  : >"$TMP/files"
  if grader_matches "$c" pushes-branch "$TMP/files"; then fail "空の一覧に pushes-branch が当たります"; fi
  # 別のブランチ・タグへの push や、objects だけが増えた記録には当たらない
  printf '.fake-remote.git/objects/ab/cdef\n.fake-remote.git/refs/heads/other\n.fake-remote.git/refs/tags/feat/2-add-farewell\n.fake-remote.git/refs/heads/feat/2-add-farewell-2\n' >"$TMP/files"
  if grader_matches "$c" pushes-branch "$TMP/files"; then fail "別の参照の記録に pushes-branch が当たります"; fi
  printf '.fake-remote.git/objects/ab/cdef\n.fake-remote.git/refs/heads/feat/2-add-farewell\n' >"$TMP/files"
  grader_matches "$c" pushes-branch "$TMP/files" || fail "push の記録に pushes-branch が当たりません"
}

@test "task-auto の下書きの PR のケースの no-ready は、PR を ready にする書き込みに当たる" {
  local c=task-auto-keeps-existing-draft
  local w
  for w in 'pr ready 98' 'pr edit 98 --ready' 'api graphql markPullRequestReadyForReview {"id":"x"}' 'api -X POST repos/me/demo/pulls/98/ready_for_review'; do
    printf 'issue edit 2 --add-assignee @me\n%s\n' "$w" >"$TMP/writes"
    grader_matches "$c" no-ready "$TMP/writes" || fail "no-ready が「${w}」に当たりません"
  done
  printf 'issue edit 2 --add-assignee @me\napi -X PUT repos/me/demo/issues/2\n' >"$TMP/writes"
  if grader_matches "$c" no-ready "$TMP/writes"; then fail "ready にしていない記録に no-ready が当たります"; fi
}

@test "task-auto の範囲外の指摘のケースの grader は、起票しないで PR を作っただけの記録には当たらない" {
  local c=task-auto-files-out-of-scope
  printf 'issue edit 2 --add-assignee @me\npr create --base main --head feat/2-add-farewell\nissue edit 2 --body-file -\n' >"$TMP/writes"
  if grader_matches "$c" files-issue "$TMP/writes"; then fail "起票していない記録に files-issue が当たります"; fi
  # opens-pr は PR を作ったかだけを見る（起票し忘れは files-issue だけで落とし、どちらで失敗したかを見分ける）
  grader_matches "$c" opens-pr "$TMP/writes" || fail "PR を作った記録に opens-pr が当たりません"
}

@test "task-auto の範囲外の指摘のケースの files-issue は、PR を作ってから起票した記録には当たらない" {
  local c=task-auto-files-out-of-scope
  printf 'pr create --base main --head feat/2-add-farewell\napi -X POST repos/me/demo/issues --input -\n' >"$TMP/writes"
  if grader_matches "$c" files-issue "$TMP/writes"; then fail "逆順の記録に files-issue が当たります"; fi
}

@test "task-auto の範囲外の指摘のケースの files-issue は、issue-create.sh の起票に当たり、gh issue create やほかの読み取り・書き込みには当たらない" {
  local c=task-auto-files-out-of-scope
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  # 当たる：手順5のとおり issue-create.sh で起票した記録（偽の gh で実際に動かす）
  printf '本文' >"$TMP/body.md"
  # shellcheck disable=SC2016 # 引数は内側の bash が展開する（空白を含むパスでも割れないように、引数で渡す）
  run "${TEST_BASH:-bash}" -c '"$0" "$1" --title t --type fix --body-file "$2" 2>/dev/null' "${TEST_BASH:-bash}" "$SCRIPTS/issue-create.sh" "$TMP/body.md"
  assert_success
  assert_equal "$(jq -r .number <<<"$output")" 99
  if grader_matches "$c" files-issue .fake-gh/writes; then fail "PR の無い記録に files-issue が当たります"; fi
  if grader_matches "$c" opens-pr .fake-gh/writes; then fail "PR の無い記録に opens-pr が当たります"; fi
  printf 'pr create --base main --head feat/2-add-farewell\n' >>.fake-gh/writes
  grader_matches "$c" files-issue .fake-gh/writes || fail "issue-create.sh の記録に files-issue が当たりません: $(cat .fake-gh/writes)"
  # 当たらない：手順5のとおりでない gh issue create・GET に本文を付けた読み取り・本文の値にパスを含むコメント・一覧の読み取り・
  # 番号付きのパスへの書き込み
  : >.fake-gh/writes
  gh issue create --title t --body b >/dev/null 2>&1 || true
  gh api -X GET repos/me/demo/issues -f state=open >/dev/null 2>&1 || true
  gh issue comment 2 --body "api -X POST repos/me/demo/issues --input - で起票する" >/dev/null 2>&1 || true
  gh api repos/me/demo/issues/2/comments -f "body=api -X POST repos/me/demo/issues --input -" >/dev/null 2>&1 || true
  gh api repos/me/demo/issues >/dev/null 2>&1 || true
  gh api -X POST repos/me/demo/issues/99/sub_issues -F sub_issue_id=1 >/dev/null 2>&1 || true
  gh api repos/me/demo/issues/2/parent >/dev/null 2>&1 || true
  [ "$(wc -l <.fake-gh/writes | tr -d ' ')" -ge 7 ] || fail "当たらない例が記録されていません: $(cat .fake-gh/writes)"
  printf 'pr create --base main --head feat/2-add-farewell\n' >>.fake-gh/writes
  if grader_matches "$c" files-issue .fake-gh/writes; then fail "当たらない例に files-issue が当たります"; fi
}

@test "task-auto-sequence の上限のケースの準備の後、記録は上限に達し、chain-decide.sh は stop（limit）、後片付けは通り、grader に当たる" {
  local c=task-auto-sequence-stops-at-limit
  run "${TEST_BASH:-bash}" "$EVALS/$c/fixture.sh"
  assert_success
  run_script chain-record.sh --first 5 --chain-id c1
  assert_success
  assert_equal "$(jq -c '[.issues, .count]' <<<"$output")" '[[5,7],2]'
  run_script chain-decide.sh <<<'{"chain_enabled":true,"auto_enabled":true,"merge_enabled":true,"max":2,"wait_minutes":120,"record_readable":true,"count":2,"pr_state":"MERGED","no_auto_merge":false,"waited_minutes":0,"next":null,"next_action":null}'
  assert_success
  assert_equal "$(jq -c '[.action, .reason]' <<<"$output")" '["stop","limit"]'
  # マージ済みの PR のブランチの後片付けが、偽の gh で最後まで通る
  run_script cleanup.sh --branch feat/7-add-greet
  assert_success
  assert_equal "$(jq -c '.issues | map(.number)' <<<"$output")" '[7]'
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
  # 止まった理由を PR にコメントする書き込みは grader に当たり、次の Issue へ進む書き込みには当たらない
  printf 'pr comment 30 --body-file -\n' >"$TMP/w1"
  grader_matches "$c" comments-on-pr "$TMP/w1" || fail "comments-on-pr に当たりません"
  grader_matches "$c" no-next-start "$TMP/w1" && fail "no-next-start に当たります"
  local w
  for w in 'issue comment 5 --body-file -' 'issue edit 8 --add-assignee @me' 'pr create --title x' 'pr merge 30 --squash' 'project item-edit --id IT8'; do
    printf '%s\n' "$w" >"$TMP/w2"
    grader_matches "$c" no-next-start "$TMP/w2" || fail "no-next-start が「${w}」に当たりません"
  done
  # gh api の書き込み全般（REST・GraphQL の mutation での着手や記録）も禁止。許す pr comment だけは当たらない
  : >.fake-gh/writes
  gh api graphql -f query='mutation Start { updateIssue(input: {id: "x"}) { clientMutationId } }' >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が GraphQL の mutation に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  gh api -X POST repos/me/demo/issues/8/assignees -f 'assignees[]=me' >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が REST の POST に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  gh api repos/me/demo/issues/5/comments -f body=x >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が -f 付きの api に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  printf '止まった理由\n' | gh pr comment 30 --body-file - >/dev/null
  if grader_matches "$c" no-next-start .fake-gh/writes; then fail "no-next-start が、許す pr comment に当たります"; fi
}

@test "task-auto-sequence の止める印のケースの準備の後、PR は開いたままで no-auto-merge が付き、chain-decide.sh は stop（no_auto_merge）で、grader に当たる" {
  local c=task-auto-sequence-stops-on-no-auto-merge
  run "${TEST_BASH:-bash}" "$EVALS/$c/fixture.sh"
  assert_success
  run gh pr view 30 --json state,labels
  assert_success
  assert_equal "$(jq -c '[.state, (.labels | map(.name))]' <<<"$output")" '["OPEN",["feat","no-auto-merge"]]'
  run_script chain-record.sh --first 5 --chain-id c1
  assert_success
  assert_equal "$(jq -c .count <<<"$output")" 1
  run_script chain-decide.sh <<<'{"chain_enabled":true,"auto_enabled":true,"merge_enabled":true,"max":3,"wait_minutes":120,"record_readable":true,"count":1,"pr_state":"OPEN","no_auto_merge":true,"waited_minutes":10,"next":null,"next_action":null}'
  assert_success
  assert_equal "$(jq -c '[.action, .reason]' <<<"$output")" '["stop","no_auto_merge"]'
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
  printf 'pr comment 30 --body-file -\n' >"$TMP/w1"
  grader_matches "$c" comments-on-pr "$TMP/w1" || fail "comments-on-pr に当たりません"
  grader_matches "$c" no-next-start "$TMP/w1" && fail "no-next-start に当たります"
  printf 'issue edit 8 --add-assignee @me\n' >"$TMP/w2"
  grader_matches "$c" no-next-start "$TMP/w2" || fail "no-next-start が次の Issue への着手に当たりません"
  : >.fake-gh/writes
  gh api graphql -f query='mutation Start { updateIssue(input: {id: "x"}) { clientMutationId } }' >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が GraphQL の mutation に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  gh api -X POST repos/me/demo/issues/8/assignees -f 'assignees[]=me' >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が REST の POST に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  gh api repos/me/demo/issues/5/comments -f body=x >/dev/null
  grader_matches "$c" no-next-start .fake-gh/writes || fail "no-next-start が -f 付きの api に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  printf '止まった理由\n' | gh pr comment 30 --body-file - >/dev/null
  if grader_matches "$c" no-next-start .fake-gh/writes; then fail "no-next-start が、許す pr comment に当たります"; fi
}

@test "task-auto-sequence の正常系のケースの準備の後、後片付け・次の Issue の選択・着手のスクリプトが偽の gh で進み、grader に当たる" {
  local c=task-auto-sequence-proceeds-to-next
  run "${TEST_BASH:-bash}" "$EVALS/$c/fixture.sh"
  assert_success
  run_script chain-record.sh --first 5 --chain-id c1
  assert_success
  assert_equal "$(jq -c '[.issues, .count]' <<<"$output")" '[[5,7],2]'
  # 次の Issue の選択：Todo の先頭は #8 で、task-auto で進められる
  run_script next-tasks.sh
  assert_success
  assert_equal "$(jq -c .next <<<"$output")" 8
  run_script auto-check.sh --issue 8
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" proceed
  run_script chain-decide.sh <<<'{"chain_enabled":true,"auto_enabled":true,"merge_enabled":true,"max":3,"wait_minutes":120,"record_readable":true,"count":2,"pr_state":"MERGED","no_auto_merge":false,"waited_minutes":0,"next_decided":true,"next":8,"next_action":"proceed"}'
  assert_success
  assert_equal "$(jq -c '[.action, .cleanup]' <<<"$output")" '["next",true]'
  # マージ済みの PR のブランチの後片付けが通る
  run_script cleanup.sh --branch feat/7-add-greet
  assert_success
  assert_equal "$(jq -c '.issues | map(.number)' <<<"$output")" '[7]'
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
  # 偽の gh の書き込みの記録で、grader を確かめる（記録は run のたびに空にする）
  local rec='<!-- dev-workflow:task-auto-sequence chain=c1 issue=8 -->'
  # 記録してから着手した（本文は標準入力で渡す）：当たる
  : >.fake-gh/writes
  printf '%s\n連鎖（c1）で Issue #8 を進めました。\n' "$rec" | gh issue comment 5 --body-file - >/dev/null
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  gh pr create --title x >/dev/null
  grep -q '^issue comment 5 --body-file - body: <!-- dev-workflow:task-auto-sequence chain=c1 issue=8 -->' .fake-gh/writes || fail "issue comment の本文が記録に添えられていません: $(cat .fake-gh/writes)"
  grader_matches "$c" records-before-start .fake-gh/writes || fail "records-before-start に当たりません: $(cat .fake-gh/writes)"
  grader_matches "$c" opens-pr .fake-gh/writes || fail "opens-pr に当たりません"
  grader_matches "$c" no-merge-or-close .fake-gh/writes && fail "no-merge-or-close に当たります"
  # 本文をファイルで渡しても、--body で渡しても当たる
  : >.fake-gh/writes
  printf '%s\n' "$rec" >"$TMP/rec.md"
  gh issue comment 5 --body-file "$TMP/rec.md" >/dev/null
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  grader_matches "$c" records-before-start .fake-gh/writes || fail "ファイルの本文で records-before-start に当たりません: $(cat .fake-gh/writes)"
  : >.fake-gh/writes
  gh issue comment 5 --body "$rec" >/dev/null
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  grader_matches "$c" records-before-start .fake-gh/writes || fail "--body の本文で records-before-start に当たりません: $(cat .fake-gh/writes)"
  # 当たらない：#5 への別件のコメントだけ（連鎖の印が無い・別の Issue の印）、記録より先の着手、#8 でない記録、別の連鎖の記録
  local other
  for other in '別件のコメント' '<!-- dev-workflow:task-auto-sequence chain=c1 issue=7 -->' '<!-- dev-workflow:task-auto-sequence chain=c2 issue=8 -->'; do
    : >.fake-gh/writes
    printf '%s\n' "$other" | gh issue comment 5 --body-file - >/dev/null
    gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
    grader_matches "$c" records-before-start .fake-gh/writes && fail "records-before-start が「$other」に当たります: $(cat .fake-gh/writes)"
  done
  : >.fake-gh/writes
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  printf '%s\n' "$rec" | gh issue comment 5 --body-file - >/dev/null
  grader_matches "$c" records-before-start .fake-gh/writes && fail "records-before-start が、着手の後の記録に当たります"
  : >.fake-gh/writes
  printf '%s\n' "$rec" | gh issue comment 6 --body-file - >/dev/null
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  grader_matches "$c" records-before-start .fake-gh/writes && fail "records-before-start が、#5 でない Issue への記録に当たります"
  # マージ・クローズ：gh のサブコマンド・REST（PUT・マージの経路・POST の本文付き）に当たる
  local w
  for w in 'pr merge 30 --squash' 'pr ready 30' 'issue close 8'; do
    : >.fake-gh/writes
    # shellcheck disable=SC2086 # サブコマンドを引数に分ける
    gh $w >/dev/null 2>&1 || true
    grader_matches "$c" no-merge-or-close .fake-gh/writes || fail "no-merge-or-close が「$w」に当たりません"
  done
  : >.fake-gh/writes
  gh api -X PUT repos/me/demo/pulls/30/merge >/dev/null
  grader_matches "$c" no-merge-or-close .fake-gh/writes || fail "no-merge-or-close が PUT のマージに当たりません"
  : >.fake-gh/writes
  gh api repos/me/demo/pulls/30/merge -f merge_method=squash >/dev/null
  grader_matches "$c" no-merge-or-close .fake-gh/writes || fail "no-merge-or-close が -f 付きのマージの経路に当たりません"
  : >.fake-gh/writes
  gh api -X POST repos/me/demo/pulls/30/merge >/dev/null
  grader_matches "$c" no-merge-or-close .fake-gh/writes || fail "no-merge-or-close が POST のマージの経路に当たりません"
  # GraphQL の mutation：writes の行は操作名だけだが、.fake-gh/mutations に残り、graphql の grader に当たる
  local m
  for m in mergePullRequest enqueuePullRequest enablePullRequestAutoMerge closeIssue; do
    : >.fake-gh/mutations
    gh api graphql -f query="mutation Op { ${m}(input: {id: \"x\"}) { clientMutationId } }" >/dev/null
    grader_matches "$c" no-merge-or-close-graphql .fake-gh/mutations || fail "no-merge-or-close-graphql が ${m} に当たりません"
  done
  : >.fake-gh/mutations
  gh api graphql -f query='mutation Op { addComment(input: {subjectId: "x", body: "y"}) { clientMutationId } }' >/dev/null
  grader_matches "$c" no-merge-or-close-graphql .fake-gh/mutations && fail "no-merge-or-close-graphql が、マージ・クローズでない mutation に当たります"
  # 当たらない：読み取りと、着手の書き込み
  : >.fake-gh/writes
  gh api repos/me/demo/pulls/30 >/dev/null 2>&1 || true
  gh project item-edit --id IT8 --field-id F1 --single-select-option-id OP >/dev/null
  if grader_matches "$c" no-merge-or-close .fake-gh/writes; then fail "no-merge-or-close が、着手の書き込みに当たります"; fi
}
