#!/usr/bin/env bash
# PR を、一定の間隔で pr-watch.sh に問い合わせて見回し、action が wait でなくなるか、上限に達したら、最後の結果を出力して終わる。
# gh-pr-check の見回り（ADR 000340）が、背景で実行する。待っている間は Claude を動かさないので、使用量を消費しない。
# 何も書き込まない（pr-watch.sh を呼ぶだけ）。
#
# 使い方: pr-watch-loop.sh [--pr N] [--interval 秒] [--max-count 回数 | --max-minutes 分]
#   --pr N            PR の番号（#N でもよい）。省略すると今のブランチの PR
#   --interval 秒     問い合わせる間隔（既定 60。1 以上 86400 以下の整数）
#   --max-count 回数  pr-watch.sh を呼ぶ回数の上限（1 以上の整数）
#   --max-minutes 分  見回る時間の上限（既定 60。1 以上 10080（7 日）以下の整数。間隔の合計で数える）。--max-count とは同時に指定できない
#
# 出力（JSON）: 最後の pr-watch.sh の出力（pr・action・reasons・respond・details）に、watch を足したもの。
#   watch   ended_by（action：action が wait でなくなった／limit：上限に達した）・polls（pr-watch.sh を呼んだ回数）・
#           elapsed_seconds（間隔の合計）
#   ended_by が action のときは、action（idle・act・conflict・stop）で次にすることを分ける。limit のときは action は wait のまま
#
# 待つ秒数は環境変数 DW_WAIT_SLEEP で差し替えられる（テスト用。上限の数え方は変わらない）。
# 止まるとき: 引数の誤り（64）。pr-watch.sh が失敗したら、その終了コードとメッセージをそのまま伝える
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

pr="" interval=60 max_count="" max_minutes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr | --interval | --max-count | --max-minutes)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "$1 に値がありません" 64
      case "$1" in
        --pr) pr="$2" ;;
        --interval) interval="$2" ;;
        --max-count) max_count="$2" ;;
        --max-minutes) max_minutes="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
# 1 以上の整数か。上限（第3引数）があれば、それ以下か（間隔と時間の積が bash の整数の範囲を超えないようにする。--max-count は比べるだけなので上限を置かない）
positive() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] || dw_die "$1 は 1 以上の整数にしてください: $2" 64
  if [ -n "${3:-}" ]; then
    # 桁数で先に弾く（桁あふれする大きさの数を、数として比べない）
    { [ "${#2}" -le 7 ] && [ "$2" -le "$3" ]; } || dw_die "$1 は $3 以下にしてください: $2" 64
  fi
}
positive --interval "$interval" 86400
[ -z "$max_count" ] || positive --max-count "$max_count"
[ -z "$max_minutes" ] || positive --max-minutes "$max_minutes" 10080
{ [ -z "$max_count" ] || [ -z "$max_minutes" ]; } || dw_die "--max-count と --max-minutes は同時に指定できません" 64
[ -z "${DW_WAIT_SLEEP:-}" ] || [[ "$DW_WAIT_SLEEP" =~ ^[0-9]+$ ]] || dw_die "DW_WAIT_SLEEP は秒数（0 以上の整数）にしてください" 64
[ -n "$max_count" ] || [ -n "$max_minutes" ] || max_minutes=60

args=()
[ -z "$pr" ] || args+=(--pr "$pr")

polls=0
while :; do
  # pr-watch.sh のエラー（終了コードと1行のメッセージ）はそのまま伝える
  if [ ${#args[@]} -gt 0 ]; then
    out="$("$BASH" "$DW_SCRIPTS_DIR/pr-watch.sh" "${args[@]}")" || exit $?
  else
    out="$("$BASH" "$DW_SCRIPTS_DIR/pr-watch.sh")" || exit $?
  fi
  polls=$((polls + 1))
  elapsed=$(((polls - 1) * interval))
  ended=""
  if [ "$(jq -r .action <<<"$out")" != wait ]; then
    ended=action
  elif [ -n "$max_count" ] && [ "$polls" -ge "$max_count" ]; then
    ended=limit
  elif [ -n "$max_minutes" ] && [ $((polls * interval)) -gt $((max_minutes * 60)) ]; then
    # 次の問い合わせの時刻が上限を超える
    ended=limit
  fi
  if [ -n "$ended" ]; then
    jq -c --arg e "$ended" --argjson p "$polls" --argjson s "$elapsed" '. + {watch: {ended_by: $e, polls: $p, elapsed_seconds: $s}}' <<<"$out"
    exit 0
  fi
  sleep "${DW_WAIT_SLEEP:-$interval}"
done
