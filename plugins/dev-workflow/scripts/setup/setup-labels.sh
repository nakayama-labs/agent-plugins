#!/usr/bin/env bash
# labels.json の定義どおりに、リポジトリのラベルを作成・更新する。何度実行しても同じ結果になる。
# 定義に無い GitHub の既定のラベル（accessibility・bug・enhancement など）は削除する。
#
# 使い方: setup-labels.sh [オプション]
#   --repo OWNER/NAME  対象のリポジトリ（既定: 今いるリポジトリ）
#   --file PATH        ラベルの定義（既定: 対象のリポジトリの .claude/dev-workflow/labels.json、無ければプラグインの既定）
#   --keep-defaults    GitHub の既定のラベルを削除しない
#   --dry-run          変更せず、行う予定の操作だけを出力する
#
# labels.json の形式: [{"name": "feat", "color": "0e8a16", "description": "新しい機能"}, ...]
# 名前は大文字と小文字を区別せずに照合する（GitHub と同じ）。色と説明が違うときだけ更新する。
# --repo が今いるリポジトリと違うときは、対象のリポジトリの既定のブランチにある
# .claude/dev-workflow/labels.json と .claude/dev-workflow/config.json を API で読む。
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

# GitHub が新しいリポジトリに付ける既定のラベル
GITHUB_DEFAULT_LABELS='["accessibility", "bug", "documentation", "duplicate", "enhancement", "good first issue", "help wanted", "invalid", "question", "wontfix"]'

repo="" file="" keep_defaults=false dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --file)
      need_value "$@"
      case "$1" in
        --repo) repo="$2" ;;
        --file) file="$2" ;;
      esac
      shift 2
      ;;
    --keep-defaults) keep_defaults=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_nwo="$(gh repo view ${repo:+"$repo"} --json nameWithOwner -q .nameWithOwner)"
here_nwo=""
if [ -n "$repo" ]; then
  here_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
# 対象が今いるリポジトリなら手元のファイルを、別のリポジトリなら API で読んだ内容を使う
remote=false
[ -z "$repo" ] || [ "$here_nwo" = "$repo_nwo" ] || remote=true

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 対象のリポジトリのファイルを $tmp に置いてそのパスを出力する。無ければ何も出力しない
fetch_remote() {
  local out
  out="$tmp/$(basename "$1")"
  if dw_fetch_repo_file "$repo_nwo" "$1" "$out"; then
    printf '%s\n' "$out"
  fi
}

# --- 定義を読む -----------------------------------------------------------------
file_label="$file"
if [ -z "$file" ]; then
  if $remote; then
    file="$(fetch_remote .claude/dev-workflow/labels.json)"
    file_label="$repo_nwo:.claude/dev-workflow/labels.json"
  else
    repo_root="$(dw_repo_root || true)"
    # ホームのリポジトリ（dw_team_dir が空）では、ユーザーの層の labels.json をリポジトリの定義として読まない
    team_dir=""
    [ -z "$repo_root" ] || team_dir="$(dw_team_dir "$repo_root")"
    if [ -n "$team_dir" ] && [ -f "$team_dir/labels.json" ]; then
      file="$team_dir/labels.json"
      file_label="$file"
    fi
  fi
  if [ -z "$file" ]; then
    file="$DW_PLUGIN_ROOT/defaults/labels.json"
    file_label="$file"
  fi
fi
[ -f "$file" ] || dw_die "ラベルの定義が見つかりません: $file" 2

# 色は先頭の # を除き小文字に揃え、説明が無ければ空文字にする
labels="$(jq -c 'if type != "array" then error("配列ではありません") else . end
  | map(if (type == "object") and ((.name | type) == "string") and (.name != "")
          and ((.color | type) == "string") and (.color | test("^#?[0-9A-Fa-f]{6}$"))
        then {name, color: (.color | ltrimstr("#") | ascii_downcase), description: (.description // "")}
        else error("name と 6 桁の color が必要です: \(tojson)") end)' "$file" 2>&1)" \
  || dw_die "ラベルの定義を読めません（${file_label}）: $labels" 2
dup="$(jq -r 'group_by(.name | ascii_downcase) | map(select(length > 1)[0].name) | join(", ")' <<<"$labels")"
[ -z "$dup" ] || dw_die "ラベルの名前が重複しています: $dup" 2

# 設定の type ラベルが定義に無ければ、起票時に付けられないので警告する。
# 別のリポジトリでは、個人の層は効かないので、チームの設定とプラグインの既定だけを見る
if $remote; then
  types="$(jq -c '.labels.types' "$DW_PLUGIN_ROOT/defaults/workflow.json")"
  team="$(fetch_remote .claude/dev-workflow/config.json)"
  if [ -n "$team" ]; then
    types="$(jq -c --argjson d "$types" '.labels.types // $d' "$team" 2>/dev/null)" \
      || dw_die "${repo_nwo} の .claude/dev-workflow/config.json を JSON として読めません" 2
  fi
else
  # labels.types が文字列の配列でなければ、設定の誤りとして終了コード 2 で止める（jq の生のエラーにしない）
  config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
  types="$(dw_labels_types "$config")"
fi
missing_types="$(jq -r --argjson l "$labels" '. - ($l | map(.name)) | join(", ")' <<<"$types")"
[ -z "$missing_types" ] || dw_warn "設定の labels.types のうち、定義に無いラベルがあります: $missing_types"
# breaking ラベルは名前が決まっているので、独自の定義に無ければ、破壊的変更の Issue を起票できない
jq -e --arg b "$DW_BREAKING_LABEL" 'any(.[]; (.name | ascii_downcase) == $b)' <<<"$labels" >/dev/null \
  || dw_warn "定義に ${DW_BREAKING_LABEL} ラベルがありません（無いと破壊的変更の Issue を起票できません。${file_label} に足してください）"

actions='[]'
# 行った（または dry-run で行う予定の）操作を記録する
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# 変更を伴う gh の呼び出し。dry-run では呼ばない
run_gh() {
  $dry_run || gh "$@" >/dev/null
}

current="$(gh label list -R "$repo_nwo" --limit 1000 --json name,color,description)"

# --- 作成・更新 -----------------------------------------------------------------
created='[]' updated='[]' deleted='[]' unchanged=0
while IFS= read -r label; do
  [ -n "$label" ] || continue
  name="$(jq -r .name <<<"$label")"
  color="$(jq -r .color <<<"$label")"
  desc="$(jq -r .description <<<"$label")"
  have="$(jq -c --arg n "$name" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))][0] // null' <<<"$current")"
  if [ "$have" = null ]; then
    note "ラベル「${name}」を作成する"
    created="$(jq -c --arg n "$name" '. + [$n]' <<<"$created")"
    run_gh label create "$name" -R "$repo_nwo" --color "$color" --description "$desc"
  elif jq -e --argjson want "$label" \
    '.name == $want.name and (.color | ascii_downcase) == $want.color and (.description // "") == $want.description' \
    <<<"$have" >/dev/null; then
    unchanged=$((unchanged + 1))
  else
    note "ラベル「${name}」の名前・色・説明を定義に揃える"
    updated="$(jq -c --arg n "$name" '. + [$n]' <<<"$updated")"
    # gh label edit の空の --description では説明を消せないことがあるので、API で直接更新する
    run_gh api -X PATCH "repos/$repo_nwo/labels/$(jq -r '.name | @uri' <<<"$have")" \
      -f new_name="$name" -f color="$color" -f description="$desc"
  fi
done <<<"$(jq -c '.[]' <<<"$labels")"

# --- 既定のラベルの削除 ---------------------------------------------------------
if ! $keep_defaults; then
  targets="$(jq -r --argjson d "$GITHUB_DEFAULT_LABELS" --argjson l "$labels" '
    ($l | map(.name | ascii_downcase)) as $keep
    | .[] | .name | select(ascii_downcase as $n | any($d[]; . == $n) and (any($keep[]; . == $n) | not))' <<<"$current")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    note "既定のラベル「${name}」を削除する"
    deleted="$(jq -c --arg n "$name" '. + [$n]' <<<"$deleted")"
    run_gh label delete "$name" -R "$repo_nwo" --yes
  done <<<"$targets"
fi

jq -n --argjson dry "$dry_run" --arg repo "$repo_nwo" --arg file "$file_label" \
  --argjson c "$created" --argjson u "$updated" --argjson d "$deleted" --argjson n "$unchanged" \
  --argjson actions "$actions" '{
    dry_run: $dry,
    repo: $repo,
    file: $file,
    labels: {created: $c, updated: $u, deleted: $d, unchanged: $n},
    actions: $actions
  }'
