#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、export がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh を PATH の先頭に置く。FAKE_SCOPES でトークンのスコープを、FAKE_GH_VERSION で gh のバージョンを変えられる。
# gh repo view は me/demo を返し、FAKE_NO_REPO があれば失敗する（GitHub のリポジトリでないとき）。
# gh label list はリポジトリにある今のラベルとして FAKE_LABELS（既定: プラグインの定義のラベルすべて）を返す。
# gh api --paginate repos/{owner}/{repo}/rules/branches/<ブランチ> は、パスを FAKE_RULES_LOG のファイル（あれば）に書き、FAKE_RULES（ブランチに効いているルール。ページごとの配列を並べる）を返す。
# FAKE_RULES が無ければ失敗する（問い合わせられないとき）。
# gh api graphql は、マージキューの有無（repository.mergeQueue）として、FAKE_MERGE_QUEUE が true ならあり、false ならなし、無ければルールセットにキューがあるか（FAKE_RULES）で返す（FAKE_MERGE_QUEUE_FAIL があれば失敗する）。
# gh api repos/{owner}/{repo}/branches/<ブランチ> は FAKE_BRANCH（ブランチの情報。古いブランチ保護を含む）を返し、無ければ失敗する。
# base_branch のワークフロー（gh api repos/{owner}/{repo}/contents/.github/workflows?ref=...）は、$TMP/workflows/ の
# ファイルの一覧を返し、ディレクトリが無ければ 404、FAKE_WORKFLOWS_FAIL があれば 403 で失敗する。ファイル（gh api -H ... .../contents/<パス>?ref=...）はそのファイルを返す。
# ほかの呼び出しは失敗する。
fake_gh() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# --paginate は取り除き、ページをまとめて出力したものとして扱う
if [ "$1" = api ] && [ "$2" = --paginate ]; then shift 2; set -- api "$@"; fi
case "$1 $2" in
  "--version "*) echo "gh version ${FAKE_GH_VERSION:-2.96.0} (2026-07-02)" ;;
  "auth status") exit "${FAKE_AUTH_STATUS:-0}" ;;
  "api -i") printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: %s\r\n\r\n{}\n' "$FAKE_SCOPES" ;;
  "repo view")
    [ -z "${FAKE_NO_REPO:-}" ] || { echo "no git remotes found" >&2; exit 1; }
    echo me/demo
    ;;
  "label list") printf '%s\n' "$FAKE_LABELS" ;;
  "api repos/{owner}/{repo}/rules/branches/"*)
    [ -n "${FAKE_RULES:-}" ] || exit 1
    if [ -n "${FAKE_RULES_LOG:-}" ]; then printf '%s\n' "$2" >"$FAKE_RULES_LOG"; fi
    printf '%s\n' "$FAKE_RULES"
    ;;
  "api graphql")
    # マージキューの有無（repository.mergeQueue）。FAKE_MERGE_QUEUE_FAIL があれば失敗する。FAKE_MERGE_QUEUE が true ならキューがある
    # （古いブランチ保護のキューのように、ルールには出ない）。ブランチを FAKE_MQ_LOG のファイル（あれば）に書く
    [ -z "${FAKE_MERGE_QUEUE_FAIL:-}" ] || { echo 'gh: Resource not accessible (HTTP 403)' >&2; exit 1; }
    for a in "$@"; do case "$a" in branch=*) [ -z "${FAKE_MQ_LOG:-}" ] || printf '%s\n' "${a#branch=}" >"$FAKE_MQ_LOG" ;; esac; done
    # FAKE_MERGE_QUEUE が無ければ、ルールセットにキューがあるとき（FAKE_RULES に merge_queue）にだけ、キューがある
    mq="${FAKE_MERGE_QUEUE:-}"
    [ -n "$mq" ] || { case "${FAKE_RULES:-}" in *'"merge_queue"'*) mq=true ;; esac; }
    if [ "$mq" = true ]; then echo '{"data": {"repository": {"mergeQueue": {"id": "MQ_1"}}}}'
    else echo '{"data": {"repository": {"mergeQueue": null}}}'; fi
    ;;
  "api repos/{owner}/{repo}/branches/"*)
    [ -n "${FAKE_BRANCH:-}" ] || exit 1
    printf '%s\n' "$FAKE_BRANCH"
    ;;
  "api repos/{owner}/{repo}/contents/.github/workflows?"*)
    if [ -n "${FAKE_WORKFLOWS_FAIL:-}" ]; then echo 'gh: Forbidden (HTTP 403)' >&2; exit 1; fi
    [ -d "$FAKE_WORKFLOWS" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    for f in "$FAKE_WORKFLOWS"/*; do
      jq -n --arg n "$(basename "$f")" '{name: $n, path: (".github/workflows/" + $n), type: "file"}'
    done | jq -s .
    ;;
  "api -H")
    f="${4%%\?*}"
    cat "$FAKE_WORKFLOWS/$(basename "$f")"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" FAKE_WORKFLOWS="$TMP/workflows"
  FAKE_LABELS="$(cat "$SCRIPTS/../defaults/labels.json")"
  export FAKE_LABELS
}

# 使い方: labels_check → labels の確認の [ok, level, detail]。確認が無ければ空
labels_check() { jq -c '.checks[] | select(.name == "labels") | [.ok, .level, .detail]' <<<"$output"; }

@test "すべて揃っていれば ok で終了コード 0" {
  fake_gh
  export FAKE_SCOPES="repo, project, workflow"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r .ok <<<"$output")" true
}

@test "project スコープが無ければ ok=false で終了コード 1" {
  fake_gh
  export FAKE_SCOPES="repo, workflow"
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-project-scope") | .ok' <<<"$output")" false
}

@test "未ログインなら gh-auth が失敗する" {
  fake_gh
  export FAKE_AUTH_STATUS=1
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-auth") | .ok' <<<"$output")" false
}

@test "Project が未設定なのは警告にとどまる" {
  fake_gh
  export FAKE_SCOPES="project"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "project") | .level' <<<"$output")" warn
}

@test "旧キー pr_respond が設定に残っていれば、pr_check に改めるよう警告する（失敗にはしない）" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{"pr_respond": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "old-pr-respond-key") | [.ok, .level] | @tsv' <<<"$output")" $'false\twarn'
  assert_output --partial "pr_check に改めてください"
}

@test "旧キー pr_respond が個人の設定（config.local.json）にあっても警告する" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{"pr_respond": {"handlers": {}}}' >.claude/dev-workflow/config.local.json
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "old-pr-respond-key") | .ok' <<<"$output")" false
}

@test "pr_check を使っていれば、旧キーの警告は出ない" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{"pr_check": {"handlers": {}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "old-pr-respond-key")] | length' <<<"$output")" 0
}

@test "pr_check.handlers の担当の skill が .claude/skills/ にあれば、警告しない" {
  fake_gh
  export HOME="$TMP/home"
  export FAKE_SCOPES="project"
  mkdir -p .claude/skills/my-respond
  echo x >.claude/skills/my-respond/SKILL.md
  echo '{"pr_check": {"handlers": {"some-bot[bot]": "my-respond"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "pr-check-handlers")] | length' <<<"$output")" 0
}

@test "pr_check.handlers の担当の skill が ~/.claude/skills/ にあれば、警告しない" {
  fake_gh
  export FAKE_SCOPES="project"
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/skills/my-respond"
  echo x >"$HOME/.claude/skills/my-respond/SKILL.md"
  echo '{"pr_check": {"handlers": {"some-bot[bot]": "my-respond"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "pr-check-handlers")] | length' <<<"$output")" 0
}

@test "pr_check.handlers の担当の skill がどこにも無ければ、警告する（失敗にはしない）" {
  fake_gh
  export HOME="$TMP/home"
  export FAKE_SCOPES="project"
  echo '{"pr_check": {"handlers": {"some-bot[bot]": "my-respnd", "other[bot]": "my-respond"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "pr-check-handlers") | [.ok, .level] | @tsv' <<<"$output")" $'false\twarn'
  assert_output --partial "my-respnd、my-respond"
}

@test "pr_check.handlers がプラグインの skill（<プラグイン>:<名前>）なら、検査しない" {
  fake_gh
  export HOME="$TMP/home"
  export FAKE_SCOPES="project"
  echo '{"pr_check": {"handlers": {"some-bot[bot]": "other-plugin:respond"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "pr-check-handlers")] | length' <<<"$output")" 0
}

@test "pr_check.handlers の形が想定外（配列・文字列でない値）でも、doctor は成功し、pr-check-handlers を出さない" {
  fake_gh
  export FAKE_SCOPES="project"
  export HOME="$TMP/home"
  echo '{"pr_check": {"handlers": ["x"]}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "pr-check-handlers")] | length' <<<"$output")" 0
  echo '{"pr_check": {"handlers": {"some-bot[bot]": 123}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '[.checks[] | select(.name == "pr-check-handlers")] | length' <<<"$output")" 0
}

@test "pr_check.handlers の skill 名が安全でない（../x・a/b・.・..）ときは、その位置に SKILL.md があっても警告する" {
  fake_gh
  export FAKE_SCOPES="project"
  export HOME="$TMP/home"
  mkdir -p .claude/x .claude/skills/a/b
  echo x >.claude/x/SKILL.md
  echo x >.claude/skills/a/b/SKILL.md
  echo x >.claude/skills/SKILL.md
  echo '{"pr_check": {"handlers": {"a[bot]": "../x", "b[bot]": "a/b", "c[bot]": ".", "d[bot]": ".."}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "pr-check-handlers") | [.ok, .level] | @tsv' <<<"$output")" $'false\twarn'
  assert_output --partial "../x、a/b、.、.."
}

@test "HOME が未設定でも、pr_check.handlers の検査は落ちず、リポジトリの層だけで判断する" {
  fake_gh
  export FAKE_SCOPES="project"
  mkdir -p .claude/skills/my-respond
  echo x >.claude/skills/my-respond/SKILL.md
  echo '{"pr_check": {"handlers": {"a[bot]": "my-respond", "b[bot]": "nothing"}}}' >.claude/dev-workflow/config.json
  unset HOME
  run_script doctor.sh
  assert_success
  assert_output --partial "pr_check.handlers の担当の skill が見つかりません: nothing（"
}

@test "pr_check.handlers の「:」「a:」「:b」は、プラグインの skill として除かず、警告する" {
  fake_gh
  export FAKE_SCOPES="project"
  export HOME="$TMP/home"
  echo '{"pr_check": {"handlers": {"a[bot]": ":", "b[bot]": "a:", "c[bot]": ":b", "d[bot]": "p:ok"}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_output --partial "見つかりません: :、a:、:b（"
}

@test "pr_check.handlers の担当の skill が空文字なら、（空）として警告する" {
  fake_gh
  export FAKE_SCOPES="project"
  export HOME="$TMP/home"
  echo '{"pr_check": {"handlers": {"some-bot[bot]": ""}}}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "pr-check-handlers") | [.ok, .level] | @tsv' <<<"$output")" $'false\twarn'
  assert_output --partial "見つかりません: （空）（"
}

@test "設定が壊れていれば config が失敗する" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{broken' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "config") | .ok' <<<"$output")" false
  # 同じ誤りを、base_branch の誤りとして二重に知らせない
  assert_equal "$(jq -c '[.checks[] | select(.name == "base-branch")]' <<<"$output")" "[]"
}

@test "古い置き場所のファイルがあれば、止めずに移すよう促す" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{}' >.claude/workflow.json
  mkdir -p .claude/review "$TMP/workflow" "$TMP/review" "$TMP/wt-parent"
  touch .claude/review/mine.md "$TMP/workflow/commit.md" "$TMP/review/mine.md"
  echo '{}' >.claude/workflow.local.json
  git worktree add -q -b feat/1-x "$TMP/wt-parent/wt"
  cd "$TMP/wt-parent/wt"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "old-locations") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  detail="$(jq -r '.checks[] | select(.name == "old-locations") | .detail' <<<"$output")"
  assert_equal "$detail" "古い置き場所のファイルは使われません。移してください: $REPO/.claude/workflow.local.json → $REPO/.claude/dev-workflow/config.local.json、$TMP/workflow → $WORKFLOW_USER_DIR/、$TMP/review → $WORKFLOW_USER_DIR/review/"
  cd "$REPO"
  run_script doctor.sh
  assert_output --partial "$REPO/.claude/workflow.json → $REPO/.claude/dev-workflow/config.json、$REPO/.claude/review → $REPO/.claude/dev-workflow/review/、"
}

@test "個人の設定が git に無視されていなければ、.gitignore に足すよう促す" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '.claude/workflow.local.json' >.gitignore
  echo '{}' >.claude/workflow.local.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "local-ignored") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  assert_output --partial "個人の設定（.claude/dev-workflow/config.local.json）が git に無視されていません。.gitignore に足してください"
  # 移して .gitignore も直せば促さない
  mv .claude/workflow.local.json .claude/dev-workflow/config.local.json
  echo '.claude/dev-workflow/config.local.json' >.gitignore
  run_script doctor.sh
  assert_equal "$(jq '[.checks[] | select(.name == "local-ignored")] | length' <<<"$output")" 0
}

@test "コミット済みの個人の設定は、.gitignore に書いてあっても、追跡を外すよう促す" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{}' >.claude/dev-workflow/config.local.json
  git add .claude/dev-workflow/config.local.json
  git -c user.name=t -c user.email=t@example.com commit -q -m local
  # .gitignore に書いても、コミット済みのファイルは追跡が外れず、変更がコミットされ続ける
  echo '.claude/dev-workflow/config.local.json' >.gitignore
  run_script doctor.sh
  assert_equal "$(jq -c '.checks[] | select(.name == "local-ignored") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  assert_output --partial "がコミットされています。git rm --cached .claude/dev-workflow/config.local.json で追跡を外し"
  git rm -q --cached .claude/dev-workflow/config.local.json
  run_script doctor.sh
  assert_equal "$(jq '[.checks[] | select(.name == "local-ignored")] | length' <<<"$output")" 0
}

@test "古い置き場所に Markdown の無いディレクトリがあるだけなら、促さない" {
  fake_gh
  export FAKE_SCOPES="project"
  mkdir -p .claude/review "$TMP/workflow"
  touch "$TMP/workflow/other.txt"
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "old-locations") | .ok' <<<"$output")" true
}

@test "gh が古ければ、止めずに更新を促す" {
  fake_gh
  export FAKE_SCOPES="repo, project" FAKE_GH_VERSION=2.93.9
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "gh-version") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  assert_output --partial "gh 2.94.0 以上を使ってください（今は 2.93.9）。gh を更新してください"
}

@test "gh 2.94.0 ちょうどなら通る（サブ Issue を gh issue で扱える最初の版）" {
  fake_gh
  export FAKE_SCOPES="repo, project" FAKE_GH_VERSION=2.94.0
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-version") | .ok' <<<"$output")" true
}

@test "gh のバージョンは数字ごとに比べる（2.100.0 は 2.94.0 より新しい）" {
  fake_gh
  export FAKE_SCOPES="repo, project" FAKE_GH_VERSION=2.100.0
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-version") | .ok' <<<"$output")" true
  export FAKE_GH_VERSION=3.0
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-version") | .ok' <<<"$output")" true
}

@test "定義にあってリポジトリに無いラベルがあれば、止めずに名前と repo-setup を知らせる" {
  fake_gh
  export FAKE_SCOPES="project"
  FAKE_LABELS="$(jq -c 'map(select(.name != "breaking" and .name != "perf"))' "$SCRIPTS/../defaults/labels.json")"
  run_script doctor.sh
  assert_success
  assert_equal "$(labels_check)" '[false,"warn","ラベルの定義にあってリポジトリに無いラベルがあります: perf, breaking。/dev-workflow:repo-setup でラベルを登録してください"]'
}

@test "定義のラベルが揃っていれば、ラベルの警告は出ない" {
  fake_gh
  export FAKE_SCOPES="project"
  # 名前は大文字と小文字を区別せず、色・説明の違いや定義に無いラベルは問わない
  FAKE_LABELS="$(jq -c 'map(.name |= ascii_upcase | .color = "000000") + [{name: "bug", color: "ededed", description: ""}]' \
    "$SCRIPTS/../defaults/labels.json")"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.[0:2]' <<<"$(labels_check)")" '[true,"warn"]'
}

@test "リポジトリ独自のラベルの定義があれば、それと比べる" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '[{"name": "feat", "color": "0e8a16"}, {"name": "breaking", "color": "b60205"}, {"name": "spike", "color": "ffffff"}]' \
    >.claude/dev-workflow/labels.json
  run_script doctor.sh
  assert_output --partial "リポジトリに無いラベルがあります: spike。"
}

@test "リポジトリ独自のラベルの定義を読めなければ、止めずに知らせる" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '[{"name": "feat", "color": "0e8a16"}, {"name": "FEAT", "color": "0e8a16"}]' >.claude/dev-workflow/labels.json
  run_script doctor.sh
  assert_success
  assert_equal "$(labels_check)" '[false,"warn","ラベルの名前が重複しています: feat"]'
}

@test "GitHub に問い合わせられないときは、ラベルの確認を飛ばす" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_LABELS='[]'
  # 未ログイン
  export FAKE_AUTH_STATUS=1
  run_script doctor.sh
  assert_equal "$(labels_check)" ""
  # GitHub のリポジトリでない
  export FAKE_AUTH_STATUS=0 FAKE_NO_REPO=1
  run_script doctor.sh
  assert_success
  assert_equal "$(labels_check)" ""
  # リポジトリの外
  unset FAKE_NO_REPO
  cd "$TMP"
  run_script doctor.sh
  assert_equal "$(labels_check)" ""
}

# 使い方: merge_check → merge-queue の確認の [ok, level, detail]。確認が無ければ空
merge_check() { jq -c '.checks[] | select(.name == "merge-queue") | [.ok, .level, .detail]' <<<"$output"; }

@test "base_branch にマージキューと strict のどちらが効いているかを示す" {
  fake_gh
  export FAKE_SCOPES="project"
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "ci"}]}}, {"type": "merge_queue", "parameters": {}}]'
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_check)" '[true,"warn","main へのマージはマージキューを通します"]'
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "ci"}]}}]'
  run_script doctor.sh
  assert_equal "$(merge_check)" '[true,"warn","main へのマージは、PR が最新の main を取り込んでいることを求めます（strict）"]'
}

@test "古いブランチ保護でキューを有効にしていて、ルールセットにキューが無くても、マージキューを通すと示す（#381）" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_MERGE_QUEUE=true FAKE_MQ_LOG="$TMP/mq-branch"
  export FAKE_RULES='[{"type": "pull_request", "parameters": {}}]'
  export FAKE_BRANCH='{"protection": {"required_status_checks": {"contexts": ["ci"]}}}'
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_check)" '[true,"warn","main へのマージはマージキューを通します"]'
  assert_equal "$(cat "$TMP/mq-branch")" main
  # キューの有無を GraphQL で読めなければ、ルールセットのキューで代える
  export FAKE_MERGE_QUEUE_FAIL=1 FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "ci"}]}}, {"type": "merge_queue", "parameters": {}}]'
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_check)" '[true,"warn","main へのマージはマージキューを通します"]'
}

@test "必須のチェックがあるのにキューも strict も無ければ、止めずに repo-setup を知らせる" {
  fake_gh
  export FAKE_SCOPES="project"
  export FAKE_RULES='[{"type": "pull_request", "parameters": {}}, {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "ci"}]}}]'
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.[0:2]' <<<"$(merge_check)")" '[false,"warn"]'
  assert_output --partial "マージキューも最新の main の取り込み（strict）も求めていません"
}

# 使い方: required_check → required-checks の確認の [ok, level, detail]。確認が無ければ空
required_check() { jq -c '.checks[] | select(.name == "required-checks") | [.ok, .level, .detail]' <<<"$output"; }

@test "必須のチェックが無ければ、キューを使っていても、止めずに repo-setup で設定するよう知らせる" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES='[{"type": "pull_request", "parameters": {}}]'
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
  detail="$(jq -r '.[2]' <<<"$(required_check)")"
  [[ "$detail" == "main へのマージに必須のチェックがありません。"* ]]
  [[ "$detail" == *"/dev-workflow:repo-setup"* ]]
  [[ "$detail" == *'"require_status_checks": false'* ]]
  # 必須のチェックが無ければ、キューも strict も意味がないので知らせない
  assert_equal "$(merge_check)" ""
  # キューを使っていても、必須のチェックが無ければ知らせる
  export FAKE_RULES='[{"type": "pull_request", "parameters": {}}, {"type": "merge_queue", "parameters": {}}]'
  run_script doctor.sh
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
  # キューも必須のチェックが無ければ意味がないので、キューの案内は出さない
  assert_equal "$(merge_check)" ""
  # 必須のチェックのルールがあっても、名前が1つも無ければ何も求めていないので知らせる
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": []}}]'
  run_script doctor.sh
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
  # 名前が空のルールは、キューも strict も無いことは知らせない（必須のチェックが無いことだけを知らせる）
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": []}}]'
  run_script doctor.sh
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
  assert_equal "$(merge_check)" ""
  # 必須のチェックがあれば知らせない
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "ci"}]}}]'
  run_script doctor.sh
  assert_equal "$(required_check)" ""
}

@test "必須のチェックが古いブランチ保護（ルールセットでない）にあれば、警告しない" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES='[]'
  export FAKE_BRANCH='{"name": "main", "protected": true, "protection": {"enabled": true, "required_status_checks": {"enforcement_level": "non_admins", "contexts": ["ci"]}}}'
  run_script doctor.sh
  assert_success
  assert_equal "$(required_check)" ""
  # strict はブランチの情報から分からないので、キューと strict のことは知らせない
  assert_equal "$(merge_check)" ""
  # ルールセットに名前の無いルールがあっても、strict かは名前のあるルールだけで見る（名前の無いルールの strict は何も求めない）
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": []}}]'
  run_script doctor.sh
  assert_equal "$(required_check)" ""
  assert_equal "$(merge_check)" ""
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": []}}]'
  run_script doctor.sh
  assert_equal "$(merge_check)" ""
  # 古いブランチ保護に必須のチェックが無ければ警告する
  export FAKE_BRANCH='{"name": "main", "protected": true, "protection": {"enabled": true, "required_status_checks": {"enforcement_level": "off", "contexts": []}}}'
  run_script doctor.sh
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
}

@test "チームの設定で必須のチェックを求めないことにしていれば、警告しない" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES='[{"type": "pull_request", "parameters": {}}]'
  echo '{"require_status_checks": false}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_success
  assert_equal "$(required_check)" '[true,"warn","main へのマージに必須のチェックはありません（設定の require_status_checks が false）"]'
}

@test "必須のチェックを求めない設定は、個人の設定やユーザーの設定では効かない" {
  # ユーザーの層も読む、導入したリポジトリで確かめる
  mark_set_up
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES='[{"type": "pull_request", "parameters": {}}]'
  echo '{"require_status_checks": false}' >.claude/dev-workflow/config.local.json
  echo '{"require_status_checks": false}' >"$WORKFLOW_USER_DIR/config.json"
  run_script doctor.sh
  assert_equal "$(jq -c '.[0:2]' <<<"$(required_check)")" '[false,"warn"]'
}

@test "マージキューの確認は設定の base_branch を見る（/ を含む名前はエンコードする）" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES="$QUEUE_RULES" FAKE_RULES_LOG="$TMP/rules-path"
  echo '{"base_branch": "release/v1"}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_equal "$(cat "$TMP/rules-path")" 'repos/{owner}/{repo}/rules/branches/release%2Fv1?per_page=100'
  assert_output --partial "release/v1 へのマージはマージキューを通します"
}

@test "base_branch が使えない値なら、base-branch が失敗し、マージキューは問い合わせない" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES="$QUEUE_RULES" FAKE_RULES_LOG="$TMP/rules-path"
  echo '{"base_branch": "-v"}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -c '.checks[] | select(.name == "base-branch") | [.ok, .detail]' <<<"$output")" \
    '[false,"設定の base_branch が git のブランチ名として使えません: -v"]'
  [ ! -e "$TMP/rules-path" ]

  # 文字列でない値も、マージキューを問い合わせない（"1" という名前のブランチとして扱わない）
  echo '{"base_branch": 1}' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -c '.checks[] | select(.name == "base-branch") | [.ok, .detail]' <<<"$output")" \
    '[false,"設定の base_branch が文字列ではありません"]'
  [ ! -e "$TMP/rules-path" ]

  # 個人の層が使える値で上書きしていても、チームの設定の値が使えなければ知らせる（setup-repo.sh はその値で止まる）
  echo '{"base_branch": "-v"}' >.claude/dev-workflow/config.json
  echo '{"base_branch": "main"}' >.claude/dev-workflow/config.local.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -c '.checks[] | select(.name == "base-branch") | [.ok, .detail]' <<<"$output")" \
    '[false,"チームの設定: 設定の base_branch が git のブランチ名として使えません: -v"]'
  [ ! -e "$TMP/rules-path" ]

  # 個人の設定が壊れて config が失敗しても、チームの設定の値の誤りは知らせる
  echo '{broken' >.claude/dev-workflow/config.local.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -c '[.checks[] | select(.name == "config" or .name == "base-branch") | [.name, .ok]]' <<<"$output")" \
    '[["config",false],["base-branch",false]]'
}

@test "マージキューの確認は、個人の設定の base_branch ではなく、チームの設定のブランチを見る" {
  # ユーザーの層も読む、導入したリポジトリで確かめる
  mark_set_up
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES="$QUEUE_RULES" FAKE_RULES_LOG="$TMP/rules-path"
  echo '{"base_branch": "mine"}' >.claude/dev-workflow/config.local.json
  echo '{"base_branch": "user"}' >"$WORKFLOW_USER_DIR/config.json"
  run_script doctor.sh
  assert_equal "$(cat "$TMP/rules-path")" 'repos/{owner}/{repo}/rules/branches/main?per_page=100'
}

@test "マージキューの確認は、ルールの一覧を全ページまとめて見る" {
  fake_gh
  export FAKE_SCOPES="project"
  FAKE_RULES="$(printf '%s\n' '[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "ci"}]}}]' \
    '[{"type": "merge_queue", "parameters": {}}]')"
  export FAKE_RULES
  run_script doctor.sh
  assert_equal "$(merge_check)" '[true,"warn","main へのマージはマージキューを通します"]'
}

@test "GitHub に問い合わせられないときは、マージキューの確認を飛ばす" {
  fake_gh
  export FAKE_SCOPES="project"
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_check)" ""
}

# 使い方: merge_group_check → merge-group の確認の [ok, level, detail]。確認が無ければ空
merge_group_check() { jq -c '.checks[] | select(.name == "merge-group") | [.ok, .level, .detail]' <<<"$output"; }

# ワークフローを置く。使い方: workflow <ファイル名> <on: の値> <ジョブの ID>
workflow() {
  mkdir -p "$FAKE_WORKFLOWS"
  printf 'on: %s\njobs:\n  %s:\n    runs-on: ubuntu-latest\n' "$2" "$3" >"$FAKE_WORKFLOWS/$1"
}

# 必須のチェック（lint-result と test-result）とマージキューのルール
QUEUE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false,
  "required_status_checks": [{"context": "lint-result"}, {"context": "test-result"}]}}, {"type": "merge_queue", "parameters": {}}]'

@test "キューを使っていて、必須のチェックのワークフローが merge_group で動かなければ知らせる" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES="$QUEUE_RULES"
  workflow lint.yml "[pull_request, merge_group]" lint-result
  workflow test.yml pull_request test-result
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_group_check)" '[false,"warn","必須のチェックのうち test-result（.github/workflows/test.yml）は、merge_group のイベントで動きません。マージキューのチェックが「待ち」のまま残り、PR がマージされません。ワークフローの on: に merge_group を足してください"]'
}

@test "キューの必須のチェックのワークフローがどれも merge_group で動けば ok、ジョブが分からなければその名前を示す" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_RULES="$QUEUE_RULES"
  workflow lint.yml merge_group lint-result
  workflow test.yml merge_group test-result
  run_script doctor.sh
  assert_equal "$(merge_group_check)" '[true,"warn","必須のチェックのワークフローは、merge_group のイベントでも動きます"]'
  rm "$FAKE_WORKFLOWS/test.yml"
  run_script doctor.sh
  assert_equal "$(merge_group_check)" '[true,"warn","必須のチェック test-result は、main のどのワークフローのジョブか分からないので、merge_group のイベントで動くか確かめられません"]'
}

@test "キューを使っていない・必須のチェックが無い・ワークフローを読めないときは、merge_group を確かめない" {
  fake_gh
  export FAKE_SCOPES="project"
  workflow lint.yml pull_request lint-result
  export FAKE_RULES='[{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true,
    "required_status_checks": [{"context": "lint-result"}]}}]'
  run_script doctor.sh
  assert_equal "$(merge_group_check)" ""
  export FAKE_RULES='[{"type": "merge_queue", "parameters": {}}]'
  run_script doctor.sh
  assert_equal "$(merge_group_check)" ""
  # ワークフローの一覧を読めない
  export FAKE_RULES="$QUEUE_RULES" FAKE_WORKFLOWS_FAIL=1
  run_script doctor.sh
  assert_success
  assert_equal "$(merge_group_check)" ""
}

@test "導入していないリポジトリでは、フックやユーザーの層が効かないことを警告する" {
  run_script doctor.sh
  jq -e '.checks[] | select(.name == "set-up") | (.ok == false and .level == "warn" and (.detail | contains("/dev-workflow:repo-setup")))' <<<"$output" >/dev/null || fail "$output"
  mark_set_up
  run_script doctor.sh
  jq -e '.checks[] | select(.name == "set-up") | .ok' <<<"$output" >/dev/null || fail "$output"
}

@test "ホームのリポジトリでは、導入できないことを知らせ、repo-setup を案内しない" {
  make_home_repo
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  run_script doctor.sh
  jq -e '.checks[] | select(.name == "set-up") | (.ok == false and .level == "warn" and (.detail | contains("ホームのリポジトリ") and (contains("導入するリポジトリ"))))' <<<"$output" >/dev/null || fail "$output"
  jq -e '.checks[] | select(.name == "set-up") | (.detail | contains("導入できません"))' <<<"$output" >/dev/null || fail "$output"
  jq -e '[.checks[] | select(.name == "set-up")][0].detail | test("^ホームのリポジトリ")' <<<"$output" >/dev/null || fail "$output"
  # ユーザーの層の base_branch を、チームの設定として読まない
  jq -e '.checks[] | select(.name == "base-branch") | .detail == "main"' <<<"$output" >/dev/null || fail "$output"
}

@test "ホームのリポジトリでは、古い置き場所のファイルを、チームの設定の置き場所（ユーザーの層）へ移すよう案内しない" {
  make_home_repo
  echo '{}' >.claude/workflow.json
  echo '{}' >.claude/workflow.local.json
  run_script doctor.sh
  jq -e '.checks[] | select(.name == "old-locations") | .ok' <<<"$output" >/dev/null || fail "$output"
  jq -e '[.checks[] | select(.name == "local-ignored")] | length == 0' <<<"$output" >/dev/null || fail "$output"
}
