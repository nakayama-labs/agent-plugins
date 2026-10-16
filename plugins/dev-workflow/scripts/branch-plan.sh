#!/usr/bin/env bash
# branch-status.sh の出力（JSON）を標準入力で受け取り、branch-update が次にすること（plan）を JSON で出力する。
# 判断は、入力の値だけで決める（git も GitHub も使わない）。組み合わせは tests/branch-plan.bats で確かめる。
# 取り込むかの判断を SKILL.md の文章に書くと、テストできず、組み合わせの抜けが残るため（ADR 000210）。
#
# 使い方: branch-status.sh | branch-plan.sh
#
# 出力（JSON）:
#   action    次にすること。merge（取り込む）・push（手元で取り込み済みの分を push する）・none（取り込まない）・
#             recheck（GitHub がまだ衝突を調べていて、手元でも確かめられない。待って調べ直す）・
#             ask_base（GitHub は遅れや衝突があると言うが、手元では取り込み先（base）を取り込み済み。マージ先を聞く）
#   reason    理由。behind（遅れている）・conflict（取り込み先（base）と衝突する）・merged_not_pushed（手元では取り込み済みで、
#             まだ push していない）・no_conflict（取り込み先（base）と衝突しない）・up_to_date（遅れていない）・
#             merge_state_unknown（衝突するか分からない）・base_mismatch（GitHub と手元で判断が食い違う）
#   queue     キューの案内。キューを使い、action が none のときだけ。conflict（キューの中で先に並んだ PR と衝突した）・
#             queued（並んでいる。入れた直後・マージの直前も）・removed（外れたまま。キューに入れた後に push していない）・
#             not_queued（入っていない。入れた後に push して、まだ入れ直していないときも）・unknown（キューの状態を
#             読めず、キューの中か分からない。queued が null）。ほかは null
#   fallback  ユーザーに確かめてからすること（merge・push）。action が recheck なら、調べ直しても分からないとき。
#             none なら、ユーザーが最新の取り込み先（base）を求めたとき（取り込むものが無ければ null）。ほかは null
#
# 判断の表（上から順に当てはめる。P は、手元では取り込み済みで、まだ push していないこと：behind が 0 で、
# pushed_behind が 1 以上。merge_state は PR の mergeStateStatus）
#   キューを使う（pr.merge_queue.enabled が true）
#     1. P で、pushed_conflicts が true か merge_state が DIRTY  → push
#     2. P で、pushed_conflicts が null で merge_state が UNKNOWN → recheck（fallback: push）
#     3. P で、それ以外                                          → none（merged_not_pushed。fallback: push）
#     4. conflicts か pushed_conflicts が true か、merge_state が DIRTY で behind が 1 以上 → merge（conflict）
#     5. merge_state が DIRTY（behind は 0）                     → ask_base
#     6. conflicts が null で merge_state が UNKNOWN             → recheck（fallback: merge）
#     7. それ以外                                                → none（no_conflict。fallback: behind が 1 以上なら merge）
#   キューを使わない（PR が無い、キューの状態を読めないときも）
#     8. P                                                       → push
#     9. behind が 1 以上                                        → merge（behind）
#    10. merge_state が BEHIND か DIRTY（behind は 0）           → ask_base
#    11. それ以外                                                → none（up_to_date）
#   queue（3・7 のとき）: キューでの状態が UNMERGEABLE なら conflict、キューの中（queued。並んでいる・入れた直後で
#   まだ状態に出ていない・マージの直前）なら queued、キューの中か分からない（queued が null。キューの状態を読めなかった）
#   なら unknown、外れたまま（removed）なら removed、どれでもなければ not_queued
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

status="$(cat)"
# JSON の値が複数あると、jq は値ごとに検証・判定して、最後の値だけが検証を通ってしまうので、先に1つだけかを確かめる
jq -s -e 'length == 1' <<<"${status}" >/dev/null 2>&1 \
  || dw_die "branch-status.sh の出力（JSON）を標準入力に渡してください（値は1つだけ）" 64
jq -e '(.behind | type) == "number"' <<<"$status" >/dev/null 2>&1 \
  || dw_die "branch-status.sh の出力（JSON）を標準入力に渡してください" 64

jq -c '
  def plan($action; $reason): {action: $action, reason: $reason, queue: null, fallback: null};
  .pr.merge_state as $state
  | ((.pr.merge_queue.enabled // false) == true) as $queue
  | (.behind == 0 and (.pushed_behind // 0) >= 1) as $merged_not_pushed
  | (if .pr.merge_queue.state == "UNMERGEABLE" then "conflict"
     elif .pr.merge_queue.queued == true then "queued"
     elif .pr.merge_queue.queued == null then "unknown"
     elif .pr.merge_queue.removed != null then "removed"
     else "not_queued" end) as $guide
  | if $queue then
      if $merged_not_pushed then
        if .pushed_conflicts == true or $state == "DIRTY" then plan("push"; "merged_not_pushed")
        elif .pushed_conflicts == null and $state == "UNKNOWN" then plan("recheck"; "merge_state_unknown") + {fallback: "push"}
        else plan("none"; "merged_not_pushed") + {queue: $guide, fallback: "push"} end
      elif .conflicts == true or .pushed_conflicts == true or ($state == "DIRTY" and .behind >= 1) then plan("merge"; "conflict")
      elif $state == "DIRTY" then plan("ask_base"; "base_mismatch")
      elif .conflicts == null and $state == "UNKNOWN" then plan("recheck"; "merge_state_unknown") + {fallback: "merge"}
      else plan("none"; "no_conflict") + {queue: $guide, fallback: (if .behind >= 1 then "merge" else null end)} end
    else
      if $merged_not_pushed then plan("push"; "merged_not_pushed")
      elif .behind >= 1 then plan("merge"; "behind")
      elif $state == "BEHIND" or $state == "DIRTY" then plan("ask_base"; "base_mismatch")
      else plan("none"; "up_to_date") end
    end' <<<"$status"
