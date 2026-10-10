#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。gh api -X POST repos/me/demo/issues は $FIX/issue.json を返し、「CreateIssue <本文>」を $CALLS に記録する。
# gh api repos/me/demo/issues/<番号> は $FIX/issue-<番号>.json を返し（無ければ 404）、「GetIssue <番号>」を記録する。
# gh api repos/<所有者>/<名前>/issues/<番号>/parent は $FIX/parent-<番号>.json を返し（無ければ 404）、「GetParent <番号>」を記録する。
# gh api -X POST .../issues/<番号>/dependencies/blocked_by は「AddBlockedBy {"issue": <番号>, "issue_id": <id>}」を記録する。
# gh api -X POST .../issues/<番号>/sub_issues は「AddSubIssue {"issue": <番号>, "sub_issue_id": <id>}」を記録する。
# gh api repos/me/demo/labels/<名前> は、$FIX/labels に名前の行があればそのラベルを返し、無ければ 404 にする。
# gh api graphql は「GraphQL」を記録して失敗する（使わないはずなので）。
# gh project と Project の REST は fake_gh_project.bash が受け持つ（ProjectView・ProjectFields・AddItem・SetField）。
# FAKE_FAIL に指定した操作名は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$FAKE_GH_PROJECT"
fake_gh_project "$@"
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
case "$1 $2" in
  "repo view") echo '{"nameWithOwner": "me/demo"}' | jq -r "$q" ;;
  # issue-create.sh（と中で呼ぶ status-set.sh）は GraphQL を使わない。呼ばれたら記録して失敗する
  "api graphql") echo "GraphQL {}" >>"$CALLS"; echo 'gh: unexpected graphql' >&2; exit 1 ;;
  "api repos/me/demo/labels/"*)
    name="${2##*/labels/}"
    if [ "${FAKE_FAIL:-}" = Label ]; then echo 'gh: Server Error (HTTP 500)' >&2; exit 1; fi
    grep -qxF "$name" "$FIX/labels" 2>/dev/null || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    jq -n --arg n "$name" '{name: $n}'
    ;;
  "api repos/"*/issues/*/parent)
    n="${2%/parent}"
    n="${n##*/}"
    echo "GetParent $n" >>"$CALLS"
    fail GetParent
    [ -f "$FIX/parent-$n.json" ] || { echo 'gh: No parent issue found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/parent-$n.json"
    ;;
  "api repos/me/demo/issues/"*)
    n="${2##*/}"
    echo "GetIssue $n" >>"$CALLS"
    fail GetIssue
    [ -f "$FIX/issue-$n.json" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/issue-$n.json"
    ;;
  "api -X")
    case "$4" in
      */dependencies/blocked_by)
        n="${4%/dependencies/blocked_by}"
        echo "AddBlockedBy $(jq -nc --argjson i "${n##*/}" --argjson b "${6#issue_id=}" '{issue: $i, issue_id: $b}')" >>"$CALLS"
        fail AddBlockedBy
        echo '{}'
        ;;
      */sub_issues)
        n="${4%/sub_issues}"
        echo "AddSubIssue $(jq -nc --argjson i "${n##*/}" --argjson s "${6#sub_issue_id=}" '{issue: $i, sub_issue_id: $s}')" >>"$CALLS"
        fail AddSubIssue
        echo '{}'
        ;;
      *)
        echo "CreateIssue $(jq -c .)" >>"$CALLS"
        if [ "${FAKE_FAIL:-}" = CreateIssue ]; then echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1; fi
        cat "$FIX/issue.json"
        ;;
    esac
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  echo '{"project": {"owner": "me", "number": 4}}' >.claude/dev-workflow/config.json
  echo '{"id": "P4", "number": 4, "url": "https://github.com/users/me/projects/4", "owner": {"login": "me", "type": "User"}}' \
    >"$FIX/ProjectView.json"
  project_fields '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}]' number
  created_issue feat
  echo '{"id": "IT30"}' >"$FIX/AddItem.json"
}

# 作った Issue として返す応答。使い方: created_issue <付いたラベル>...
created_issue() {
  jq -n --args '{number: 30, id: 1030, html_url: "https://github.com/me/demo/issues/30", node_id: "I30",
    labels: ($ARGS.positional | map({name: .}))}' "$@" >"$FIX/issue.json"
}

# Project の項目の一覧（REST）。使い方: project_items <所有者/名前>:<番号>:<Story Point（空なら null）>...
project_items() {
  jq -n --args '$ARGS.positional | map(split(":") | {node_id: "IT\(.[1])",
    content: {number: (.[1] | tonumber), repository_url: "https://api.github.com/repos/\(.[0])"},
    fields: [{id: 2, name: "Story Point", data_type: "number", value: (if .[2] == "" then null else (.[2] | tonumber) end)}]})' \
    "$@" >"$FIX/ProjectItems.json"
}

# 既にある Issue（依存先や親）。REST の id は 1000 + 番号にする。使い方: existing_issue <番号>...
existing_issue() {
  local n
  for n in "$@"; do
    issue_json me/demo "$n" >"$FIX/issue-$n.json"
  done
}

# REST の Issue の応答。使い方: issue_json <所有者/名前> <番号>
issue_json() {
  jq -n --arg r "$1" --argjson n "$2" \
    '{id: (1000 + $n), node_id: "I\($n)", number: $n, url: "https://api.github.com/repos/\($r)/issues/\($n)"}'
}

# <子> の親を <親> にする（親は同じリポジトリ。別のリポジトリなら <所有者/名前> も渡す）。
# 使い方: set_parent <子> <親> [所有者/名前]
set_parent() {
  issue_json "${3:-me/demo}" "$2" >"$FIX/parent-$1.json"
}

# REST の項目の一覧（id は数値、node_id が gh project で使う id）。
# 使い方: project_fields <Status の選択肢> <Story Point の項目の data_type（無ければ none）>
project_fields() {
  jq -n --argjson opts "$1" --arg sp "$2" '
    [{id: 1, node_id: "F1", name: "Status", data_type: "single_select", options: ($opts | map({id, name: {raw: .name}}))}]
    + (if $sp == "none" then [] else [{id: 2, node_id: "F2", name: "Story Point", data_type: $sp, options: null}] end)' \
    >"$FIX/ProjectFields.json"
}

run_create() {
  run "${TEST_BASH:-bash}" "$SCRIPTS/issue-create.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: args <操作名> [何回目か] → 記録した変数または本文の JSON
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }

# 変更を伴う呼び出しが1つも無いことを確かめる。あれば記録を表示して失敗する
assert_no_changes() {
  if grep -qE '^(CreateIssue|AddItem|SetField|AddBlockedBy|AddSubIssue) ' "$CALLS"; then
    fail "$(printf '呼ばれないはずの操作が呼ばれました:\n%s' "$(cat "$CALLS")")"
  fi
}

@test "Issue を作り、type ラベルを付け、Project に追加して Todo にする" {
  setup_fake_gh
  printf '## 背景\n説明\n' >body.md
  run_create --title "ログインを追加する" --type feat --body-file body.md
  assert_success
  assert_equal "$(args CreateIssue)" '{"title":"ログインを追加する","body":"## 背景\n説明","labels":["feat"]}'
  assert_equal "$(args AddItem)" '{"_":["4"],"owner":"me","url":"https://github.com/me/demo/issues/30","format":"json"}'
  assert_equal "$(called SetField)" 1
  assert_equal "$(args SetField | jq -c '[."project-id", .id, ."field-id", ."single-select-option-id"]')" '["P4","IT30","F1","O1"]'
  assert_equal "$(jq -c '[.number, .url, .project.status, .project.story_point]' <<<"$json")" \
    '[30,"https://github.com/me/demo/issues/30","Todo",null]'
}

@test "Status は status-set.sh を通して設定し、項目を読み直す GraphQL は呼ばない" {
  setup_fake_gh
  run_create --title t --type feat
  assert_success
  # Project は、作る前の確認と status-set.sh とで2回読む
  assert_equal "$(called ProjectView)" 2
  assert_equal "$(called GraphQL)" 0
  assert_equal "$(called AddItem)" 1
  assert_equal "$(jq -c '[.project.item_id, .project.status]' <<<"$json")" '["IT30","Todo"]'
}

@test "--breaking なら、type ラベルとは別に breaking ラベルも付ける" {
  setup_fake_gh
  echo breaking >"$FIX/labels"
  created_issue feat breaking
  run_create --title t --type feat --breaking
  assert_success
  assert_equal "$(args CreateIssue | jq -c .labels)" '["feat","breaking"]'
  assert_equal "$(jq -c '[.type, .breaking]' <<<"$json")" '["feat",true]'
}

@test "--breaking で、リポジトリの Breaking のような大文字のラベルが付いても成功する" {
  setup_fake_gh
  echo breaking >"$FIX/labels"
  created_issue feat Breaking
  run_create --title t --type feat --breaking
  assert_success
  assert_equal "$(jq -r .breaking <<<"$json")" true
}

@test "--breaking を付けなければ、breaking ラベルを付けない" {
  setup_fake_gh
  run_create --title t --type feat
  assert_success
  assert_equal "$(args CreateIssue | jq -c .labels)" '["feat"]'
  assert_equal "$(jq -r .breaking <<<"$json")" false
}

@test "--breaking でリポジトリに breaking ラベルが無ければ、何も作らずに setup-labels.sh を案内する" {
  setup_fake_gh
  run_create --title t --type feat --breaking
  assert_failure 2
  assert_output --partial "me/demo に breaking ラベルがありません（setup-labels.sh を実行して作ってください。.claude/dev-workflow/labels.json を使っていれば、先にそこへ breaking を足してください）"
  assert_no_changes
}

@test "--breaking で breaking ラベルを 404 以外の理由で確かめられなければ、何も作らずに止まる" {
  setup_fake_gh
  FAKE_FAIL=Label run_create --title t --type feat --breaking
  assert_failure
  assert_output --partial "breaking ラベルを確かめられませんでした: gh: Server Error (HTTP 500)"
  assert_no_changes
}

@test "--breaking で breaking ラベルが付かなければ、作った Issue の番号を伝えて止まる" {
  setup_fake_gh
  echo breaking >"$FIX/labels"
  run_create --title t --type feat --breaking
  assert_failure
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、breaking ラベルを付けられませんでした"
}

@test "本文は標準入力からも渡せる" {
  setup_fake_gh
  created_issue fix
  run_create --title t --type fix --body-file - <<<"本文"
  assert_success
  assert_equal "$(args CreateIssue | jq -r .body)" "本文"
}

@test "Story Point を指定すると、数値の項目に設定する" {
  setup_fake_gh
  run_create --title t --type feat --story-point 5
  assert_success
  assert_equal "$(called SetField)" 2
  assert_equal "$(args SetField 2 | jq -c '[."field-id", .number]')" '["F2","5"]'
  assert_equal "$(jq -r .project.story_point <<<"$json")" 5
}

@test "Story Point が整数でなければ、何も作らずに止まる" {
  setup_fake_gh
  for v in abc 0.5; do
    run_create --title t --type feat --story-point "$v"
    assert_failure 64
    assert_output --partial "--story-point には整数を指定してください: $v"
  done
  assert_no_changes
}

@test "Story Point の 21 と 34 は設定できるが、分割を勧める警告を出す" {
  setup_fake_gh
  for v in 21 34; do
    run_create --title t --type feat --story-point "$v"
    assert_success
    assert_output --partial "Story Point ${v} は大きいので、Issue を分割できないか検討してください"
    assert_equal "$(jq -r .project.story_point <<<"$json")" "$v"
  done
}

@test "Story Point の 13 以下では警告しない" {
  setup_fake_gh
  run_create --title t --type feat --story-point 13
  assert_success
  refute_output --partial "分割"
}

@test "type ラベルが付かなかったら（書き込み権限が無い）、Project に追加せずに伝える" {
  setup_fake_gh
  created_issue
  run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、type ラベル「feat」を付けられませんでした"
  assert_equal "$(called AddItem)" 0
}

@test "type が labels.types に無ければ、何も作らずに止まる" {
  setup_fake_gh
  run_create --title t --type feature
  assert_failure 64
  assert_output --partial "type は labels.types のどれかにしてください"
  assert_no_changes
}

@test "Story Point がフィボナッチ数でない、または 34 より大きければ、何も作らずに止まる" {
  setup_fake_gh
  for v in 4 0 55; do
    run_create --title t --type feat --story-point "$v"
    assert_failure 64
    assert_output --partial "Story Point は 1 / 2 / 3 / 5 / 8 / 13 / 21 / 34 のどれかにしてください: $v"
  done
  assert_no_changes
}

@test "Project に Story Point の項目が無いのに指定されたら、何も作らずに止まる" {
  setup_fake_gh
  project_fields '[{"id": "O1", "name": "Todo"}]' none
  run_create --title t --type feat --story-point 3
  assert_failure 1
  assert_output --partial "Story Point の項目「Story Point」がありません"
  assert_no_changes
}

@test "Project の Story Point の項目が数値でなければ、何も作らずに止まる" {
  setup_fake_gh
  project_fields '[{"id": "O1", "name": "Todo"}]' text
  run_create --title t --type feat --story-point 3
  assert_failure 1
  assert_output --partial "項目「Story Point」が数値ではありません"
  assert_no_changes
}

@test "組織の Project は、REST の orgs の項目の一覧を読む" {
  setup_fake_gh
  echo '{"id": "P4", "number": 4, "url": "u", "owner": {"login": "me", "type": "Organization"}}' >"$FIX/ProjectView.json"
  run_create --title t --type feat --story-point 3
  assert_success
  assert_equal "$(args ProjectFields | jq -r .path)" "orgs/me/projectsV2/4/fields?per_page=100"
}

@test "todo の列が Status 列に無ければ、何も作らずに止まる" {
  setup_fake_gh
  echo '{"project": {"owner": "me", "number": 4}, "status": {"todo": "Backlog"}}' >.claude/dev-workflow/config.json
  run_create --title t --type feat
  assert_failure 1
  assert_output --partial "todo の列「Backlog」が Status 列にありません"
  assert_no_changes
}

@test "Project が見つからなければ（gh は Could not resolve のエラーを返す）、何も作らずに止まる" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="GraphQL: Could not resolve to a ProjectV2 with the number 4. (user.projectV2)" \
    run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/4"
  assert_no_changes
}

@test "Project を読めない（スコープ不足など）ときは、見つからないとは言わずに GitHub の理由を伝える" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="GraphQL: Your token has not been granted the required scopes (INSUFFICIENT_SCOPES)" \
    run_create --title t --type feat
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: GraphQL: Your token has not been granted the required scopes"
  refute_output --partial "見つかりません"
  assert_no_changes
}

@test "project.number が未設定なら、Issue だけ作って警告する" {
  setup_fake_gh
  echo '{}' >.claude/dev-workflow/config.json
  created_issue docs
  run_create --title t --type docs
  assert_success
  assert_output --partial "project.number が未設定なので"
  assert_equal "$(called CreateIssue)" 1
  assert_equal "$(called ProjectView)" 0
  assert_equal "$(called AddItem)" 0
  assert_equal "$(jq -c .project <<<"$json")" null
}

@test "--blocked-by を指定すると、起票の後に依存関係（blocked by）を登録する" {
  setup_fake_gh
  existing_issue 12 15
  run_create --title t --type feat --blocked-by 12 --blocked-by 15
  assert_success
  assert_equal "$(called AddBlockedBy)" 2
  assert_equal "$(args AddBlockedBy 1)" '{"issue":30,"issue_id":1012}'
  assert_equal "$(args AddBlockedBy 2)" '{"issue":30,"issue_id":1015}'
  assert_equal "$(jq -c .blocked_by <<<"$json")" '[12,15]'
}

@test "--blocked-by が無ければ、依存関係を登録せず blocked_by は空" {
  setup_fake_gh
  run_create --title t --type feat
  assert_success
  assert_equal "$(called GetIssue)" 0
  assert_equal "$(called AddBlockedBy)" 0
  assert_equal "$(jq -c .blocked_by <<<"$json")" '[]'
}

@test "--blocked-by の番号は # を付けても、重複しても、先頭が 0 でもよい" {
  setup_fake_gh
  existing_issue 12
  run_create --title t --type feat --blocked-by '#12' --blocked-by 012 --blocked-by 12
  assert_success
  assert_equal "$(called AddBlockedBy)" 1
  assert_equal "$(jq -c .blocked_by <<<"$json")" '[12]'
}

@test "--blocked-by の Issue が無ければ、何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  run_create --title t --type feat --blocked-by 12 --blocked-by 99
  assert_failure 1
  assert_output --partial "依存する Issue #99 がありません"
  assert_no_changes
}

@test "--blocked-by に PR の番号を指定したら、Issue が無いとみなして何も作らずに止まる" {
  setup_fake_gh
  jq -n '{id: 1013, number: 13, pull_request: {url: "u"}}' >"$FIX/issue-13.json"
  run_create --title t --type feat --blocked-by 13
  assert_failure 1
  assert_output --partial "依存する Issue #13 がありません"
  assert_no_changes
}

@test "--blocked-by の Issue を 404 以外の理由で確かめられなければ、GitHub の理由を伝えて何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  FAKE_FAIL=GetIssue FAKE_FAIL_MSG="gh: Server Error (HTTP 500)" run_create --title t --type feat --blocked-by 12
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: gh: Server Error (HTTP 500)"
  refute_output --partial "がありません"
  assert_no_changes
}

@test "--blocked-by が正の整数でなければ、何も作らずに止まる" {
  setup_fake_gh
  for v in abc 0 1.5 '#'; do
    run_create --title t --type feat --blocked-by "$v"
    assert_failure 64
    assert_output --partial "--blocked-by には Issue の番号を指定してください: $v"
  done
  assert_equal "$(called GetIssue)" 0
  assert_no_changes
}

@test "--parent を指定すると、起票した Issue を親のサブ Issue にする" {
  setup_fake_gh
  existing_issue 12
  run_create --title t --type feat --parent '#12'
  assert_success
  assert_equal "$(called AddSubIssue)" 1
  assert_equal "$(args AddSubIssue)" '{"issue":12,"sub_issue_id":1030}'
  assert_equal "$(jq -c .parent <<<"$json")" '{"number":12,"depth":2,"story_point_cleared":null}'
}

@test "--parent の親の Project の項目は、リポジトリの綴りの大文字小文字が違っても同じリポジトリのものとして見つける" {
  setup_fake_gh
  existing_issue 12
  project_items Other/Repo:12:3 Me/Demo:12:8
  run_create --title t --type feat --parent 12 --story-point 3
  assert_success
  assert_equal "$(jq -c .parent <<<"$json")" '{"number":12,"depth":2,"story_point_cleared":8}'
}

@test "--parent の親の Project の項目に repository_url が無いものがあっても、飛ばして親の項目を見つける" {
  setup_fake_gh
  existing_issue 12
  project_items me/demo:12:8
  jq '[{node_id: "ITX", content: {number: 12}, fields: []}] + .' "$FIX/ProjectItems.json" >"$FIX/p" && mv "$FIX/p" "$FIX/ProjectItems.json"
  run_create --title t --type feat --parent 12 --story-point 3
  assert_success
  assert_equal "$(jq -c .parent <<<"$json")" '{"number":12,"depth":2,"story_point_cleared":8}'
}

@test "--parent の親に Story Point が入っていれば、子を足した後に空欄にする" {
  setup_fake_gh
  existing_issue 12
  # 別のリポジトリの同じ番号の Issue は親ではない
  project_items other/repo:12:3 me/demo:12:8 me/demo:13:5
  run_create --title t --type feat --parent 12 --story-point 3
  assert_success
  # 項目の一覧は、リポジトリと Issue で絞り、Story Point の項目の値だけを読む
  assert_equal "$(args ProjectItems)" '{"path":"users/me/projectsV2/4/items","f":["q=repo:me/demo is:issue","per_page=100","fields=2"]}'
  # Status・子の Story Point・親の Story Point の順に設定する
  assert_equal "$(called SetField)" 3
  assert_equal "$(args SetField 3 | jq -c '[.id, ."field-id", has("clear")]')" '["IT12","F2",true]'
  assert_equal "$(jq -c .parent <<<"$json")" '{"number":12,"depth":2,"story_point_cleared":8}'
}

@test "--parent の親の Story Point が空欄か、親が Project に無ければ、親の Story Point には触れない" {
  setup_fake_gh
  existing_issue 12
  project_items me/demo:12:
  run_create --title t --type feat --parent 12
  assert_success
  assert_equal "$(called SetField)" 1
  assert_equal "$(jq -c .parent.story_point_cleared <<<"$json")" null

  : >"$CALLS"
  project_items me/demo:13:5
  run_create --title t --type feat --parent 12
  assert_success
  assert_equal "$(called SetField)" 1
}

@test "--parent で Project が未設定、または Story Point の項目が無ければ、項目の一覧を読まない" {
  setup_fake_gh
  existing_issue 12
  project_fields '[{"id": "O1", "name": "Todo"}]' none
  run_create --title t --type feat --parent 12
  assert_success
  assert_equal "$(called ProjectItems)" 0

  echo '{}' >.claude/dev-workflow/config.json
  created_issue feat
  run_create --title t --type feat --parent 12
  assert_success
  assert_equal "$(called ProjectItems)" 0
  assert_equal "$(called AddSubIssue)" 2
}

@test "--parent の親の Story Point を読めなければ、何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  FAKE_FAIL=ProjectItems run_create --title t --type feat --parent 12
  assert_failure 1
  assert_output --partial "親の Issue #12 の Story Point を読めませんでした"
  assert_no_changes
}

@test "--parent の親の Story Point を空欄にできなければ、作った Issue の番号を伝える" {
  setup_fake_gh
  existing_issue 12
  project_items me/demo:12:8
  # 1回目（Status）は通し、2回目（親の Story Point）で失敗させる
  FAKE_FAIL=SetField.2 run_create --title t --type feat --parent 12
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、#12 のサブ Issue にした後、親の Story Point 8 を空欄にできませんでした"
}

@test "--parent が無ければ、サブ Issue にせず parent は null" {
  setup_fake_gh
  run_create --title t --type feat
  assert_success
  assert_equal "$(called GetParent)" 0
  assert_equal "$(called AddSubIssue)" 0
  assert_equal "$(jq -c .parent <<<"$json")" null
}

@test "--parent で 2 層目になるときは警告しない" {
  setup_fake_gh
  existing_issue 12
  run_create --title t --type feat --parent 12
  assert_success
  refute_output --partial "層目になります"
}

@test "既定の上限 3 層では、3 層目は警告して作り、4 層目は何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  set_parent 12 5
  run_create --title t --type feat --parent 12
  assert_success
  assert_output --partial "warn: #12 の子にすると 3 層目になります（目安は 2 層まで）"
  assert_equal "$(args AddSubIssue)" '{"issue":12,"sub_issue_id":1030}'
  assert_equal "$(jq -c .parent.depth <<<"$json")" 3

  # 親の親は別のリポジトリにあってもたどる
  : >"$CALLS"
  set_parent 5 2 other/repo
  run_create --title t --type feat --parent 12
  assert_failure 2
  assert_output --partial "#12 の子にすると、親子の深さが上限の 3 層を超えます（sub_issues.max_depth）"
  assert_equal "$(args GetParent 2)" 5
  assert_no_changes
}

@test "sub_issues.max_depth を 2 にすると、3 層目になる指定は何も作らずに止まる" {
  setup_fake_gh
  echo '{"project": {"owner": "me", "number": 4}, "sub_issues": {"max_depth": 2}}' >.claude/dev-workflow/config.json
  existing_issue 12
  set_parent 12 5
  run_create --title t --type feat --parent 12
  assert_failure 2
  assert_output --partial "#12 の子にすると、親子の深さが上限の 2 層を超えます（sub_issues.max_depth）"
  assert_no_changes
}

@test "親子の深さを数えるとき、上限を超えると分かったらそれより上はたどらない" {
  setup_fake_gh
  existing_issue 12
  set_parent 12 5
  set_parent 5 2
  set_parent 2 1
  run_create --title t --type feat --parent 12
  assert_failure 2
  assert_equal "$(called GetParent)" 2
}

@test "sub_issues.max_depth が 1・2・3 のどれでもなければ、何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  for v in 0 4 '"2"' null; do
    echo "{\"project\": {\"owner\": \"me\", \"number\": 4}, \"sub_issues\": {\"max_depth\": $v}}" >.claude/dev-workflow/config.json
    run_create --title t --type feat --parent 12
    assert_failure 2
    assert_output --partial "sub_issues.max_depth は 1・2・3 のどれかにしてください"
  done
  assert_no_changes
}

@test "--parent の Issue が無い、または PR の番号なら、何も作らずに止まる" {
  setup_fake_gh
  jq -n '{id: 1013, number: 13, pull_request: {url: "u"}}' >"$FIX/issue-13.json"
  for n in 99 13; do
    run_create --title t --type feat --parent "$n"
    assert_failure 1
    assert_output --partial "親にする Issue #${n} がありません（me/demo）"
  done
  assert_no_changes
}

@test "--parent の親を 404 以外の理由でたどれなければ、GitHub の理由を伝えて何も作らずに止まる" {
  setup_fake_gh
  existing_issue 12
  FAKE_FAIL=GetParent FAKE_FAIL_MSG="gh: Server Error (HTTP 500)" run_create --title t --type feat --parent 12
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: gh: Server Error (HTTP 500)"
  assert_no_changes
}

@test "--parent が正の整数でなければ、何も作らずに止まる" {
  setup_fake_gh
  for v in abc 0 '#'; do
    run_create --title t --type feat --parent "$v"
    assert_failure 64
    assert_output --partial "--parent には Issue の番号を指定してください: $v"
  done
  assert_equal "$(called GetIssue)" 0
  assert_no_changes
}

@test "サブ Issue にできなければ、作った Issue の番号を伝える" {
  setup_fake_gh
  existing_issue 12
  FAKE_FAIL=AddSubIssue run_create --title t --type feat --parent 12
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、#12 のサブ Issue にできませんでした"
}

@test "依存関係を登録できなければ、作った Issue の番号を伝える" {
  setup_fake_gh
  existing_issue 12
  FAKE_FAIL=AddBlockedBy run_create --title t --type feat --blocked-by 12
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、#12 への依存（blocked by）を登録できませんでした"
}

@test "Issue を作った後に失敗したら、作った Issue の番号を伝える" {
  setup_fake_gh
  FAKE_FAIL=SetField run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、Status を「Todo」にできませんでした"
}

@test "Issue を作れなければ止まる" {
  setup_fake_gh
  FAKE_FAIL=CreateIssue run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue を作れませんでした"
  assert_equal "$(called AddItem)" 0
}

@test "--title と --type は必須" {
  setup_fake_gh
  run_create --type feat
  assert_failure 64
  assert_output --partial "--title は必須です"
  run_create --title t
  assert_failure 64
  assert_output --partial "--type は必須です"
}

@test "--help は使い方を表示する" {
  setup_fake_gh
  run_create --help
  assert_success
  assert_output --partial "--story-point"
  assert_output --partial "--blocked-by"
  assert_output --partial "--parent"
  refute_output --partial "set -euo"
}

@test "Project の自動追加と重なって「Content already exists」で失敗しても、再試行して続ける" {
  setup_fake_gh
  export DW_RETRY_SLEEP=0
  export FAKE_FAIL=AddItem.1
  export FAKE_FAIL_MSG='GraphQL: Content already exists in this project (addProjectV2ItemById)'
  run_create --title t --type feat
  assert_success
  assert_equal "$(called AddItem)" 2
  assert_equal "$(jq -c '[.project.item_id, .project.status]' <<<"$json")" '["IT30","Todo"]'
}

@test "「Content already exists」で再試行しても失敗し続けても、既存の項目を探して最後まで進める" {
  setup_fake_gh
  export DW_RETRY_SLEEP=0
  export FAKE_FAIL=AddItem
  export FAKE_FAIL_MSG='GraphQL: Content already exists in this project (addProjectV2ItemById)'
  existing_issue 12
  # 別のリポジトリの同じ番号の項目は、この Issue ではない
  project_items other/repo:30: me/demo:30:
  run_create --title t --type feat --story-point 3 --blocked-by 12
  assert_success
  assert_equal "$(called AddItem)" 3
  assert_equal "$(args ProjectItems)" '{"path":"users/me/projectsV2/4/items","f":["q=repo:me/demo is:issue","per_page=100"]}'
  assert_equal "$(jq -c '[.project.item_id, .project.status]' <<<"$json")" '["IT30","Todo"]'
  # Status と Story Point を設定し、依存関係も登録する
  assert_equal "$(called SetField)" 2
  assert_equal "$(called AddBlockedBy)" 1
}

@test "「Content already exists」で失敗し、既存の項目も見つからないときは止まる" {
  setup_fake_gh
  export DW_RETRY_SLEEP=0
  export FAKE_FAIL=AddItem
  export FAKE_FAIL_MSG='GraphQL: Content already exists in this project (addProjectV2ItemById)'
  project_items me/demo:99:
  run_create --title t --type feat
  assert_failure
  assert_output --partial "Project に追加できませんでした"
  assert_equal "$(called SetField)" 0
}

@test "Project への追加が別の理由で失敗したときは、再試行せずに止まる" {
  setup_fake_gh
  export DW_RETRY_SLEEP=0
  export FAKE_FAIL=AddItem
  run_create --title t --type feat
  assert_failure
  assert_equal "$(called AddItem)" 1
  assert_output --partial "Project に追加できませんでした"
}

@test "本文が長くても（引数の長さの上限を超える大きさでも）Issue を作れる" {
  setup_fake_gh
  # 日本語は UTF-8 で1文字3バイトなので、6万文字で 180KB ほどになる（Linux の引数1つの上限は 128KiB）
  { printf '## 背景\n'; head -c 60000 /dev/zero | tr '\0' x | sed 's/x/あ/g'; } >body.md
  run_create --title t --type feat --body-file body.md
  assert_success
  assert_equal "$(args CreateIssue | jq -r .body)" "$(cat body.md)"
}

@test "本文に絵文字があっても（4096 バイトを超える1行でも）壊さずに Issue を作れる" {
  # 標準入力の jq -Rs は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  setup_fake_gh
  { printf '## 背景\n'; emoji_text 3000; } >body.md
  run_create --title t --type feat --body-file body.md
  assert_success
  assert_equal "$(args CreateIssue | jq -r .body)" "$(cat body.md)"
}
