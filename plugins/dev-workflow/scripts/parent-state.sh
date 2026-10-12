#!/usr/bin/env bash
# Issue の親（とさらに上の親）の状態を調べて、JSON で出力する。何も変えない。
# 子がすべて閉じた親を閉じるかの確認（task-finish・task-cancel）の材料にする。確認と文章は呼ぶ側（スキル）が担当する。
#
# 使い方: parent-state.sh --issue N [--assume-closed M]...
#   --issue N          Issue の番号（#N でもよい）。この Issue の親を、近い順にたどる
#   --assume-closed M  Issue M を、閉じたものとして数える。繰り返して指定するか、カンマ区切り（M1,M2）で複数の番号を渡せる。
#                      番号の後に :理由 を付けると、その閉じ方（completed・not_planned・duplicate）で数える（M:not_planned。付けなければ completed）。
#                      GitHub がまだ open と返す子の閉じ方を、suggest に反映するため（task-cancel は取りやめの理由を付けて渡す）PR のマージで GitHub が閉じる Issue は、
#                      マージの直後は少し遅れて閉じるので、task-finish が片付けている Issue を渡す
#
# 出力: {issue, parents: [近い順の親]}。親の要素は
#   number, title, state（open か closed）, state_reason, column（Project の Status の列。Project が未設定・項目が無ければ null）,
#   children: {total, closed, open, list: [{number, title, state, state_reason}]},
#   all_closed: 子が1つ以上あり、すべて閉じている,
#   suggest: 親が開いていて all_closed のとき、閉じ方の案（completed か not_planned）。それ以外は null
#             子がすべて取りやめ（not_planned・duplicate）なら not_planned、それ以外は completed
# 別のリポジトリの親は含めない（そこで打ち切る。設計書 §4）。親が無ければ parents は [] 。
# 親が、トークンで読めないリポジトリにあるときは（/parent が 404 でも Issue の応答に parent_issue_url がある）、親なしと数えず、エラーで止まる（終了コード 1）。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" assumed='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --assume-closed)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      if [ "$1" = --issue ]; then
        issue="$(dw_issue_number "$1" "$2")"
      else
        # カンマで分ける（IFS で分けるだけで、glob 展開はしない）。空の要素（1,,2 の真ん中など）は無視し、番号でないもの（* など）は 64 で止まる
        IFS=, read -r -a parts <<<"$2"
        for v in ${parts[@]+"${parts[@]}"}; do
          [ -n "$v" ] || continue
          why=completed
          case "$v" in
            *:*) why="${v#*:}"; v="${v%%:*}" ;;
          esac
          case "$why" in
            completed | not_planned | duplicate) ;;
            *) dw_die "$1 の理由は completed・not_planned・duplicate のどれかにしてください: $why" 64 ;;
          esac
          n="$(dw_issue_number "$1" "$v")"
          assumed="$(jq -c --argjson n "$n" --arg w "$why" '. + [{number: $n, reason: $w}]' <<<"$assumed")"
        done
      fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
project_id=""
number="$(jq -r '.project.number // empty' <<<"$config")"
if [ -n "$number" ]; then
  owner="$(jq -r '.project.owner // empty' <<<"$config")"
  [ -n "$owner" ] || owner="${repo_nwo%%/*}"
  # Project を読めなくても止めない。親の閉じ忘れの確認には、列は要らない（column を null にして続ける）
  if ! project_id="$(dw_gh_find gh project view "$number" --owner "$owner" --format json | jq -r '.id // empty')" || [ -z "$project_id" ]; then
    project_id=""
    dw_warn "Project（${owner}/${number}）を読めなかったので、親の列（column）は null にします"
  fi
fi

chain="$(dw_issue_parents "$repo_nwo" "$issue")"
out='[]'
for p in $(jq -r '.[].number' <<<"$chain"); do
  parent="$(jq -c --argjson p "$p" '.[] | select(.number == $p)' <<<"$chain")"
  children="$(dw_sub_issues "repos/$repo_nwo/issues/$p")"
  column=""
  if [ -n "$project_id" ]; then
    items="$(dw_issue_items "$repo_nwo" "$p")" || items=null
    column="$(jq -r --arg p "$project_id" '[.projectItems.nodes[]? | select(.project.id == $p)][0].fieldValueByName.name // empty' <<<"$items")"
  fi
  # 子の一覧は本文を含んで長くなりうるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
  out="$(printf '%s\n' "$out" "$children" | jq -sc --argjson parent "$parent" --argjson assumed "$assumed" --arg column "$column" '
    .[1] as $kids | .[0]
    | ($kids | map(. as $k | {number, title,
      state: (if ($assumed | any(.number == $k.number)) then "closed" else $k.state end),
      state_reason: (if ($assumed | any(.number == $k.number)) and $k.state != "closed"
        then ([$assumed[] | select(.number == $k.number)][0].reason) else ($k.state_reason // null) end)})) as $list
    | ($list | map(select(.state == "closed")) | length) as $closed
    | ($list | length > 0 and $closed == ($list | length)) as $all
    | . + [$parent + {
        column: (if $column == "" then null else $column end),
        children: {total: ($list | length), closed: $closed, open: (($list | length) - $closed), list: $list},
        all_closed: $all,
        suggest: (if $parent.state == "open" and $all
          then (if ($list | all(.state_reason == "not_planned" or .state_reason == "duplicate")) then "not_planned" else "completed" end)
          else null end)}]')"
done

jq -n --argjson i "$issue" --argjson parents "$out" '{issue: $i, parents: $parents}'
