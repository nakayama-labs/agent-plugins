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

@test "判定・保留のスクリプトとプラグインは、PR のブランチでなく、既定のブランチを trusted/ にチェックアウトしたものを使う" {
  # 既定のブランチを trusted/ に取る（repair ジョブ。PR のブランチの後）
  trusted_co="$(awk '/ref: \$\{\{ github.event.repository.default_branch \}\}/ { r = NR } /path: trusted/ { p = NR } END { print (p - r == 1 || r - p == 1) ? "ok" : "ng" }' "$WF")"
  [ "$trusted_co" = ok ] || fail "既定のブランチを path: trusted にチェックアウトしていません"
  first_pr="$(grep -n 'ref: ${{ matrix.item.branch }}' "$WF" | head -1 | cut -d: -f1)"
  trusted_line="$(grep -n 'path: trusted' "$WF" | head -1 | cut -d: -f1)"
  [ "$first_pr" -lt "$trusted_line" ] || fail "trusted/ のチェックアウトが、PR のブランチより前にあります（PR 側のチェックアウトが消します）"
  grep -q "echo '/trusted/' >> .git/info/exclude" "$WF"
  # Claude のプラグインは trusted/ のもの。作業ディレクトリ側のプラグインを読ませない
  [ "$(grep -c -- '--plugin-dir ${{ github.workspace }}/trusted/plugins/dev-workflow' "$WF")" = 2 ]
  if grep -E -- '--plugin-dir (plugins|\./plugins)' "$WF"; then fail "PR 側のプラグインを読み込んでいます"; fi
  # Bash で許可するスクリプトのパスも trusted/ の下だけ
  allowed="$(grep -A1 'ALLOWED_TOOLS: >-' "$WF")"
  [[ "$allowed" == *'Bash(${{ github.workspace }}/trusted/plugins/dev-workflow/scripts/*)'* ]] || fail "許可するスクリプトのパスが trusted/ の下ではありません"
  [[ "$allowed" != *'workspace }}/plugins/'* ]] || fail "PR 側のスクリプトの実行を許可しています"
  # 判定し直す step と保留の step は、trusted/ の中で動かす
  [[ "$(step_of 'PR の今の状態を判定し直す')" == *'working-directory: trusted'* ]]
  [[ "$(step_of '上限に達したので')" == *'working-directory: trusted'* ]]
}

@test "判定し直す step は、信頼する側の pr-repair-select.sh --pr で決め直し、イベントの投稿者は渡さず、対象でなければ skip にする" {
  w="$(step_of 'PR の今の状態を判定し直す' | grep -v '^ *#')"
  [[ "$w" == *'.github/scripts/pr-repair-select.sh --pr "$PR_NUMBER"'* ]] || fail "pr-repair-select.sh --pr を使っていません"
  [[ "$w" != *'--sender'* ]] || fail "判定し直しで投稿者を渡しています"
  [[ "$w" == *'// "skip"'* ]] || fail "対象でないときの skip がありません"
  [[ "$w" != *'pr-watch.sh'* ]] || fail "pr-watch.sh だけで決め直しています"
  # skip のときは、後の step（act・conflict・stop だけが動く）が動かない
  for a in act conflict stop; do grep -q "steps.watch.outputs.action == '$a'" "$WF" || fail "$a の step がありません"; done
  if grep -q "action == 'skip'" "$WF"; then fail "skip で動く step があります"; fi
}

@test "ALLOWED_TOOLS は task-auto.yml の --allowedTools と同じ内容（スクリプトのパスだけ違う）で、双方のコメントに互いが書いてある" {
  TA="$BATS_TEST_DIRNAME/../.github/workflows/task-auto.yml"
  mine="$(grep -A1 'ALLOWED_TOOLS: >-' "$WF" | tail -1 | sed -e 's/^ *//' -e 's#/trusted/plugins#/plugins#')"
  theirs="$(grep -- '--allowedTools "' "$TA" | sed -e 's/.*--allowedTools "//' -e 's/"$//')"
  [ -n "$mine" ] && [ "$mine" = "$theirs" ] || fail "ALLOWED_TOOLS が task-auto.yml と違います: $mine / $theirs"
  grep -q 'task-auto.yml の --allowedTools と同じ内容' "$WF"
  grep -q 'pr-repair.yml の ALLOWED_TOOLS と同じ内容' "$TA"
}

@test "見回りの設定（config.local.json）は、スクリプトで書く（find と repair の jq の重複をなくす）" {
  [ "$(grep -c 'pr-repair-config.sh' "$WF")" -ge 3 ]
  if grep -q "jq -n --arg app" "$WF"; then fail "ワークフローに設定を書く jq が残っています"; fi
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
  [ "$(grep -c 'persist-credentials: false' "$WF")" = 3 ]
}

@test "この実行だけ個人の層（config.local.json）で見回りを有効にし、チームの設定には書かない" {
  grep -q 'config.local.json' "$WF"
  if grep -q '"repair"' "$BATS_TEST_DIRNAME/../.claude/dev-workflow/config.json"; then fail "チームの設定に repair があります"; fi
}

@test "実行の id は、auto-hold.sh が受け付ける文字（英数字と . _ -）だけでできる" {
  run grep -E '^      RUN_ID:' "$WF"
  [[ "$output" =~ RUN_ID:\ pr-repair-\$\{\{\ github.run_id\ \}\}-\$\{\{\ github.run_attempt\ \}\}-\$\{\{\ matrix.item.pr\ \}\}$ ]]
}

@test "チェックアウトの前に PR が開いているかを確かめ、閉じていれば準備・判定・失敗の通知を飛ばす（ブランチが消えた誤通知を防ぐ）" {
  # 確かめる step が、PR のブランチのチェックアウトより前にある
  open_line=$(grep -n 'name: PR がまだ開いているかを確かめる' "$WF" | head -1 | cut -d: -f1)
  checkout_line=$(grep -n 'ref: ${{ matrix.item.branch }}' "$WF" | head -1 | cut -d: -f1)
  [ -n "$open_line" ] && [ -n "$checkout_line" ] && [ "$open_line" -lt "$checkout_line" ]
  # PR のブランチのチェックアウトと、それに依存する準備・判定は、開いているときだけ動く
  for n in 'name: 道具を入れる' 'name: git の作者と認証を App にする' 'name: PR の今の状態を判定し直す'; do
    run step_of "${n#name: }"
    [[ "$output" == *"if: steps.open.outputs.open == 'true'"* ]]
  done
  # 失敗の通知は、閉じているとわかった PR には付けない
  [ "$(grep -c "steps.open.outputs.open != 'false'" "$WF")" = 2 ]
}

@test "claude-code-action は、指摘に対応してよい投稿者（bot）を実行者として拒否しない（allowed_bots）" {
  [ "$(grep -c 'allowed_bots: ${{ env.ALLOWED_AUTHORS }}' "$WF")" = 2 ]
}

@test "保留で止まるときのコメントは、再開に Issue を保留の列から戻すことを書く（保留の列にある間は見回らない）" {
  grep -q '再開するには、Issue を保留の列から戻してください' "$WF"
  grep -q '再開するには、Issue を保留の列から戻します' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
}
