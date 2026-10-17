#!/usr/bin/env bats
# chain-decide.sh の判断の表（スクリプトの先頭のコメント）を、行ごとと、その境目で確かめる。
# 入力は JSON なので、git も GitHub も使わない。

load test_helper

# 既定：すべての条件を満たす（next になる）。最初の Issue の1件を進めた後で、上限は3
READY='{"chain_enabled":true,"auto_enabled":true,"merge_enabled":true,"max":3,"wait_minutes":120,"record_readable":true,"count":1,"pr_state":"MERGED","no_auto_merge":false,"waited_minutes":0,"next":12,"next_action":"proceed"}'

# 使い方: check <jq のフィルタ> <期待する「action reason」>
check() {
  local input
  input="$(jq -c "$1" <<<"$READY")"
  run_script chain-decide.sh <<<"$input"
  assert_success
  assert_equal "$(jq -r '[.action, .reason] | join(" ")' <<<"$output")" "$2"
}

@test "全部の条件を満たせば next" {
  check '.' "next ready"
}

@test "表 1〜3：連鎖・task-auto・無人のマージのどれかが有効でなければ（省略・null も）stop" {
  check '.chain_enabled = false' "stop chain_disabled"
  check 'del(.chain_enabled)' "stop chain_disabled"
  check '.chain_enabled = null' "stop chain_disabled"
  check '.auto_enabled = false' "stop auto_disabled"
  check 'del(.auto_enabled)' "stop auto_disabled"
  check '.merge_enabled = false' "stop merge_disabled"
  check 'del(.merge_enabled)' "stop merge_disabled"
}

@test "表 4：連鎖の記録を読めなければ、件数を数えられないので stop" {
  check '.record_readable = false' "stop record_unreadable"
  check 'del(.record_readable)' "stop record_unreadable"
}

@test "表 5：no-auto-merge が付いていれば、PR がマージ済みでも、待っていても stop（次へ進まない）" {
  check '.no_auto_merge = true' "stop no_auto_merge"
  check '.no_auto_merge = true | .pr_state = "OPEN"' "stop no_auto_merge"
}

@test "表 6〜8：PR がマージされていなければ、閉じていれば stop、開いていれば待つ（待つ時間の境目は、ちょうどで stop）" {
  check '.pr_state = "CLOSED"' "stop pr_closed"
  check '.pr_state = "OPEN"' "wait pr_open"
  check 'del(.pr_state)' "wait pr_open"
  check '.pr_state = "OPEN" | .waited_minutes = 119' "wait pr_open"
  check '.pr_state = "OPEN" | .waited_minutes = 120' "stop wait_timeout"
  check '.pr_state = "OPEN" | .waited_minutes = 500' "stop wait_timeout"
}

@test "表 9：進めた件数が上限に達したら stop（上限の1つ手前までは進む）" {
  check '.count = 2' "next ready"
  check '.count = 3' "stop limit"
  check '.count = 4' "stop limit"
  check 'del(.count)' "stop limit"
  check '.max = 1 | .count = 1' "stop limit"
  check '.max = 1 | .count = 0' "next ready"
  check 'del(.max) | .count = 1' "stop limit"
}

@test "表 10・11：次の Issue が無い、task-auto を動かせない（proceed でない）なら stop" {
  check '.next = null' "stop no_next"
  check 'del(.next)' "stop no_next"
  check '.next_action = "hold"' "stop next_not_startable"
  check '.next_action = "disabled"' "stop next_not_startable"
  check 'del(.next_action)' "stop next_not_startable"
}

@test "表は上から順に当てはめる（連鎖が無効なら、ほかの理由より先にそれで止まる）" {
  check '.chain_enabled = false | .count = 9 | .next = null' "stop chain_disabled"
  check '.no_auto_merge = true | .count = 9' "stop no_auto_merge"
  check '.count = 9 | .next = null' "stop limit"
}

@test "入力の型や値が違えば終了コード 64 で止まる" {
  for f in '.chain_enabled = "true"' '.max = 0' '.max = 1.5' '.wait_minutes = 0' '.count = -1' '.waited_minutes = "x"' '.pr_state = "MERGING"' '.next = 0' '.next = "12"'; do
    run_script chain-decide.sh <<<"$(jq -c "$f" <<<"$READY")"
    [ "$status" -eq 64 ] || fail "$f が 64 で止まりません（$status）"
  done
  run_script chain-decide.sh <<<'[1]'
  assert_failure 64
  run_script chain-decide.sh <<<"$READY $READY"
  assert_failure 64
}
