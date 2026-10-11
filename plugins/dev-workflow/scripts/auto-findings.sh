#!/usr/bin/env bash
# task-auto が範囲外とした指摘の記録（JSON のファイル）を検査し、PR を作る前に、全件に起票した番号か起票しなかった理由があることを確かめる。
# 記録は task-auto が書く（ワークツリーの外の一時ファイル）。範囲外の指摘をモデルの記憶の中にだけ置くと、落としても気付けないため
# （#307）、ファイルに残し、数と中身をスクリプトで確かめる。何も変えない。
#
# 記録の形: 指摘ごとのオブジェクトの配列。範囲外の指摘が1件も無ければ []。
#   summary      指摘の要約（ファイルと行を含める。空でない文字列）
#   disposition  扱い。次のどれか
#                  filed       起票した。issue に起票した Issue の番号が要る
#                  duplicate   重複していたので起票しなかった。issue に既にある Issue の番号が要る
#                  breaking    破壊的変更になるので起票しなかった。reason が要る
#                  limit       上限（auto.max_new_issues）で起票しなかった。reason が要る
#                  failed      起票に失敗した。reason が要る
#   issue        Issue の番号（正の整数）。filed・duplicate で要る
#   reason       起票しなかった理由（空でない文字列）。breaking・limit・failed で要る
#
# 使い方: auto-findings.sh --file PATH --expect N
#   --file PATH  記録のファイル
#   --expect N   手順4のレビューのすべての周の一覧から数え直した、範囲外とした指摘の数（0 以上の整数）。
#                記録の件数と同じでなければ止まる（記録に書き出し忘れた指摘を見つけるため。記録どうしの比べでは見つけられない）
#
# 止まるとき: --file・--expect が無い・--expect が整数でない・記録のファイルが無い（終了コード 64）、
#             記録が JSON の配列でない・件数が --expect と違う・番号も理由も無い指摘がある・disposition が使えない値（2）
#
# 出力: {file, total, expected, counts（disposition ごとの件数）, filed（起票した Issue の番号）, duplicates（重複で起票しなかった指摘の既存の Issue の番号）}
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

file="" expect=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file | --expect)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --file) file="$2" ;;
        --expect) expect="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$file" ] || dw_die "--file は必須です" 64
[ -n "$expect" ] || dw_die "--expect は必須です（手順4のレビューの一覧から数え直した、範囲外とした指摘の数）" 64
case "$expect" in
  *[!0-9]*) dw_die "--expect は 0 以上の整数にしてください: $expect" 64 ;;
esac
[ -f "$file" ] || dw_die "範囲外の指摘の記録のファイルがありません: $file（指摘が無くても [] を書いてください）" 64

jq -e 'type == "array"' "$file" >/dev/null 2>&1 \
  || dw_die "範囲外の指摘の記録が JSON の配列ではありません: $file" 2

# 件数が違えば、書き出し忘れ（または多く書いた）ので止まる。--expect は 10 進に直す（先頭の 0 を 8 進にしない）
total="$(jq length "$file")"
expect_n="$(jq -n --arg e "$expect" '$e | tonumber')"
[ "$total" -eq "$expect_n" ] \
  || dw_die "範囲外の指摘の記録は ${total} 件ですが、レビューの一覧から数え直すと ${expect_n} 件です。書き出し忘れた指摘を記録に足してください" 2

# 番号も理由も無い指摘、扱いが決まっていない指摘を探す（1件ずつ、位置と要約を添える）
# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
problems="$(jq -r '
  def nonblank: type == "string" and test("\\S");
  def posint: type == "number" and . >= 1 and . == floor;
  to_entries[]
  | .key as $i | .value as $e
  | (if ($e | type) != "object" then "オブジェクトではありません"
     elif ($e.summary | nonblank | not) then "summary が空です"
     elif (["filed", "duplicate", "breaking", "limit", "failed"] | index($e.disposition) | not) then "disposition が使えない値です（\($e.disposition // "なし")）"
     elif ($e.disposition == "filed" or $e.disposition == "duplicate") and (($e.issue | posint) | not)
       then "\($e.disposition) なのに、issue に Issue の番号がありません"
     elif ($e.disposition == "breaking" or $e.disposition == "limit" or $e.disposition == "failed") and (($e.reason | nonblank) | not)
       then "\($e.disposition) なのに、reason に起票しなかった理由がありません"
     else empty end) as $why
  | "\($i + 1) 件目（\(if ($e | type) == "object" then ($e.summary // "要約なし") else "不明" end)）：\($why)"' "$file")"
if [ -n "$problems" ]; then
  dw_die "範囲外の指摘の記録に、起票した番号も起票しなかった理由も無い指摘があります。$(printf '%s' "$problems" | tr '\n' ' ')" 2
fi

# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
jq --arg f "$file" --argjson ex "$expect_n" '{
  file: $f,
  total: length,
  expected: $ex,
  counts: (reduce .[] as $e ({filed: 0, duplicate: 0, breaking: 0, limit: 0, failed: 0}; .[$e.disposition] += 1)),
  filed: [.[] | select(.disposition == "filed") | .issue],
  duplicates: [.[] | select(.disposition == "duplicate") | .issue]
}' "$file"
