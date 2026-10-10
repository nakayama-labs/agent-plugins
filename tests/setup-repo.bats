#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。
# gh api <パス>（GET）は、リポジトリなら repo.json、ルールセットの一覧なら rulesets.json、
# ルールセット1件なら ruleset.json を返す。ブランチ（.../branches/<名前>）は $FIX/branches/<名前> があればその中身（空なら {}）を返し、無ければ 404 にする。
# gh api -X <メソッド> <パス> --input - は「<メソッド> <パス> <本文>」を $CALLS に1行ずつ記録し、
# $FIX/<メソッド>.json があれば返す。FAKE_FAIL に指定したメソッド（GET を含む）は 403 で失敗する。
# gh repo view は、リポジトリを指定すれば repo-view.json、指定しなければ here.json を返す。
# 別のリポジトリのファイル（gh api -H ... .../contents/<パス>）は $FIX/remote/<パス> を返し、無ければ 404 にする。
# 組織（orgs/<名前>）は $FIX/org.json に -q を適用して返し、無ければ 404 にする（組織の所有者でないときはプランが返らない）。
# ブランチのワークフロー（.../contents/.github/workflows?ref=...）は $FIX/workflows/ のファイルの一覧を返し、
# ディレクトリが無ければ 404 にし、FAKE_WORKFLOWS_FAIL があれば 403 で失敗する。ファイル（gh api -H ... .../contents/.github/workflows/<名前>?ref=...）はそのファイルを返す。
# ブランチに効いているルール（.../rules/branches/<名前>）は $FIX/branch-rules.json（無ければ []）を返す。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# --paginate は取り除き、ページが1つだけのときと同じに扱う
if [ "$1" = api ] && [ "$2" = --paginate ]; then shift 2; set -- api "$@"; fi
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
case "$1 $2" in
  "repo view")
    case "${3:-}" in
      "" | -*) f=here.json ;;
      *) f=repo-view.json ;;
    esac
    [ -f "$FIX/$f" ] || f=repo-view.json
    jq -r "$q" "$FIX/$f"
    ;;
  "api -X")
    if [ "$3" = "${FAKE_FAIL:-}" ]; then echo 'gh: Upgrade to GitHub Pro (HTTP 403)' >&2; exit 1; fi
    printf '%s %s %s\n' "$3" "$4" "$(jq -c .)" >>"$CALLS"
    if [ -f "$FIX/$3.json" ]; then cat "$FIX/$3.json"; else echo '{}'; fi
    ;;
  "api -H")
    path="${4#repos/*/*/contents/}"
    case "$path" in
      .github/workflows/*) cat "$FIX/workflows/$(basename "${path%%\?*}")"; exit ;;
    esac
    if [ -f "$FIX/remote/$path" ]; then cat "$FIX/remote/$path"
    else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    ;;
  "api "*)
    if [ "${FAKE_FAIL:-}" = GET ]; then echo 'gh: Upgrade to GitHub Pro (HTTP 403)' >&2; exit 1; fi
    case "$2" in
      */rules/branches/*)
        if [ -f "$FIX/branch-rules.json" ]; then cat "$FIX/branch-rules.json"; else echo '[]'; fi
        ;;
      */contents/.github/workflows\?*)
        if [ -n "${FAKE_WORKFLOWS_FAIL:-}" ]; then echo 'gh: Forbidden (HTTP 403)' >&2; exit 1; fi
        [ -d "$FIX/workflows" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
        for f in "$FIX/workflows"/*; do
          jq -n --arg n "$(basename "$f")" '{name: $n, path: (".github/workflows/" + $n), type: "file"}'
        done | jq -s .
        ;;
      */branches/*)
        b="$FIX/branches/${2##*/branches/}"
        if [ -s "$b" ]; then cat "$b"
        elif [ -f "$b" ]; then echo '{}'
        else echo 'gh: Branch not found (HTTP 404)' >&2; exit 1; fi
        ;;
      orgs/*)
        if [ -f "$FIX/org.json" ]; then jq -r "$q" "$FIX/org.json"
        else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
        ;;
      */rulesets\?*) cat "$FIX/rulesets.json" ;;
      */rulesets/*) cat "$FIX/ruleset.json" ;;
      *) cat "$FIX/repo.json" ;;
    esac
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  echo '{"nameWithOwner": "me/demo"}' >"$FIX/repo-view.json"
  repo_settings '{"allow_squash_merge": true, "allow_merge_commit": true, "allow_rebase_merge": true,
    "delete_branch_on_merge": false, "squash_merge_commit_title": "COMMIT_OR_PR_TITLE",
    "squash_merge_commit_message": "COMMIT_MESSAGES"}'
  echo '[]' >"$FIX/rulesets.json"
  echo '{"id": 42}' >"$FIX/POST.json"
}

# リポジトリの設定。管理者権限があり、既定のブランチは main。使い方: repo_settings <マージ方法の設定の JSON> [上書きする JSON]
repo_settings() {
  jq -n --argjson s "$1" --argjson o "${2:-"{}"}" \
    '{default_branch: "main", permissions: {admin: true}} + $s + $o' >"$FIX/repo.json"
}

# 揃った状態のリポジトリの設定。使い方: settled_repo [上書きする JSON]
settled_repo() {
  repo_settings '{"allow_squash_merge": true, "allow_merge_commit": false, "allow_rebase_merge": false,
    "delete_branch_on_merge": true, "squash_merge_commit_title": "PR_TITLE",
    "squash_merge_commit_message": "PR_BODY"}' "${1:-"{}"}"
}

# 既存のルールセット（main を守る）。使い方: existing_ruleset [pull_request の parameters に足す JSON] [ほかのルールの配列]
existing_ruleset() {
  echo '[{"id": 7, "name": "dev-workflow", "source_type": "Repository"}]' >"$FIX/rulesets.json"
  jq -n --argjson p "${1:-"{}"}" --argjson extra "${2:-"[]"}" '{
    id: 7, name: "dev-workflow", target: "branch", enforcement: "active", bypass_actors: [],
    source_type: "Repository", source: "me/demo",
    conditions: {ref_name: {include: ["refs/heads/main"], exclude: []}},
    rules: ([{type: "deletion"}, {type: "non_fast_forward"},
      {type: "pull_request", parameters: ({dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false, require_last_push_approval: false,
        required_approving_review_count: 0, required_review_thread_resolution: false,
        allowed_merge_methods: ["squash"]} + $p)}] + $extra)}' >"$FIX/ruleset.json"
}

run_setup() {
  run "${TEST_BASH:-bash}" "$SCRIPTS/setup/setup-repo.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: body <メソッド> → 記録した本文の JSON
body() { grep "^$1 " "$CALLS" | head -n 1 | cut -d' ' -f3-; }

# 変更を伴う呼び出しが1つも無いことを確かめる。あれば記録を表示して失敗する
assert_no_calls() {
  if [ -s "$CALLS" ]; then
    fail "$(printf '呼ばれないはずの操作が呼ばれました:\n%s' "$(cat "$CALLS")")"
  fi
}

@test "マージ方法を揃え、違う項目だけを送る" {
  setup_fake_gh
  settled_repo '{"allow_merge_commit": true}'
  run_setup
  assert_success
  assert_equal "$(called PATCH)" 1
  assert_equal "$(body PATCH)" '{"allow_merge_commit":false}'
  assert_equal "$(jq -c .settings.changed <<<"$json")" '["allow_merge_commit"]'
}

@test "スカッシュのタイトルと本文は、片方だけ違っても組で送る" {
  setup_fake_gh
  settled_repo '{"squash_merge_commit_message": "COMMIT_MESSAGES"}'
  existing_ruleset
  run_setup
  assert_success
  assert_equal "$(body PATCH)" '{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  assert_equal "$(jq -c .settings.changed <<<"$json")" '["squash_merge_commit_message"]'
}

@test "ルールセットが無ければ作る（PR 必須・スカッシュのみ・強制 push と削除の禁止・例外なし）" {
  setup_fake_gh
  run_setup
  assert_success
  assert_equal "$(called POST)" 1
  req="$(body POST)"
  assert_equal "$(jq -c '[.name, .enforcement, .conditions.ref_name.include, .bypass_actors]' <<<"$req")" \
    '["dev-workflow","active",["refs/heads/main"],[]]'
  assert_equal "$(jq -c '[.rules[].type]' <<<"$req")" '["deletion","non_fast_forward","pull_request"]'
  assert_equal "$(jq -c '.rules[2].parameters | [.required_approving_review_count, .allowed_merge_methods]' <<<"$req")" \
    '[0,["squash"]]'
  assert_equal "$(jq -c '.ruleset | [.id, .created]' <<<"$json")" '[42,true]'
}

@test "揃っていれば何も変更しない（2回目の実行）" {
  setup_fake_gh
  settled_repo
  existing_ruleset
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -c .actions <<<"$json")" '[]'
  assert_equal "$(jq -r .ruleset.id <<<"$json")" 7
}

@test "GitHub が付け足す項目やルールの順番の違いは変更とみなさない" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{"required_reviewers": []}'
  jq '.rules |= reverse | . + {created_at: "2026-01-01", _links: {}}' "$FIX/ruleset.json" >"$FIX/r.json"
  mv "$FIX/r.json" "$FIX/ruleset.json"
  run_setup
  assert_success
  assert_no_calls
}

@test "--require-approval を付けなければ、既存の承認の数を変えない" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{"required_approving_review_count": 2}'
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -r .ruleset.required_approvals <<<"$json")" 2
}

@test "--require-approval で承認の数を変え、ほかのルールと pull_request の設定は残す" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{"dismiss_stale_reviews_on_push": true}' \
    '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "test"}]}}]'
  run_setup --require-approval 1
  assert_success
  assert_equal "$(called PUT)" 1
  grep -q '^PUT repos/me/demo/rulesets/7 ' "$CALLS"
  req="$(body PUT)"
  assert_equal "$(jq -c '.rules[] | select(.type == "pull_request") | .parameters
    | [.required_approving_review_count, .dismiss_stale_reviews_on_push]' <<<"$req")" '[1,true]'
  assert_equal "$(jq -c '[.rules[].type] | sort' <<<"$req")" \
    '["deletion","non_fast_forward","pull_request","required_status_checks"]'
}

@test "例外（bypass_actors）が足されていれば外す" {
  setup_fake_gh
  settled_repo
  existing_ruleset
  jq '.bypass_actors = [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]' \
    "$FIX/ruleset.json" >"$FIX/r.json"
  mv "$FIX/r.json" "$FIX/ruleset.json"
  run_setup
  assert_success
  assert_equal "$(called PUT)" 1
  assert_equal "$(body PUT | jq -c .bypass_actors)" '[]'
}

@test "設定の base_branch を守る（既定のブランチと違えば警告する）" {
  setup_fake_gh
  mkdir -p "$FIX/branches" && touch "$FIX/branches/develop"
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  run_setup
  assert_success
  assert_equal "$(body POST | jq -c .conditions.ref_name.include)" '["refs/heads/develop"]'
  assert_output --partial "守るブランチ develop は、リポジトリの既定のブランチ（main）と違います"
}

@test "設定の base_branch がダッシュで始まれば、dry-run でも止まる" {
  setup_fake_gh
  echo '{"base_branch": "-v"}' >.claude/dev-workflow/config.json
  run_setup --dry-run
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -v"
}

@test "チームの設定が空のファイルなら、JSON として読めないことを示して止まる" {
  setup_fake_gh
  : >.claude/dev-workflow/config.json
  run_setup --dry-run
  assert_failure 2
  assert_output --partial "me/demo の .claude/dev-workflow/config.json を JSON のオブジェクトとして読めません"
}

@test "設定の base_branch が文字列でなければ、dry-run でも止まる（\"1\" という名前のブランチを守ろうとしない）" {
  setup_fake_gh
  echo '{"base_branch": 1}' >.claude/dev-workflow/config.json
  run_setup --dry-run
  assert_failure 2
  assert_output --partial "設定の base_branch が文字列ではありません"
}

@test "個人の設定（config.local.json・ユーザーの設定）の base_branch は使わない" {
  # ユーザーの層も読む、導入したリポジトリで確かめる
  mark_set_up
  setup_fake_gh
  echo '{"base_branch": "mine"}' >.claude/dev-workflow/config.local.json
  echo '{"base_branch": "user"}' >"$WORKFLOW_USER_DIR/config.json"
  run_setup
  assert_success
  assert_equal "$(body POST | jq -c .conditions.ref_name.include)" '["refs/heads/main"]'
}

@test "守るブランチがリポジトリに無ければ、dry-run でも止まる" {
  setup_fake_gh
  settled_repo '{"default_branch": "master"}'
  run_setup --dry-run
  assert_failure 2
  assert_output --partial "守るブランチ main が me/demo にありません（既定のブランチは master）"
}

@test "管理者権限が無ければ、dry-run でも止まる" {
  setup_fake_gh
  settled_repo '{"permissions": {"admin": false, "push": true}}'
  run_setup --dry-run
  assert_failure 77
  assert_output --partial "me/demo の管理者権限が必要です"
}

@test "--require-approval が 10 を超えるとエラーになる" {
  setup_fake_gh
  run_setup --require-approval 11 --dry-run
  assert_failure 64
  assert_output --partial "0〜10"
}

@test "組織のルールセットは同じ名前でも使わない" {
  setup_fake_gh
  settled_repo
  echo '[{"id": 9, "name": "dev-workflow", "source_type": "Organization"}]' >"$FIX/rulesets.json"
  run_setup
  assert_success
  assert_equal "$(called POST)" 1
}

@test "--repo で別のリポジトリを指定したら、そのリポジトリの base_branch を使う" {
  setup_fake_gh
  echo '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  mkdir -p "$FIX/remote/.claude/dev-workflow"
  echo '{"base_branch": "trunk"}' >"$FIX/remote/.claude/dev-workflow/config.json"
  mkdir -p "$FIX/branches" && touch "$FIX/branches/trunk"
  run_setup --repo me/demo
  assert_success
  assert_equal "$(body POST | jq -c .conditions.ref_name.include)" '["refs/heads/trunk"]'
}

@test "別のリポジトリに設定が無ければ、プラグインの既定（main）を使う" {
  setup_fake_gh
  echo '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  run_setup --repo me/demo
  assert_success
  assert_equal "$(body POST | jq -c .conditions.ref_name.include)" '["refs/heads/main"]'
}

@test "dry-run では変更せず、予定の操作だけを出力する" {
  setup_fake_gh
  run_setup --dry-run
  assert_success
  assert_no_calls
  assert_equal "$(jq -r .dry_run <<<"$json")" true
  assert_equal "$(jq '.actions | length' <<<"$json")" 2
  assert_equal "$(jq -r '.actions[1]' <<<"$json")" \
    "ルールセット「dev-workflow」を作成し、main への直接 push・強制 push・削除を禁止する（必要な承認: 0）"
}

@test "API が失敗したら GitHub の理由を表示して止まる" {
  setup_fake_gh
  settled_repo
  FAKE_FAIL=POST run_setup
  assert_failure 1
  assert_output --partial "POST repos/me/demo/rulesets に失敗しました"
  assert_output --partial "Upgrade to GitHub Pro"
}

@test "読み取りの API が失敗したら、dry-run でも GitHub の理由を表示して止まる" {
  setup_fake_gh
  FAKE_FAIL=GET run_setup --dry-run
  assert_failure 1
  assert_output --partial "gh api repos/me/demo に失敗しました"
  assert_output --partial "Upgrade to GitHub Pro"
}

@test "ルールセットの一覧は複数のページをまとめて探す" {
  setup_fake_gh
  settled_repo
  existing_ruleset
  echo '[{"id": 1, "name": "other", "source_type": "Repository"}]
[{"id": 7, "name": "dev-workflow", "source_type": "Repository"}]' >"$FIX/rulesets.json"
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -r .ruleset.id <<<"$json")" 7
}

@test "--require-approval に数字以外を渡すとエラーになる" {
  setup_fake_gh
  run_setup --require-approval one
  assert_failure 64
}

@test "--help は使い方を表示する" {
  setup_fake_gh
  run_setup --help
  assert_success
  assert_output --partial "--require-approval"
  refute_output --partial "set -euo"
}

# 必須のチェックの規則。使い方: checks_rule <最新の取り込みを求めるか true|false> <名前>...
checks_rule() {
  local strict="$1"
  shift
  jq -nc --argjson s "$strict" '$ARGS.positional as $n | {type: "required_status_checks", parameters: {
    strict_required_status_checks_policy: $s, do_not_enforce_on_create: false,
    required_status_checks: ($n | map({context: ., integration_id: 15368}))}}' --args "$@"
}

@test "--required-check で、必須のチェックと最新の main の取り込みを求めるルールセットを作る" {
  setup_fake_gh
  run_setup --required-check lint-result --required-check test-result
  assert_success
  rule="$(body POST | jq -c '.rules[] | select(.type == "required_status_checks")')"
  assert_equal "$(jq -c '.parameters | [.strict_required_status_checks_policy, [.required_status_checks[].context]]' <<<"$rule")" \
    '[true,["lint-result","test-result"]]'
  assert_equal "$(jq -c '.ruleset.required_checks' <<<"$json")" '["lint-result","test-result"]'
}

@test "--required-check を付けなければ、既存の必須のチェックに触れない" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{}' "[$(checks_rule false old-check)]"
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -c .ruleset.required_checks <<<"$json")" '[]'
}

@test "--required-check は、既存の必須のチェックを指定した一覧に置き換える（足りない名前を足し、余る名前を外す）" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{}' "[$(checks_rule false old-check)]"
  run_setup --required-check new-check
  assert_success
  assert_equal "$(called PUT)" 1
  req="$(body PUT)"
  assert_equal "$(jq -c '[.rules[] | select(.type == "required_status_checks")] | length' <<<"$req")" 1
  assert_equal "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters
    | [.strict_required_status_checks_policy, [.required_status_checks[].context]]' <<<"$req")" '[true,["new-check"]]'
}

@test "必須のチェックが指定どおりなら変更しない（GitHub が付ける項目と並び順は無視する）" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{}' "[$(checks_rule true test-result lint-result)]"
  run_setup --required-check lint-result --required-check test-result --required-check lint-result
  assert_success
  assert_no_calls
}

@test "最新の取り込みを求めていない既存の必須のチェックは、名前が同じでも揃える" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{}' "[$(checks_rule false lint-result)]"
  run_setup --required-check lint-result
  assert_success
  assert_equal "$(called PUT)" 1
  assert_equal "$(body PUT | jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy')" true
}

@test "--required-check に値が無ければ使い方の誤り（64）" {
  setup_fake_gh
  run_setup --required-check
  assert_failure 64
  assert_output --partial "--required-check に値がありません"
}

@test "dry-run では、必須のチェックを揃える予定を出すだけで変更しない" {
  setup_fake_gh
  settled_repo
  existing_ruleset
  run_setup --dry-run --required-check lint-result
  assert_success
  assert_no_calls
  assert_output --partial "必須のチェック: lint-result"
}

@test "--required-check で置き換えても、同じ名前の既存の integration_id は引き継ぎ、新しい名前には付けない" {
  setup_fake_gh
  settled_repo
  existing_ruleset '{}' "[$(checks_rule false lint-result)]"
  run_setup --required-check lint-result --required-check test-result
  assert_success
  assert_equal "$(called PUT)" 1
  assert_equal "$(body PUT | jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks')" \
    '[{"context":"lint-result","integration_id":15368},{"context":"test-result"}]'
}

# キューの規則。使い方: queue_rule [parameters に足す JSON]
queue_rule() {
  jq -nc --argjson p "${1:-"{}"}" '{type: "merge_queue", parameters: ({merge_method: "SQUASH",
    max_entries_to_build: 5, min_entries_to_merge: 1, max_entries_to_merge: 5,
    min_entries_to_merge_wait_minutes: 5, grouping_strategy: "ALLGREEN", check_response_timeout_minutes: 60} + $p)}'
}

# 所有者の種類と公開範囲。使い方: owned_by <User|Organization> <public|private|internal>
owned_by() {
  jq --arg t "$1" --arg v "$2" '. + {owner: {login: "me", type: $t}, visibility: $v}' "$FIX/repo.json" >"$FIX/r.json"
  mv "$FIX/r.json" "$FIX/repo.json"
}

@test "--merge-queue で、キュー（スカッシュ）を設定し、必須のチェックの strict は外す" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset
  run_setup --merge-queue --required-check lint-result
  assert_success
  assert_equal "$(called PUT)" 1
  req="$(body PUT)"
  assert_equal "$(jq -c '.rules[] | select(.type == "merge_queue") | .parameters | [.merge_method, .grouping_strategy]' <<<"$req")" \
    '["SQUASH","ALLGREEN"]'
  assert_equal "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy' <<<"$req")" false
  assert_equal "$(jq -c '[.merge_queue.available, .merge_queue.enabled, .ruleset.strict]' <<<"$json")" '[true,true,false]'
  assert_output --partial "必須のチェック: lint-result、マージキュー（スカッシュ）"
}

@test "--merge-queue だけでも、既存の必須のチェックの strict を外す" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(checks_rule true lint-result)]"
  run_setup --merge-queue
  assert_success
  req="$(body PUT)"
  assert_equal "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters
    | [.strict_required_status_checks_policy, [.required_status_checks[].context]]' <<<"$req")" '[false,["lint-result"]]'
}

@test "キューの既存の設定（同時に組む数など）は残し、マージ方法だけスカッシュに揃える" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(queue_rule '{"merge_method": "MERGE", "max_entries_to_merge": 2}')]"
  run_setup --merge-queue
  assert_success
  assert_equal "$(body PUT | jq -c '.rules[] | select(.type == "merge_queue") | .parameters | [.merge_method, .max_entries_to_merge]')" \
    '["SQUASH",2]'
}

@test "キューが揃っていれば、何も付けなくても --merge-queue でも変更しない" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(checks_rule false lint-result), $(queue_rule)]"
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -c '[.merge_queue.enabled, .ruleset.strict]' <<<"$json")" '[true,false]'
  run_setup --merge-queue --required-check lint-result
  assert_success
  assert_no_calls
}

@test "キューを使っていれば、--required-check で置き換えても strict は求めない" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(checks_rule false lint-result), $(queue_rule)]"
  run_setup --required-check test-result
  assert_success
  req="$(body PUT)"
  assert_equal "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters
    | [.strict_required_status_checks_policy, [.required_status_checks[].context]]' <<<"$req")" '[false,["test-result"]]'
  assert_equal "$(jq -c '[.rules[] | select(.type == "merge_queue")] | length' <<<"$req")" 1
}

@test "--no-merge-queue でキューを外し、必須のチェックの strict を求める" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(checks_rule false lint-result), $(queue_rule)]"
  run_setup --no-merge-queue
  assert_success
  req="$(body PUT)"
  assert_equal "$(jq -c '[.rules[] | select(.type == "merge_queue")] | length' <<<"$req")" 0
  assert_equal "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy' <<<"$req")" true
  assert_equal "$(jq -c '[.merge_queue.enabled, .ruleset.strict]' <<<"$json")" '[false,true]'
  assert_output --partial "最新の main の取り込み、マージキューを外す"
}

@test "個人のアカウントのリポジトリでは、--merge-queue は dry-run でも止まる" {
  setup_fake_gh
  settled_repo
  owned_by User public
  run_setup --merge-queue --dry-run
  assert_failure 2
  assert_output --partial "me/demo ではマージキューを使えません"
}

@test "キューを使えるかを出力する（個人は false、組織の公開は true、組織の非公開はプランで決める）" {
  setup_fake_gh
  settled_repo
  existing_ruleset
  owned_by User public
  run_setup --dry-run
  assert_equal "$(jq -c .merge_queue <<<"$json")" '{"available":false,"enabled":false,"merge_group":null}'
  owned_by Organization public
  run_setup --dry-run
  assert_equal "$(jq -c .merge_queue.available <<<"$json")" true
  owned_by Organization private
  echo '{"plan": {"name": "enterprise"}}' >"$FIX/org.json"
  run_setup --dry-run
  assert_equal "$(jq -c .merge_queue.available <<<"$json")" true
  echo '{"plan": {"name": "team"}}' >"$FIX/org.json"
  run_setup --dry-run
  assert_equal "$(jq -c .merge_queue.available <<<"$json")" false
}

@test "組織の非公開リポジトリでプランが分からなければ、警告して --merge-queue を続ける" {
  setup_fake_gh
  settled_repo
  owned_by Organization private
  existing_ruleset
  run_setup --merge-queue
  assert_success
  assert_output --partial "マージキューを使えるか確かめられません"
  assert_equal "$(jq -c .merge_queue.available <<<"$json")" null
  assert_equal "$(called PUT)" 1
}

# ワークフローを置く。使い方: workflow <ファイル名> <on: の値> <ジョブの ID>...
workflow() {
  local name="$1" on="$2"
  shift 2
  mkdir -p "$FIX/workflows"
  { printf 'on: %s\njobs:\n' "$on"; printf '  %s:\n    runs-on: ubuntu-latest\n' "$@"; } >"$FIX/workflows/$name"
}

@test "キューを使うとき、必須のチェックのワークフローが merge_group で動かなければ、dry-run でも警告する" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset
  workflow ci.yml pull_request lint-result
  workflow test.yml "[pull_request, merge_group]" test-result
  run_setup --merge-queue --required-check lint-result --required-check test-result --required-check codecov --dry-run
  assert_success
  assert_no_calls
  assert_output --partial "必須のチェックのうち lint-result（.github/workflows/ci.yml）は、merge_group のイベントで動きません"
  assert_output --partial "必須のチェック codecov は、main のどのワークフローのジョブか分からないので"
  assert_equal "$(jq -c .merge_queue.merge_group <<<"$json")" \
    '{"not_running":[{"check":"lint-result","workflows":[".github/workflows/ci.yml"],"reason":"on"}],"unknown":["codecov"]}'
}

@test "キューを使わないときも、既存の必須のチェックを確かめて出力する（警告はしない）" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset '{}' "[$(checks_rule true lint-result)]"
  workflow ci.yml pull_request lint-result
  run_setup --dry-run
  assert_success
  refute_output --partial "warn:"
  assert_equal "$(jq -c '[.merge_queue.enabled, .merge_queue.merge_group.not_running[].check]' <<<"$json")" '[false,"lint-result"]'
}

@test "ほかのルールセットが求める必須のチェックも確かめ、必須のチェックが無ければ確かめない" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset
  workflow ci.yml merge_group lint-result
  workflow org.yml pull_request org-check
  run_setup --merge-queue --dry-run
  assert_success
  assert_equal "$(jq -c .merge_queue.merge_group <<<"$json")" null
  # 組織のルールセット（id 99）の必須のチェック。このルールセット（id 7）の古い一覧は、置き換えるので見ない
  echo '[{"type": "required_status_checks", "ruleset_id": 99, "parameters": {"required_status_checks": [{"context": "org-check"}]}},
    {"type": "required_status_checks", "ruleset_id": 7, "parameters": {"required_status_checks": [{"context": "old"}]}}]' >"$FIX/branch-rules.json"
  run_setup --merge-queue --required-check lint-result --dry-run
  assert_success
  assert_equal "$(jq -c .merge_queue.merge_group <<<"$json")" \
    '{"not_running":[{"check":"org-check","workflows":[".github/workflows/org.yml"],"reason":"on"}],"unknown":[]}'
}

@test "古いブランチ保護が求める必須のチェックも確かめる" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset
  workflow ci.yml merge_group lint-result
  workflow legacy.yml pull_request legacy-check
  mkdir -p "$FIX/branches"
  echo '{"name": "main", "protection": {"enabled": true, "required_status_checks": {"contexts": ["legacy-check"]}}}' >"$FIX/branches/main"
  run_setup --merge-queue --required-check lint-result --dry-run
  assert_success
  assert_equal "$(jq -c .merge_queue.merge_group <<<"$json")" \
    '{"not_running":[{"check":"legacy-check","workflows":[".github/workflows/legacy.yml"],"reason":"on"}],"unknown":[]}'
}

@test "ワークフローを読めなくても、キューを使うときは警告して設定は続ける" {
  setup_fake_gh
  settled_repo
  owned_by Organization public
  existing_ruleset
  export FAKE_WORKFLOWS_FAIL=1
  run_setup --merge-queue --required-check lint-result
  assert_success
  assert_output --partial "必須のチェックのワークフローが merge_group のイベントで動くか確かめられません: GitHub の API に失敗しました: gh: Forbidden (HTTP 403)"
  assert_equal "$(jq -c .merge_queue.merge_group <<<"$json")" null
  assert_equal "$(called PUT)" 1
}

@test "ホームのリポジトリでは、ユーザーの層の base_branch を、守るブランチを決めるチームの設定として読まない" {
  setup_fake_gh
  make_home_repo
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  run_setup
  assert_success
  assert_equal "$(body POST | jq -c .conditions.ref_name.include)" '["refs/heads/main"]'
}

@test "--required-check の名前に絵文字があっても（4096 バイトを超えても）壊さずに、ルールセットとその結果に出す" {
  # 標準入力の jq -R -s は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  setup_fake_gh
  name="$(emoji_text 1500)"
  run_setup --required-check "$name" --required-check lint-result
  assert_success
  rule="$(body POST | jq -c '.rules[] | select(.type == "required_status_checks")')"
  assert_equal "$(jq -r '.parameters.required_status_checks[].context' <<<"$rule" | head -n 1)" "$name"
  assert_equal "$(jq -r '.ruleset.required_checks[0]' <<<"$json")" "$name"
}
