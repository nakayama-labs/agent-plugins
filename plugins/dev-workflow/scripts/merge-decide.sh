#!/usr/bin/env bash
# 無人でマージキューに入れてよいかを、値だけから判断の表で決めて JSON で出力する（ADR 000411・000412）。
# 判断は入力の値だけで決める（git も GitHub も使わない）。組み合わせは tests/merge-decide.bats で確かめる。
# repair-next.sh と同じ作りで、pr-watch.sh（見回りの idle・wait・act・conflict の分類）には足さず、別のスクリプトにしてある。
#
# 使い方: echo '<入力 JSON>' | merge-decide.sh
#
# 入力（JSON）。真偽値でない値は終了コード 64 で止まる。省略と null は、安全側（merge にならない側）の既定で扱う
#   enabled                  設定 auto.merge.enabled。true のときだけ merge になりうる（既定 false）。
#                            allow_ai_merge は入力に入れない。それは手元で人が頼んだときの AI のマージの許可で、
#                            無人のマージの許可とは別の設定にしたため（ADR 000411）
#   require_human_approval   設定 auto.merge.require_human_approval（省略・null は true として扱う。人の approve が無ければ待つ側に倒す）
#   state                    PR の状態。OPEN 以外は対象にしない
#   fork                     フォークからの PR か（既定 true）
#   task_auto_author         PR の作成者が task-auto の GitHub App の bot か（既定 false）
#   draft                    下書きか（既定 true）
#   no_auto_merge            ラベル no-auto-merge が付いているか（既定 false）
#   queue                    none（キューに入っていない）・queued（入っている）・removed（今の head はキューから外れた）
#   checks                   必須のチェック（lint-result・test-result）。pass・pending・fail（既定 pending）
#   unresolved_threads       resolved でないレビューのスレッドの数。0 以上の整数（既定 1）
#   changes_requested        最新の状態が changes requested のレビュアーがいるか（人も bot も。省略・null は true として扱う）
#   bot_approved             coderabbitai[bot] か github-actions[bot] の approve が、最新の head に付いているか（既定 false）
#   human_approved           write 以上の人の approve が、最新の head に付いているか（既定 false）
#
# 出力（JSON）: {action, reason}
#   action  merge（マージキューに入れる。スカッシュ）・dequeue（キューから外す）・
#           wait（今は入れない。次の機会に判定し直す。理由のコメントは付けない）・
#           skip（無人のマージの対象外。何もしない）・stop（人が直すまで入れない。連鎖も止まる）
#
# 判断の表（上から順に当てはめる）
#   1. enabled が true でない                            → skip（disabled）
#   2. state が OPEN でない                              → skip（not_open）
#   3. fork が false でない                              → skip（fork）
#   4. task_auto_author が true でない                   → skip（not_task_auto）
#   5. draft が false でない                             → skip（draft）
#   6. no_auto_merge が true で、queue が queued         → dequeue（no_auto_merge）
#   7. no_auto_merge が true                             → stop（no_auto_merge）
#   8. queue が queued                                   → wait（queued。changes_requested やチェックの失敗は見ない。キューの CI が決める。
#                                                           キューから外すのは、6 の no_auto_merge のときだけ）
#   9. queue が removed                                  → stop（removed_from_queue。その head は二度と入れない）
#  10. changes_requested が true                         → wait（changes_requested）
#  11. checks が pending                                 → wait（checks_pending）、fail → wait（checks_failed）
#  12. unresolved_threads が 1 以上                      → wait（unresolved_threads）
#  13. bot_approved が true でない                       → wait（no_bot_approval）
#  14. require_human_approval が true で human_approved が true でない → wait（no_human_approval）
#  15. 上のどれでもない                                  → merge（ready）
#   queue が none・queued・removed 以外、checks が pass・pending・fail 以外の値は、終了コード 64 で止まる
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

input="$(cat)"
jq -e '
  def bool: . == null or type == "boolean";
  type == "object"
  and (.enabled | bool) and (.require_human_approval | bool) and (.fork | bool) and (.task_auto_author | bool)
  and (.draft | bool) and (.no_auto_merge | bool) and (.changes_requested | bool) and (.bot_approved | bool)
  and (.human_approved | bool)
  and (.unresolved_threads == null or ((.unresolved_threads | type) == "number" and .unresolved_threads >= 0 and .unresolved_threads == (.unresolved_threads | floor)))
  and (.state == null or (.state | type) == "string")
  and (.queue == null or (.queue | IN("none", "queued", "removed")))
  and (.checks == null or (.checks | IN("pass", "pending", "fail")))' <<<"$input" >/dev/null 2>&1 \
  || dw_die "入力の型か値が違います（真偽値の項目、数値の unresolved_threads、queue は none・queued・removed、checks は pass・pending・fail）" 64

# 既定の値は、検証の後に、ここで1か所に置く（検証は null か許可値だけを通すので、false などが既定の値に化けることは無い）
jq -c '
  def r($a; $why): {action: $a, reason: $why};
  # false は // で既定の値に化けるので、真偽値の既定は null かどうかで置く
  (.queue //= "none" | .checks //= "pending" | .unresolved_threads //= 1
   | (if .changes_requested == null then .changes_requested = true else . end)
   | (if .require_human_approval == null then .require_human_approval = true else . end))
  | if .enabled != true then r("skip"; "disabled")
  elif .state != "OPEN" then r("skip"; "not_open")
  elif .fork != false then r("skip"; "fork")
  elif .task_auto_author != true then r("skip"; "not_task_auto")
  elif .draft != false then r("skip"; "draft")
  elif .no_auto_merge == true and .queue == "queued" then r("dequeue"; "no_auto_merge")
  elif .no_auto_merge == true then r("stop"; "no_auto_merge")
  elif .queue == "queued" then r("wait"; "queued")
  elif .queue == "removed" then r("stop"; "removed_from_queue")
  elif .changes_requested == true then r("wait"; "changes_requested")
  elif .checks == "pending" then r("wait"; "checks_pending")
  elif .checks == "fail" then r("wait"; "checks_failed")
  elif .unresolved_threads >= 1 then r("wait"; "unresolved_threads")
  elif .bot_approved != true then r("wait"; "no_bot_approval")
  elif .require_human_approval == true and .human_approved != true then r("wait"; "no_human_approval")
  else r("merge"; "ready") end' <<<"$input"
