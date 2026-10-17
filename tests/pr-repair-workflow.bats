#!/usr/bin/env bats
# pr-repair.yml（PR の指摘と CI の失敗を、Claude が無人で直す）の、安全に関わる書き方を確かめる（#341、ADR 000285）。
# 構文は actionlint が確かめる。ここでは、壊れると暴走や使用量の浪費につながる点（直列化・強制 push をしない・Claude を動かす条件・
# 権限）を、文字として確かめる。
# シングルクォートの中の ${{ ... }} は、ワークフローの文字そのものを探す（展開しない）
# shellcheck disable=SC2016

load test_helper

setup() {
  test_helper_setup
  WF="$BATS_TEST_DIRNAME/../.github/workflows/pr-repair.yml"
}

teardown() { rm -rf "$TMP"; }

# 使い方: step_of <step の名前に含まれる文字列> → その step の本文（次の「      - 」の step の前まで）
step_of() {
  awk -v n="$1" '
    /^      - / { on = (index($0, n) > 0) }
    on { print }
  ' "$WF"
}

@test "定期の見回りと、PR への指摘のイベントで起動する" {
  grep -qE '^  schedule:' "$WF"
  grep -qE '^  pull_request_review:' "$WF"
  grep -qE '^  pull_request_review_comment:' "$WF"
  grep -qE '^  issue_comment:' "$WF"
}

@test "GITHUB_TOKEN には権限を与えない（書き込みは App のトークンで行う）" {
  grep -qE '^permissions: \{\}$' "$WF"
  grep -q 'actions/create-github-app-token@v3' "$WF"
}

@test "同じ PR は concurrency で直列にし、実行中のものを取り消さない。PR は1つずつ順に処理する" {
  grep -qE '^    concurrency:$' "$WF"
  grep -qF 'group: pr-repair-${{ matrix.item.pr }}' "$WF"
  grep -qE '^      cancel-in-progress: false$' "$WF"
  if grep -q 'cancel-in-progress: true' "$WF"; then fail "cancel-in-progress: true があります"; fi
  grep -qE '^      max-parallel: 1$' "$WF"
}

@test "強制 push・マージ・resolve を、ワークフローでは行わない" {
  for w in '--force' 'force-with-lease' 'gh pr merge' 'resolveReviewThread' 'git push'; do
    if grep -q -e "$w" <(grep -v '^ *#' "$WF"); then fail "ワークフローに「${w}」があります"; fi
  done
}

@test "Claude を動かす step は、判定し直した action が act か conflict のときだけ。stop のときは Claude を動かさず、保留の列に移して止まる" {
  act="$(step_of 'gh-pr-check')"
  [[ "$act" == *"if: steps.watch.outputs.action == 'act'"* ]] || fail "gh-pr-check の step の条件が act だけではありません"
  conf="$(step_of 'branch-update')"
  [[ "$conf" == *"if: steps.watch.outputs.action == 'conflict'"* ]] || fail "branch-update の step の条件が conflict だけではありません"
  stop="$(step_of '上限に達したので')"
  [[ "$stop" == *"if: steps.watch.outputs.action == 'stop'"* ]] || fail "止まる step の条件が stop だけではありません"
  [[ "$stop" == *'auto-hold.sh'* ]] || fail "止まる step が auto-hold.sh を使っていません"
  [[ "$stop" == *'--repair-reason'* ]] || fail "止まる理由の種類を渡していません"
  [[ "$stop" != *'claude-code-action'* ]] || fail "止まる step で Claude を動かしています"
  # Claude の step は2つだけ
  [ "$(grep -c 'uses: anthropics/claude-code-action@' "$WF")" = 2 ]
}

@test "直す対象の PR を選ぶ処理は、Claude を使わないスクリプトで、既定のブランチのものを使う" {
  grep -qF '.github/scripts/pr-repair-select.sh' "$WF"
  grep -qF 'ref: ${{ github.event.repository.default_branch }}' "$WF"
}

@test "Claude には、gh-pr-check を無人で、branch-update を無人で呼ばせ、AskUserQuestion を許可しない" {
  grep -qF '/dev-workflow:gh-pr-check ${{ matrix.item.pr }}' "$WF"
  grep -qF '/dev-workflow:branch-update ${{ matrix.item.pr }}' "$WF"
  grep -q '無人で対応' "$WF"
  grep -q '無人で直す' "$WF"
  allowed="$(grep -A1 'ALLOWED_TOOLS: >-' "$WF")"
  [[ "$allowed" != *AskUserQuestion* ]]
}

@test "push の認証は App のトークンで通し、チェックアウトにトークンを残さない" {
  grep -q 'gh auth setup-git' "$WF"
  [ "$(grep -c 'persist-credentials: false' "$WF")" = 2 ]
}

@test "この実行だけ個人の層（config.local.json）で見回りを有効にし、チームの設定には書かない" {
  grep -q 'config.local.json' "$WF"
  grep -q 'enabled: true' "$WF"
  if grep -q '"repair"' "$BATS_TEST_DIRNAME/../.claude/dev-workflow/config.json"; then fail "チームの設定に repair があります"; fi
}

@test "実行の id は、auto-hold.sh が受け付ける文字（英数字と . _ -）だけでできる" {
  run grep -E '^      RUN_ID:' "$WF"
  [[ "$output" =~ RUN_ID:\ pr-repair-\$\{\{\ github.run_id\ \}\}-\$\{\{\ github.run_attempt\ \}\}-\$\{\{\ matrix.item.pr\ \}\}$ ]]
}
