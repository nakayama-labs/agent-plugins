#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# pr-watch.sh を、$TMP/seq の行（action と reasons の JSON）を1回ごとに1行ずつ返す偽物に差し替えた、スクリプトの写しで動かす。
# 呼ばれるたびに $TMP/calls に「pr-watch <引数>」を足す。seq の行が尽きたら、最後の行を返し続ける。
# 待つ秒数は DW_WAIT_SLEEP=0 で飛ばす。
setup() {
  test_helper_setup
  mkdir -p "$TMP/plugin"
  cp -R "$SCRIPTS" "$TMP/plugin/scripts"
  cat >"$TMP/plugin/scripts/pr-watch.sh" <<'SH'
#!/usr/bin/env bash
echo "pr-watch $*" >>"$CALLS"
n=$(grep -c '^pr-watch' "$CALLS")
total=$(wc -l <"$SEQ" | tr -d ' ')
[ "$n" -le "$total" ] || n="$total"
if [ -f "$TMP/fail" ]; then echo "error: boom" >&2; exit 3; fi
jq -c --argjson l "$(sed -n "${n}p" "$SEQ")" '$l + {pr: {number: 5}}' <<<'{}'
SH
  chmod +x "$TMP/plugin/scripts/pr-watch.sh"
  CALLS="$TMP/calls" SEQ="$TMP/seq"
  : >"$CALLS"
  export CALLS SEQ TMP DW_WAIT_SLEEP=0
}

teardown() { rm -rf "$TMP"; }

loop() { run "${TEST_BASH:-bash}" "$TMP/plugin/scripts/pr-watch-loop.sh" "$@"; }

seq_of() { printf '%s\n' "$@" >"$SEQ"; }

@test "wait の間は続け、wait 以外になったら、その結果と watch を出して終わる" {
  seq_of '{"action":"wait","reasons":["ci_pending"]}' '{"action":"wait","reasons":["ci_pending"]}' '{"action":"idle","reasons":["nothing_to_do"]}'
  loop --pr 5 --interval 30
  assert_success
  assert_equal "$(jq -c '[.action, .watch]' <<<"$output")" '["idle",{"ended_by":"action","polls":3,"elapsed_seconds":60}]'
  assert_equal "$(grep -c '^pr-watch' "$CALLS")" 3
  grep -q '^pr-watch --pr 5$' "$CALLS"
}

@test "act・conflict・stop も、wait 以外なので 1 回目で終わる" {
  for a in act conflict stop; do
    : >"$CALLS"
    seq_of "{\"action\":\"$a\",\"reasons\":[\"x\"]}"
    loop
    assert_success
    assert_equal "$(jq -c '[.action, .watch.ended_by, .watch.polls]' <<<"$output")" "[\"$a\",\"action\",1]"
  done
}

@test "上限（回数）に達したら、wait のまま ended_by が limit で終わる" {
  seq_of '{"action":"wait","reasons":["ci_pending"]}'
  loop --max-count 4
  assert_success
  assert_equal "$(jq -c '[.action, .watch]' <<<"$output")" '["wait",{"ended_by":"limit","polls":4,"elapsed_seconds":180}]'
  assert_equal "$(grep -c '^pr-watch' "$CALLS")" 4
}

@test "上限（分）は間隔の合計で数える。既定は間隔 60 秒・上限 60 分" {
  seq_of '{"action":"wait","reasons":["ci_pending"]}'
  loop --interval 600 --max-minutes 30
  assert_success
  # 0・10・20・30 分に問い合わせ、次は 40 分で上限を超える
  assert_equal "$(jq -c '.watch' <<<"$output")" '{"ended_by":"limit","polls":4,"elapsed_seconds":1800}'
  : >"$CALLS"
  loop
  assert_success
  assert_equal "$(jq -c '.watch' <<<"$output")" '{"ended_by":"limit","polls":61,"elapsed_seconds":3600}'
}

@test "何も書き込まない（呼ぶのは pr-watch.sh だけ）" {
  seq_of '{"action":"wait","reasons":["ci_pending"]}' '{"action":"idle","reasons":["nothing_to_do"]}'
  loop
  assert_success
  run grep -vc '^pr-watch' "$CALLS"
  assert_output 0
}

@test "pr-watch.sh が失敗したら、その終了コードとメッセージで止まる" {
  seq_of '{"action":"wait","reasons":[]}'
  touch "$TMP/fail"
  loop
  assert_failure 3
  assert_output --partial "boom"
}

@test "引数の誤りは 64 で止まる。--help は使い方を出す" {
  for a in "--interval 0" "--interval x" "--max-count 0" "--max-minutes -1" "--max-count 3 --max-minutes 3" "--pr" "--nope"; do
    # shellcheck disable=SC2086
    loop $a
    assert_failure 64
  done
  loop --help
  assert_success
  assert_output --partial "使い方: pr-watch-loop.sh"
}
