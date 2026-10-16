#!/usr/bin/env bats
# repair-next.sh の判断の表（スクリプトの先頭のコメント）を、行ごとと、その境目で確かめる。
# 入力は JSON なので、git も GitHub も使わない。

load test_helper

# start の既定：plan は merge、dirty でなく、unpulled は 0
START='{"step":"start","rechecks":0,"status":{"dirty":false,"unpulled":0,"plan":{"action":"merge","reason":"conflict"}}}'
# verify の既定：テストとチェックは通り、repair-push-check.sh は ok
VERIFY='{"step":"verify","status":{"unpulled":0},"checks":"pass","fix_attempts":0,"max_fix_attempts":3,"push_check_ok":true}'

# 使い方: check <入力> <jq のフィルタ> <期待する「action reason」>
check() {
  local input
  input="$(jq -c "$2" <<<"$1")"
  run_script repair-next.sh <<<"$input"
  assert_success
  assert_equal "$(jq -r '[.action, .reason] | join(" ")' <<<"$output")" "$3"
}

@test "start 1：plan.action が none なら、取り込まずに終える（plan.reason をそのまま返す）" {
  check "$START" '.status.plan = {"action":"none","reason":"no_conflict","queue":"conflict"}' "finish no_conflict"
  check "$START" '.status.plan = {"action":"none","reason":"up_to_date"}' "finish up_to_date"
  # none なら、dirty でも unpulled でも、何もせずに終える
  check "$START" '.status.plan = {"action":"none","reason":"merged_not_pushed"} | .status.dirty = true | .status.unpulled = 2' "finish merged_not_pushed"
}

@test "start 2：ask_base は止まる（dirty・unpulled より先）" {
  check "$START" '.status.plan.action = "ask_base" | .status.dirty = true | .status.unpulled = 1' "stop base_mismatch"
}

@test "start 3：recheck は 3 回まで再実行し、それでも recheck なら止まる" {
  check "$START" '.status.plan.action = "recheck"' "recheck merge_state_unknown"
  check "$START" '.status.plan.action = "recheck" | .rechecks = 2' "recheck merge_state_unknown"
  check "$START" '.status.plan.action = "recheck" | .rechecks = 3' "stop recheck_exhausted"
  # recheck では dirty を先に見ない（調べ直すだけ）
  check "$START" '.status.plan.action = "recheck" | .status.dirty = true' "recheck merge_state_unknown"
  # rechecks が無ければ 0 回
  check "$START" '.status.plan.action = "recheck" | del(.rechecks)' "recheck merge_state_unknown"
}

@test "start 4：dirty は、merge でも push でも止まる（unpulled より先）" {
  check "$START" '.status.dirty = true' "stop dirty"
  check "$START" '.status.plan.action = "push" | .status.dirty = true' "stop dirty"
  check "$START" '.status.dirty = true | .status.unpulled = 1' "stop dirty"
}

@test "start 5：unpulled が 1 以上なら、merge でも push でも先に pull する" {
  check "$START" '.status.unpulled = 1' "pull unpulled"
  check "$START" '.status.plan.action = "push" | .status.unpulled = 3' "pull unpulled"
}

@test "start 6・7：merge は取り込む。push は取り込まずにテストとチェックへ" {
  check "$START" '.' "merge conflict"
  check "$START" '.status.plan = {"action":"merge","reason":"behind"}' "merge behind"
  check "$START" '.status.plan = {"action":"push","reason":"merged_not_pushed"}' "checks merged_not_pushed"
}

@test "start 8：plan.action が未知の値なら止まる。ただし unpulled が 1 以上なら pull が先" {
  check "$START" '.status.plan = {"action":"bogus","reason":"x"}' "stop unknown_plan"
  check "$START" '.status.plan = {"action":"bogus","reason":"x"} | .status.unpulled = 1' "pull unpulled"
  check "$START" '.status.plan = {"action":"bogus","reason":"x"} | .status.dirty = true' "stop dirty"
}

@test "start：dirty が false でも null でも、unpulled が無ければ進む" {
  check "$START" 'del(.status.dirty) | del(.status.unpulled)' "merge conflict"
}

@test "verify 1：unpulled が 1 以上なら、何より先に pull する" {
  check "$VERIFY" '.status.unpulled = 1' "pull unpulled"
  check "$VERIFY" '.status.unpulled = 1 | .checks = "fail"' "pull unpulled"
  check "$VERIFY" '.status.unpulled = 1 | .checks = "unconfirmed"' "pull unpulled"
}

@test "verify 2：checks が unconfirmed なら止まる" {
  check "$VERIFY" '.checks = "unconfirmed"' "stop checks_unconfirmed"
}

@test "verify 3：checks が pending ならテストとチェックを実行する" {
  check "$VERIFY" '.checks = "pending"' "checks not_run"
}

@test "verify 4：fail は上限未満なら直し、上限以上なら止まる" {
  check "$VERIFY" '.checks = "fail"' "fix checks_failed"
  check "$VERIFY" '.checks = "fail" | .fix_attempts = 2' "fix checks_failed"
  check "$VERIFY" '.checks = "fail" | .fix_attempts = 3' "stop same_failure"
  check "$VERIFY" '.checks = "fail" | .fix_attempts = 1 | .max_fix_attempts = 1' "stop same_failure"
  # 回数の指定が無ければ 0 回目・上限 3
  check "$VERIFY" '.checks = "fail" | del(.fix_attempts) | del(.max_fix_attempts)' "fix checks_failed"
}

@test "verify 5〜7：pass なら、push_check_ok が null で確認、false で止まる、true で push" {
  check "$VERIFY" '.push_check_ok = null' "push_check not_checked"
  check "$VERIFY" 'del(.push_check_ok)' "push_check not_checked"
  check "$VERIFY" '.push_check_ok = false' "stop forbidden_paths"
  check "$VERIFY" '.' "push ready"
}

@test "verify：fail のときは push_check_ok が false でも true でも直すのが先" {
  check "$VERIFY" '.checks = "fail" | .push_check_ok = false' "fix checks_failed"
}

@test "入力の誤りは 64 で止まる" {
  run_script repair-next.sh <<<'{"step":"nope"}'
  assert_failure 64
  run_script repair-next.sh <<<'{"step":"start","status":{}}'
  assert_failure 64
  run_script repair-next.sh <<<'{"step":"verify","checks":"maybe"}'
  assert_failure 64
  run_script repair-next.sh <<<'not json'
  assert_failure 64
  run_script repair-next.sh --nope <<<"$START"
  assert_failure 64
}

@test "出力は action と reason の2つ" {
  run_script repair-next.sh <<<"$START"
  assert_success
  assert_equal "$(jq -c 'keys' <<<"$output")" '["action","reason"]'
}

@test "verify 1・5：dirty が true なら、何より先に止まる（未コミットの変更の木に pull しない。push にも含めない）" {
  check "$VERIFY" '.status.dirty = true' "stop dirty"
  check "$VERIFY" '.status.dirty = true | .push_check_ok = null' "stop dirty"
  check "$VERIFY" '.status.dirty = true | .checks = "fail"' "stop dirty"
  check "$VERIFY" '.status.dirty = true | .checks = "unconfirmed"' "stop dirty"
  check "$VERIFY" '.status.dirty = true | .status.unpulled = 1' "stop dirty"
  check "$VERIFY" '.status.dirty = false | .status.unpulled = 1' "pull unpulled"
  check "$VERIFY" '.status.dirty = false' "push ready"
}

@test "入力の型が違うと 64 で止まる（null と省略は既定の値）" {
  local f
  for f in '.rechecks = "1"' '.rechecks = true' '.status.dirty = "false"' '.status.dirty = 0' '.status.unpulled = "1"'; do
    run_script repair-next.sh <<<"$(jq -c "$f" <<<"$START")"
    assert_failure 64
  done
  for f in '.fix_attempts = "1"' '.max_fix_attempts = "3"' '.push_check_ok = "true"' '.push_check_ok = 1' '.status.dirty = "true"' '.status.unpulled = [1]'; do
    run_script repair-next.sh <<<"$(jq -c "$f" <<<"$VERIFY")"
    assert_failure 64
  done
  check "$VERIFY" '.fix_attempts = null | .max_fix_attempts = null | .status.dirty = null' "push ready"
}

@test "--stop-reasons は、判断の表（--help）の stop の reason の一覧と同じ（#332）" {
  run_script repair-next.sh --stop-reasons
  assert_success
  listed="$(jq -r '.[]' <<<"$output" | sort -u)"
  [ -n "$listed" ] || fail "--stop-reasons が空です"
  run_script repair-next.sh --help
  assert_success
  # 判断の表の「→ stop（<reason>）」「上限以上 → stop（<reason>）」から取り出す
  table="$(grep -o 'stop（[a-z][a-z_0-9]*）' <<<"$output" | sed 's/^stop（//; s/）$//' | sort -u)"
  assert_equal "$listed" "$table"
}

@test "stop を返すとき、reason は --stop-reasons の一覧のどれか" {
  run_script repair-next.sh --stop-reasons
  stops="$output"
  for input in \
    '{"step":"start","status":{"plan":{"action":"ask_base"}}}' \
    '{"step":"start","rechecks":3,"status":{"plan":{"action":"recheck"}}}' \
    '{"step":"start","status":{"dirty":true,"plan":{"action":"merge"}}}' \
    '{"step":"start","status":{"plan":{"action":"what"}}}' \
    '{"step":"verify","checks":"unconfirmed"}' \
    '{"step":"verify","checks":"fail","fix_attempts":3}' \
    '{"step":"verify","checks":"pass","push_check_ok":false}'; do
    run_script repair-next.sh <<<"$input"
    assert_success
    assert_equal "$(jq -r .action <<<"$output")" stop
    jq -e --argjson s "$stops" '.reason | IN($s[])' <<<"$output" >/dev/null || fail "一覧に無い reason: $output"
  done
}

@test "一覧（stop_reasons）に無い stop の reason を返そうとしたら、1行のメッセージを出して終了コード 2 で止まる" {
  # 一覧から dirty を外した写しで、dirty の stop を返させる
  mkdir -p "$TMP/s"
  cp -R "$SCRIPTS/lib" "$TMP/s/"
  sed 's/"dirty",//' "$SCRIPTS/repair-next.sh" >"$TMP/s/repair-next.sh"
  run "${TEST_BASH:-bash}" "$TMP/s/repair-next.sh" <<<'{"step":"verify","status":{"dirty":true},"checks":"pass"}'
  assert_failure 2
  assert_output --partial "stop の reason が一覧（stop_reasons）にありません: dirty"
  assert_equal "${#lines[@]}" 1
  refute_output --partial '"action"'
}

@test "標準入力に JSON の値が複数あるときは 64（最後の値だけで判断しない）" {
  run_script repair-next.sh <<<"$START $START"
  assert_failure 64
  run_script repair-next.sh <<<'{"step":"x"} '"$START"
  assert_failure 64
  run_script repair-next.sh <<<"$START"'{"step":"x"}'
  assert_failure 64
  run_script repair-next.sh <<<"$START"
  assert_success
}
