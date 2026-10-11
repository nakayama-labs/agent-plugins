#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

BODY='## 背景
なし

## やること
- [ ] a.sh を足す

## 完了条件
- a.sh が動く

## 依存
- なし'

# 使い方: set_config <jq の式> → チームの設定を書き換える
set_config() {
  jq "$1" .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
}

# task-auto を有効にし、保留の列を設定して、Issue #17（feat）に本文を入れる
setup_auto() {
  setup_fake_gh
  set_config '. + {auto: {enabled: true}, status: {hold: "On Hold"}}'
  fake_issue_body 17 "$BODY"
  # 前の作業のブランチを探す（dw_issue_work）ために、origin を作る
  git add -A && git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
}

run_check() {
  run_script auto-check.sh "$@"
  printf '%s\n' "$output"
}

@test "有効で、Issue が止まる条件に当たらなければ proceed" {
  setup_auto
  run_check --issue '#17'
  assert_success
  assert_equal "$(jq -c '[.action, .reasons, .issue.number, .issue.type, .issue.breaking]' <<<"$output")" '["proceed",[],17,"feat",false]'
  assert_equal "$(jq -c .settings <<<"$output")" '{"max_fix_attempts":3,"max_new_issues":3,"hold":"On Hold"}'
}

@test "既定（auto.enabled が false）なら disabled で、Issue も読まない" {
  setup_fake_gh
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .issue]' <<<"$output")" '["disabled",null]'
  assert_equal "$(called issue-view)" 0
}

@test "enabled が true でなければ（文字列の \"true\" でも）disabled" {
  setup_fake_gh
  set_config '. + {auto: {enabled: "true"}, status: {hold: "On Hold"}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" disabled
}

@test "保留の列が無ければ no_hold で、Issue も読まない" {
  setup_fake_gh
  set_config '. + {auto: {enabled: true}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" no_hold
  assert_output --partial "repo-setup"
  assert_equal "$(called issue-view)" 0
}

@test "保留の列がほかの役割と同じ名前なら止まる" {
  setup_auto
  set_config '.status.hold = "Todo"'
  run_check --issue 17
  assert_failure 2
  assert_output --partial "保留の列（status.hold）は、ほかの役割（status.todo）と別の列名にしてください"
}

@test "max_fix_attempts が1以上の整数でなければ、max_new_issues が0以上の整数でなければ止まる" {
  setup_auto
  for v in 0 -1 1.5 '"3"' null; do
    set_config ".auto.max_fix_attempts = $v"
    run_check --issue 17
    assert_failure 2
    assert_output --partial "auto.max_fix_attempts は1以上の整数にしてください"
  done
  set_config '.auto.max_fix_attempts = 2 | .auto.max_new_issues = 0'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c .settings <<<"$output")" '{"max_fix_attempts":2,"max_new_issues":0,"hold":"On Hold"}'
  set_config '.auto.max_new_issues = -1'
  run_check --issue 17
  assert_failure 2
  assert_output --partial "auto.max_new_issues は0以上の整数にしてください"
}

@test "閉じた Issue と親の Issue は not_startable" {
  setup_auto
  jq '.state = "CLOSED"' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["not_startable",["Issue #17 は閉じています"]]'
  jq '.state = "OPEN" | .subIssuesSummary = {total: 2}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" not_startable
  assert_output --partial "親の Issue（サブ Issue が 2 件）"
}

@test "breaking ラベル（大文字でも）と、type ラベルが1つでないことは hold の理由になる" {
  setup_auto
  fake_issue 17 '["feat", "Breaking"]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .issue.breaking, (.reasons | length)]' <<<"$output")" '["hold",true,1]'
  assert_output --partial "breaking ラベルが付いています"
  fake_issue 17 '["feat", "fix"]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .issue.type]' <<<"$output")" '["hold",null]'
  assert_output --partial "type ラベルが1つではありません（今は feat, fix）"
  fake_issue 17 '[]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_output --partial "type ラベルがありません"
}

@test "「やること」「完了条件」が無い・テンプレートのままなら hold の理由になる" {
  setup_auto
  fake_issue_body 17 '## 背景
何か

## やること
- [ ]

## 完了条件
-
'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" hold
  assert_equal "$(jq -r '.reasons | length' <<<"$output")" 2
  assert_output --partial "本文の「やること」に項目がありません"
  assert_output --partial "本文の「完了条件」に項目がありません"
  fake_issue_body 17 '何かを直す'
  run_check --issue 17
  assert_equal "$(jq -r '.reasons | length' <<<"$output")" 2
}

@test "コードブロックと HTML のコメントの中の見出しや項目は数えない" {
  setup_auto
  fake_issue_body 17 '## やること
<!-- - [ ] コメントの中
-->
```
## 完了条件
- コードの中
```
- [ ] 本当の項目'
  run_check --issue 17
  assert_equal "$(jq -c .reasons <<<"$output")" '["本文の「完了条件」に項目がありません（どこまでやれば終わりかが決まっていません）"]'
}

@test "英語の見出し（Tasks・Acceptance criteria。大文字と小文字は問わない）と CRLF の本文も読む" {
  setup_auto
  fake_issue_body 17 $'### TASKS\r\n- [x] done\r\n\r\n### Acceptance Criteria ###\r\n1. works\r\n'
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" proceed
}

@test "PR の番号なら止まる" {
  setup_auto
  jq '.url = "https://github.com/me/demo/pull/17"' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_failure 2
  assert_output --partial "#17 は PR です"
}

@test "type ラベルは大文字と小文字を区別せずに照合し、設定の書き方の type にする（Fix と fix は1つと数える）" {
  setup_auto
  for labels in '["Fix"]' '["Fix", "fix"]'; do
    fake_issue 17 "$labels"
    fake_issue_body 17 "$BODY"
    run_check --issue 17
    assert_success
    assert_equal "$(jq -c '[.action, .issue.type]' <<<"$output")" '["proceed","fix"]'
  done
}

# shellcheck disable=SC2016 # 本文のバッククォートは Markdown の文字で、展開させない
@test "本文の節は md_scan と同じ決まりで読む（コードブロックの閉じ方・行内の \`\`\`・行の途中の <!--・節の中の小見出し）" {
  setup_auto
  # ```` の囲みの中の ``` では閉じない。```x``` は囲みではない。行の途中の <!-- はコメントの始まりではない。
  # 節の中の ### の小見出しの下の項目も、その節の項目として数える
  fake_issue_body 17 '## やること
````
```
## 完了条件
````
```bash run.sh```
### スクリプト
- [ ] a.sh を足す <!-- 補足

## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["proceed",[]]'
}

@test "小見出しの節は、同じかより上の段の見出しで終わる（別の節の項目を数えない）" {
  setup_auto
  fake_issue_body 17 '### やること
## 背景
- 項目に見えるが背景の行
## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_equal "$(jq -c .reasons <<<"$output")" '["本文の「やること」に項目がありません（何をするかが決まっていません）"]'
}

@test "無効なら、auto の値が誤っていても disabled を返す（Issue も読まない）" {
  setup_fake_gh
  set_config '. + {auto: {enabled: false, max_fix_attempts: 0, max_new_issues: "x"}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .settings]' <<<"$output")" '["disabled",null]'
  assert_equal "$(called issue-view)" 0
}

@test "閉じた Issue は、止まる条件（breaking・type ラベル・本文）にも当たっても not_startable（hold にしない）" {
  setup_auto
  fake_issue 17 '["feat", "breaking"]' CLOSED
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["not_startable",["Issue #17 は閉じています"]]'
}

@test "issue に本文（body）も出す（task-auto が Issue を読み直さずに、あいまいかを判断できるように）" {
  setup_auto
  run_check --issue 17
  assert_equal "$(jq -r .issue.body <<<"$output")" "$BODY"
}

@test "前の作業の確かなブランチが1つあれば、名前のまま使い回す（resume。ワークツリーがあればその場所も。origin だけにあっても）" {
  setup_auto
  run_check --issue 17
  assert_equal "$(jq -c .resume <<<"$output")" null
  git branch feat/17-old-work
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["proceed",{"branch":"feat/17-old-work","worktree":null}]'
  git worktree add -q "$TMP/wt" feat/17-old-work
  run_check --issue 17
  assert_equal "$(jq -c .resume <<<"$output")" "{\"branch\":\"feat/17-old-work\",\"worktree\":\"$TMP/wt\"}"
  git worktree remove "$TMP/wt"
  git branch -D -q feat/17-old-work
  # 番号の先頭が 0 のブランチも、名前を作り直さずにそのまま返す（作り直すと feat/17-… になり、別のブランチになる）
  git push -q origin main:refs/heads/feat/017-remote-only
  run_check --issue 17
  assert_equal "$(jq -c .resume <<<"$output")" '{"branch":"feat/017-remote-only","worktree":null}'
}

@test "前の作業のブランチを1つに決められなければ hold（複数・type が違う・候補だけ・別のブランチの開いた PR）" {
  setup_auto
  git branch feat/17-a
  git branch feat/17-b
  # 確かなブランチのどれかの PR は、「別のブランチ」の理由を重ねて出さない
  link_prs 5:OPEN:feat/17-b
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .reasons, .resume]' <<<"$output")" \
    '["hold",["Issue #17 の作業のブランチが複数あります（feat/17-a, feat/17-b）。どれで続けるかは人が決めます"],null]'
  git branch -D -q feat/17-b
  link_prs
  # 確かなブランチの type が Issue の type と違えば、type ラベル・ブランチ名・PR のタイトルの type がそろわないので止まる
  fake_issue 17 '["fix"]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["hold",null]'
  assert_output --partial "Issue #17 の作業のブランチ feat/17-a の type（feat）が、Issue の type（fix）と違います"
  fake_issue 17 '["feat"]'
  fake_issue_body 17 "$BODY"
  git branch -D -q feat/17-a
  git branch wip/17-try
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["hold",null]'
  assert_output --partial "Issue #17 の作業かもしれないブランチがあります（wip/17-try）"
  # 候補のブランチを head に持つ開いている PR は、同じ理由を重ねて出さない
  link_prs 5:OPEN:wip/17-try
  run_check --issue 17
  assert_equal "$(jq -r '.reasons | length' <<<"$output")" 1
  git branch -D -q wip/17-try
  git branch feat/17-a
  link_prs 5:OPEN:other-branch
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" hold
  assert_output --partial "Issue #17 を閉じる PR #5 が、別のブランチ（other-branch）で開いています"
  link_prs 5:OPEN:feat/17-a
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .resume.branch]' <<<"$output")" '["proceed","feat/17-a"]'
}

@test "行の中の <!-- … --> は外してから見る（コメントだけの項目は空、見出しの後ろのコメントは見出しの一部にしない）" {
  setup_auto
  fake_issue_body 17 '## やること <!-- 必須 -->
<!-- 何をするか書く -->
- [ ] <!-- 例: ここに書く -->

## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["hold",["本文の「やること」に項目がありません（何をするかが決まっていません）"]]'
  # コメントの外に文字があれば項目として数える（間の文字を消すほど広くは外さない）
  fake_issue_body 17 '## やること <!-- 必須 -->
- [ ] <!-- a --> a.sh を足す <!-- b -->

## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" proceed
}

@test "ほかの理由で止まるときは、前の作業のブランチを探さない（origin も PR も読まない）" {
  setup_auto
  fake_issue 17 '["feat", "breaking"]'
  fake_issue_body 17 "$BODY"
  git remote set-url origin "$TMP/none.git"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["hold",null]'
}

@test "gh が古ければ、Issue を読まずに止まる" {
  setup_auto
  FAKE_GH_VERSION=2.72.0 run_check --issue 17
  assert_failure 2
  assert_output --partial "gh"
  assert_equal "$(called issue-view)" 0
}

@test "gh 2.93.0 でも（サブ Issue を読める 2.94.0 より古いので）、Issue を読まずに止まる" {
  setup_auto
  FAKE_GH_VERSION=2.93.0 run_check --issue 17
  assert_failure 2
  assert_output --partial "gh 2.94.0 以上が要ります（今は 2.93.0）"
  assert_equal "$(called issue-view)" 0
}

@test "使い回すブランチが、Issue を閉じる今のリポジトリの PR でマージ済みなら hold（終わった作業の上に続けない）" {
  setup_auto
  git branch feat/17-old
  link_prs 5:MERGED:feat/17-old
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["hold",null]'
  assert_output --partial "Issue #17 の作業のブランチ feat/17-old は、PR #5 でマージ済みです"
  # 別のブランチ（もう残っていない）や、フォーク・別のリポジトリのマージ済みの PR は、使い回すブランチには関係しない
  for spec in 5:MERGED:feat/17-other 5:MERGED:feat/17-old:me/demo:true 5:MERGED:feat/17-old:other/demo; do
    link_prs "$spec"
    run_check --issue 17
    assert_equal "$(jq -c '[.action, .resume.branch]' <<<"$output")" '["proceed","feat/17-old"]'
  done
  # 参照に repository が無くても、フォークでなければ今のリポジトリの PR として扱う
  link_prs 5:MERGED:feat/17-old:none
  run_check --issue 17
  assert_output --partial "PR #5 でマージ済みです"
}

@test "Issue を閉じるフォークか別のリポジトリの PR が開いていれば、ブランチ名が同じでも hold（参照に repository が無ければ isCrossRepository で決める）" {
  setup_auto
  git branch feat/17-x
  for spec in 6:OPEN:feat/17-x:me/demo:true 6:OPEN:feat/17-x:other/demo; do
    link_prs "$spec"
    run_check --issue 17
    assert_equal "$(jq -c '[.action, .resume]' <<<"$output")" '["hold",null]'
    assert_output --partial "Issue #17 を閉じる PR #6 が、フォーク（別のリポジトリ）から開いています"
  done
  for spec in 6:OPEN:feat/17-x 6:OPEN:feat/17-x:none; do
    link_prs "$spec"
    run_check --issue 17
    assert_equal "$(jq -c '[.action, .resume.branch]' <<<"$output")" '["proceed","feat/17-x"]'
  done
}

@test "Issue の本文が長くても（引数の長さの上限の 128 KiB を超えても）止まらない" {
  setup_auto
  long_text "$TMP/long"
  fake_issue_body 17 "${BODY/なし/$(cat "$TMP/long")}"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons, (.issue.body | length > 60000)]' <<<"$output")" '["proceed",[],true]'
}

@test "labels.types が文字列の配列でなければ、設定の誤りの1行と終了コード 2 で止まる" {
  setup_auto
  for v in '"xfeat"' null 5 '[1]' '["feat", null]'; do
    set_config ".labels.types = $v"
    run_check --issue 17
    assert_failure 2
    assert_output --partial "error: labels.types（$(jq -nc "$v")）が文字列の配列ではありません。設定を直してください"
    refute_output --partial "Cannot iterate"
    assert_equal "${#lines[@]}" 1
  done
}

@test "auto.enabled が true でなければ、labels.types が壊れていても何もしない（無効のリポジトリは設定の誤りで止まらない）" {
  setup_fake_gh
  set_config '. + {auto: {enabled: false}, labels: {types: "x"}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" disabled
}
