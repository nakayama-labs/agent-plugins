#!/usr/bin/env bats
# chain-record.sh（連鎖の記録を、最初の Issue のコメントから読み、足す）を、偽の gh で確かめる。
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# 使い方: set_comments <本文>... → Issue #17 のコメントを、その本文のコメントにする（上から古い順）
set_comments() {
  jq -n '$ARGS.positional | map({body: .})' --args "$@" >"$TMP/c.json"
  jq --slurpfile c "$TMP/c.json" '. + {comments: $c[0]}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
}

# 連鎖 c1 の記録のコメントの本文
rec() { printf '<!-- dev-workflow:task-auto-sequence chain=c1 issue=%s -->\n連鎖（c1）で Issue #%s を進めました。' "$1" "$1"; }

setup_chain() {
  setup_fake_gh
  # 足す Issue #20（Issue として読める）
  jq '.number = 20 | .url = "https://github.com/me/demo/issues/20"' "$FIX/issue-17.json" >"$FIX/issue-20.json"
}

@test "記録が無ければ、件数は 0 で、コメントしない（読むだけ）" {
  setup_chain
  set_comments "人のコメント"
  run_script chain-record.sh --first '#17' --chain-id c1
  assert_success
  assert_equal "$(jq -c '[.issues, .count, .recorded]' <<<"$output")" '[[],0,false]'
  assert_equal "$(called issue-comment)" 0
}

@test "連鎖の id が同じ記録だけを、Issue の番号の重複を除いて数える" {
  setup_chain
  set_comments "$(rec 17)" "$(rec 20)" "$(rec 20)" "$(rec 9 | sed 's/chain=c1/chain=c2/')" "引用: $(rec 30)"
  run_script chain-record.sh --first 17 --chain-id c1
  assert_success
  assert_equal "$(jq -c '[.issues, .count]' <<<"$output")" '[[17,20],2]'
}

@test "連鎖の id に . が入っていても、ほかの文字に一致させない" {
  setup_chain
  set_comments "$(rec 17 | sed 's/chain=c1/chain=a.b/')" "$(rec 20 | sed 's/chain=c1/chain=aXb/')"
  run_script chain-record.sh --first 17 --chain-id a.b
  assert_success
  assert_equal "$(jq -c .issues <<<"$output")" '[17]'
}

@test "--add で、記録に無い Issue を最初の Issue にコメントして足す" {
  setup_chain
  set_comments "$(rec 17)"
  run_script chain-record.sh --first 17 --chain-id c1 --add '#20'
  assert_success
  assert_equal "$(jq -c '[.issues, .count, .recorded]' <<<"$output")" '[[17,20],2,true]'
  assert_equal "$(called issue-comment)" 1
  assert_equal "$(args issue-comment)" 17
  assert_equal "$(head -n 1 "$TMP/issue-comment-body")" "<!-- dev-workflow:task-auto-sequence chain=c1 issue=20 -->"
}

@test "--add の Issue が既に記録にあれば、コメントを足し直さない" {
  setup_chain
  set_comments "$(rec 17)" "$(rec 20)"
  run_script chain-record.sh --first 17 --chain-id c1 --add 20
  assert_success
  assert_equal "$(jq -c '[.issues, .recorded]' <<<"$output")" '[[17,20],false]'
  assert_equal "$(called issue-comment)" 0
}

@test "連鎖を始めるときは、最初の Issue 自身を足す" {
  setup_chain
  set_comments
  run_script chain-record.sh --first 17 --chain-id c1 --add 17
  assert_success
  assert_equal "$(jq -c '[.issues, .count, .recorded]' <<<"$output")" '[[17],1,true]'
}

@test "--dry-run は、コメントせず、足す予定の分を含めて出す" {
  setup_chain
  set_comments "$(rec 17)"
  run_script chain-record.sh --first 17 --chain-id c1 --add 20 --dry-run
  assert_success
  assert_equal "$(jq -c '[.issues, .recorded, .dry_run]' <<<"$output")" '[[17,20],true,true]'
  assert_equal "$(called issue-comment)" 0
}

@test "最初の Issue を読めなければ（記録が読めない）、終了コード 1 で止まる" {
  setup_chain
  FAKE_FAIL=issue-view run_script chain-record.sh --first 17 --chain-id c1
  assert_failure 1
  assert_output --partial "を読めません"
}

@test "コメントできなければ、終了コード 1 で止まる（進めずに連鎖を終える）" {
  setup_chain
  set_comments
  FAKE_FAIL=issue-comment run_script chain-record.sh --first 17 --chain-id c1 --add 20
  assert_failure 1
  assert_output --partial "連鎖の記録をコメントできませんでした"
}

@test "引数の誤りは終了コード 64 で止まる" {
  setup_chain
  run_script chain-record.sh --chain-id c1
  assert_failure 64
  run_script chain-record.sh --first 17
  assert_failure 64
  run_script chain-record.sh --first 17 --chain-id 'a b'
  assert_failure 64
  run_script chain-record.sh --first 17 --chain-id 'c-->'
  assert_failure 64
  assert_equal "$(called issue-view)" 0
}

@test "--first が PR の番号なら、終了コード 2 で止まり、コメントしない" {
  setup_chain
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "comments": []}' >"$FIX/issue-21.json"
  run_script chain-record.sh --first 21 --chain-id c1 --add 21
  assert_failure 2
  assert_output --partial "最初の Issue #21 は PR です"
  assert_equal "$(called issue-comment)" 0
}

@test "--first が無い番号なら、終了コード 2 で止まり、コメントしない" {
  setup_chain
  run_script chain-record.sh --first 99 --chain-id c1 --add 99
  assert_failure 2
  assert_output --partial "最初の Issue #99 が"
  assert_equal "$(called issue-comment)" 0
}

@test "--add が PR の番号・無い番号なら、コメントする前に終了コード 2 で止まる（記録に Issue でない番号を入れない）" {
  setup_chain
  set_comments "$(rec 17)"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "comments": []}' >"$FIX/issue-21.json"
  run_script chain-record.sh --first 17 --chain-id c1 --add 21
  assert_failure 2
  assert_output --partial "足す Issue #21 は PR です"
  run_script chain-record.sh --first 17 --chain-id c1 --add 99
  assert_failure 2
  assert_output --partial "足す Issue #99 が"
  assert_equal "$(called issue-comment)" 0
}
