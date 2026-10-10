#!/usr/bin/env bats

load test_helper

@test "設定ファイルが無ければプラグインの既定値を返す" {
  run_script config.sh .status.start
  assert_success
  assert_output "In Progress"
}

@test "上位の層が決めていない項目には下位の層の値が効く" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"commit": {"scope_required": true}}' >.claude/dev-workflow/config.json
  run_script config.sh '[.language, .commit.scope_required, .commit.types[0]] | tojson'
  assert_success
  assert_output '["en",true,"feat"]'
}

@test "同じ項目はリポジトリの規約がユーザーの好みより優先される" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"language": "ja"}' >.claude/dev-workflow/config.json
  run_script config.sh .language
  assert_output "ja"
}

@test "個人の上書き（local）はリポジトリの規約より優先される" {
  echo '{"language": "ja"}' >.claude/dev-workflow/config.json
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  run_script config.sh .language
  assert_output "en"
}

@test "ワークツリーではメインのワークツリーの local を使う" {
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script config.sh .language
  assert_output "en"
}

@test "既にある PR テンプレートを検出し、リポジトリの規約で上書きできる" {
  mkdir -p .github
  touch .github/pull_request_template.md
  run_script config.sh .pr.template
  assert_output ".github/pull_request_template.md"

  echo '{"pr": {"template": "docs/pr.md"}}' >.claude/dev-workflow/config.json
  run_script config.sh .pr.template
  assert_output "docs/pr.md"
}

@test "commitlint の設定を検出する" {
  touch commitlint.config.js
  run_script config.sh .detected.commitlint
  assert_output "commitlint.config.js"
}

@test "ガイドはユーザー → リポジトリの順に並ぶ" {
  mark_set_up
  mkdir -p .claude/dev-workflow
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  echo repo >.claude/dev-workflow/commit.md
  run_script config.sh '.guides.commit[1]'
  assert_output "$REPO/.claude/dev-workflow/commit.md"
  run_script config.sh '.guides.commit[0]'
  assert_output "$WORKFLOW_USER_DIR/commit.md"
}

@test "明示的な null で既定値を消せる" {
  echo '{"status": {"done": null}}' >.claude/dev-workflow/config.json
  run_script config.sh .status.done
  assert_output "null"
}

@test "JSON として読めない設定はエラーになる" {
  echo '{broken' >.claude/dev-workflow/config.json
  run_script config.sh
  assert_failure 2
  assert_output --partial "JSON のオブジェクトとして読めません"
}

@test "オブジェクト以外の設定（配列・null・複数の値）はエラーになる" {
  mark_set_up
  for body in '[]' 'null' '{"a": 1}{"b": 2}'; do
    printf '%s\n' "$body" >"$WORKFLOW_USER_DIR/config.json"
    run_script config.sh
    assert_failure 2
    assert_output --partial "JSON のオブジェクトとして読めません"
  done
}

@test "WORKFLOW_REPO_ROOT を指定すると、今いる場所ではなくそのリポジトリの local を使う" {
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  mkdir -p "$TMP/other/.claude/dev-workflow"
  git -C "$TMP/other" init -q -b main
  echo '{"language": "fr"}' >"$TMP/other/.claude/dev-workflow/config.local.json"
  cd "$TMP/other"
  WORKFLOW_REPO_ROOT="$TMP/wt" run_script config.sh .language
  assert_output "en"
}

@test "テンプレートは大文字小文字を区別せずに検出し、実際のパスを返す" {
  mkdir -p docs .github/Issue_Template
  touch docs/PULL_REQUEST_TEMPLATE.md
  run_script config.sh '[.pr.template, .detected.issue_templates, .detected.pr_templates] | tojson'
  assert_success
  assert_output '["docs/PULL_REQUEST_TEMPLATE.md",".github/Issue_Template",null]'
}

@test "テンプレートのディレクトリの候補に、同じ名前のファイルは当てはめない" {
  mkdir -p .github
  touch .github/pull_request_template .github/ISSUE_TEMPLATE.md
  run_script config.sh '[.detected.pr_templates, .detected.issue_templates] | tojson'
  assert_output '[null,".github/ISSUE_TEMPLATE.md"]'
}

@test "テンプレートは拡張子を問わずに検出する（.txt・拡張子なし）" {
  mkdir -p .github docs
  touch .github/Pull_Request_Template.txt docs/ISSUE_TEMPLATE
  run_script config.sh '[.pr.template, .detected.issue_templates] | tojson'
  assert_output '[".github/Pull_Request_Template.txt","docs/ISSUE_TEMPLATE"]'
}

@test "拡張子を問わない候補でも、名前が前方一致するだけのファイルやディレクトリには当てはめない" {
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  touch .github/pull_request_template_old.md .github/PULL_REQUEST_TEMPLATE/a.md
  run_script config.sh '[.pr.template, .detected.pr_templates] | tojson'
  assert_output '[null,".github/PULL_REQUEST_TEMPLATE"]'
}

@test "拡張子が .md・.txt・なし以外のファイル（バックアップや .yml）はテンプレートとみなさない" {
  mkdir -p .github
  touch .github/pull_request_template.md~ .github/issue_template.yml
  run_script config.sh '[.pr.template, .detected.issue_templates] | tojson'
  assert_output '[null,null]'
}

@test "review.max_rounds の既定は 3 で、上位の層で上書きできる" {
  run_script config.sh .review.max_rounds
  assert_success
  assert_output "3"
  echo '{"review": {"max_rounds": 5}}' >.claude/dev-workflow/config.json
  run_script config.sh .review.max_rounds
  assert_success
  assert_output "5"
}

@test "review.max_rounds の既定は 1 以上の整数（review スキルが前提にしている）" {
  run_script config.sh '.review.max_rounds | (type == "number" and . >= 1 and . == floor)'
  assert_success
  assert_output "true"
}

@test "review.model の既定は null（セッションと同じモデル）で、上位の層で指定できる" {
  run_script config.sh .review.model
  assert_success
  assert_output "null"
  echo '{"review": {"model": "opus"}}' >.claude/dev-workflow/config.local.json
  run_script config.sh .review.model
  assert_success
  assert_output "opus"
}

@test "review.code_review_effort の既定は null（/code-review に段階を渡さない）で、上位の層で指定できる" {
  run_script config.sh .review.code_review_effort
  assert_success
  assert_output "null"
  echo '{"review": {"code_review_effort": "low"}}' >.claude/dev-workflow/config.local.json
  run_script config.sh .review.code_review_effort
  assert_success
  assert_output "low"
}

@test "導入していないリポジトリやリポジトリの外では、ユーザーの層（設定とガイド）を読まない" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  run_script config.sh '[.language, .guides, .sources] | tojson'
  assert_success
  assert_output "[\"ja\",{},[\"$(cd "$SCRIPTS/.." && pwd)/defaults/workflow.json\"]]"
  cd "$TMP"
  run_script config.sh '[.language, .guides] | tojson'
  assert_success
  assert_output '["ja",{}]'
  # 壊れたユーザーの層も読まないので、止まらない
  echo '{broken' >"$WORKFLOW_USER_DIR/config.json"
  run_script config.sh .language
  assert_success
  assert_output ja
}

@test "導入したリポジトリでは、ユーザーの層を読む（ワークツリーにチームの設定が無くても、メインのワークツリーにあれば導入した）" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  mark_set_up
  run_script config.sh '[.language, .guides.commit] | tojson'
  assert_output "[\"en\",[\"$WORKFLOW_USER_DIR/commit.md\"]]"
  # 初期設定をコミットする前に作ったワークツリーには、チームの設定が無い
  git worktree add -q "$TMP/wt" -b feat/1-x
  cd "$TMP/wt"
  [ ! -f .claude/dev-workflow/config.json ]
  run_script config.sh '[.language, .guides.commit] | tojson'
  assert_output "[\"en\",[\"$WORKFLOW_USER_DIR/commit.md\"]]"
}

@test "base_branch が不正でも、ほかの項目は読める（base_branch は使う側の dw_base_branch で検査する）" {
  echo '{"base_branch": "-foo"}' >.claude/dev-workflow/config.json
  run_script config.sh .status.start
  assert_success
  assert_output "In Progress"
}

@test "ホームのリポジトリでは、ユーザーの層のファイルをチームの設定・個人の上書き・ガイドとして読まない" {
  make_home_repo
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"language": "fr"}' >"$WORKFLOW_USER_DIR/config.local.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  run_script config.sh '[.language, .guides, (.sources | length)] | tojson'
  assert_success
  assert_output '["ja",{},1]'
  # 壊れていても読まないので、止まらない
  echo '{broken' >"$WORKFLOW_USER_DIR/config.json"
  run_script config.sh .language
  assert_success
  assert_output ja
}

@test "ホームのリポジトリのワークツリーでは、コミットされたユーザーの層の写しを、チームの設定として読まない" {
  make_home_repo
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  git add -f .claude/dev-workflow
  git commit -q -m "user layer"
  git worktree add -q "$TMP/wt" -b feat/1-x
  # ワークツリーには、コミットされたファイルの写しがある（ユーザーの層とは別の場所）
  [ -f "$TMP/wt/.claude/dev-workflow/config.json" ]
  cd "$TMP/wt"
  run_script config.sh '[.language, .guides, (.sources | length), .set_up] | tojson'
  assert_success
  assert_output '["ja",{},1,false]'
}

@test "set_up は、導入したか（dw_is_set_up）を真偽値で出す。チームの設定が無ければ false（#244）" {
  rm -f .claude/dev-workflow/config.json
  run_script config.sh .set_up
  assert_output "false"
  # ディレクトリと config.local.json だけでは導入したとみなさない
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  run_script config.sh .set_up
  assert_output "false"
  mark_set_up
  run_script config.sh .set_up
  assert_output "true"
}

@test "set_up は、ワークツリーにチームの設定が無くても、メインのワークツリーにあれば true。どちらにも無ければ false（#244）" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  cd "$TMP/wt"
  run_script config.sh .set_up
  assert_output "false"
  mark_set_up "$REPO"
  [ ! -f .claude/dev-workflow/config.json ]
  run_script config.sh .set_up
  assert_output "true"
}

@test "set_up は、リポジトリの外では false（#244）" {
  mkdir "$TMP/outside"
  cd "$TMP/outside"
  WORKFLOW_REPO_ROOT="" run_script config.sh .set_up
  assert_output "false"
}

@test "set_up は、どの層の設定に同じ名前のキーがあっても変わらない（#244）" {
  echo '{"set_up": true}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"set_up": true}' >.claude/dev-workflow/config.local.json
  run_script config.sh .set_up
  assert_output "false"
  echo '{"set_up": false}' >.claude/dev-workflow/config.json
  echo '{"set_up": false}' >.claude/dev-workflow/config.local.json
  run_script config.sh .set_up
  assert_output "true"
}

@test "sources は、設定ファイルのパスに絵文字があっても壊さずに出す（4096 バイトの区切りにかかる入力は作れない）" {
  # 標準入力の jq -R は、1行が約 4096 バイトを超えるとき、行の先頭から 4092〜4094 バイト目に始まる絵文字を壊す。
  # sources は1行に1つのパスで、パスは PATH_MAX（4096）未満なので、その位置に絵文字が来る行は作れない。
  # 修正前でも通る（回帰テストではない）。絵文字のパスが、dw_json_lines_nonempty を通っても保たれることだけ確かめる
  mark_set_up
  dir="$TMP/😀😀-user"
  mkdir -p "$dir"
  echo '{"language": "en"}' >"$dir/config.json"
  WORKFLOW_USER_DIR="$dir" run_script config.sh '.sources | tojson'
  assert_success
  assert_equal "$(jq -r 'map(select(endswith("😀😀-user/config.json"))) | length' <<<"$output")" 1
}
