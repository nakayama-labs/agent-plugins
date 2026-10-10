#!/usr/bin/env bash
# 5つの層の設定を項目ごとに合わせて JSON で出力する。
#
# 使い方: config.sh [jq フィルター]
#   例: config.sh .status.start   → In Progress
#
# 層（下ほど優先。上位の層が決めていない項目には下位の値が効く）:
#   5. プラグインの既定             defaults/workflow.json
#   4. ユーザーの好み               ~/.claude/dev-workflow/config.json（導入したリポジトリの中でだけ読む）
#   3. 既にある規約                 PR テンプレートなどを自動で検出
#   2. チームの規約                 <repo>/.claude/dev-workflow/config.json
#   1. 個人がそのリポジトリで上書き  <repo>/.claude/dev-workflow/config.local.json
#
# 文章のガイド（*.md）は guides.<名前> にパスの配列として入る（優先度の低い順）。
# 導入したリポジトリ（チームの設定 2 があるリポジトリ。dw_is_set_up）でなければ、ユーザーの層（層4 と
# ~/.claude/dev-workflow/*.md）は読まない（設計書 §1）。
# ホームのリポジトリ（<repo>/.claude/dev-workflow が ~/.claude/dev-workflow と同じ場所）は、導入したリポジトリにならず、
# その場所のファイルはチームの設定としても個人の上書きとしても読まない（dw_team_dir）。
# 導入したかは、出力のトップレベルの set_up（真偽値）でも分かる。スキルが設定ファイルを自分で探さずに読むための値で、
# ユーザーの層の判定（user_dir）と同じ1回の判定から決め、層を合わせた後に足すので、どの層の設定でも変えられない。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
dw_require jq

filter="${1:-.}"
repo_root="$(dw_repo_root || true)"
# 導入していないリポジトリでは、ユーザーの層を読まない（空になるので飛ばす）
user_dir="$(dw_user_dir_for "$repo_root")"
# チームの設定の置き場所。ホームのリポジトリ（ユーザーの層と同じ場所）では空で、チームの設定としては読まない
team_dir=""
[ -z "$repo_root" ] || team_dir="$(dw_team_dir "$repo_root")"
# 導入したか（user_dir は導入したときだけ空でなくなる。判定は dw_is_set_up の1回だけ）
set_up=false
[ -z "$user_dir" ] || set_up=true

layers=()
sources=()

add_layer() {
  [ -f "$1" ] || return 0
  dw_check_json "$1"
  layers+=("$(cat "$1")")
  sources+=("$1")
}

first_existing() {
  local f
  for f in "$@"; do
    if [ -e "$repo_root/$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# 層3: リポジトリに既にある規約を見つける
detect_existing() {
  local pr_tpl pr_tpls commitlint contributing issue_tpl
  # 候補は空白区切りの一覧なので、わざと分割して渡す
  # shellcheck disable=SC2086
  pr_tpl="$(dw_find_nocase "$repo_root" $DW_PR_TEMPLATE_FILES || true)"
  # shellcheck disable=SC2086
  pr_tpls="$(dw_find_nocase "$repo_root" $DW_PR_TEMPLATE_DIRS || true)"
  commitlint="$(first_existing commitlint.config.js commitlint.config.cjs commitlint.config.mjs \
    commitlint.config.ts .commitlintrc .commitlintrc.json .commitlintrc.yaml .commitlintrc.yml \
    .commitlintrc.js .commitlintrc.cjs || true)"
  contributing="$(first_existing CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md || true)"
  # Issue テンプレートのディレクトリか、古い形式の1ファイル
  # shellcheck disable=SC2086
  issue_tpl="$(dw_find_nocase "$repo_root" $DW_ISSUE_TEMPLATES || true)"
  jq -n --arg pr "$pr_tpl" --arg prs "$pr_tpls" --arg cl "$commitlint" --arg co "$contributing" --arg it "$issue_tpl" '
    def opt: if . == "" then null else . end;
    (if $pr != "" then {pr: {template: $pr}} else {} end)
    + {detected: {commitlint: ($cl | opt), contributing: ($co | opt), pr_templates: ($prs | opt),
        issue_templates: ($it | opt)}}'
}

add_layer "$DW_PLUGIN_ROOT/defaults/workflow.json"
[ -z "$user_dir" ] || add_layer "$user_dir/config.json"
if [ -n "$repo_root" ]; then
  layers+=("$(detect_existing)")
  [ -z "$team_dir" ] || add_layer "$team_dir/config.json"
  # ワークツリーで作業中なら、メインのワークツリーに置いた個人の設定を使う
  add_layer "$(dw_local_config_file "$repo_root")"
fi

# 文章のガイド（優先度の低い順: ユーザー → リポジトリ）
guides='{}'
for dir in "$user_dir" "$team_dir"; do
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    continue
  fi
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    guides="$(jq -c --arg k "$(basename "$f" .md)" --arg p "$f" '.[$k] += [$p]' <<<"$guides")"
  done
done

# shellcheck disable=SC2119 # 引数（フィルター）は省く
sources_json="$(printf '%s\n' ${sources[@]+"${sources[@]}"} | dw_json_lines_nonempty)"

printf '%s\n' "${layers[@]}" \
  | jq -s --argjson guides "$guides" --argjson sources "$sources_json" --argjson set_up "$set_up" \
      'reduce .[] as $l ({}; . * $l) + {guides: $guides, sources: $sources, set_up: $set_up}' \
  | jq -r "$filter"
