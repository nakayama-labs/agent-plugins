#!/usr/bin/env bash
# レビューのサブエージェントに使うモデル（設定の review.model）を、このリポジトリの中の選んだ層の設定ファイルに書く。
# 何度実行しても同じ結果になる。オプションを付けなければ、今の設定と、どの層で決めたかだけを出力する。
# ユーザーの層（~/.claude/dev-workflow/config.json）には書かない（ほかの導入したリポジトリにも効くため）。
# ホームのリポジトリ（<repo>/.claude/dev-workflow が ~/.claude/dev-workflow と同じ場所になるリポジトリ）では、
# 書く操作（--review-model）は、何も書かずに終了コード 2 で止まる。読むのは、
# config.sh と同じく、導入したリポジトリ（.claude/dev-workflow/config.json があるリポジトリ）の中でだけ。
#
# 使い方: setup-models.sh [オプション]
#   --review-model M   opus・sonnet・haiku・fable のどれか。off なら null を書き、セッションと同じモデルで動かす
#   --scope S          書く層。local（<repo>/.claude/dev-workflow/config.local.json。自分だけ）・
#                      team（<repo>/.claude/dev-workflow/config.json。チームで共有する。コミットが要る）。
#                      --review-model と一緒に使う（どちらか片方だけでは止まる）
#   --dry-run          変更せず、行う予定の操作だけを出力する
#
# 出力: review.model（層を合わせた後の値）・review.decided（どれかの層で決めてあるか）・
#       review.layers（review.model を決めている層と値）・file（書く・書いたファイル）・changed・
#       local_git（local に書くとき、そのファイルがコミットされてしまわないか。ignored・not_ignored・tracked。
#       それ以外は null）・actions
# local は team より優先されるので、team に書いたのに local が別の値を決めていると、書いても効かないので警告する。
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

review_model="" scope="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --review-model | --scope)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      case "$1" in
        --review-model) review_model="$2" ;;
        --scope) scope="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

value=""
if [ -n "$review_model" ]; then
  if [ "$review_model" = off ]; then
    value=null
  else
    value="$(jq -n --arg m "$review_model" '$m')"
    dw_json_enum_ok "$DW_REVIEW_MODELS" "$value" \
      || dw_die "--review-model は off か $(dw_json_enum_names "$DW_REVIEW_MODELS") のどれかにしてください: ${review_model}" 64
  fi
  case "$scope" in
    local | team) ;;
    "") dw_die "--review-model には --scope（local・team）が要ります" 64 ;;
    *) dw_die "--scope は local・team のどちらかにしてください: ${scope}" 64 ;;
  esac
elif [ -n "$scope" ]; then
  dw_die "--scope は --review-model と一緒に使ってください" 64
fi

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
# ホームのリポジトリでは、チームの設定がユーザーの層のファイルになってしまうので、書かずに止まる
# （何も書かない確認だけの実行は、層が無い状態を出力する）
[ -z "$value" ] || dw_refuse_home_repo "$repo_root"
team_file="$(dw_team_dir "$repo_root")"
[ -z "$team_file" ] || team_file="$team_file/config.json"
# 個人の上書き（local）は、config.sh が読むのと同じファイルに書く
local_file="$(dw_local_config_file "$repo_root")"

# 層ごとに review.model を決めているか（null も「オフに決めた」とみなす）。優先度の低い順に並べる
layers="$(dw_review_model_layers "$repo_root" | dw_json_lines_nonempty 'map(split("\t")
  | {layer: .[0], file: .[1], model: (.[2] | fromjson)})')"

file=null changed=false actions='[]' local_git=null
if [ -n "$value" ]; then
  case "$scope" in
    team) target="$team_file" ;;
    local) target="$local_file" ;;
  esac
  file="$(jq -n --arg f "$target" '$f')"
  # review がオブジェクトでないと書けないので、dry-run（setup-all.sh の確認）のときから止める
  # （JSON として読めるかは、dw_review_model_layers が両方の層で確かめ済み）
  if [ -f "$target" ]; then
    jq -e '(.review | type) == "object" or .review == null' "$target" >/dev/null \
      || dw_die "${target} の review がオブジェクトではないので、review.model を書けません" 2
  fi
  # 決めていない（キーが無い）ことと、null に決めたことを分けるため、無ければ空にする
  current="$(jq -r --arg f "$target" 'map(select(.file == $f) | .model | tojson) | first // ""' <<<"$layers")"
  # 既に同じ値なら書き直さない（書式の違いで空白だけの差分を作らない）
  if [ "$current" != "$value" ]; then
    changed=true
    label="$(if [ "$value" = null ]; then echo "null（セッションと同じモデル）"; else jq -r . <<<"$value"; fi)"
    actions="$(jq -c --arg a "$target の review.model を ${label} にする" '. + [$a]' <<<"$actions")"
    if ! $dry_run; then
      # $v は jq の変数で、bash に展開させない
      # shellcheck disable=SC2016
      dw_write_config "$target" --argjson v "$value" '.review = ((.review // {}) + {model: $v})'
    fi
  fi
  layers="$(jq -c --arg n "$scope" --arg f "$target" --argjson v "$value" \
    'map(select(.layer != $n)) + [{layer: $n, file: $f, model: $v}]
     | sort_by({user: 0, team: 1, local: 2}[.layer])' <<<"$layers")"
  # 上位の層が別の値を決めていれば、書いても効かない
  over="$(jq -r --arg n "$scope" --argjson v "$value" \
    '({user: 0, team: 1, local: 2}) as $o | map(select($o[.layer] > $o[$n] and .model != $v)) | last // empty
     | "\(.file) の review.model（\(.model)）が優先されるので、書いた値は効きません"' <<<"$layers")"
  [ -z "$over" ] || dw_warn "$over"
  # 個人の設定はコミットしないので、コミットされてしまうなら知らせる（setup-all.sh が次にやることに出す）
  if [ "$scope" = local ]; then
    state="$(dw_local_config_state "$repo_root")"
    local_git="$(jq -n --arg s "$state" '$s')"
    hint="$(dw_local_config_hint "$state")"
    [ -z "$hint" ] || dw_warn "$hint"
  fi
fi

jq -n --argjson layers "$layers" --argjson file "$file" --argjson changed "$changed" --argjson local_git "$local_git" \
  --argjson dry "$dry_run" --argjson actions "$actions" '{
    dry_run: $dry,
    review: {model: ((($layers | last) // {model: null}).model), decided: ($layers | length > 0), layers: $layers},
    file: $file,
    changed: $changed,
    local_git: $local_git,
    actions: $actions
  }'
