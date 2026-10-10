#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

PLUGIN_REVIEW="$(cd "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review" && pwd)"

# 使い方: perspective <ディレクトリ> <名前> <title> [本文]
perspective() {
  mkdir -p "$1"
  printf -- '---\ntitle: %s\n---\n\n%s\n' "$3" "${4:-指示を書く}" >"$1/$2.md"
}

# 使い方: names <jq のパス> → 名前を1行ずつ
names() { jq -r "$1[].name" <<<"$output"; }

@test "同梱の観点はどれも形式に合う" {
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq '.invalid' <<<"$output")" "[]"
  for f in "$PLUGIN_REVIEW"/*.md; do
    jq -e --arg n "$(basename "$f" .md)" '.perspectives | any(.name == $n and .layer == "plugin")' <<<"$output" >/dev/null \
      || fail "$f が perspectives にありません"
  done
}

@test "3つの層の観点を合わせ、名前の順に出力する" {
  mark_set_up
  perspective "$WORKFLOW_USER_DIR/review" zz-user "ユーザーの観点"
  perspective "$REPO/.claude/dev-workflow/review" aa-repo "リポジトリの観点"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '.perspectives[] | select(.name == "zz-user") | [.title, .layer, .path, .overrides]' <<<"$output")" \
    "[\"ユーザーの観点\",\"user\",\"$WORKFLOW_USER_DIR/review/zz-user.md\",[]]"
  assert_equal "$(jq -r '.perspectives[] | select(.name == "aa-repo") | .layer' <<<"$output")" repo
  assert_equal "$(names .perspectives)" "$(names .perspectives | LC_ALL=C sort)"
}

@test "同じ名前の観点は上位の層のファイルを使い、上書きしたパスを残す" {
  mark_set_up
  perspective "$WORKFLOW_USER_DIR/review" docs-sync "ユーザーの版"
  perspective "$REPO/.claude/dev-workflow/review" docs-sync "リポジトリの版"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '[.perspectives[] | select(.name == "docs-sync")] | length' <<<"$output")" 1
  assert_equal "$(jq -c '.perspectives[] | select(.name == "docs-sync") | [.title, .layer, .overrides]' <<<"$output")" \
    "[\"リポジトリの版\",\"repo\",[\"$PLUGIN_REVIEW/docs-sync.md\",\"$WORKFLOW_USER_DIR/review/docs-sync.md\"]]"
}

@test "enabled: false で下位の層の観点を止める（本文と title は省ける）" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\nenabled: false\n---\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  jq -e '.perspectives | all(.name != "docs-sync")' <<<"$output" >/dev/null || fail "docs-sync が止まっていません"
  assert_equal "$(jq -c '.disabled' <<<"$output")" \
    "[{\"name\":\"docs-sync\",\"layer\":\"repo\",\"path\":\"$REPO/.claude/dev-workflow/review/docs-sync.md\",\"overrides\":[\"$PLUGIN_REVIEW/docs-sync.md\"]}]"
}

@test "上位の層で enabled: true にすると、止めた観点を戻せる" {
  mkdir -p "$WORKFLOW_USER_DIR/review"
  printf -- '---\nenabled: false\n---\n' >"$WORKFLOW_USER_DIR/review/docs-sync.md"
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: "戻す"\nenabled: true\n---\n本文\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "docs-sync") | .title' <<<"$output")" "戻す"
  assert_equal "$(jq -c '.disabled' <<<"$output")" "[]"
}

@test "形式の誤ったファイルは警告して invalid に入れ、ほかの観点は使う" {
  d="$REPO/.claude/dev-workflow/review"
  perspective "$d" ok "使う"
  perspective "$d" Bad_Name "名前の誤り"
  printf 'frontmatter が無い\n' >"$d/no-fm.md"
  printf -- '---\ntitle: 閉じていない\n' >"$d/unclosed.md"
  printf -- '---\nenabled: no\ntitle: x\n---\n本文\n' >"$d/bad-enabled.md"
  printf -- '---\ntitle:\n---\n本文\n' >"$d/no-title.md"
  printf -- '---\ntitle: 本文が無い\n---\n\n  \n' >"$d/no-body.md"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.layer == "repo") | .name' <<<"$output")" ok
  assert_equal "$(jq -r '.invalid[] | "\(.path | split("/") | last) \(.reason)"' <<<"$output" | LC_ALL=C sort)" "$(LC_ALL=C sort <<'EOF'
Bad_Name.md ファイル名は小文字の英数字と - だけにしてください
bad-enabled.md enabled は true か false にしてください
no-body.md 本文（レビューの指示）がありません
no-fm.md 先頭に --- で囲んだ frontmatter がありません
no-title.md title がありません
unclosed.md 先頭に --- で囲んだ frontmatter がありません
EOF
)"
  assert_equal "$(grep -c '^warn: 観点ファイルを使いません' "$TMP/err")" 6
}

@test "CRLF の改行と引用符で囲んだ title を読める" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- "---\r\ntitle: 'CRLF の観点'\r\n---\r\n本文\r\n" >"$REPO/.claude/dev-workflow/review/crlf.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "crlf") | .title' <<<"$output")" "CRLF の観点"
}

@test "上位の層のファイルが形式の誤りで使えないときは、下位の層の同じ名前の観点も使わない" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\nenabled: no\n---\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>'$TMP/err'"
  assert_success
  jq -e '.perspectives | all(.name != "docs-sync")' <<<"$output" >/dev/null || fail "下位の層の docs-sync が使われています"
  assert_equal "$(jq -c '.invalid[] | select(.path | endswith("/docs-sync.md")) | .overrides' <<<"$output")" \
    "[\"$PLUGIN_REVIEW/docs-sync.md\"]"
  grep -q "同じ名前の下位の層の観点も使いません: docs-sync" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "先頭に BOM がある観点ファイルを読める" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf '\357\273\277---\ntitle: BOM の観点\n---\n本文\n' >"$REPO/.claude/dev-workflow/review/bom.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "bom") | .title' <<<"$output")" "BOM の観点"
}

@test "リポジトリの外や導入していないリポジトリでは、プラグインの観点だけを出力する（ユーザーの観点は使わない）" {
  perspective "$WORKFLOW_USER_DIR/review" mine "ユーザーの観点"
  cd "$TMP"
  run_script review-perspectives.sh
  assert_success
  jq -e '(.perspectives | any(.name == "mine") | not) and (.perspectives | any(.layer == "plugin"))' <<<"$output" >/dev/null || fail "$output"
  cd "$REPO"
  run_script review-perspectives.sh
  assert_success
  jq -e '(.perspectives | any(.name == "mine") | not) and (.perspectives | any(.layer == "plugin"))' <<<"$output" >/dev/null || fail "$output"
  mark_set_up
  run_script review-perspectives.sh
  assert_success
  jq -e '.perspectives | any(.name == "mine" and .layer == "user")' <<<"$output" >/dev/null || fail "$output"
}

@test "不明な引数は使い方の誤りにする" {
  run_script review-perspectives.sh --foo
  assert_failure 64
  assert_output --partial "不明な引数です: --foo"
}

# 条件で絞り込むテストの準備。基点（init）の後に main へ1つコミットし、work ブランチで <ファイル> を変える
# 使い方: branch_changing <ファイル>...
branch_changing() {
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b work
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    echo x >"$f"
  done
  git add -A
  git commit -q -m change
}

# 使い方: perspective_when <名前> <frontmatter に足す行>
perspective_when() {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: %s\n%b\n---\n本文\n' "$1" "$2" >"$REPO/.claude/dev-workflow/review/$1.md"
}

# 使い方: skipped_reason <名前> → 外した理由（外していなければ空）
skipped_reason() { jq -r --arg n "$1" '.skipped[] | select(.name == $n) | .reason' <<<"$output"; }
used() { jq -e --arg n "$1" '.perspectives | any(.name == $n)' <<<"$output" >/dev/null; }

@test "types に当てはまる観点だけを使い、当てはまらない観点は理由とともに skipped に出す" {
  branch_changing a.txt
  perspective_when only-fix 'types: [fix, perf]'
  perspective_when only-feat 'types: feat'
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  used only-feat || fail "only-feat が使われていません: $output"
  used only-fix && fail "only-fix が外れていません: $output"
  assert_equal "$(skipped_reason only-fix)" "type（feat）が types（fix、perf）のどれでもない"
  assert_equal "$(jq -r '.skipped[] | select(.name == "only-fix") | .layer' <<<"$output")" repo
}

@test "type が分からなければ、types を書いた観点は外す" {
  branch_changing a.txt
  perspective_when only-fix 'types: [fix]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason only-fix)" "type が分からない（types: fix）"
}

@test "paths は差分のファイルのどれかが当たるときだけ使う" {
  branch_changing src/lib/a.sh docs/b.md
  perspective_when shell 'paths: ["**/*.sh"]'
  perspective_when ci 'paths: [".github/**", "*.yml"]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used shell || fail "$output"
  assert_equal "$(skipped_reason ci)" "差分のファイルが paths（.github/**、*.yml）に当たらない"
}

@test "paths は .gitignore と同じ書き方：* は / をまたがず、**/ は0個以上のディレクトリに当たる" {
  branch_changing src/a.ts lib/sub/b.sh
  perspective_when root-sh 'paths: "*.sh"'
  perspective_when star-dir 'paths: "lib/*.sh"'
  perspective_when ts 'paths: "src/**/*.ts"'
  perspective_when lib-all 'paths: "lib/**"'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  [ -n "$(skipped_reason root-sh)" ] || fail "*.sh がルートの外の .sh に当たっています: $output"
  [ -n "$(skipped_reason star-dir)" ] || fail "lib/*.sh が lib/sub/b.sh に当たっています: $output"
  used ts || fail "src/**/*.ts が src/a.ts に当たっていません: $output"
  used lib-all || fail "$output"
}

@test "paths の ! は除外で、除外されないファイルが1つでもあれば使う" {
  branch_changing docs/a.md
  perspective_when not-docs 'paths: ["!docs/**"]'
  perspective_when code 'paths: ["**", "!**/*.md"]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  [ -n "$(skipped_reason not-docs)" ] || fail "$output"
  [ -n "$(skipped_reason code)" ] || fail "$output"
  echo x >b.sh
  git add b.sh
  git commit -q -m code
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used not-docs || fail "$output"
  used code || fail "$output"
}

@test "サブディレクトリで実行しても、paths はリポジトリのルートから当てる" {
  branch_changing src/a.sh
  perspective_when shell 'paths: "src/*.sh"'
  cd src
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used shell || fail "$output"
}

@test "名前を変えたファイルは、元の名前も paths に当てる" {
  mkdir -p old
  echo x >old/a.txt
  git add -A && git commit -q -m add
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b work
  git mv old new
  git commit -q -m rename
  perspective_when old-dir 'paths: old/*'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used old-dir || fail "$output"
}

@test "issue: required は Issue があるときだけ使う" {
  branch_changing a.txt
  perspective_when needs-issue 'issue: required'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason needs-issue)" "Issue が無い（issue: required）"
  run_script review-perspectives.sh --base "$BASE" --target main --issue 12
  assert_success
  used needs-issue || fail "$output"
}

@test "base_ahead: required はマージ先が基点より進んでいるときだけ使う" {
  branch_changing a.txt
  perspective_when drift 'base_ahead: required'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason drift)" "マージ先（main）が基点より進んでいない（base_ahead: required）"
  git checkout -q main
  git commit -q --allow-empty -m later
  git checkout -q work
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used drift || fail "$output"
}

@test "条件を複数書くと、すべてに当てはまるときだけ使う" {
  branch_changing a.sh
  perspective_when both 'types: fix\npaths: "*.md"'
  run_script review-perspectives.sh --base "$BASE" --target main --type fix
  assert_success
  assert_equal "$(skipped_reason both)" "差分のファイルが paths（*.md）に当たらない"
}

@test "条件を書いていない観点と、--base を渡さないときは、条件で外さない" {
  branch_changing a.txt
  perspective_when plain ''
  perspective_when only-fix 'types: fix\nissue: required'
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  used plain || fail "$output"
  run_script review-perspectives.sh
  assert_success
  used only-fix || fail "$output"
  assert_equal "$(jq -c .skipped <<<"$output")" "[]"
}

@test "条件の書き方が誤っていれば invalid に入れる" {
  perspective_when bad-types 'types: [Fix]'
  perspective_when empty-types 'types: []'
  perspective_when empty-paths 'paths:'
  perspective_when bad-issue 'issue: yes'
  perspective_when bad-ahead 'base_ahead: true'
  perspective_when bad-builtin 'builtin: lint'
  perspective_when abs-path 'paths: "/etc/*"'
  perspective_when up-path 'paths: ["!../x"]'
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>/dev/null"
  assert_success
  assert_equal "$(jq -r '.invalid[] | "\(.path | split("/") | last) \(.reason)"' <<<"$output" | LC_ALL=C sort)" "$(LC_ALL=C sort <<'EOF2'
bad-ahead.md base_ahead は required にしてください
bad-builtin.md builtin は code-review にしてください
bad-issue.md issue は required にしてください
bad-types.md types は type の名前（小文字の英数字と -）の一覧にしてください
abs-path.md paths はリポジトリのルートからの相対パスのパターンにしてください（/ で始めない・.. を使わない）: /etc/*
up-path.md paths はリポジトリのルートからの相対パスのパターンにしてください（/ で始めない・.. を使わない）: !../x
empty-paths.md paths にパターンがありません
empty-types.md types に type がありません
EOF2
)"
}

@test "builtin の観点は本文を省け、perspectives に builtin を出す" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: 組み込み\nbuiltin: code-review\n---\n' >"$REPO/.claude/dev-workflow/review/mine.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "mine") | .builtin' <<<"$output")" code-review
  assert_equal "$(jq -r '.perspectives[] | select(.name == "docs-sync") | .builtin' <<<"$output")" null
}

@test "条件で絞り込む引数の誤りは使い方の誤りにし、無い ref は止める" {
  run_script review-perspectives.sh --type fix
  assert_failure 64
  assert_output --partial "--base と --target の両方を渡してください"
  run_script review-perspectives.sh --base HEAD --target HEAD --issue abc
  assert_failure 64
  run_script review-perspectives.sh --base nothing --target HEAD
  assert_failure 2
  assert_output --partial "基点のコミットが見つかりません: nothing"
  run_script review-perspectives.sh --base HEAD --target origin/main
  assert_failure 2
  assert_output --partial "マージ先が見つかりません: origin/main"
}

@test "同梱の観点の条件：regression-test は fix、test-coverage は feat・refactor・perf、issue-requirements は Issue、main-drift はマージ先が進んだときだけ使う" {
  branch_changing a.txt
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  for n in regression-test issue-requirements main-drift; do
    [ -n "$(skipped_reason "$n")" ] || fail "$n が外れていません: $output"
  done
  used test-coverage || fail "$output"
  used code-review || fail "$output"
  used docs-sync || fail "$output"
  for t in refactor perf; do
    run_script review-perspectives.sh --base "$BASE" --target main --type "$t"
    assert_success
    used test-coverage || fail "type が $t で test-coverage が使われていません: $output"
  done
  for t in fix docs test; do
    run_script review-perspectives.sh --base "$BASE" --target main --type "$t"
    assert_success
    assert_equal "$(skipped_reason test-coverage)" "type（${t}）が types（feat、refactor、perf）のどれでもない"
  done
  git checkout -q main
  git commit -q --allow-empty -m later
  git checkout -q work
  run_script review-perspectives.sh --base "$BASE" --target main --type fix --issue 1
  assert_success
  for n in regression-test issue-requirements main-drift; do
    used "$n" || fail "$n が使われていません: $output"
  done
}

@test "同梱の code-review は組み込みのコマンドを呼ぶ印があり、上の層で止められる" {
  run_script review-perspectives.sh
  assert_equal "$(jq -r '.perspectives[] | select(.name == "code-review") | .builtin' <<<"$output")" code-review
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\nenabled: false\n---\n' >"$REPO/.claude/dev-workflow/review/code-review.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.disabled[].name' <<<"$output")" code-review
}

@test "日本語のファイル名も paths のパターンに当てる" {
  branch_changing docs/設計.md
  perspective_when docs 'paths: ["docs/*"]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used docs || fail "$output"
}

# --auto のテストの準備。偽の gh と origin 役の bare リポジトリを用意し、ブランチ <名前> を作って a.txt を変える
# 使い方: auto_branch <ブランチ名>
auto_branch() {
  setup_fake_gh
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b "$1"
  echo x >a.txt
  git add a.txt
  git commit -q -m change
}

@test "--auto は Issue の type ラベルと番号、origin のマージ先と基点を決めて絞り込む" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["fix", "breaking"]'
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c .context <<<"$output")" \
    "{\"base\":\"$BASE\",\"target\":\"origin/main\",\"ahead\":0,\"issue\":17,\"type\":\"fix\",\"type_from\":\"issue\",\"max_rounds\":3,\"model\":null,\"code_review_effort\":null,\"fallback\":null}"
  used regression-test || fail "Issue の type（fix）で regression-test が使われていません: $output"
  used issue-requirements || fail "$output"
  [ -n "$(skipped_reason main-drift)" ] || fail "$output"
}

@test "--auto は、マージ先に後から入ったコミットを fetch して base_ahead を判断する" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  git clone -q "$TMP/origin.git" "$TMP/other"
  git -C "$TMP/other" commit -q --allow-empty -m later
  git -C "$TMP/other" push -q origin main
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.base, .context.ahead]' <<<"$output")" "[\"$BASE\",1]"
  used main-drift || fail "$output"
}

@test "--auto は、開いた PR のマージ先が設定の base_branch と違えば、PR のマージ先をマージ先にする（#284）" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  # origin の release/v1 を、ブランチを作った後の main より1つ進んだ位置に作る
  git clone -q "$TMP/origin.git" "$TMP/other"
  git -C "$TMP/other" switch -q -c release/v1
  git -C "$TMP/other" commit -q --allow-empty -m release
  git -C "$TMP/other" push -q origin release/v1
  echo '[{"baseRefName": "release/v1", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.target, .context.base, .context.ahead]' <<<"$output")" "[\"origin/release/v1\",\"$BASE\",1]"
  assert_equal "$(args pr-list)" "--head feat/17-add-thing --state open --json number,url,baseRefName,isCrossRepository"
  # fork の PR のマージ先は使わない
  echo '[{"baseRefName": "release/v1", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.target, .context.ahead]' <<<"$output")" '["origin/main",0]'
}

@test "--auto は、PR のマージ先を取得できず手元にも無ければ、警告して設定の base_branch で判断する（止めない。#284）" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  # origin に release/v1 が無い
  echo '[{"baseRefName": "release/v1", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.context.target, .context.base, .context.fallback]' <<<"$output")" "[\"origin/main\",\"$BASE\",\"fetch_failed\"]"
  grep -qF "マージ先を origin/main として判断します" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "--auto は、base_branch がダッシュで始まれば、取得せずに止まる（git fetch のオプションとして扱わせない）" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  jq '.base_branch = "-v"' .claude/dev-workflow/config.json >"$TMP/config.json"
  mv "$TMP/config.json" .claude/dev-workflow/config.json
  run_script review-perspectives.sh --auto
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -v"
}

@test "--auto は、Issue の type ラベルが1つに決まらなければブランチ名の type を使う" {
  auto_branch fix/17-bug
  fake_issue 17 '["feat", "fix"]'
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.type, .context.type_from, .context.issue]' <<<"$output")" '["fix","branch",17]'
}

@test "--auto は、Issue が見つからなければ Issue は無いものとし、ブランチ名の type を使う" {
  auto_branch fix/17-bug
  rm "$FIX/issue-17.json"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[null,"fix","branch"]'
  assert_equal "$(skipped_reason issue-requirements)" "Issue が無い（issue: required）"
  grep -q "Issue #17 が見つからないので" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "--auto は、gh で Issue を読めなければ番号は使い、type はブランチ名から決める" {
  auto_branch fix/17-bug
  fake_issue 17 '["feat"]'
  export FAKE_FAIL=issue-view FAKE_FAIL_MSG="HTTP 401: Bad credentials"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[17,"fix","branch"]'
  grep -q "Issue #17 を読めません（HTTP 401: Bad credentials）" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "--auto は、ブランチ名が branch.pattern の形でなければ Issue も type も無いものとする" {
  auto_branch hotfix-typo
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[null,null,null]'
  assert_equal "$(skipped_reason regression-test)" "type が分からない（types: fix）"
}

@test "--auto は、fetch できなくても手元の origin のマージ先で判断し、それも無ければ止まる" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  mv "$TMP/origin.git" "$TMP/gone.git"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  grep -q "origin/main を最新にできませんでした" "$TMP/err" || fail "$(cat "$TMP/err")"
  git update-ref -d refs/remotes/origin/main
  run_script review-perspectives.sh --auto
  assert_failure 2
  assert_output --partial "マージ先が見つかりません: origin/main"
}

@test "--auto はほかの絞り込みの引数と一緒に使えない" {
  run_script review-perspectives.sh --auto --type fix
  assert_failure 64
}

@test "--auto は、branch.pattern に {type} が無くても Issue の番号を読む" {
  auto_branch 17-bug
  echo '{"branch": {"pattern": "{issue_number}-{slug}"}}' >"$REPO/.claude/dev-workflow/config.json"
  fake_issue 17 '["fix"]'
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[17,"fix","issue"]'
}

@test "--auto は、設定の review.max_rounds を context に出す" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  echo '{"review": {"max_rounds": 5}}' >.claude/dev-workflow/config.json
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c .context.max_rounds <<<"$output")" 5
}

@test "--auto は、review.max_rounds が1以上の整数でなければ止まる" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  for v in 0 -1 2.5 '"3"' null true '[]'; do
    echo "{\"review\": {\"max_rounds\": $v}}" >.claude/dev-workflow/config.json
    run_script review-perspectives.sh --auto
    assert_failure 2
    assert_output --partial "review.max_rounds は1以上の整数にしてください"
  done
}

@test "--auto は、設定の review.model を context に出す" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  for v in opus sonnet haiku fable; do
    echo "{\"review\": {\"model\": \"$v\"}}" >.claude/dev-workflow/config.json
    run_script review-perspectives.sh --auto
    assert_success
    assert_equal "$(jq -r .context.model <<<"$output")" "$v"
  done
}

@test "--auto は、review.model が null か使えるモデルの別名でなければ止まる" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  for v in '"gpt"' '"Opus"' '"claude-opus-5-5"' '""' 1 true '["opus"]' '{"model": "opus"}'; do
    echo "{\"review\": {\"model\": $v}}" >.claude/dev-workflow/config.json
    run_script review-perspectives.sh --auto
    assert_failure 2
    assert_output --partial "review.model は null か opus・sonnet・haiku・fable のどれかにしてください"
  done
}

@test "--auto は、ユーザーの層の review.model を、導入したリポジトリでだけ使う" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  echo '{"review": {"model": "opus"}}' >"$WORKFLOW_USER_DIR/config.json"
  rm -f .claude/dev-workflow/config.json
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(json_of "$output" | jq -c .context.model)" null
  mark_set_up
  run_script review-perspectives.sh --auto
  assert_success
  refute_output --partial "warn:"
  assert_equal "$(json_of "$output" | jq -r .context.model)" opus
  # リポジトリの層で決めれば、そちらを使う。local は team より優先する
  echo '{"review": {"model": "haiku"}}' >.claude/dev-workflow/config.json
  echo '{"review": {"model": "sonnet"}}' >.claude/dev-workflow/config.local.json
  run_script review-perspectives.sh --auto
  assert_equal "$(json_of "$output" | jq -r .context.model)" sonnet
}

@test "--auto は、設定の review.code_review_effort を context に出し、既定は null（段階を渡さない）" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c .context.code_review_effort <<<"$output")" null
  for v in low medium high xhigh max; do
    echo "{\"review\": {\"code_review_effort\": \"$v\"}}" >.claude/dev-workflow/config.json
    run_script review-perspectives.sh --auto
    assert_success
    assert_equal "$(jq -r .context.code_review_effort <<<"$output")" "$v"
  done
}

@test "--auto でなければ、context は null で、review.code_review_effort の誤りでは止まらない" {
  echo '{"review": {"code_review_effort": "ultra"}}' >.claude/dev-workflow/config.json
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c .context <<<"$output")" null
}

@test "--auto は、review.code_review_effort が null か low〜max の段階でなければ止まる" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  for v in '"ultra"' '"High"' '"auto"' '""' 3 true '["low"]' '{"effort": "low"}'; do
    echo "{\"review\": {\"code_review_effort\": $v}}" >.claude/dev-workflow/config.json
    run_script review-perspectives.sh --auto
    assert_failure 2
    assert_output --partial "review.code_review_effort は null か low・medium・high・xhigh・max のどれかにしてください"
  done
}

@test "--auto は、review.code_review_effort をユーザーの層（導入したリポジトリだけ）と config.local.json で決められ、local が優先する" {
  auto_branch feat/17-add-thing
  fake_issue 17 '["feat"]'
  echo '{"review": {"code_review_effort": "low"}}' >"$WORKFLOW_USER_DIR/config.json"
  rm -f .claude/dev-workflow/config.json
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(json_of "$output" | jq -c .context.code_review_effort)" null
  mark_set_up
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(json_of "$output" | jq -r .context.code_review_effort)" low
  echo '{"review": {"code_review_effort": "high"}}' >.claude/dev-workflow/config.json
  echo '{"review": {"code_review_effort": "medium"}}' >.claude/dev-workflow/config.local.json
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(json_of "$output" | jq -r .context.code_review_effort)" medium
}

@test "--auto は、ブランチ名の番号が PR の番号なら、Issue は無いものとし、PR のラベルで type を決めない" {
  auto_branch fix/21-bug
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "labels": [{"name": "feat"}]}' >"$FIX/issue-21.json"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[null,"fix","branch"]'
  grep -q "#21 は PR なので、Issue は無いものとして判断します" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "--auto は、ブランチ名の番号が 0 なら止まらずに Issue は無いものとし、017 なら 17 として読む" {
  auto_branch fix/0-bug
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' --auto 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[null,"fix","branch"]'
  grep -q "ブランチ名の番号 0 は Issue の番号として使えないので、Issue は無いものとして判断します" "$TMP/err" || fail "$(cat "$TMP/err")"
  git checkout -q -b fix/017-bug
  fake_issue 17 '["feat"]'
  run_script review-perspectives.sh --auto
  assert_success
  assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[17,"feat","issue"]'
}

@test "--auto は、Issue の type ラベルを大文字と小文字を区別せずに照合し、設定の書き方の type にする" {
  auto_branch 17-bug
  echo '{"branch": {"pattern": "{issue_number}-{slug}"}}' >"$REPO/.claude/dev-workflow/config.json"
  for labels in '["FIX"]' '["FIX", "fix"]'; do
    fake_issue 17 "$labels"
    run_script review-perspectives.sh --auto
    assert_success
    assert_equal "$(jq -c '[.context.issue, .context.type, .context.type_from]' <<<"$output")" '[17,"fix","issue"]'
  done
}

@test "frontmatter に同じキーの行がたくさんあっても（パイプの容量を超えても）、最初の値を読む" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  {
    printf -- '---\ntitle: 最初の title\n'
    yes 'title: 後の title' | head -n 10000
    printf -- '---\n\n指示を書く\n'
  } >"$REPO/.claude/dev-workflow/review/many.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "many") | .title' <<<"$output")" "最初の title"
}

@test "--auto は、branch.pattern が正規表現として正しくなければ、Issue は無いものとせず設定の誤りで終了コード 2" {
  auto_branch feat/17-add-thing
  echo '{"branch": {"pattern": "{type}/{issue_number}-{slug}("}}' >.claude/dev-workflow/config.json
  run_script review-perspectives.sh --auto
  assert_failure 2
  assert_output --partial "正規表現として正しくありません"
}

@test "ホームのリポジトリでは、ユーザーの層の観点を、ユーザーの層としてもリポジトリの層としても使わない" {
  make_home_repo
  mkdir -p "$WORKFLOW_USER_DIR/review"
  printf -- '---\ntitle: 自分の観点\n---\n\n本文\n' >"$WORKFLOW_USER_DIR/review/mine.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '[.perspectives[] | select(.name == "mine")] | length' <<<"$output")" 0
}

@test "paths のパターンに絵文字があっても（4096 バイトを超える1行でも）壊さずに読む" {
  # 標準入力の jq -Rsc は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  branch_changing a.txt
  pattern="$(emoji_text 1500)"
  perspective_when emoji-path "paths: \"${pattern}\""
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason emoji-path)" "差分のファイルが paths（${pattern}）に当たらない"
}
