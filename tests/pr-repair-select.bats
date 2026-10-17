#!/usr/bin/env bats
# .github/scripts/pr-repair-select.sh（pr-repair.yml が、無人で直す対象の PR を選ぶ）のテスト（#341）。
# gh と、pr-watch.sh・pr-feedback.sh を偽物に置き換える。判定の表（誰の PR を対象にするか・止まった PR を飛ばすか・
# 許可していない投稿者で Claude を動かさないか）を、PR の状態の組み合わせで確かめる。

load test_helper

setup() {
  test_helper_setup
  mark_set_up
  SEL="$BATS_TEST_DIRNAME/../.github/scripts/pr-repair-select.sh"
  FIX="$TMP/fix"
  mkdir -p "$TMP/bin" "$FIX" "$TMP/plugin"
  # config.sh は本物（保留の列の名前を読む）。pr-watch.sh と pr-feedback.sh は、$FIX の JSON を返す偽物
  cp -R "$SCRIPTS" "$TMP/plugin/scripts"
  cp -R "$SCRIPTS/../defaults" "$TMP/plugin/defaults"
  cat >"$TMP/plugin/scripts/pr-watch.sh" <<'SH'
#!/usr/bin/env bash
echo "pr-watch $*" >>"$CALLS"
n="$2"
[ ! -f "$FIX/watch-$n.fail" ] || { echo "error: boom" >&2; exit 3; }
cat "$FIX/watch-$n.json"
SH
  cat >"$TMP/plugin/scripts/pr-feedback.sh" <<'SH'
#!/usr/bin/env bash
echo "pr-feedback $*" >>"$CALLS"
n="$2"
[ -f "$FIX/fb-$n.json" ] || exit 1
cat "$FIX/fb-$n.json"
SH
  chmod +x "$TMP/plugin/scripts/"*.sh
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# --jq の後の式を、ファイルの JSON に適用する偽の gh
echo "gh $*" >>"$CALLS"
filter=.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" != --jq ] || filter="${args[$((i + 1))]}"
done
case "$*" in
  *"pulls?state=open"*) jq -r "$filter" "$FIX/open.json" ;;
  *"/collaborators/"*"/permission"*)
    who="${2##*/collaborators/}"; who="${who%%/*}"
    if [ -f "$FIX/perm-$who.json" ]; then jq -r "$filter" "$FIX/perm-$who.json"
    elif [ -f "$FIX/perm-$who.err" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api repos/me/demo/pulls/"*)
    n="${2##*/}"
    [ -f "$FIX/pull-$n.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$FIX/pull-$n.json" ;;
  "issue view "*) n="$3"; jq -r "$filter" "$FIX/items-$n.json" ;;
  *) echo "偽の gh: 想定外の呼び出し: $*" >&2; exit 99 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  CALLS="$TMP/calls"; : >"$CALLS"
  export CALLS FIX TMP PATH="$TMP/bin:$PATH"
  export SCRIPTS_DIR="$TMP/plugin/scripts" GITHUB_REPOSITORY=me/demo BOT_LOGINS='task-app[bot]' APP_LOGIN='task-app[bot]'
  echo '{"status": {"hold": "On Hold"}, "repair": {"allowed_authors": ["review-bot[bot]"]}}' >"$REPO/.claude/dev-workflow/config.json"
  echo '[]' >"$FIX/open.json"
}

# 偽物の呼び出しの記録（$CALLS）に、パターンに合う行が無いこと
not_called() { if grep -q -e "$1" "$CALLS"; then fail "呼ばれています: $1"; fi; }

# 標準エラー（飛ばした理由の1行）を混ぜずに、標準出力の JSON だけを $output に取る
# （失敗したときだけ標準エラーも出して、原因を読めるようにする）
run_sel() { run bash -c '"$0" "$@" 2>"$TMP/err"; rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err"; exit "$rc"' "$SEL" "$@"; }

teardown() { rm -rf "$TMP"; }

# 使い方: pull <番号> [author] [draft] [head のリポジトリ] [本文]
pull() {
  jq -n --argjson n "$1" --arg a "${2:-task-app[bot]}" --argjson d "${3:-false}" --arg r "${4:-me/demo}" --arg b "${5:-Closes #$(($1 + 100))}" \
    '{number: $n, state: "open", draft: $d, user: {login: $a}, body: $b, head: {ref: "feat/\($n)", sha: "abc\($n)", repo: {full_name: $r}}}' >"$FIX/pull-$1.json"
  echo "$1" >>"$FIX/open.list"
  jq -Rsc 'split("\n") | map(select(. != "") | {number: tonumber})' "$FIX/open.list" >"$FIX/open.json"
  echo '{"projectItems": []}' >"$FIX/items-$(($1 + 100)).json"
}
# 使い方: watch <番号> <action> [reasons の JSON]
watch() { jq -nc --arg a "$2" --argjson r "${3:-[]}" '{action: $a, reasons: $r}' >"$FIX/watch-$1.json"; }
# 使い方: fb <番号> <投稿者> <返事をしていない項目の数>（コメントとして）
fb() {
  jq -nc --arg a "$2" --argjson k "$3" \
    '{feedback: [{author: $a, threads: [], reviews: [], comments: [range(0; $k) | {needs_attention: true}]}]}' >"$FIX/fb-$1.json"
}

@test "自動で作った PR（作成者が App・head が同じリポジトリ・開いている）の act・conflict・stop を、番号・Issue・ブランチつきで選ぶ" {
  pull 1; pull 2; pull 3
  watch 1 act '["ci_failed"]'; watch 2 conflict '["conflicting"]'; watch 3 stop '["same_failure","ci_failed"]'
  run_sel
  assert_success
  [ "$(jq -c '[.[] | [.pr, .issue, .branch, .head_sha, .action]]' <<<"$output")" = '[[1,101,"feat/1","abc1","act"],[2,102,"feat/2","abc2","conflict"],[3,103,"feat/3","abc3","stop"]]' ]
  [ "$(jq -c '.[2].reasons' <<<"$output")" = '["same_failure","ci_failed"]' ]
}

@test "idle・wait の PR は選ばない（Claude を動かさない）" {
  pull 1; pull 2; pull 3
  watch 1 idle '["nothing_to_do"]'; watch 2 wait '["ci_pending"]'; watch 3 idle '["not_open"]'
  run_sel
  assert_success
  assert_output '[]'
}

@test "作成者が App でない PR・下書き・フォークの PR は、pr-watch.sh を呼ばずに飛ばす" {
  pull 1 alice; pull 2 'task-app[bot]' true; pull 3 'task-app[bot]' false other/fork
  watch 1 act '["ci_failed"]'; watch 2 act '["ci_failed"]'; watch 3 act '["ci_failed"]'
  run_sel
  assert_success
  assert_output '[]'
  not_called '^pr-watch'
}

@test "作成者のログイン名は、[bot] の有無・大文字小文字を区別せずに比べる（pr-watch.sh と同じ DW_JQ_LOGIN_NORM の規則）" {
  pull 1 'Task-App[bot]'; pull 2 'TASK-APP'
  watch 1 act '["ci_failed"]'; watch 2 act '["ci_failed"]'
  run_sel
  assert_success
  [ "$(jq 'length' <<<"$output")" = 2 ]
}

@test "閉じる Issue が1つに決まらない PR（無い・複数）は飛ばす" {
  pull 1 'task-app[bot]' false me/demo 'Closes なし'; pull 2 'task-app[bot]' false me/demo 'Closes #5 and fixes #6'
  watch 1 act '["ci_failed"]'; watch 2 act '["ci_failed"]'
  run_sel
  assert_success
  assert_output '[]'
}

@test "同じ Issue を Closes と closes で2回書いても、1つの Issue として選ぶ" {
  pull 1 'task-app[bot]' false me/demo 'Closes #7. closes #7'
  echo '{"projectItems": []}' >"$FIX/items-7.json"
  watch 1 act '["ci_failed"]'
  run_sel
  assert_success
  [ "$(jq -r '.[0].issue' <<<"$output")" = 7 ]
}

@test "閉じる Issue が保留の列にある PR は、止まっているので pr-watch.sh を呼ばずに飛ばす" {
  pull 1; pull 2
  echo '{"projectItems": [{"status": {"name": "On Hold"}}]}' >"$FIX/items-101.json"
  echo '{"projectItems": [{"status": {"name": "In Review"}}]}' >"$FIX/items-102.json"
  watch 1 act '["ci_failed"]'; watch 2 act '["ci_failed"]'
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[2]' ]
  not_called '^pr-watch --pr 1$'
}

@test "保留の列が設定されていないときは、止まるときに移す列が無いので、何も選ばない" {
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  cat >"$TMP/plugin/scripts/config.sh" <<'SH'
#!/usr/bin/env bash
:
SH
  pull 1; watch 1 act '["ci_failed"]'
  run_sel
  assert_success
  assert_output '[]'
}

@test "1つの PR の判定に失敗しても、ほかの PR は続ける" {
  pull 1; pull 2
  touch "$FIX/watch-1.fail"; watch 2 act '["ci_failed"]'
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[2]' ]
}

@test "--pr で指定した PR だけを調べる（開いている PR の一覧は読まない）" {
  pull 1; pull 2
  watch 1 act '["ci_failed"]'; watch 2 act '["ci_failed"]'
  run_sel --pr '#2'
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[2]' ]
  not_called 'pulls?state=open'
}

@test "CI の失敗が無く、返事をしていない指摘が許可していない投稿者のものだけの act は、Claude を動かさないよう選ばない" {
  pull 1
  watch 1 act '["unanswered_comments"]'; fb 1 stranger 1
  run_sel
  assert_success
  assert_output '[]'
}

@test "返事をしていない指摘が、許可した投稿者（設定 repair.allowed_authors）のものなら選ぶ" {
  pull 1
  watch 1 act '["unanswered_comments"]'; fb 1 'review-bot[bot]' 1
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[1]' ]
}

@test "返事をしていない指摘が、リポジトリの write 以上の人のものなら選び、read の人のものなら選ばない" {
  pull 1; pull 2
  watch 1 act '["unanswered_reviews"]'; fb 1 maintainer 1
  watch 2 act '["unanswered_reviews"]'; fb 2 reader 1
  echo '{"role_name": "write"}' >"$FIX/perm-maintainer.json"
  echo '{"role_name": "read"}' >"$FIX/perm-reader.json"
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[1]' ]
}

@test "CI の失敗があれば、指摘の投稿者によらず選ぶ（CI の失敗は投稿者を問わず直す対象）" {
  pull 1
  watch 1 act '["ci_failed","unanswered_comments"]'; fb 1 stranger 1
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[1]' ]
  not_called '^pr-feedback'
}

@test "指摘の投稿者を読めない（pr-feedback.sh が失敗した）ときは、対象にする" {
  pull 1
  watch 1 act '["unanswered_comments"]'
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[1]' ]
}

@test "イベントの投稿者が無人の実行そのもの（App）のときは、ループを防ぐため何も選ばない" {
  pull 1; watch 1 act '["ci_failed"]'
  run_sel --pr 1 --sender 'task-app[bot]'
  assert_success
  assert_output '[]'
  not_called '^pr-watch'
}

@test "イベントの投稿者が、許可した投稿者でも write 以上の人でもなければ、何も選ばない" {
  pull 1; watch 1 act '["ci_failed"]'
  echo '{"role_name": "triage"}' >"$FIX/perm-tri.json"
  run_sel --pr 1 --sender tri
  assert_success
  assert_output '[]'
  run_sel --pr 1 --sender nobody
  assert_success
  assert_output '[]'
  not_called '^pr-watch'
}

@test "イベントの投稿者が、repair.allowed_authors か write 以上の人なら、その PR を調べる" {
  pull 1; watch 1 act '["ci_failed"]'
  run_sel --pr 1 --sender 'review-bot[bot]'
  assert_success
  [ "$(jq 'length' <<<"$output")" = 1 ]
  echo '{"role_name": "admin"}' >"$FIX/perm-boss.json"
  run_sel --pr 1 --sender boss
  assert_success
  [ "$(jq 'length' <<<"$output")" = 1 ]
}

@test "権限を読むときに404以外で失敗したら、権限なしと取り違えず失敗にする" {
  pull 1; watch 1 act '["ci_failed"]'
  touch "$FIX/perm-flaky.err"
  run_sel --pr 1 --sender flaky
  assert_failure
}

@test "引数の誤りは終了コード 64" {
  run_sel --pr
  [ "$status" -eq 64 ]
  run_sel --nope
  [ "$status" -eq 64 ]
}

@test "ログイン名を比べる規則は、DW_JQ_LOGIN_NORM（pr-watch.sh・pr-feedback.sh と同じ定義）を使い、スクリプトの中で書き直さない" {
  grep -q 'DW_JQ_LOGIN_NORM' "$SEL"
  if grep -v '^ *#' "$SEL" | grep -q "sub(.*bot\|\\[bot\\]"; then fail "select の中で、ログイン名の規則を書き直しています"; fi
}

@test "権限を読めない（404 以外）ときは、イベントの投稿者の確認でも、指摘の投稿者の確認でも、失敗にする" {
  pull 1; watch 1 act '["unanswered_comments"]'; fb 1 flaky 1
  touch "$FIX/perm-flaky.err"
  run_sel
  assert_failure
}

@test "同じ投稿者の権限は、同じ実行の中で1回しか読まない（結果を覚える）。大文字小文字だけ違う綴りも同じ" {
  pull 1; pull 2
  watch 1 act '["unanswered_comments"]'; watch 2 act '["unanswered_comments"]'
  fb 1 Maintainer 1; fb 2 maintainer 1
  echo '{"role_name": "write"}' >"$FIX/perm-Maintainer.json"
  echo '{"role_name": "write"}' >"$FIX/perm-maintainer.json"
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[1,2]' ]
  [ "$(grep -c '/permission' "$CALLS")" = 1 ]
}

@test "権限なしの結果も覚える。失敗は覚えず、失敗で止まる" {
  pull 1; pull 2
  watch 1 act '["unanswered_comments"]'; watch 2 act '["unanswered_comments"]'
  fb 1 reader 1; fb 2 reader 1
  echo '{"role_name": "read"}' >"$FIX/perm-reader.json"
  run_sel
  assert_success
  assert_output '[]'
  [ "$(grep -c '/permission' "$CALLS")" = 1 ]
}

@test "ログイン名の形でない投稿者（repair-author.sh が終了コード 64）は、許可しない扱いにして続け、見回り全体を止めない" {
  pull 1; pull 2
  watch 1 act '["unanswered_comments"]'; fb 1 'bad/name' 1
  watch 2 act '["unanswered_comments"]'; fb 2 'review-bot[bot]' 1
  run_sel
  assert_success
  [ "$(jq -c '[.[].pr]' <<<"$output")" = '[2]' ]
  not_called 'bad/name'
}

@test "イベントの投稿者がログイン名の形でないときも、許可しない扱いで何も選ばず、失敗にしない" {
  pull 1; watch 1 act '["ci_failed"]'
  run_sel --pr 1 --sender 'a/b'
  assert_success
  assert_output '[]'
}
