#!/usr/bin/env bats
# merge-decide.sh の判断の表（スクリプトの先頭のコメント）を、行ごとと、その境目で確かめる。
# 入力は JSON なので、git も GitHub も使わない。

load test_helper

# 既定：すべての条件を満たす（merge になる）
READY='{"enabled":true,"require_human_approval":false,"state":"OPEN","fork":false,"task_auto_author":true,"draft":false,"no_auto_merge":false,"queue":"none","checks":"pass","unresolved_threads":0,"changes_requested":false,"bot_approved":true,"human_approved":false}'

# 使い方: check <jq のフィルタ> <期待する「action reason」>
check() {
  local input
  input="$(jq -c "$1" <<<"$READY")"
  run_script merge-decide.sh <<<"$input"
  assert_success
  assert_equal "$(jq -r '[.action, .reason] | join(" ")' <<<"$output")" "$2"
}

@test "全部の条件を満たせば merge" {
  check '.' "merge ready"
}

@test "表 1：auto.merge.enabled が false・省略なら、ほかが全部満たされていても merge を返さない" {
  check '.enabled = false' "skip disabled"
  check 'del(.enabled)' "skip disabled"
  check '.enabled = null' "skip disabled"
  # allow_ai_merge は見ない（true にしても、enabled が false なら merge しない。enabled が true なら allow_ai_merge が無くても merge する）
  check '.enabled = false | .allow_ai_merge = true' "skip disabled"
  check '.allow_ai_merge = false' "merge ready"
}

@test "表 2〜5：対象外の PR（OPEN でない・フォーク・task-auto が作っていない・下書き）は skip" {
  check '.state = "MERGED"' "skip not_open"
  check '.state = "CLOSED"' "skip not_open"
  check 'del(.state)' "skip not_open"
  check '.fork = true' "skip fork"
  check 'del(.fork)' "skip fork"
  check '.task_auto_author = false' "skip not_task_auto"
  check 'del(.task_auto_author)' "skip not_task_auto"
  check '.draft = true' "skip draft"
  check 'del(.draft)' "skip draft"
  # 対象外は、止める印やキューの状態より先
  check '.fork = true | .no_auto_merge = true | .queue = "queued"' "skip fork"
}

@test "表 6〜7：no-auto-merge は、キューに入っていれば外し、入っていなければ止まる" {
  check '.no_auto_merge = true | .queue = "queued"' "dequeue no_auto_merge"
  check '.no_auto_merge = true' "stop no_auto_merge"
  check '.no_auto_merge = true | .queue = "removed"' "stop no_auto_merge"
}

@test "表 8〜9：キューに入っていれば待ち、今の head がキューから外れていれば止まる" {
  check '.queue = "queued"' "wait queued"
  check '.queue = "removed"' "stop removed_from_queue"
  # 外れた head は、ほかの条件を満たしていても入れ直さない
  check '.queue = "removed" | .human_approved = true' "stop removed_from_queue"
}

@test "表 10：changes requested が1人でもいれば待つ（approve があっても）" {
  check '.changes_requested = true' "wait changes_requested"
  check '.changes_requested = true | .human_approved = true' "wait changes_requested"
}

@test "表 11：必須のチェックが pass でなければ待つ（省略は pending）" {
  check '.checks = "pending"' "wait checks_pending"
  check 'del(.checks)' "wait checks_pending"
  check '.checks = "fail"' "wait checks_failed"
}

@test "表 12：resolved でないスレッドが1つでもあれば待つ（省略は未解決あり）" {
  check '.unresolved_threads = 1' "wait unresolved_threads"
  check 'del(.unresolved_threads)' "wait unresolved_threads"
  check '.unresolved_threads = 0' "merge ready"
}

@test "表 13：最新の head への bot の approve が無ければ待つ" {
  check '.bot_approved = false' "wait no_bot_approval"
  check 'del(.bot_approved)' "wait no_bot_approval"
  # 人の approve は bot の approve の代わりにならない
  check '.bot_approved = false | .human_approved = true' "wait no_bot_approval"
}

@test "表 14：require_human_approval が true のときだけ、人の approve も要る" {
  check '.require_human_approval = true' "wait no_human_approval"
  check '.require_human_approval = true | .human_approved = true' "merge ready"
  check '.require_human_approval = false | .human_approved = false' "merge ready"
  check '.require_human_approval = true | .bot_approved = false | .human_approved = true' "wait no_bot_approval"
}

@test "入力の型・値が違うときは終了コード 64 で止まる" {
  run_script merge-decide.sh <<<'{"enabled":"true"}'
  assert_failure 64
  run_script merge-decide.sh <<<'{"queue":"waiting"}'
  assert_failure 64
  run_script merge-decide.sh <<<'{"checks":"success"}'
  assert_failure 64
  run_script merge-decide.sh <<<'{"unresolved_threads":"0"}'
  assert_failure 64
  run_script merge-decide.sh <<<'[]'
  assert_failure 64
}

@test "--help は判断の表を出し、不明な引数は 64" {
  run_script merge-decide.sh --help
  assert_success
  assert_output --partial "判断の表"
  assert_output --partial "allow_ai_merge は入力に入れない"
  run_script merge-decide.sh --nope
  assert_failure 64
}
