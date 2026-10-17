#!/usr/bin/env bash
# 連鎖（マージの後に次の Issue へ進める）で、次の Issue へ進んでよいかを、値だけから判断の表で決めて JSON で出力する（ADR 000411）。
# 判断は入力の値だけで決める（git も GitHub も使わない）。組み合わせは tests/chain-decide.bats で確かめる。
# merge-decide.sh・repair-next.sh と同じ作りで、入力は task-auto-sequence が、設定・PR・連鎖の記録（chain-record.sh）・
# next-tasks.sh・auto-check.sh から集める。
#
# 使い方: echo '<入力 JSON>' | chain-decide.sh
#
# 入力（JSON）。真偽値でない値は終了コード 64 で止まる。省略と null は、安全側（next にならない側）の既定で扱う
#   chain_enabled     設定 auto.chain.enabled（既定 false）
#   auto_enabled      設定 auto.enabled（既定 false）
#   merge_enabled     設定 auto.merge.enabled（既定 false）。連鎖は無人のマージが前提（ADR 000411）
#   max               設定 auto.chain.max。1 以上の整数（省略・null は 1 として扱う。進めない側に倒す）
#   wait_minutes      設定 auto.chain.wait_minutes。1 以上の整数（省略・null は 1 として扱う。待たずに止める側に倒す）
#   record_readable   連鎖の記録（最初の Issue のコメント）を読めたか（既定 false）
#   count             記録にある、これまでに進めた Issue の数（最初の Issue も数える。0 以上の整数。既定は max（上限に達した扱い））
#   pr_state          直前の Issue の PR の状態。MERGED・OPEN・CLOSED（既定 OPEN）
#   no_auto_merge     その PR にラベル no-auto-merge が付いているか（既定 false）
#   waited_minutes    PR を出して task-auto が終わった時刻から、今までの分（0 以上の整数。既定 0）
#   next              task-next の先頭の Issue の番号（親・待ち・保留は除く。無ければ null）
#   next_action       その Issue への auto-check.sh の action（proceed のときだけ進める）
#
# 出力（JSON）: {action, reason}
#   action  next（次の Issue へ進む）・wait（PR がまだマージされていない。待つ）・stop（連鎖を終える。止まった理由を伝える）
#
# 判断の表（上から順に当てはめる）
#   1. chain_enabled が true でない                       → stop（chain_disabled）
#   2. auto_enabled が true でない                        → stop（auto_disabled）
#   3. merge_enabled が true でない                       → stop（merge_disabled）
#   4. record_readable が true でない                     → stop（record_unreadable。件数を数えられないので終える）
#   5. no_auto_merge が true                              → stop（no_auto_merge。マージせず、次へも進まない）
#   6. pr_state が CLOSED                                 → stop（pr_closed。マージされずに閉じた）
#   7. pr_state が OPEN で waited_minutes ≥ wait_minutes  → stop（wait_timeout）
#   8. pr_state が OPEN                                   → wait（pr_open。次の機会に判定し直す）
#   9. count が max 以上                                  → stop（limit）
#  10. next が無い                                        → stop（no_next）
#  11. next_action が proceed でない                      → stop（next_not_startable）
#  12. 上のどれでもない                                   → next（ready）
#   pr_state が MERGED・OPEN・CLOSED 以外の値、max・wait_minutes・count・waited_minutes が整数でない・範囲外のときは、終了コード 64 で止まる
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
# JSON の値が複数あると、jq は値ごとに検証・判定して、最後の値だけが検証を通ってしまうので、先に1つだけかを確かめる
jq -s -e 'length == 1' <<<"${input}" >/dev/null 2>&1 \
  || dw_die "入力（JSON）は1つのオブジェクトにしてください" 64
jq -e '
  def bool: . == null or type == "boolean";
  def int($min): . == null or (type == "number" and . >= $min and . == floor);
  type == "object"
  and (.chain_enabled | bool) and (.auto_enabled | bool) and (.merge_enabled | bool)
  and (.record_readable | bool) and (.no_auto_merge | bool)
  and (.max | int(1)) and (.wait_minutes | int(1)) and (.count | int(0)) and (.waited_minutes | int(0))
  and (.pr_state == null or (.pr_state | IN("MERGED", "OPEN", "CLOSED")))
  and (.next == null or ((.next | type) == "number" and .next >= 1 and .next == (.next | floor)))
  and (.next_action == null or (.next_action | type) == "string")' <<<"$input" >/dev/null 2>&1 \
  || dw_die "入力の型か値が違います（真偽値の項目、max・wait_minutes は1以上の整数、count・waited_minutes は0以上の整数、pr_state は MERGED・OPEN・CLOSED、next は Issue の番号か null）" 64

# 既定の値は、検証の後に、ここで1か所に置く（false などが既定の値に化けないよう、null かどうかで置く）
jq -c '
  def r($a; $why): {action: $a, reason: $why};
  (.max //= 1 | .wait_minutes //= 1 | .waited_minutes //= 0 | .pr_state //= "OPEN" | .count //= .max)
  | if .chain_enabled != true then r("stop"; "chain_disabled")
  elif .auto_enabled != true then r("stop"; "auto_disabled")
  elif .merge_enabled != true then r("stop"; "merge_disabled")
  elif .record_readable != true then r("stop"; "record_unreadable")
  elif .no_auto_merge == true then r("stop"; "no_auto_merge")
  elif .pr_state == "CLOSED" then r("stop"; "pr_closed")
  elif .pr_state == "OPEN" and .waited_minutes >= .wait_minutes then r("stop"; "wait_timeout")
  elif .pr_state == "OPEN" then r("wait"; "pr_open")
  elif .count >= .max then r("stop"; "limit")
  elif .next == null then r("stop"; "no_next")
  elif .next_action != "proceed" then r("stop"; "next_not_startable")
  else r("next"; "ready") end' <<<"$input"
