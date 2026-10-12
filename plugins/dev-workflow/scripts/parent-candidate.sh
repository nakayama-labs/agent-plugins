#!/usr/bin/env bash
# 既にある Issue を、起票する Issue の親にできるかを判定して、JSON で出力する。何も変えない。
# task-create で、分けた Issue の案の木の一番上の親を「外す」とき、外した親の代わりに、重なる既にある Issue を
# 子の親にできるかを決める。確認と文章は呼ぶ側（スキル）が担当する。
#
# 使い方: parent-candidate.sh --issue N --levels L
#   --issue N   親にする候補の、同じリポジトリの Issue の番号（#N でもよい）
#   --levels L  候補の下に紐付ける層の数（1〜7。必須）。外した親の子だけなら 1、その子にさらに子（孫）があれば 2
#
# 次の3つのどれかに当てはまれば、親にせず、子を親なしで起票する（action: no_parent）。どれにも当てはまらなければ親にする（action: use_as_parent）。
#   has_sub_issues     候補がサブ Issue を持つ（閉じた子も含む。応答の sub_issues_summary.total で決め、無ければ1件だけ読む）
#   has_parent         候補が既に親を持つ（別のリポジトリの親も含む）
#   exceeds_max_depth  候補の下に紐付けた一番深い Issue が、設定の sub_issues.max_depth（既定 3）の層を超える
#                      深さは issue-create.sh の検査と同じく、候補から上へ issues/{番号}/parent をたどって数える（一番上の Issue が1層目。
#                      別のリポジトリの親もたどる）。上限を超えると分かった時点でたどるのを止める（規則は lib/common.sh の dw_sub_issue_depth）
#                      親が、トークンで読めないリポジトリにあるときは（/parent が 404 でも Issue の応答に parent_issue_url がある）、親なしと数えず、エラーで止まる（終了コード 1）
#
# 出力: {issue, has_sub_issues, parent（一番近い親の {number, repo} か null）,
#        depth（紐付けた一番深い Issue の層。上限を超えると分かってたどるのを止めたときは null）, max_depth,
#        has_parent, exceeds_max_depth, reasons（当てはまった条件の名前の配列。親にするなら []）, action（use_as_parent か no_parent）}
# 候補が無い・PR の番号・サブ Issue を読めない（sub_issues_summary が無く、読み出しが 404・410 を含めて失敗した）なら止まる（終了コード 1）。sub_issues.max_depth が 1・2・3 のどれでもなければ止まる（終了コード 2）。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" levels=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --levels)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      if [ "$1" = --issue ]; then
        issue="$(dw_issue_number "$1" "$2")"
      else
        # 大きな値で bash の算術があふれないよう、GitHub の親子の上限（8層）に収まる 1〜7 に限る
        case "$2" in
          [1-7]) levels="$2" ;;
          *) dw_die "--levels には 1〜7 の整数を指定してください: $2" 64 ;;
        esac
      fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
[ -n "$levels" ] || dw_die "--levels は必須です" 64

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
max_depth="$(dw_max_depth "$config")"

candidate="$(dw_rest_issue "$repo_nwo" "$issue")"
[ "$candidate" != null ] || dw_die "親にする候補の Issue #${issue} がありません（${repo_nwo}）"
path="$(jq -r '.url | sub("^.*?/repos/"; "repos/")' <<<"$candidate")"

# サブ Issue があるか。Issue の応答の sub_issues_summary.total で決め、無いときだけ1件だけ読む（全ページは読まない。
# issue-cancel.sh と同じ読み方）。読めなければ、404・410 も含めて止まる（404 は「無い」とも「読めない（GHES・権限の無いトークン）」とも
# 取れ、「無い」として親にすると、起票した後の紐付けで失敗して、子が中途半端に残るため。止まれば、スキルは親なしとして扱う）
has_subs="$(jq '.sub_issues_summary.total // null | if . == null then null else . > 0 end' <<<"$candidate")"
if [ "$has_subs" = null ]; then
  has_subs="$(gh api "$path/sub_issues?per_page=1" | jq 'length > 0')" \
    || dw_die "#${issue} のサブ Issue を読めませんでした"
fi

# 候補の下に levels 層を紐付けたときの深さ（規則は dw_sub_issue_depth）。親があるかは知りたいので、少なくとも1回はたどる
result="$(dw_sub_issue_depth "$candidate" "$levels" "$max_depth" 1)"

jq -n --argjson i "$issue" --argjson subs "$has_subs" --argjson r "$result" --argjson max "$max_depth" '
  {has_sub_issues: $subs, has_parent: ($r.first != null), exceeds_max_depth: $r.exceeds} as $c
  | ([$c | to_entries[] | select(.value) | .key]) as $reasons
  | {issue: $i, has_sub_issues: $subs, parent: $r.first, depth: $r.depth, max_depth: $max,
     has_parent: $c.has_parent, exceeds_max_depth: $c.exceeds_max_depth,
     reasons: $reasons, action: (if $reasons == [] then "use_as_parent" else "no_parent" end)}'
