#!/usr/bin/env bash
# Issue を起票し、type ラベルを付け、Project に追加して todo の列にする。Story Point と依存する Issue・親の Issue も設定できる。
#
# 使い方: issue-create.sh --title TITLE --type TYPE [オプション]
#   --title TITLE        Issue のタイトル（必須）
#   --type TYPE          type ラベル。設定の labels.types のどれか（必須）
#   --body-file PATH     本文のファイル。- なら標準入力（既定: 本文なし）
#   --story-point N      Story Point。1, 2, 3, 5, 8, 13, 21, 34 のどれか（既定: 空欄）。
#                        21 と 34 は設定できるが、分割を勧める警告を出す
#   --blocked-by N       依存する（先に終わらせる）同じリポジトリの Issue の番号（#N でもよい）。複数回指定できる
#   --parent N           親にする同じリポジトリの Issue の番号（#N でもよい）。起票した Issue を N のサブ Issue にする。
#                        親子の深さが設定の sub_issues.max_depth（既定 3）を超えるなら、Issue を作る前に止める。
#                        目安の 2 層より深くなる（3 層目になる）ときは、作るが警告する。
#                        Story Point は子にだけ付けるので、親の Project の Story Point が入っていれば空欄にする
#   --breaking           破壊的変更なので、type ラベルとは別に breaking ラベルも付ける
#                        （リポジトリにラベルが無ければ、Issue を作る前に止める）
#
# 行うこと:
#   1. 設定と Project（project.owner / project.number）、Status 列・todo の列・Story Point の項目、
#      依存する Issue・親の Issue と breaking ラベルがあるか、親子の深さが上限を超えないかを確かめる
#      （問題があれば Issue を作る前に止める）
#   2. Issue を作る（type ラベル付き。--breaking なら breaking ラベルも）
#   3. Project に追加し（既に入っていれば既存の項目を使う）、Status を todo の列に（status-set.sh）、Story Point を設定する
#   4. 依存する Issue を、GitHub の依存関係（blocked by）に登録する
#   5. 親の Issue があれば、起票した Issue をそのサブ Issue にし、親の Story Point を空欄にする
# project.number が未設定なら、Issue だけ作って警告する。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

title="" type="" body_file="" sp="" parent="" breaking=false
# 依存する Issue の番号（空白区切り。重複は除く）
blocked_by=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title | --type | --body-file | --story-point)
      need_value "$@"
      case "$1" in
        --title) title="$2" ;;
        --type) type="$2" ;;
        --body-file) body_file="$2" ;;
        --story-point) sp="$2" ;;
      esac
      shift 2
      ;;
    --blocked-by)
      need_value "$@"
      # 本文に書くときと同じ #12 の形や、先頭の 0 も受け付ける（dw_issue_number）
      n="$(dw_issue_number "$1" "$2")"
      case " $blocked_by " in
        *" $n "*) ;;
        *) blocked_by="${blocked_by:+$blocked_by }$n" ;;
      esac
      shift 2
      ;;
    --parent)
      need_value "$@"
      parent="$(dw_issue_number "$1" "$2")"
      shift 2
      ;;
    --breaking) breaking=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$title" ] || dw_die "--title は必須です" 64
[ -n "$type" ] || dw_die "--type は必須です" 64

body=""
if [ -n "$body_file" ]; then
  if [ "$body_file" = - ]; then
    body="$(cat)"
  else
    [ -f "$body_file" ] || dw_die "本文のファイルがありません: $body_file" 64
    body="$(cat "$body_file")"
  fi
fi

# --- 1. 設定の確認 --------------------------------------------------------------
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
jq -e --arg t "$type" '.labels.types | index($t)' <<<"$config" >/dev/null \
  || dw_die "type は labels.types のどれかにしてください（$(jq -r '.labels.types | join(" / ")' <<<"$config")）: $type" 64
if [ -n "$sp" ]; then
  # 05 のような先頭の 0 は JSON の数値に揃える
  case "$sp" in
    *[!0-9]*) dw_die "--story-point には整数を指定してください: $sp" 64 ;;
  esac
  sp="$((10#$sp))"
  jq -e --argjson n "$sp" 'index($n)' <<<"$DW_STORY_POINTS" >/dev/null \
    || dw_die "Story Point は $(jq -r 'map(tostring) | join(" / ")' <<<"$DW_STORY_POINTS") のどれかにしてください: $sp" 64
  if [ "$sp" -ge "$DW_STORY_POINT_SPLIT" ]; then
    dw_warn "Story Point ${sp} は大きいので、Issue を分割できないか検討してください"
  fi
fi

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
owner="$(jq -r '.project.owner // empty' <<<"$config")"
number="$(jq -r '.project.number // empty' <<<"$config")"
[ -n "$owner" ] || owner="${repo_nwo%%/*}"
todo_name="$(jq -r '.status.todo // empty' <<<"$config")"
sp_name="$(jq -r '.story_point.field' <<<"$config")"

project=null
sp_field_id=""
if [ -n "$number" ]; then
  project="$(dw_project_fields "$owner" "$number")"
  status_field="$(jq -c '[.fields[] | select(.name == "Status")][0] // null' <<<"$project")"
  [ "$status_field" != null ] || dw_die "Project に Status 列がありません"
  todo_id="$(jq -r --arg n "$todo_name" '[.options[] | select(.name == $n)][0].id // empty' <<<"$status_field")"
  [ -n "$todo_id" ] || dw_die "todo の列「${todo_name:-（未設定）}」が Status 列にありません"
  sp_field="$(jq -c --arg n "$sp_name" '[.fields[] | select(.name == $n)][0] // null' <<<"$project")"
  if [ -n "$sp" ]; then
    [ "$sp_field" != null ] || dw_die "Project に Story Point の項目「${sp_name}」がありません（setup-project.sh で追加してください）"
    [ "$(jq -r .dataType <<<"$sp_field")" = number ] || dw_die "項目「${sp_name}」が数値ではありません"
  fi
  # --parent で親の Story Point を空欄にするときにも使うので、数値の項目があれば --story-point が無くても読む
  if [ "$sp_field" != null ] && [ "$(jq -r .dataType <<<"$sp_field")" = number ]; then
    sp_field_id="$(jq -r .id <<<"$sp_field")"
  fi
else
  dw_warn "project.number が未設定なので、Project には追加しません（setup-project.sh --write-config で設定できます）"
fi

# 依存する Issue の「番号:id」（空白区切り）。依存関係の登録（REST）には node id ではなく数値の id を使う。
# PR の番号は無い Issue として扱う（dw_issue_ref。issue-depend.sh と同じ）
blocking=""
for n in $blocked_by; do
  ref="$(dw_issue_ref "$repo_nwo" "$n")"
  [ -n "$ref" ] || dw_die "依存する Issue #${n} がありません（${repo_nwo}）"
  blocking="${blocking:+$blocking }$n:${ref%% *}"
done

# 親の Issue があるか（PR は除く）と、親子の深さが上限を超えないかを確かめる
if [ -n "$parent" ]; then
  max_depth="$(dw_max_depth "$config")"
  parent_issue="$(dw_rest_issue "$repo_nwo" "$parent")"
  [ "$parent_issue" != null ] || dw_die "親にする Issue #${parent} がありません（${repo_nwo}）"
  # 起票する Issue は親の 1 層下。上限を超えると分かったら、それより上はたどらない（深さの規則は dw_sub_issue_depth）
  depth_check="$(dw_sub_issue_depth "$parent_issue" 1 "$max_depth")"
  # exceeds と depth（超えるときは空）を、jq を1回だけ起動して読む。空になりうる depth は後ろに置く
  # （区切りの空白は read が続けて読み飛ばすので、前に置くと exceeds がずれる）
  read -r exceeds depth <<<"$(jq -r '"\(.exceeds) \(.depth // "")"' <<<"$depth_check")"
  [ "$exceeds" = false ] \
    || dw_die "#${parent} の子にすると、親子の深さが上限の ${max_depth} 層を超えます（sub_issues.max_depth）" 2
  if [ "$depth" -gt "$DW_SUB_ISSUE_DEPTH_GUIDE" ]; then
    dw_warn "#${parent} の子にすると ${depth} 層目になります（目安は ${DW_SUB_ISSUE_DEPTH_GUIDE} 層まで）"
  fi

  # 親の Project の項目と、今の Story Point。Project に入っていなければ、外す値も無い
  parent_item=null
  if [ -n "$sp_field_id" ]; then
    sp_db_id="$(jq -r .databaseId <<<"$sp_field")"
    parent_item="$(dw_project_item "$(jq -r .restPath <<<"$project")" "$repo_nwo" "$parent" "$sp_db_id" \
      | jq -c --argjson f "$sp_db_id" '
          if . == null then null else {id: .node_id, story_point: ([.fields[]? | select(.id == $f)][0].value)} end')" \
      || dw_die "親の Issue #${parent} の Story Point を読めませんでした"
  fi
fi

# GitHub は無いラベルを付けようとすると新しく作るので、色と説明の揃ったラベルがあるかを先に確かめる
labels="$(jq -nc --arg t "$type" '[$t]')"
if $breaking; then
  if ! err="$(gh api "repos/$repo_nwo/labels/$DW_BREAKING_LABEL" 2>&1 >/dev/null)"; then
    case "$err" in
      *"HTTP 404"*) dw_die "${repo_nwo} に ${DW_BREAKING_LABEL} ラベルがありません（setup-labels.sh を実行して作ってください。.claude/dev-workflow/labels.json を使っていれば、先にそこへ ${DW_BREAKING_LABEL} を足してください）" 2 ;;
      *) dw_die "${DW_BREAKING_LABEL} ラベルを確かめられませんでした: $err" ;;
    esac
  fi
  labels="$(jq -c --arg b "$DW_BREAKING_LABEL" '. + [$b]' <<<"$labels")"
fi

# --- 2. Issue を作る ------------------------------------------------------------
# 本文は大きいことがあるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
issue="$(printf '%s' "$body" | dw_jq_text --arg t "$title" --argjson l "$labels" '{title: $t, body: $dw_in, labels: $l}' \
  | gh api -X POST "repos/$repo_nwo/issues" --input -)" || dw_die "Issue を作れませんでした"
issue_number="$(jq -r .number <<<"$issue")"
issue_url="$(jq -r .html_url <<<"$issue")"

# ここから先で失敗しても Issue は残るので、番号を伝えて止める
fail_after_create() { dw_die "Issue #${issue_number}（${issue_url}）は作りましたが、$1"; }

# 書き込み権限が無いと、GitHub はラベルを黙って無視するので、付いたかを応答で確かめる
jq -e --arg t "$type" 'any(.labels[]?; .name == $t)' <<<"$issue" >/dev/null \
  || fail_after_create "type ラベル「${type}」を付けられませんでした（リポジトリへの書き込み権限が必要です）"
if $breaking; then
  # 既にある Breaking のようなラベルが付くこともあるので、大文字と小文字を区別せずに照合する（GitHub と同じ）
  jq -e --arg b "$DW_BREAKING_LABEL" 'any(.labels[]?; (.name | ascii_downcase) == $b)' <<<"$issue" >/dev/null \
    || fail_after_create "${DW_BREAKING_LABEL} ラベルを付けられませんでした"
fi

# --- 3. Project に追加し、Status と Story Point を設定する ------------------------
item_id=""
if [ "$project" != null ]; then
  project_id="$(jq -r .id <<<"$project")"
  # 自動追加が有効でも、既に入っていれば既存の項目が返るだけなので重複しない
  item_id="$(dw_project_add_item "$owner" "$number" "$issue_url")" \
    || fail_after_create "Project に追加できませんでした"

  # 列を移す処理は status-set.sh にまとめる。項目の ID は分かっているので渡し、項目を読み直す GraphQL を省く
  "$BASH" "$DW_SCRIPTS_DIR/status-set.sh" --issue "$issue_number" --to todo --item-id "$item_id" >/dev/null \
    || fail_after_create "Status を「${todo_name}」にできませんでした"
  if [ -n "$sp" ]; then
    dw_project_set_field "$project_id" "$item_id" "$sp_field_id" --number "$sp" \
      || fail_after_create "Story Point を設定できませんでした"
  fi
fi

# --- 4. 依存関係（blocked by）を登録する -----------------------------------------
for pair in $blocking; do
  dw_add_blocked_by "$repo_nwo" "$issue_number" "${pair#*:}" \
    || fail_after_create "#${pair%%:*} への依存（blocked by）を登録できませんでした"
done

# --- 5. 親の Issue のサブ Issue にし、親の Story Point を空欄にする（REST には子の数値の id を送る） ---
parent_sp=""
if [ -n "$parent" ]; then
  gh api -X POST "repos/$repo_nwo/issues/$parent/sub_issues" -F sub_issue_id="$(jq -r .id <<<"$issue")" >/dev/null \
    || fail_after_create "#${parent} のサブ Issue にできませんでした"
  parent_sp="$(jq -r '.story_point // empty' <<<"$parent_item")"
  if [ -n "$parent_sp" ]; then
    dw_project_set_field "$(jq -r .id <<<"$project")" "$(jq -r .id <<<"$parent_item")" "$sp_field_id" --clear \
      || fail_after_create "#${parent} のサブ Issue にした後、親の Story Point ${parent_sp} を空欄にできませんでした"
  fi
fi

jq -n --argjson n "$issue_number" --arg url "$issue_url" --arg type "$type" --arg item "$item_id" \
  --argjson project "$project" --arg status "$todo_name" --arg sp "$sp" \
  --arg blocked "$blocked_by" --arg parent "$parent" --arg depth "${depth:-}" --arg parent_sp "$parent_sp" --argjson breaking "$breaking" '{
    number: $n,
    url: $url,
    type: $type,
    breaking: $breaking,
    blocked_by: ($blocked | split(" ") | map(select(. != "") | tonumber)),
    parent: (if $parent == "" then null else {number: ($parent | tonumber), depth: ($depth | tonumber),
      story_point_cleared: (if $parent_sp == "" then null else ($parent_sp | tonumber) end)} end),
    project: (if $project then {number: $project.number, item_id: $item, status: $status,
      story_point: (if $sp == "" then null else ($sp | tonumber) end)} else null end)
  }'
