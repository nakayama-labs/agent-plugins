#!/usr/bin/env bash
# リポジトリのマージ方法を設定し、マージ先のブランチを守るルールセットを登録する。何度実行しても同じ結果になる。
#
# 使い方: setup-repo.sh [オプション]
#   --repo OWNER/NAME       対象のリポジトリ（既定: 今いるリポジトリ）
#   --require-approval N    マージに必要な承認の数（0〜10。既定: 今の値のまま。新しく作るときは 0）
#   --required-check NAME   マージの前に成功を求めるチェックの名前（繰り返し指定できる。既定: ルールセットの必須のチェックの一覧に触れない）
#                           指定すると、指定した名前の一覧で必須のチェックを置き換え、マージキューを使わないなら、
#                           PR が最新の base_branch を取り込んでいること（strict）も求める
#   --merge-queue           マージキューを使う（スカッシュでマージする）。必須のチェックの strict は外す
#                           キューを使えないリポジトリ（個人のアカウントのリポジトリなど）では止まる
#   --no-merge-queue        マージキューを外す。必須のチェックがあれば strict を求める
#                           （どちらも付けなければ、キューを今のまま使う・使わない）
#   --dry-run               変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. マージ方法：スカッシュのみ許可（コミットのタイトルは PR タイトル、本文は PR 本文）、
#      マージしたブランチを自動で削除する
#   2. ルールセット「dev-workflow」：設定の base_branch への直接 push を禁止して PR を必須にし、
#      強制 push と削除を禁止する。管理者も例外にしない
#      --required-check を指定したときだけ、必須のステータスチェックの一覧を揃える
#      strict（PR が最新の base_branch を取り込んでいること）は、キューの有無で決める。キューを使っていれば
#      （オプションが無くても）外す。キューが最新の base_branch と組み合わせた結果で CI を動かすためである。
#      使っていなければ、--required-check・--no-merge-queue のときに求め、どちらも無ければ今のまま
#      このスクリプトが扱わないルール（オプションを指定しないときの必須のステータスチェックなど）は残す
#   3. 必須のチェックがあれば、そのワークフローが merge_group のイベントで動くかを確かめる（merge-group-check.sh。
#      dry-run でも確かめ、結果は merge_queue.merge_group に出す）。キューを使うのに動かない・確かめられない
#      チェックがあれば警告する（理由は merge-group-check.sh の先頭）。止めはしない
# リポジトリの管理者権限が必要（dry-run でも確かめる）。守るブランチがリポジトリに無ければ止める。
# 守るブランチは、チームの設定（.claude/dev-workflow/config.json）の base_branch で決める（個人の設定は使わない）。
# --repo が今いるリポジトリと違うときは、対象のリポジトリの .claude/dev-workflow/config.json を API で読む。
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

RULESET_NAME="dev-workflow"
# スクリプトが揃えるリポジトリの設定
SETTINGS='{
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY"
}'

repo="" approvals="" dry_run=false
# マージキュー：on は使う、off は外す、空は今のまま
queue=""
checks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --require-approval)
      need_value "$@"
      case "$1" in
        --repo) repo="$2" ;;
        --require-approval) approvals="$2" ;;
      esac
      shift 2
      ;;
    --required-check)
      need_value "$@"
      checks+=("$2")
      shift 2
      ;;
    --merge-queue) queue=on; shift ;;
    --no-merge-queue) queue=off; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
case "$approvals" in
  *[!0-9]*) dw_die "--require-approval には数字を指定してください: $approvals" 64 ;;
esac
# GitHub が受け付ける範囲。dry-run で確かめられるよう、API に送る前に調べる
if [ -n "$approvals" ] && [ "$approvals" -gt 10 ]; then
  dw_die "--require-approval は 0〜10 で指定してください: $approvals" 64
fi

# 必須のチェックの名前（指定が無ければ []）。重複は1つにまとめる
checks_json="$(printf '%s\n' ${checks[@]+"${checks[@]}"} | dw_json_lines_nonempty unique)"

repo_nwo="$(gh repo view ${repo:+"$repo"} --json nameWithOwner -q .nameWithOwner)"
here_nwo=""
if [ -n "$repo" ]; then
  here_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

# --- 守るブランチ（設定の base_branch） ------------------------------------------
# チームの設定（.claude/dev-workflow/config.json）とプラグインの既定だけで決める（dw_team_base_branch）
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
team=""
if [ -z "$repo" ] || [ "$here_nwo" = "$repo_nwo" ]; then
  repo_root="$(dw_repo_root || true)"
  # ホームのリポジトリ（dw_team_dir が空）では、ユーザーの層のファイルをチームの設定として読まない
  team_dir=""
  [ -z "$repo_root" ] || team_dir="$(dw_team_dir "$repo_root")"
  if [ -n "$team_dir" ] && [ -f "$team_dir/config.json" ]; then
    team="$team_dir/config.json"
  fi
elif dw_fetch_repo_file "$repo_nwo" .claude/dev-workflow/config.json "$tmp/workflow.json"; then
  # 別のリポジトリでは、そのリポジトリの既定のブランチにある設定を読む
  team="$tmp/workflow.json"
fi
branch="$(dw_team_base_branch "$team" "${repo_nwo} の .claude/dev-workflow/config.json")"

actions='[]'
# 行った（または dry-run で行う予定の）操作を記録する
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# 読み取りの API。失敗したら GitHub の理由を伝えて止める
# （例：非公開のリポジトリで、プランによってルールセットを使えない）
get() {
  local out
  out="$(gh api "$@" 2>&1)" || dw_die "gh api ${*} に失敗しました: $out"
  printf '%s\n' "$out"
}

# 変更を伴う API の呼び出し。本文は JSON を標準入力から渡す。dry-run では呼ばずに null を返す
# 使い方: mutate <メソッド> <パス> <本文の JSON>
mutate() {
  local out
  if $dry_run; then
    echo null
    return
  fi
  # 非公開のリポジトリでは、プランによってルールセットを使えない。GitHub の理由をそのまま伝える
  out="$(gh api -X "$1" "$2" --input - <<<"$3" 2>&1)" || dw_die "$1 $2 に失敗しました: $out"
  printf '%s\n' "$out"
}

current="$(get "repos/$repo_nwo")"
# 設定の変更には管理者権限が要る。dry-run でも確かめ、setup-all.sh が途中で止まらないようにする
[ "$(jq -r '.permissions.admin // false' <<<"$current")" = true ] \
  || dw_die "${repo_nwo} の管理者権限が必要です（マージ方法とルールセットの変更のため）" 77

# 無いブランチを守っても意味がないので止める。既定のブランチと違うだけなら、意図した運用かもしれないので警告にとどめる
default_branch="$(jq -r .default_branch <<<"$current")"
if [ "$branch" != "$default_branch" ]; then
  if ! out="$(gh api "repos/$repo_nwo/branches/$(jq -rn --arg b "$branch" '$b | @uri')" 2>&1)"; then
    case "$out" in
      *"HTTP 404"*) dw_die "守るブランチ ${branch} が ${repo_nwo} にありません（既定のブランチは ${default_branch}）。.claude/dev-workflow/config.json の base_branch を設定してください" 2 ;;
      *) dw_die "ブランチ ${branch} を確かめられません: $out" ;;
    esac
  fi
  dw_warn "守るブランチ ${branch} は、リポジトリの既定のブランチ（${default_branch}）と違います"
fi

# マージキューを使えるか（true・false、確かめられなければ null）。GitHub では、Organization の公開リポジトリと、
# GitHub Enterprise Cloud の Organization の非公開リポジトリで使える。個人のアカウントのリポジトリでは使えない
queue_available=null
case "$(jq -r '.owner.type // empty' <<<"$current")/$(jq -r '.visibility // empty' <<<"$current")" in
  User/*) queue_available=false ;;
  Organization/public) queue_available=true ;;
  Organization/*)
    # 組織のプランは組織の所有者にしか返らない。返らなければ確かめられないので null のままにする
    plan="$(gh api "orgs/$(jq -r .owner.login <<<"$current")" -q '.plan.name // empty' 2>/dev/null || true)"
    case "$plan" in
      "") ;;
      enterprise) queue_available=true ;;
      *) queue_available=false ;;
    esac
    ;;
esac
if [ "$queue" = on ]; then
  case "$queue_available" in
    false) dw_die "${repo_nwo} ではマージキューを使えません（Organization の公開リポジトリか、GitHub Enterprise Cloud の Organization の非公開リポジトリで使えます）" 2 ;;
    null) dw_warn "${repo_nwo} でマージキューを使えるか確かめられません（GitHub Enterprise Cloud の Organization の非公開リポジトリで使えます）" ;;
  esac
fi

# --- 1. マージ方法 --------------------------------------------------------------
changed="$(jq -nc --argjson want "$SETTINGS" --argjson cur "$current" \
  '[$want | to_entries[] | select(.value != $cur[.key]) | .key]')"
if [ "$changed" != "[]" ]; then
  note "マージ方法をスカッシュのみにし、マージしたブランチを自動で削除する（$(jq -r 'join(", ")' <<<"$changed")）"
  # 違う項目だけを送る。ただし GitHub はスカッシュのタイトルと本文を組で求める（本文だけだと 422）ので、片方が違えば両方送る
  mutate PATCH "repos/$repo_nwo" "$(jq -c --argjson c "$changed" '
    ["squash_merge_commit_title", "squash_merge_commit_message"] as $pair
    | (if any($c[]; . as $k | $pair | index($k)) then $c + $pair else $c end) as $send
    | with_entries(select(.key as $k | $send | index($k)))' <<<"$SETTINGS")" >/dev/null
fi

# --- 2. ルールセット ------------------------------------------------------------
# 組織のルールセットも返るので、このリポジトリのものだけを名前で探す。--paginate はページごとに配列を出力する
rulesets="$(get --paginate "repos/$repo_nwo/rulesets?per_page=100")"
ruleset_id="$(jq -rs --arg n "$RULESET_NAME" \
  '[.[][] | select(.name == $n and .source_type == "Repository")][0].id // empty' <<<"$rulesets")"
existing='null'
if [ -n "$ruleset_id" ]; then
  existing="$(get "repos/$repo_nwo/rulesets/$ruleset_id")"
fi

# 既存の pull_request の設定は残し、承認の数（指定されたときだけ）とマージ方法を揃える
# マージキューは、--merge-queue・--no-merge-queue が無ければ今のまま。strict はキューの有無で決める（先頭のコメント）。
# キューを使っていれば外し、使っていなければ --required-check・--no-merge-queue のときに求め、どちらも無ければ今のまま
desired="$(jq -n --argjson ex "$existing" --arg name "$RULESET_NAME" --arg ref "refs/heads/$branch" \
  --arg n "$approvals" --argjson checks "$checks_json" --arg queue "$queue" '
  ([($ex // {}).rules // [] | .[] | select(.type == "pull_request")][0].parameters // {}) as $old
  | ([($ex // {}).rules // [] | .[] | select(.type == "required_status_checks")][0].parameters.required_status_checks // []) as $oldchecks
  | ([($ex // {}).rules // [] | .[] | select(.type == "merge_queue")][0].parameters) as $oldqueue
  | (if $queue == "" then $oldqueue != null else $queue == "on" end) as $useq
  | (if $useq then false elif ($checks | length) > 0 or $queue == "off" then true else null end) as $strict
  | (["deletion", "non_fast_forward", "pull_request", "merge_queue"]
    + (if ($checks | length) > 0 then ["required_status_checks"] else [] end)) as $managed
  | {
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {ref_name: {include: [$ref], exclude: []}},
      rules: (
        [($ex // {}).rules // [] | .[] | select(.type as $t | $managed | index($t) | not)]
        + [{type: "deletion"}, {type: "non_fast_forward"},
           {type: "pull_request", parameters: ({
              dismiss_stale_reviews_on_push: false,
              require_code_owner_review: false,
              require_last_push_approval: false,
              required_approving_review_count: 0,
              required_review_thread_resolution: false
            } + $old + {allowed_merge_methods: ["squash"]}
              + (if $n == "" then {} else {required_approving_review_count: ($n | tonumber)} end))}]
        + (if ($checks | length) > 0 then
            [{type: "required_status_checks", parameters: {
              strict_required_status_checks_policy: $strict,
              do_not_enforce_on_create: false,
              # 同じ名前の既存のチェックが報告元のアプリ（integration_id）を指定していれば、引き継ぐ
              required_status_checks: ($checks | map(. as $c
                | ([$oldchecks[] | select(.context == $c and .integration_id != null)][0].integration_id) as $i
                | {context: $c} + (if $i == null then {} else {integration_id: $i} end)))}}]
          else [] end)
        # 既存の設定（同時に組む数など）は残し、マージ方法だけスカッシュに揃える
        + (if $useq then
            [{type: "merge_queue", parameters: ({
              max_entries_to_build: 5,
              min_entries_to_merge: 1,
              max_entries_to_merge: 5,
              min_entries_to_merge_wait_minutes: 5,
              grouping_strategy: "ALLGREEN",
              check_response_timeout_minutes: 60
            } + ($oldqueue // {}) + {merge_method: "SQUASH"})}]
          else [] end)
      )
    }
  # 既存の必須のチェックも含めて strict を揃える。jq 1.7 はオブジェクトの値の中の「| if」を読めないので、作った後に書き換える
  | if $strict == null then . else
      .rules |= map(if .type == "required_status_checks"
        then .parameters.strict_required_status_checks_policy = $strict else . end)
    end')"
# 必須のチェックの規則（無ければ null）と、キューを使うか
checks_rule="$(jq -c '[.rules[] | select(.type == "required_status_checks")][0]' <<<"$desired")"
queue_enabled="$(jq '[.rules[] | select(.type == "merge_queue")] | length > 0' <<<"$desired")"
checks_note=""
if [ "$checks_json" != "[]" ]; then
  checks_note="、必須のチェック: $(jq -r 'join(", ")' <<<"$checks_json")"
fi
if [ "$(jq -r '.parameters.strict_required_status_checks_policy // false' <<<"$checks_rule")" = true ] \
  && { [ "$checks_json" != "[]" ] || [ "$queue" = off ]; }; then
  if [ -n "$checks_note" ]; then
    checks_note="${checks_note}・最新の ${branch} の取り込み"
  else
    checks_note="、最新の ${branch} の取り込み"
  fi
fi
if $queue_enabled; then
  checks_note="${checks_note}、マージキュー（スカッシュ）"
elif [ "$queue" = off ] && [ "$(jq '[(.rules // [])[] | select(.type == "merge_queue")] | length > 0' <<<"$existing")" = true ]; then
  checks_note="${checks_note}、マージキューを外す"
fi
approvals_now="$(jq '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count' <<<"$desired")"

# 必須のチェックを出すワークフローが merge_group のイベントで動くか（理由は merge-group-check.sh の先頭）。
# キューを使うかを決める材料にするため、キューを使わないときも確かめる（警告はキューを使うときだけ）。必須のチェックは、このルールセットのものと、
# 組織などのほかのルールセットが base_branch に求めるもの（rules/branches）と、古いブランチ保護が求めるものを合わせる
other_rules="$(dw_branch_rules "$repo_nwo" "$branch")" || other_rules='[]'
other_checks="$(dw_required_checks "$other_rules" "$(dw_classic_required_checks "$repo_nwo" "$branch")" "$ruleset_id" 2>/dev/null)" \
  || other_checks='[]'
all_checks="$(jq -c --argjson o "$other_checks" '[.rules[] | select(.type == "required_status_checks")
  | .parameters.required_status_checks[].context] + $o | unique' <<<"$desired")"
merge_group=null
if [ "$all_checks" != "[]" ]; then
  if mg="$("$BASH" "$DW_SCRIPTS_DIR/merge-group-check.sh" --repo "$repo_nwo" --branch "$branch" --checks-json "$all_checks" 2>&1)" \
    && merge_group="$(jq -c '{not_running, unknown}' <<<"$mg" 2>/dev/null)"; then
    if $queue_enabled; then
      while IFS= read -r m; do
        dw_warn "$m"
      done < <(jq -r '.messages | .not_running, .unknown | values' <<<"$mg")
    fi
  else
    merge_group=null
    if $queue_enabled; then
      dw_warn "必須のチェックのワークフローが merge_group のイベントで動くか確かめられません: $(printf '%s\n' "$mg" | tail -n 1 | LC_ALL=C sed 's/^error: //')"
    fi
  fi
fi

# 比べる形に揃える（ルールは種類の順、GitHub が付け足す項目は除く）
normalize() {
  jq -S '{enforcement, target, bypass_actors: (.bypass_actors // []),
    conditions: {ref_name: {include: (.conditions.ref_name.include // []), exclude: (.conditions.ref_name.exclude // [])}},
    rules: ((.rules // []) | map({type} + (if .parameters then {parameters} else {} end))
      # 必須のチェックは、GitHub が付け足す項目（integration_id など）と並び順の違いを無視して、名前と厳密さだけを比べる
      | map(if .type == "required_status_checks" then
          .parameters |= {strict: (.strict_required_status_checks_policy // false),
                          checks: ([.required_status_checks[]?.context] | sort)}
        else . end)
      | sort_by(.type))}'
}

created=false updated=false
if [ "$existing" = null ]; then
  note "ルールセット「${RULESET_NAME}」を作成し、${branch} への直接 push・強制 push・削除を禁止する（必要な承認: ${approvals_now}${checks_note}）"
  created=true
  ruleset_id="$(mutate POST "repos/$repo_nwo/rulesets" "$desired" | jq -r '.id // empty')"
elif [ "$(normalize <<<"$existing")" != "$(normalize <<<"$desired")" ]; then
  note "ルールセット「${RULESET_NAME}」を揃える（${branch} を保護、必要な承認: ${approvals_now}${checks_note}）"
  updated=true
  mutate PUT "repos/$repo_nwo/rulesets/$ruleset_id" "$desired" >/dev/null
fi

jq -n --argjson dry "$dry_run" --arg repo "$repo_nwo" --arg branch "$branch" --argjson changed "$changed" \
  --arg id "$ruleset_id" --argjson created "$created" --argjson updated "$updated" \
  --argjson approvals "$approvals_now" --argjson checks "$checks_json" --argjson actions "$actions" \
  --argjson qa "$queue_available" --argjson qe "$queue_enabled" --argjson rule "$checks_rule" \
  --argjson mg "$merge_group" '{
    dry_run: $dry,
    repo: $repo,
    branch: $branch,
    settings: {changed: $changed},
    ruleset: {id: (if $id == "" then null else ($id | tonumber) end), created: $created, updated: $updated,
      required_approvals: $approvals, required_checks: $checks,
      # 必須のチェックが無ければ null
      strict: (if $rule == null then null else ($rule.parameters.strict_required_status_checks_policy // false) end)},
    # merge_group：必須のチェックのワークフローが merge_group で動くか（merge-group-check.sh の not_running・unknown。
    # not_running の要素は check・workflows・reason（on: に merge_group が無ければ on、ジョブの if: で除けば if））。
    # 必須のチェックが無い、または確かめられなければ null
    merge_queue: {available: $qa, enabled: $qe, merge_group: $mg},
    actions: $actions
  }'
