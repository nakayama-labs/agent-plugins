#!/usr/bin/env bash
# 実行環境と設定を確認し、結果を JSON で出力する。
# level が error の確認に1つでも失敗したら終了コード 1。
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"checks":[{"name":"jq","ok":false,"level":"error","detail":"jq が見つかりません"}]}\n'
  exit 1
fi

checks=""
gh_auth=false

# 使い方: check <名前> <true|false> <error|warn> <詳細>
check() {
  checks="$checks$(jq -nc --arg n "$1" --argjson ok "$2" --arg l "$3" --arg d "$4" \
    '{name: $n, ok: $ok, level: $l, detail: $d}')
"
}

has() { command -v "$1" >/dev/null 2>&1; }

# bash 3.2 以上
if [ "${BASH_VERSINFO[0]}" -gt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  check bash true error "$BASH_VERSION"
else
  check bash false error "bash 3.2 以上が必要です（現在 ${BASH_VERSION}）"
fi

check jq true error "$(jq --version)"

if has git; then check git true error "$(git --version)"; else check git false error "git が見つかりません"; fi

if has gh; then
  check gh true error "$(gh --version | head -n 1)"
  # 古いと使えない機能があるだけなので、止めずに更新を促す
  gh_version="$(dw_gh_version)"
  if [ -n "$gh_version" ] && dw_version_ge "$gh_version" "$DW_GH_MIN_VERSION"; then
    check gh-version true warn "$gh_version"
  else
    check gh-version false warn "gh ${DW_GH_MIN_VERSION} 以上を使ってください（今は ${gh_version:-不明}）。gh を更新してください（https://cli.github.com/）"
  fi
  if gh auth status -h github.com >/dev/null 2>&1; then
    gh_auth=true
    check gh-auth true error "github.com にログイン済み"
    scopes="$(gh api -i user 2>/dev/null | tr -d '\r' | LC_ALL=C sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')"
    if [ -z "$scopes" ]; then
      check gh-project-scope false warn "トークンのスコープを確認できません（fine-grained token など）"
    elif printf '%s\n' "$scopes" | tr ',' '\n' | sed 's/^ *//' | grep -qx project; then
      check gh-project-scope true error "$scopes"
    else
      check gh-project-scope false error "project スコープがありません。ターミナルで gh auth refresh -h github.com -s project を実行してください"
    fi
  else
    check gh-auth false error "ターミナルで gh auth login を実行してください"
  fi
else
  check gh false error "gh が見つかりません（https://cli.github.com/）"
fi

repo_root="$(dw_repo_root || true)"
# チームの設定のファイル。ホームのリポジトリでは、ユーザーの層と同じ場所になるので無い（dw_team_dir）
team_config=""
[ -z "$repo_root" ] || team_config="$(dw_team_dir "$repo_root")"
[ -z "$team_config" ] || team_config="$team_config/config.json"
# チームの設定の base_branch。setup-repo.sh とマージキューの確認（下）が使う。使えない値なら空にし、理由を team_base_err に残す
team_base="" team_base_err=""
if [ -n "$repo_root" ]; then
  team_base="$( (dw_team_base_branch "$team_config" .claude/dev-workflow/config.json) 2>&1)" \
    || { team_base_err="${team_base#error: }"; team_base=""; }
fi

if config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" 2>&1)"; then
  check config true error "$(jq -r '.sources | join(", ")' <<<"$config")"
  if [ "$(jq -r '.project.number // empty' <<<"$config")" != "" ]; then
    check project true warn "$(jq -r '"\(.project.owner)/\(.project.number)"' <<<"$config")"
  else
    check project false warn "Project が未設定です（.claude/dev-workflow/config.json の project）"
  fi
  # config.sh は base_branch を検査しないので、使う側（dw_base_branch）と同じ検査をここで行う。使えない値だと、
  # base_branch を使うスクリプト（task-start・pr-create など）が止まる。個人の層が上書きしていても、チームの設定の値
  # （team_base）も確かめる
  if ! base_check="$(dw_base_branch "$config" 2>&1)"; then
    check base-branch false error "${base_check#error: }"
  elif [ -n "$team_base_err" ]; then
    check base-branch false error "チームの設定: ${team_base_err}"
  else
    check base-branch true error "$base_check"
  fi
else
  check config false error "$config"
  # 合わせた設定は読めなくても、チームの設定の値の誤りは知らせる（直した後に、もう1つ誤りが出てこないように）。
  # チームの設定のファイルそのものが読めないときは、config の失敗と同じ誤りなので、二重に知らせない
  if [ -n "$team_base_err" ] && [ -n "$team_config" ] && dw_is_json_object "$team_config"; then
    check base-branch false error "チームの設定: ${team_base_err}"
  fi
fi

# 改名前の設定のキー pr_respond は使われない（pr_check に改めた。別名は残さない）ので、残っていれば知らせる
# （config.sh が失敗したときの $config はエラーメッセージなので、jq が読めず、ここには入らない）
if jq -e 'type == "object" and has("pr_respond")' >/dev/null 2>&1 <<<"$config"; then
  check old-pr-respond-key false warn "設定のキー pr_respond は使われません。pr_check に改めてください（例：pr_respond.handlers → pr_check.handlers）。どの層の設定にあっても同じです（.claude/dev-workflow/config.json・config.local.json・~/.claude/dev-workflow/config.json）"
fi

# pr_check.handlers に書いた担当の skill が、リポジトリ（.claude/skills/）かユーザー（~/.claude/skills/）にあるかを確かめる。
# 書き間違えた名前は、gh-pr-check を実行して担当の skill を呼ぶときまで分からないため。
# プラグインの skill（<プラグイン>:<名前>）は置き場所が違うので検査しない
if [ -n "$repo_root" ]; then
  missing_handlers=""
  while IFS= read -r handler_skill; do
    # <プラグイン>:<名前>（両側が1文字以上）の形だけを除く。「:」「a:」「:b」は壊れた名前なので除かない
    case "$handler_skill" in ?*:?*) continue ;; esac
    # パスに組み立てるのは、安全な名前（英数字・.・_・-）だけ。../x や a/b のような名前は「無い」ものとして扱う
    if ! [[ "$handler_skill" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$handler_skill" = . ] || [ "$handler_skill" = .. ] \
      || { [ ! -f "$repo_root/.claude/skills/$handler_skill/SKILL.md" ] && { [ -z "${HOME:-}" ] || [ ! -f "$HOME/.claude/skills/$handler_skill/SKILL.md" ]; }; }; then
      missing_handlers="$missing_handlers${missing_handlers:+、}${handler_skill:-（空）}"
    fi
  done < <(jq -r '(.pr_check.handlers // {}) | if type == "object" then .[] | strings else empty end' 2>/dev/null <<<"$config" || true)
  if [ -n "$missing_handlers" ]; then
    check pr-check-handlers false warn "pr_check.handlers の担当の skill が見つかりません: ${missing_handlers}（$repo_root/.claude/skills/<名前>/SKILL.md か ~/.claude/skills/<名前>/SKILL.md に置いてください。名前の書き間違いなら直してください）。見つからないと、gh-pr-check が担当の skill を呼べません"
  fi
fi

# 古い置き場所（.claude/dev-workflow/ にまとめる前）のファイルは使われないので、移すよう促す
moves=""
# 使い方: old_location <古いパス> <新しいパス>。古いパスがディレクトリなら、*.md があるときだけ数える
old_location() {
  if [ -d "$1" ]; then
    ls "$1"/*.md >/dev/null 2>&1 || return 0
  elif [ ! -f "$1" ]; then
    return 0
  fi
  moves="$moves${moves:+、}$1 → $2"
}
if [ -n "$repo_root" ]; then
  # プラグインは導入したリポジトリにだけ効く（設計書 §1）。導入していないと、使う人が気づかないまま守りが外れるので知らせる
  if dw_is_home_repo "$repo_root"; then
    check set-up false warn "ホームのリポジトリ（${repo_root}）には導入できません。チームの設定の置き場所 .claude/dev-workflow が、ユーザーの層（$(dw_user_dir)）と同じ場所になり、ユーザーの層の設定がチームの設定に見えてしまうためです。フックは動かず、ユーザーの層の設定・文章のガイド・レビューの観点も使いません。導入するリポジトリ（ホームの下の、ホームのリポジトリではないもの）で /dev-workflow:repo-setup を実行してください"
  elif dw_is_set_up "$repo_root"; then
    check set-up true warn "導入済み（.claude/dev-workflow/config.json があります）"
  else
    check set-up false warn "このリポジトリにはプラグインを導入していません（.claude/dev-workflow/config.json がありません）。フック（main を守る・タスクの進め方を渡す・リンクを出す）は動かず、~/.claude/dev-workflow/ の設定・文章のガイド・レビューの観点も使いません。/dev-workflow:repo-setup で導入してください"
  fi
  # ホームのリポジトリには、チームの設定も個人の上書きも無い（置き場所がユーザーの層になる）ので、そこへ移すよう案内しない
  if ! dw_is_home_repo "$repo_root"; then
    old_location "$repo_root/.claude/workflow.json" "$repo_root/.claude/dev-workflow/config.json"
    old_location "$repo_root/.claude/workflow" "$repo_root/.claude/dev-workflow/"
    old_location "$repo_root/.claude/review" "$repo_root/.claude/dev-workflow/review/"
    old_location "$repo_root/.claude/labels.json" "$repo_root/.claude/dev-workflow/labels.json"
    # 個人の設定はメインのワークツリーに置く
    main_root="$(dw_main_root "$repo_root" || true)"
    local_root="${main_root:-$repo_root}"
    old_location "$local_root/.claude/workflow.local.json" "$local_root/.claude/dev-workflow/config.local.json"
    # .gitignore が古い名前だけを無視している、または既にコミットしてあると、個人の設定がコミットされうる
    # （dw_local_config_state で両方を見分け、それぞれに合う案内を出す）
    if [ -f "$local_root/.claude/workflow.local.json" ] || [ -f "$(dw_local_config_file "$repo_root")" ]; then
      hint="$(dw_local_config_hint "$(dw_local_config_state "$repo_root")")"
      [ -z "$hint" ] || check local-ignored false warn "$hint"
    fi
  fi
fi
user_parent="$(dirname "$(dw_user_dir)")"
old_location "$user_parent/workflow/workflow.json" "$(dw_user_dir)/config.json"
old_location "$user_parent/workflow" "$(dw_user_dir)/"
old_location "$user_parent/review" "$(dw_user_review_dir)/"
if [ -n "$moves" ]; then
  check old-locations false warn "古い置き場所のファイルは使われません。移してください: ${moves}"
else
  check old-locations true warn "古い置き場所のファイルはありません"
fi

# ラベルの定義にあってリポジトリに無いラベルがあると、起票などで止まる。定義に足したラベルは、
# 初期設定を済ませたリポジトリには入らないので知らせる。GitHub に問い合わせられないときは飛ばす
if $gh_auth && [ -n "$repo_root" ]; then
  labels_err="$(mktemp)"
  labels="$("$BASH" "$DW_SCRIPTS_DIR/setup/setup-labels.sh" --dry-run --keep-defaults 2>"$labels_err")"
  labels_status=$?
  if [ "$labels_status" -eq 0 ] && missing="$(jq -er '.labels.created | join(", ")' <<<"$labels" 2>/dev/null)"; then
    if [ -n "$missing" ]; then
      check labels false warn "ラベルの定義にあってリポジトリに無いラベルがあります: ${missing}。/dev-workflow:repo-setup でラベルを登録してください"
    else
      check labels true warn "ラベルの定義にあるラベルはすべてリポジトリにあります"
    fi
  elif [ "$labels_status" -eq 2 ]; then
    # 終了コード 2 は定義を読めないとき。GitHub に問い合わせられないときと違い、直さないと起票などで止まる
    check labels false warn "$(tail -n 1 "$labels_err" | LC_ALL=C sed 's/^error: //')"
  fi
  rm -f "$labels_err"
fi

# base_branch にマージキューと strict（最新の取り込みを求める）のどちらが効いているかを示す。どちらも無いと、
# 古い base_branch で通った CI の結果のままマージして壊れることがある。組織のルールセットも含めて見るため、
# ブランチに効いているルール（rules/branches）を読む。キューを使うかは、古いブランチ保護のキューも含めるため、ルールではなく
# GraphQL の repository.mergeQueue で読む（ADR 000381。読めなければルールのキューで代える）。ブランチは、setup-repo.sh がルールセットで守るものと同じく、
# チームの設定で決める（個人の設定は使わない）。GitHub に問い合わせられないときは飛ばす
# 使えない値なら、設定の確認（base-branch）で知らせ、ここでは問い合わせずに飛ばす
base_branch="$team_base"
# 必須のチェックの有無は、名前の一覧（required。ルールセットと古いブランチ保護を合わせる）だけで決め、strict かは、
# 名前のあるルールセットのルール（check_rules）だけで見る。ルールがあっても名前が1つも無ければ、何も求めていない
if $gh_auth && [ -n "$repo_root" ] && [ -n "$base_branch" ] \
  && rules="$(dw_branch_rules '{owner}/{repo}' "$base_branch")" \
  && required="$(dw_required_checks "$rules" "$(dw_classic_required_checks '{owner}/{repo}' "$base_branch")" 2>/dev/null)" \
  && { queue="$(dw_merge_queue_for_branch '{owner}/{repo}' "$base_branch" 2>/dev/null)" \
    || queue="$(jq -s "$DW_JQ_MERGE_QUEUE"' add // [] | merge_queue' <<<"$rules" 2>/dev/null)"; } \
  && merge="$(jq -ser --argjson required "$required" --argjson queue "$queue" "$DW_JQ_CHECK_RULES"'
    # --paginate はページごとに配列を出力するので、1つにまとめる
    add // []
    | if $required == [] then "no-checks"
    elif $queue then "queue"
    elif any(check_rules[]; .parameters.strict_required_status_checks_policy) then "strict"
    elif check_rules != [] then "none"
    else "classic" end' <<<"$rules" 2>/dev/null)"; then
  case "$merge" in
    queue) check merge-queue true warn "${base_branch} へのマージはマージキューを通します" ;;
    strict) check merge-queue true warn "${base_branch} へのマージは、PR が最新の ${base_branch} を取り込んでいることを求めます（strict）" ;;
    none) check merge-queue false warn "${base_branch} へのマージに、マージキューも最新の ${base_branch} の取り込み（strict）も求めていません。古い ${base_branch} で通った CI のままマージすると壊れることがあります。/dev-workflow:repo-setup で設定してください" ;;
    # no-checks（必須のチェックが無い）は、キューがあっても、キューも strict も意味がないので知らせない（下で必須のチェックが無いことを知らせる）
    # classic（必須のチェックが古いブランチ保護にだけある）は、ブランチの情報から strict が分からないので知らせない
  esac
  # 必須のチェックが無いと、キューを使っていても、CI が通らなくてもマージできる。CI の無いリポジトリでは
  # 毎回の警告になるので、チームの設定で求めないことにしていれば警告しない
  if [ "$required" = "[]" ]; then
    if [ "$(dw_team_config "$team_config" require_status_checks 2>/dev/null)" = false ]; then
      check required-checks true warn "${base_branch} へのマージに必須のチェックはありません（設定の require_status_checks が false）"
    else
      check required-checks false warn "${base_branch} へのマージに必須のチェックがありません。CI が通らなくてもマージできます。/dev-workflow:repo-setup で必須のチェックを設定してください。CI が無いなら、.claude/dev-workflow/config.json に \"require_status_checks\": false を書くと、この警告は出なくなります"
    fi
  fi
  # キューを使っていれば、必須のチェックのワークフローが merge_group のイベントで動くかを確かめる（理由は
  # merge-group-check.sh の先頭）。確かめられないときは飛ばす
  if [ "$merge" = queue ]; then
    if [ "$required" != "[]" ] \
      && mg="$("$BASH" "$DW_SCRIPTS_DIR/merge-group-check.sh" --branch "$base_branch" --checks-json "$required" 2>/dev/null)"; then
      if [ "$(jq -r '.messages.not_running // empty' <<<"$mg")" != "" ]; then
        check merge-group false warn "$(jq -r .messages.not_running <<<"$mg")"
      elif [ "$(jq -r '.messages.unknown // empty' <<<"$mg")" != "" ]; then
        check merge-group true warn "$(jq -r .messages.unknown <<<"$mg")"
      else
        check merge-group true warn "必須のチェックのワークフローは、merge_group のイベントでも動きます"
      fi
    fi
  fi
fi

result="$(printf '%s' "$checks" | jq -s '{ok: (map(select(.level == "error" and (.ok | not))) | length == 0), checks: .}')"
printf '%s\n' "$result"
[ "$(jq -r .ok <<<"$result")" = true ]
