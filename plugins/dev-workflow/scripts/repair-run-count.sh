#!/usr/bin/env bash
# 無人の push の回数（repair.max_pushes_per_pr と比べる値）を、PR のコメントの repair-run のマーカーから数えて JSON で出力する
# （ADR 000339「push の回数の数え方」）。判断は入力の値だけで決める（git も GitHub も使わない）。
#
# 使い方: gh api --paginate --slurp 'repos/{owner}/{repo}/issues/<PR番号>/comments?per_page=100' | repair-run-count.sh --head SHA [--logins L1,L2] [--since TIME] [--commits FILE]
#   標準入力  PR のコメント。`gh api --paginate --slurp 'repos/{owner}/{repo}/issues/<PR番号>/comments?per_page=100'` の出力（配列の配列。
#             --slurp の無い配列も可）を勧める。`gh pr view <PR番号> --json comments` の出力（{comments: [...]}）も読めるが、
#             コメントが多い PR では全部を返さないことがあり、数え落とす
#   --head SHA    今の PR の head の sha（16 進で 7 文字以上）
#   --logins L    数える投稿者のログイン名（, 区切り。区切りの前後の空白は除く。repair.reply_logins）。省略すると投稿者を問わない。
#                 大文字小文字と末尾の [bot] を除いて比べる（gh pr view では app、gh api では app[bot] と綴りが違うため）
#   --commits FILE  PR のコミットの一覧（`gh api --paginate --slurp 'repos/{owner}/{repo}/pulls/<PR番号>/commits?per_page=100'` の出力。
#                 配列の配列。--slurp の無い配列も可）。指定すると、head が進んだ回のうち、進んだ先のコミット（`head` の sha を親に持つコミット）の
#                 committer が --logins のもの（無人の実行のもの）の回だけを数える。bot など人以外の push で head が進んだ回は、
#                 無人の push が失敗していても head が進むので、数えない（ADR 000380）。進んだ先のコミットが一覧に無いとき・committer の
#                 ログインが読めないときは、少なく数えて上限を超えないように、数える側に倒す。省略すると、head が進んだ回をすべて数える
#   --since TIME  この時刻（ISO 8601。例: 2026-10-10T01:02:03Z。小数の秒・+09:00 などの時差も可）より後のコメントだけを
#                 数える（再開の起点。ADR 000285）。日時が読めないコメント（ありえない日時・範囲の外の時差も）は、落とさずに数える側に倒す
#
# 数え方:
#   - 本文の先頭が <!-- dev-workflow:repair-run head=<sha> --> のコメントは、<sha> が今の head と違うもの（PR の head が
#     そこから進んだもの）だけを、<sha> の値ごとに1回と数える。<sha> が今の head と同じもの（push に失敗した・push の前に
#     止まった回）は数えない。sha は大文字と小文字を区別しない。今の head と比べるときは、長さが違えば、短い方が長い方の先頭と
#     一致すれば同じとみなす。<sha> の値ごとにまとめるときは、完全に一致するものだけを同じとみなす（長さの違う同じコミットは
#     別に数える。先頭が同じ別のコミットを1つにまとめて、少なく数えないため）
#   - 本文の先頭が <!-- dev-workflow:repair-run --> の古い形式（head が無い）と、<sha> が 7 文字未満で比べられないものは、
#     1つを1回と数える（少なく数えて上限を超えないように、多い側に倒す。ADR 000285）
#
# 出力（JSON）: {count（数えた回数）, pushed_heads（数えた head の sha）, legacy（head が無いか短すぎて1つ1回と数えた数）,
#               not_pushed（head が今の head と同じで数えなかった数）, other_pushed（--commits で、head が進んだのが無人の実行以外の
#               committer のコミットだったために数えなかった head の数）, runs（対象の repair-run の数）}
#
# 止まるとき: --head が無い・16 進で 7 文字以上でない・--since が読める ISO 8601 でない（ありえない日時・範囲の外の時差も）・不明な引数・
#             入力が JSON のコメントの一覧でない（64）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

head_sha="" logins="" since="" commits=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head | --logins | --since | --commits)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --head) head_sha="$2" ;;
        --logins) logins="$2" ;;
        --since) since="$2" ;;
        --commits) commits="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$head_sha" ] || dw_die "--head は必須です" 64
case "$head_sha" in
  *[!0123456789abcdefABCDEF]* | ?????? | ????? | ???? | ??? | ?? | ?)
    dw_die "--head は 16 進で 7 文字以上の sha にしてください: ${head_sha}" 64 ;;
esac

# ISO 8601 の日時を UNIX 秒にする。jq の fromdateiso8601 は小数の秒と時差を読めないので、先に分けて整える。
# 読めなければ null（書式は合うがありえない日時（13 月・25 時など）と、範囲の外の時差（時が 14 を超える・分が 59 を超える）も）
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
jq_epoch='def epoch:
  (if type == "string" then (first(capture("^(?<d>(?<Y>[0-9]{4})-(?<M>[0-9]{2})-(?<D>[0-9]{2})T(?<h>[0-9]{2}):(?<m>[0-9]{2}):(?<s>[0-9]{2}))(?<f>\\.[0-9]+)?(?<z>Z|z|(?<sign>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2}))$")) // null) else null end) as $m
  | if $m == null then null
    elif ($m.M | tonumber) < 1 or ($m.M | tonumber) > 12 or ($m.D | tonumber) < 1 or ($m.D | tonumber) > 31
      or ($m.h | tonumber) > 23 or ($m.m | tonumber) > 59 or ($m.s | tonumber) > 60 then null
    elif $m.sign != null and (($m.oh | tonumber) > 14 or ($m.om | tonumber) > 59) then null
    else (try (($m.d + "Z") | fromdateiso8601) catch null) as $base
      | if $base == null then null
        else (if $m.f == null then 0 else ("0" + $m.f | tonumber) end) as $frac
          | (if $m.sign == null then 0
             else (if $m.sign == "-" then -1 else 1 end) * (($m.oh | tonumber) * 3600 + ($m.om | tonumber) * 60)
             end) as $off
          | $base + $frac - $off
        end
    end;'
if [ -n "$since" ]; then
  jq -en --arg t "$since" "$jq_epoch"'$t | epoch | . != null' >/dev/null 2>&1 \
    || dw_die "--since は ISO 8601 の時刻（例: 2026-10-10T01:02:03Z）にしてください: ${since}" 64
fi

# コメントは長くなりうるので、引数ではなくファイルで jq に渡す
if [ -n "$commits" ]; then
  [ -f "$commits" ] || dw_die "--commits のファイルがありません: ${commits}" 64
  jq -e 'type == "array"' "$commits" >/dev/null 2>&1 \
    || dw_die "--commits は、gh api の pulls/<番号>/commits の出力（JSON の配列）にしてください: ${commits}" 64
else
  commits=/dev/null
fi
input_file="$(mktemp "${TMPDIR:-/tmp}/repair-run-count.XXXXXX")"
trap 'rm -f "$input_file"' EXIT
cat >"$input_file"
jq -e '(type == "object" and (.comments | type) == "array") or type == "array"' "$input_file" >/dev/null 2>&1 \
  || dw_die "入力は、gh pr view --json comments か gh api の issues/<番号>/comments の出力（JSON）にしてください" 64

# --commits が無いときは /dev/null を読ませ、$have_commits を false にする
if [ "$commits" = /dev/null ]; then have_commits=false; else have_commits=true; fi
jq -c --argjson have_commits "$have_commits" --slurpfile commit_lists "$commits" --arg head "$head_sha" --arg logins "$logins" --arg since "$since" "$DW_JQ_LOGIN_NORM$jq_epoch"'
  # 長さの違う sha は、短い方が長い方の先頭と一致すれば同じ（どちらも小文字にしてある）
  def same_sha($a; $b): ($a | startswith($b)) or ($b | startswith($a));
  (if type == "object" then .comments else . end | flatten) as $all
  | ($logins | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != "") | norm)) as $allowed
  | (if $since == "" then null else ($since | epoch) end) as $from
  | [ $all[]
      | select(type == "object")
      | ((.author.login // .user.login // "") | norm) as $who
      | ((.createdAt // .created_at) | epoch) as $at
      | select(($allowed | length) == 0 or ($who | IN($allowed[])))
      # 日時が読めないコメントは、落とさずに数える側に倒す
      | select($from == null or $at == null or $at > $from)
      | (.body // "") | strings | capture("^\\s*<!-- dev-workflow:repair-run(?: head=(?<sha>[0-9A-Fa-f]+))? -->")
      | .sha
    ] as $runs
  | ($head | ascii_downcase) as $now
  | [ $runs[] | select(. != null and length >= 7) | ascii_downcase ] as $with_head
  | ([ $runs[] | select(. == null or length < 7) ] | length) as $legacy
  | [ $with_head[] | select(same_sha(.; $now) | not) ] as $moved_all
  # --commits があれば、進んだ先のコミット（head の sha を親に持つもの）の committer が無人の実行のものだけを数える。
  # 進んだ先が一覧に無い・committer のログインが無いときは、数える側に倒す
  | ([ $commit_lists[] | if type == "array" then flatten else [] end | .[] | select(type == "object") ]) as $pr_commits
  | def moved_by_other($sha):
      [ $pr_commits[] | select([ (.parents // [])[] | (.sha // "" | ascii_downcase) | select(. != "" and same_sha(.; $sha)) ] | length > 0) ] as $children
      | ($children | length) > 0
        and all($children[]; ((.committer.login // "") | norm) as $c
                | $c != "" and ($allowed | length) > 0 and ($c | IN($allowed[]) | not));
  [ $moved_all[] | select($have_commits and moved_by_other(.) | not) ] as $moved
  | [ $moved_all[] | select($have_commits and moved_by_other(.)) ] as $others
  # 同じ sha（小文字にして完全に一致するもの）は1回にする。前方一致でまとめると、先頭が同じ別のコミットを1つにして少なく数えるため
  | ($moved | unique) as $pushed
  | {
      count: (($pushed | length) + $legacy),
      pushed_heads: $pushed,
      legacy: $legacy,
      other_pushed: ($others | unique | length),
      not_pushed: ([ $with_head[] | select(same_sha(.; $now)) ] | length),
      runs: ($runs | length)
    }' "$input_file"
