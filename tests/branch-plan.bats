#!/usr/bin/env bats
# branch-plan.sh の判断の表（スクリプトの先頭のコメント）を、行ごとと、その境目で確かめる。
# 入力は branch-status.sh の出力（JSON）なので、git も GitHub も使わない。

load test_helper

# 既定の状態：キューを使うリポジトリで、PR は CLEAN、手元も push 済みのブランチも最新で、キューには入っていない
BASE='{"behind": 0, "up_to_date": true, "conflicts": false, "pushed_behind": 0, "pushed_conflicts": false,
  "pr": {"number": 5, "url": "u", "merge_state": "CLEAN",
         "merge_queue": {"enabled": true, "state": null, "position": null, "queued": false, "removed": null}}}'

# キューを使わないリポジトリにする
NQ='.pr.merge_queue.enabled = false'
# 遅れている（main が2つ進んだ）
BEHIND='.behind = 2 | .up_to_date = false'
# 手元では取り込み済みで、まだ push していない（push 済みのブランチは1つ遅れている）
P='.pushed_behind = 1'

# 既定の状態を jq のフィルタ $1 で変えて branch-plan.sh に渡し、「action reason queue fallback」（null は -）が $2 と同じかを確かめる
check_plan() {
  local input
  input="$(jq -c "$1" <<<"$BASE")"
  run_script branch-plan.sh <<<"$input"
  assert_success
  assert_equal "$(jq -r '[.action, .reason, .queue, .fallback] | map(. // "-") | join(" ")' <<<"$output")" "$2"
}

@test "出力は action・reason・queue・fallback の4つ" {
  run_script branch-plan.sh <<<"$BASE"
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"action":"none","reason":"no_conflict","queue":"not_queued","fallback":null}'
}

@test "キューを使う 1：取り込み済みで未 push で、push 済みのブランチが衝突するなら push" {
  check_plan "$P | .pushed_conflicts = true" "push merged_not_pushed - -"
  check_plan "$P | .pr.merge_state = \"DIRTY\"" "push merged_not_pushed - -"
  check_plan "$P | .pushed_conflicts = null | .pr.merge_state = \"DIRTY\"" "push merged_not_pushed - -"
}

@test "キューを使う 2：取り込み済みで未 push で、衝突を手元で確かめられず GitHub も調べている途中なら recheck（fallback は push）" {
  check_plan "$P | .pushed_conflicts = null | .pr.merge_state = \"UNKNOWN\"" "recheck merge_state_unknown - push"
}

@test "キューを使う 3：取り込み済みで未 push でも、push 済みのブランチが衝突しなければ取り込まない（fallback は push）" {
  check_plan "$P" "none merged_not_pushed not_queued push"
  # 手元で衝突しないと分かっていれば、GitHub が調べている途中（UNKNOWN）でも待たない
  check_plan "$P | .pr.merge_state = \"UNKNOWN\"" "none merged_not_pushed not_queued push"
  # 手元で確かめられなくても、GitHub が衝突していないと言っていれば待たない
  check_plan "$P | .pushed_conflicts = null" "none merged_not_pushed not_queued push"
}

@test "キューを使う 4：main と衝突するなら取り込む" {
  check_plan "$BEHIND | .conflicts = true" "merge conflict - -"
  # 手元で衝突すると分かっていれば、GitHub が調べている途中（UNKNOWN）でも待たない
  check_plan "$BEHIND | .conflicts = true | .pr.merge_state = \"UNKNOWN\"" "merge conflict - -"
  # 手元で衝突しなくても、確かめられなくても、GitHub が DIRTY と言い、遅れていれば取り込む
  check_plan "$BEHIND | .pr.merge_state = \"DIRTY\"" "merge conflict - -"
  check_plan "$BEHIND | .conflicts = null | .pr.merge_state = \"DIRTY\"" "merge conflict - -"
  # 手元では push していないコミットのおかげで衝突しなくても、GitHub が見る push 済みのブランチが衝突するなら、
  # GitHub の判定がまだ（UNKNOWN）か古く（CLEAN）ても取り込む
  check_plan "$BEHIND | .pushed_behind = 2 | .pushed_conflicts = true | .pr.merge_state = \"UNKNOWN\"" "merge conflict - -"
  check_plan "$BEHIND | .pushed_behind = 2 | .pushed_conflicts = true" "merge conflict - -"
  check_plan "$BEHIND | .conflicts = null | .pushed_behind = 2 | .pushed_conflicts = true | .pr.merge_state = \"UNKNOWN\"" "merge conflict - -"
}

@test "キューを使う 5：遅れていないのに DIRTY なら、マージ先を聞く" {
  check_plan '.pr.merge_state = "DIRTY"' "ask_base base_mismatch - -"
}

@test "キューを使う 6：衝突を手元で確かめられず、GitHub も調べている途中なら recheck（fallback は merge）" {
  check_plan "$BEHIND | .conflicts = null | .pr.merge_state = \"UNKNOWN\"" "recheck merge_state_unknown - merge"
}

@test "キューを使う 7：main と衝突していなければ、遅れていても取り込まない（fallback は、遅れていれば merge）" {
  # 遅れていなければ、最新の main を求められても取り込むものが無い
  check_plan "." "none no_conflict not_queued -"
  check_plan "$BEHIND" "none no_conflict not_queued merge"
  check_plan "$BEHIND | .pr.merge_state = \"BEHIND\"" "none no_conflict not_queued merge"
  # 手元で衝突しないと分かっていれば、GitHub が調べている途中（UNKNOWN）でも待たない
  check_plan "$BEHIND | .pr.merge_state = \"UNKNOWN\"" "none no_conflict not_queued merge"
  # 手元で確かめられなくても、GitHub が衝突していないと言っていれば取り込まない
  check_plan "$BEHIND | .conflicts = null | .pr.merge_state = \"BLOCKED\"" "none no_conflict not_queued merge"
}

@test "キューの案内：キューでの状態に合わせて queue を出す" {
  check_plan '.pr.merge_queue.state = "UNMERGEABLE" | .pr.merge_queue.position = 2 | .pr.merge_queue.queued = true' "none no_conflict conflict -"
  local s
  for s in QUEUED AWAITING_CHECKS MERGEABLE LOCKED; do
    check_plan ".pr.merge_queue.state = \"$s\" | .pr.merge_queue.position = 1 | .pr.merge_queue.queued = true" "none no_conflict queued -"
  done
  # 入れた直後でまだ state に出ていない・マージの直前（queued が true で state は null）も queued（#323）
  check_plan '.pr.merge_queue.queued = true' "none no_conflict queued -"
  # キューの状態を読めず、キューの中か分からない（queued が null）なら unknown（#323）
  check_plan '.pr.merge_queue.queued = null' "none no_conflict unknown -"
  check_plan "$BEHIND | .pr.merge_queue.queued = null" "none no_conflict unknown merge"
  check_plan '.pr.merge_queue.removed = {"reason": "merge_conflict", "at": "2026-10-04T16:36:30Z"}' "none no_conflict removed -"
  check_plan "$P | .pr.merge_queue.removed = {\"reason\": \"failed_checks\", \"at\": \"t\"}" "none merged_not_pushed removed push"
}

@test "キューの案内は、取り込まない（none）ときだけ出す" {
  check_plan "$BEHIND | .conflicts = true | .pr.merge_queue.state = \"UNMERGEABLE\"" "merge conflict - -"
  check_plan "$P | .pushed_conflicts = true | .pr.merge_queue.removed = {\"reason\": \"merge_conflict\", \"at\": \"t\"}" "push merged_not_pushed - -"
}

@test "キューを使わない 8：取り込み済みで未 push なら push" {
  check_plan "$NQ | $P" "push merged_not_pushed - -"
  check_plan "$NQ | $P | .pr.merge_state = \"BEHIND\"" "push merged_not_pushed - -"
}

@test "キューを使わない 9：遅れていれば、衝突の有無にかかわらず取り込む" {
  check_plan "$NQ | $BEHIND" "merge behind - -"
  check_plan "$NQ | $BEHIND | .conflicts = true | .pr.merge_state = \"DIRTY\"" "merge behind - -"
  check_plan "$NQ | $BEHIND | .conflicts = null | .pr.merge_state = \"UNKNOWN\"" "merge behind - -"
}

@test "キューを使わない 10：遅れていないのに BEHIND か DIRTY なら、マージ先を聞く" {
  check_plan "$NQ | .pr.merge_state = \"BEHIND\"" "ask_base base_mismatch - -"
  check_plan "$NQ | .pr.merge_state = \"DIRTY\"" "ask_base base_mismatch - -"
}

@test "キューを使わない 11：遅れていなければ、すでに最新" {
  check_plan "$NQ" "none up_to_date - -"
  check_plan "$NQ | .pr.merge_state = \"BLOCKED\"" "none up_to_date - -"
  check_plan "$NQ | .pr.merge_state = \"UNKNOWN\"" "none up_to_date - -"
}

@test "PR が無いとき・キューの状態を読めないときは、キューを使わないものとして決める" {
  check_plan ".pr = null | $BEHIND" "merge behind - -"
  check_plan ".pr = null | $P" "push merged_not_pushed - -"
  check_plan ".pr = null" "none up_to_date - -"
  check_plan ".pr.merge_queue = null | $BEHIND" "merge behind - -"
  check_plan '.pr.merge_queue = null | .pr.merge_state = "BEHIND"' "ask_base base_mismatch - -"
  check_plan '.pr.merge_queue = null | .pr.merge_state = "DIRTY"' "ask_base base_mismatch - -"
}

@test "origin にブランチが無ければ（pushed_behind が null）、取り込み済みで未 push とはみなさない" {
  check_plan '.pushed_behind = null | .pushed_conflicts = null' "none no_conflict not_queued -"
  check_plan "$NQ | .pushed_behind = null | .pushed_conflicts = null" "none up_to_date - -"
}

@test "入力が branch-status.sh の出力でなければ止まる" {
  run_script branch-plan.sh <<<"not json"
  assert_failure 64
  assert_output --partial "branch-status.sh の出力（JSON）を標準入力に渡してください"
  run_script branch-plan.sh <<<'{"pr": null}'
  assert_failure 64
}

@test "--help で使い方と判断の表を出し、不明な引数は拒否する" {
  run_script branch-plan.sh --help
  assert_success
  assert_output --partial "使い方: branch-status.sh | branch-plan.sh"
  assert_output --partial "判断の表"
  run_script branch-plan.sh --foo
  assert_failure 64
  assert_output --partial "不明な引数です: --foo"
}

@test "標準入力に JSON の値が複数あるときは 64（最後の値だけで判断しない）" {
  run_script branch-plan.sh <<<"$BASE $BASE"
  assert_failure 64
  run_script branch-plan.sh <<<'{"behind":"x"} '"$BASE"
  assert_failure 64
  run_script branch-plan.sh <<<"$BASE"'{"behind":"x"}'
  assert_failure 64
}
