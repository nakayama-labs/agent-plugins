#!/usr/bin/env bats
# 子を start の列に移したときの、親の Issue の列の移動（status-set.sh）と、親の状態の取得（parent-state.sh）
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# REST の issues/<子>/parent が返す親。使い方: set_parent <子の番号> <親の番号> [open | closed] [所有者/名前（既定 me/demo）] [state_reason]
set_parent() {
  jq -nc --argjson n "$2" --arg s "${3:-open}" --arg r "${4:-me/demo}" --arg sr "${5:-}" '{number: $n, title: "親 \($n)", state: $s,
    state_reason: (if $sr == "" then null else $sr end), url: "https://api.github.com/repos/\($r)/issues/\($n)",
    repository_url: "https://api.github.com/repos/\($r)"}' >"$FIX/parent-$1.json"
}

# 親（など）の Issue の Project P4 での項目と今の列。使い方: item_of <番号> <列名 | absent>
item_of() {
  jq -n --argjson n "$1" --arg s "$2" '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/\($n)", projectItems: {nodes: (
    if $s == "absent" then [] else [{id: "IT\($n)", project: {id: "P4"}, fieldValueByName: {name: $s}}] end)}}}}}' >"$FIX/IssueItem-issue-$1.json"
}

setup_parents() {
  setup_fake_gh
  # 17 → 10 → 5
  set_parent 17 10
  set_parent 10 5
  item_of 17 Todo
  item_of 10 Todo
  item_of 5 Todo
}

moved() { grep '^SetField ' "$CALLS" | cut -d' ' -f2- | jq -r '.id' | tr '\n' ','; }

@test "子を start に移すと、todo の列にある親と上の親も start に移る" {
  setup_parents
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
  assert_equal "$(jq -c '[.parents[] | [.issue, .from, .to]]' <<<"$output")" '[[10,"Todo","In Progress"],[5,"Todo","In Progress"]]'
  assert_equal "$(jq -c '.actions' <<<"$output")" \
    '["Issue #17 を「Todo」から「In Progress」に移す","親の Issue #10 を「Todo」から「In Progress」に移す","親の Issue #5 を「Todo」から「In Progress」に移す"]'
}

@test "task-start でも親が start に移り、結果に出る" {
  setup_parents
  git init -q -b main "$TMP/origin.git" --bare
  git -C "$REPO" remote add origin "$TMP/origin.git"
  git add .claude/dev-workflow/config.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
  git push -q origin main
  run_script task-start.sh --issue 17 --slug x
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
  assert_equal "$(json_of "$output" | jq -c '[.status.parents[].issue]')" "[10,5]"
  assert_equal "$(json_of "$output" | jq -c '.actions | map(select(startswith("親の"))) | length')" 2
}

@test "todo より先の列にある親は動かさない（上の親は todo なら移す）" {
  setup_parents
  item_of 10 "In Progress"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "Done の列にある親も動かさない" {
  setup_parents
  item_of 10 Done
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "閉じた親は動かさない" {
  setup_parents
  set_parent 17 10 closed me/demo completed
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "Project に入っていない親は、追加も移動もしない" {
  setup_parents
  item_of 10 absent
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(called AddItem)" 0
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "別のリポジトリの親は動かさず、そこから上もたどらない" {
  setup_parents
  set_parent 17 10 open other/repo
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,"
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
}

@test "start 以外の列（pr_opened・Done）に移すときは、親を動かさない" {
  setup_parents
  run_script status-set.sh --issue 17 --to Done
  assert_success
  assert_equal "$(called api-parent)" 0
  assert_equal "$(moved)" "IT17,"
  echo '{"project": {"owner": "me", "number": 4}, "status": {"pr_opened": "In Progress"}}' >"$REPO/.claude/dev-workflow/config.json"
  : >"$CALLS"
  run_script status-set.sh --issue 17 --to pr_opened
  assert_success
  assert_equal "$(called api-parent)" 0
  assert_equal "$(moved)" "IT17,"
}

@test "親の列を移せなくても、子の移動は止めずに警告する" {
  setup_parents
  FAKE_FAIL=SetField.2 FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_output --partial "親の Issue #10 の列を start に移せませんでした"
  assert_equal "$(json_of "$output" | jq -r '[.changed, .to] | join(",")')" "true,In Progress"
}

@test "親を読めなくても、子の移動は止めずに警告する" {
  setup_parents
  FAKE_FAIL=api-parent FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_output --partial "Issue #17 の親を読めなかったので、親の列は移しません"
  assert_equal "$(moved)" "IT17,"
}

@test "dry-run では親も移さず、予定に出す" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --dry-run
  assert_success
  assert_equal "$(called SetField)" 0
  assert_equal "$(jq -c '[.actions[] | select(startswith("親の"))] | length' <<<"$output")" 2
}

@test "--no-parents では親を読まない" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --no-parents
  assert_success
  assert_equal "$(called api-parent)" 0
}

@test "--only-from は、今の列が違えば何もせず、--item-id とは一緒に指定できない" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --only-from Done
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called SetField)" 0
  run_script status-set.sh --issue 17 --to start --only-from todo --item-id X
  assert_failure 64
}

# --- parent-state.sh ----------------------------------------------------------------

sub() { jq -nc --argjson n "$1" --arg s "$2" --arg r "${3:-}" '{number: $n, title: "子 \($n)", state: $s, state_reason: (if $r == "" then null else $r end)}'; }
set_children() { local p="$1"; shift; printf '%s\n' "$@" | jq -s . >"$FIX/sub-issues-$p.json"; }

@test "parent-state: 子がすべて閉じた親は all_closed で、completed を案にする" {
  setup_parents
  set_children 10 "$(sub 17 open)" "$(sub 18 closed completed)"
  set_children 5 "$(sub 10 open)"
  run_script parent-state.sh --issue 17 --assume-closed 17
  assert_success
  assert_equal "$(jq -c '.parents[0] | [.number, .state, .column, .children.total, .children.closed, .children.open, .all_closed, .suggest]' <<<"$output")" \
    '[10,"open","Todo",2,2,0,true,"completed"]'
  # 上の親は、下の親がまだ開いているので all_closed ではない
  assert_equal "$(jq -c '.parents[1] | [.number, .all_closed, .suggest]' <<<"$output")" '[5,false,null]'
}

@test "parent-state: 子がすべて取りやめなら not_planned を案にする。混ざっていれば completed" {
  setup_parents
  set_children 10 "$(sub 17 closed not_planned)" "$(sub 18 closed duplicate)"
  set_children 5 "$(sub 10 open)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" not_planned
  set_children 10 "$(sub 17 closed not_planned)" "$(sub 18 closed completed)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" completed
}

@test "parent-state: 開いている子があれば all_closed ではなく、閉じた親には案を出さない" {
  setup_parents
  set_parent 17 10 closed me/demo completed
  set_children 10 "$(sub 17 closed completed)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '.parents | length' <<<"$output")" 2
  assert_equal "$(jq -c '.parents[0] | [.state, .all_closed, .suggest]' <<<"$output")" '["closed",true,null]'
  set_parent 17 10
  set_children 10 "$(sub 17 closed completed)" "$(sub 18 open)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '.parents[0] | [.all_closed, .suggest, .children.open]' <<<"$output")" '[false,null,1]'
}

@test "parent-state: 親が無ければ空、別のリポジトリの親は含めない、Project が未設定なら column は null" {
  setup_fake_gh
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
  set_parent 17 10 open other/repo
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
  setup_parents
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  set_children 10 "$(sub 17 open)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '.parents[0].column' <<<"$output")" null
  assert_equal "$(called ProjectView)" 0
}

# --- 追加：引数・失敗・境界 ---------------------------------------------------------

@test "parent-state: 引数の誤りは 64 で止まる" {
  setup_parents
  run_script parent-state.sh
  assert_failure 64
  run_script parent-state.sh --issue
  assert_failure 64
  run_script parent-state.sh --issue 17 --assume-closed
  assert_failure 64
  run_script parent-state.sh --issue 17 --bogus
  assert_failure 64
}

@test "parent-state: サブ Issue を読めなければ止まる" {
  setup_parents
  FAKE_FAIL=api-sub-issues run_script parent-state.sh --issue 17
  assert_failure
  assert_output --partial "#10 のサブ Issue を読めませんでした"
}

@test "parent-state: 子が 0 の親・閉じた親・開いた子が残る親には suggest を出さない（確認の対象は suggest が null でない親だけ）" {
  setup_parents
  set_children 10 "$(sub 17 closed completed)"
  set_children 5 "$(sub 10 open)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '[.parents[] | .suggest]' <<<"$output")" '["completed",null]'
  # 子が 0
  rm -f "$FIX/sub-issues-10.json"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '.parents[0] | [.children.total, .all_closed, .suggest]' <<<"$output")" '[0,false,null]'
  # 閉じた親
  set_parent 17 10 closed me/demo completed
  set_children 10 "$(sub 17 closed completed)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '.parents[0].suggest' <<<"$output")" null
  # 開いた子が残る親
  set_parent 17 10
  set_children 10 "$(sub 17 closed completed)" "$(sub 18 open)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '.parents[0].suggest' <<<"$output")" null
}

@test "parent-state: --assume-closed は、既に閉じた子の閉じ方を変えず、一覧に無い番号は無視し、複数の指定（繰り返しとカンマ）を受ける" {
  setup_parents
  set_children 10 "$(sub 17 open)" "$(sub 18 closed not_planned)" "$(sub 19 open)"
  run_script parent-state.sh --issue 17 --assume-closed 18,99 --assume-closed 17
  assert_success
  assert_equal "$(jq -c '.parents[0].children | [.total, .closed, .open]' <<<"$output")" '[3,2,1]'
  assert_equal "$(jq -c '.parents[0].children.list | map({number, state, state_reason})' <<<"$output")" \
    '[{"number":17,"state":"closed","state_reason":"completed"},{"number":18,"state":"closed","state_reason":"not_planned"},{"number":19,"state":"open","state_reason":null}]'
  run_script parent-state.sh --issue 17 --assume-closed 17,19
  assert_equal "$(jq -c '.parents[0] | [.all_closed, .suggest]' <<<"$output")" '[true,"completed"]'
  run_script parent-state.sh --issue 17 --assume-closed 17 --assume-closed '#19'
  assert_equal "$(jq -c '.parents[0] | [.all_closed, .suggest]' <<<"$output")" '[true,"completed"]'
}

@test "parent-state: Project を読めなくても止めず、column を null にして警告する" {
  setup_parents
  set_children 10 "$(sub 17 open)"
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="gh: boom" run_script parent-state.sh --issue 17
  assert_success
  assert_output --partial "Project（me/4）を読めなかったので"
  assert_equal "$(json_of "$output" | jq -c '.parents[0].column')" null
  # Project が無い（404）ときも同じ
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="Could not resolve to a ProjectV2 (HTTP 404)" run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(json_of "$output" | jq -c '.parents[0].column')" null
}

@test "親をたどる層は 8 までで、途中が別のリポジトリならそこで打ち切る" {
  setup_fake_gh
  # 17 → 101 → 102 → … → 109（9 層上まである）
  set_parent 17 101
  for n in 101 102 103 104 105 106 107 108; do set_parent "$n" "$((n + 1))"; done
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '[.parents[].number]' <<<"$output")" '[101,102,103,104,105,106,107,108]'
  # 連鎖の途中（5）だけ別のリポジトリ
  rm -f "$FIX"/parent-1*.json
  set_parent 17 10
  set_parent 10 5 open other/repo
  set_parent 5 3
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '[.parents[].number]' <<<"$output")" '[10]'
}

@test "親のリポジトリ名は大文字小文字を区別せずに比べる" {
  setup_parents
  set_parent 17 10 open Me/Demo
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '[.parents[].number]' <<<"$output")" '[10,5]'
}

@test "parent-state: --assume-closed の値は glob 展開せず、空の要素は無視し、番号でないものは 64 で止まる" {
  setup_parents
  set_children 10 "$(sub 17 open)" "$(sub 19 open)"
  touch "$TMP/17" "$TMP/19"
  cd "$TMP"
  run_script parent-state.sh --issue 17 --assume-closed '*'
  assert_failure 64
  run_script parent-state.sh --issue 17 --assume-closed '17,,19'
  assert_success
  assert_equal "$(jq -c '.parents[0] | [.all_closed, .suggest]' <<<"$output")" '[true,"completed"]'
  run_script parent-state.sh --issue 17 --assume-closed ','
  assert_success
  assert_equal "$(jq -c '.parents[0].all_closed' <<<"$output")" false
}

@test "--only-from に未設定の役割を渡すと skipped になり、Project に無い Issue には何もしない" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --only-from hold
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called SetField)" 0
  item_of 17 absent
  jq -n '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/17", projectItems: {nodes: []}}}}}' >"$FIX/IssueItem.json"
  rm -f "$FIX/IssueItem-issue-17.json"
  run_script status-set.sh --issue 17 --to start --only-from todo
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called AddItem)" 0
  assert_equal "$(called SetField)" 0
}

@test "列名で pr_opened と同じ列を渡しても親は動かさず、start の役割なら動かす（pr_opened と start が同じ列のとき）" {
  setup_parents
  echo '{"project": {"owner": "me", "number": 4}, "status": {"pr_opened": "In Progress"}}' >"$REPO/.claude/dev-workflow/config.json"
  run_script status-set.sh --issue 17 --to "In Progress"
  assert_success
  assert_equal "$(called api-parent)" 0
  assert_equal "$(moved)" "IT17,"
  : >"$CALLS"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
}

@test "列名で start の列を渡しても、pr_opened の列と別なら親が動く" {
  setup_parents
  run_script status-set.sh --issue 17 --to "In Progress"
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
}

@test "親の移動に失敗・親を読めなかったことは、JSON の warnings にも出る" {
  setup_parents
  FAKE_FAIL=SetField.2 FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(json_of "$output" | jq -c '.warnings | length')" 1
  assert_equal "$(json_of "$output" | jq -r '.warnings[0]')" "親の Issue #10 の列を start に移せませんでした（Issue #17 の移動は済んでいます）（原因: Issue #10 の Status を「In Progress」にできませんでした）"
  FAKE_FAIL=api-parent FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_equal "$(json_of "$output" | jq -r '.warnings[0]')" "Issue #17 の親を読めなかったので、親の列は移しません（原因: GitHub の API に失敗しました: gh: boom）"
  run_script status-set.sh --issue 17 --to start
  assert_equal "$(json_of "$output" | jq -c '.warnings')" "[]"
}

@test "親の移動に失敗した原因（標準エラーの1行）を警告に添える" {
  setup_parents
  FAKE_FAIL=SetField.2 FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(json_of "$output" | jq -r '.warnings[0]')" "親の Issue #10 の列を start に移せませんでした（Issue #17 の移動は済んでいます）（原因: Issue #10 の Status を「In Progress」にできませんでした）"
}

@test "parent-state: --assume-closed に理由を付けると、その閉じ方で suggest が決まる（全員取りやめなら not_planned）" {
  setup_parents
  set_children 10 "$(sub 17 open)" "$(sub 18 closed not_planned)"
  run_script parent-state.sh --issue 17 --assume-closed 17:not_planned
  assert_success
  assert_equal "$(jq -c '.parents[0] | [.suggest, .children.list[0].state_reason]' <<<"$output")" '["not_planned","not_planned"]'
  run_script parent-state.sh --issue 17 --assume-closed 17:duplicate
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" not_planned
  # 理由なしは completed
  run_script parent-state.sh --issue 17 --assume-closed 17
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" completed
  # カンマ区切り・繰り返しと両立し、不正な理由は 64
  set_children 10 "$(sub 17 open)" "$(sub 19 open)"
  run_script parent-state.sh --issue 17 --assume-closed 17:not_planned,19:not_planned
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" not_planned
  run_script parent-state.sh --issue 17 --assume-closed 17:not_planned --assume-closed 19
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" completed
  run_script parent-state.sh --issue 17 --assume-closed 17:bogus
  assert_failure 64
}

@test "親の移動が成功したときに内側が出した標準エラーの警告も、外側の標準エラーと warnings に引き継ぐ" {
  setup_parents
  mkdir -p "$TMP/wrap"
  cat >"$TMP/wrap/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "project item-edit" ] && [ -n "\${NOISY:-}" ]; then echo "gh: deprecated flag" >&2; fi
exec "$TMP/bin/gh" "\$@"
SH
  chmod +x "$TMP/wrap/gh"
  PATH="$TMP/wrap:$PATH" NOISY=1 run_script status-set.sh --issue 17 --to start
  assert_success
  assert_output --partial "warn: 親の Issue #10: gh: deprecated flag"
  assert_equal "$(json_of "$output" | jq -r '.warnings[0]')" "親の Issue #10: gh: deprecated flag"
  assert_equal "$(json_of "$output" | jq -c '[.parents[].issue]')" "[10,5]"
}

@test "親の読み取り用の一時ファイルは、終了時に残さない" {
  setup_parents
  mkdir -p "$TMP/tmpdir"
  TMPDIR="$TMP/tmpdir" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(find "$TMP/tmpdir" -type f | wc -l | tr -d ' ')" 0
}

@test "親や子の本文が長くても（引数の長さの上限の 128 KiB を超えても）、親をたどって状態を出す" {
  setup_parents
  long_text "$TMP/long"
  # REST の parent と sub_issues は、Issue の本文も返す
  for f in "$FIX/parent-17.json" "$FIX/parent-10.json"; do
    jq --rawfile b "$TMP/long" '. + {body: $b}' "$f" >"$TMP/j" && mv "$TMP/j" "$f"
  done
  set_children 10 "$(sub 17 open)" "$(sub 18 closed completed)"
  set_children 5 "$(sub 10 open)"
  jq --rawfile b "$TMP/long" 'map(. + {body: $b})' "$FIX/sub-issues-10.json" >"$TMP/j" && mv "$TMP/j" "$FIX/sub-issues-10.json"
  run_script parent-state.sh --issue 17 --assume-closed 17
  assert_success
  assert_equal "$(jq -c '[.parents[] | [.number, .children.total, .all_closed]]' <<<"$output")" '[[10,2,true],[5,1,false]]'
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
}

@test "親が読めない（/parent が 404 でも Issue の応答に parent_issue_url がある）ときは、親なしとは数えずに止まる（#347）" {
  setup_fake_gh
  # 17 → 10（読める）→ 10 の親は読めない
  set_parent 17 10
  jq -c '. + {parent_issue_url: "https://api.github.com/repos/other/private/issues/3"}' "$FIX/parent-17.json" >"$FIX/p.json"
  mv "$FIX/p.json" "$FIX/parent-17.json"
  run_script parent-state.sh --issue 17
  assert_failure
  assert_output --partial "#10 の親（https://api.github.com/repos/other/private/issues/3）を読めません"
  # 最初の Issue の親が読めないときも同じ
  rm -f "$FIX"/parent-*.json "$FIX"/issue-*.json
  jq -nc '{number: 17, url: "https://api.github.com/repos/me/demo/issues/17", parent_issue_url: "https://api.github.com/repos/other/private/issues/3"}' >"$FIX/issue-17.json"
  run_script parent-state.sh --issue 17
  assert_failure
  assert_output --partial "#17 の親"
  # parent_issue_url が null なら、本当に親が無いので、止まらない
  jq -nc '{number: 17, parent_issue_url: null}' >"$FIX/issue-17.json"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '.parents' <<<"$output")" '[]'
}

@test "子を start に移すとき、親が読めない（/parent が 404 で parent_issue_url がある）と、子の操作は成功し、警告して親の列は移さない（#347）" {
  setup_parents
  rm -f "$FIX/parent-17.json"
  jq -nc '{number: 17, url: "https://api.github.com/repos/me/demo/issues/17", parent_issue_url: "https://api.github.com/repos/other/private/issues/3"}' >"$FIX/issue-17.json"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,"
  assert_equal "$(json_of "$output" | jq -c .parents)" '[]'
  assert_equal "$(json_of "$output" | jq -r ".warnings | join(\"\\n\")")" "$(printf '%s' "Issue #17 の親を読めなかったので、親の列は移しません（原因: #17 の親（https://api.github.com/repos/other/private/issues/3）を読めません（トークンで読めないリポジトリにあるかもしれません）。親があるので、親なしとは数えません）")"
}
