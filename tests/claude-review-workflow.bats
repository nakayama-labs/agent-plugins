#!/usr/bin/env bats
# claude-review.yml で Claude が review.md を書けるように、許可の規則とプロンプトのパスの書き方を確かめる（#405）。
# 絶対パス（//home/runner/...）の Write の規則は、実行で拒否されて review.md が作られないことがあった。

load test_helper

setup() {
  test_helper_setup
  mark_set_up
  WF="$BATS_TEST_DIRNAME/../.github/workflows/claude-review.yml"
}

@test "allowedTools の書き込みの許可は、review.md の1ファイルだけを相対パスで指し、Write と Edit の両方がある" {
  line="$(grep -- '--allowedTools' "$WF")"
  [[ "$line" != *'env.REVIEW_DIR'* ]]
  [[ "$line" != *'//'* ]]
  [[ "$line" != *'**'* ]]
  [[ "$line" == *'Write(/.claude-review/review.md)'* ]]
  [[ "$line" == *'Edit(/.claude-review/review.md)'* ]]
}

@test "REVIEW_DIR は、許可の規則が指す .claude-review ディレクトリと同じ" {
  grep -qE 'REVIEW_DIR: \$\{\{ github.workspace \}\}/\.claude-review$' "$WF"
}

@test "プロンプトは review.md を相対パスで指し、絶対パスの REVIEW_DIR を使わない" {
  grep -q '\.claude-review/review\.md' "$WF"
  run bash -c "sed -n '/^        id: claude/,/^      - name:/p' '$WF' | grep -c 'REVIEW_DIR'"
  [ "$output" = 0 ]
}

@test "review.md が無いときの失敗は、ディレクトリの内容と拒否された操作を出す" {
  # shellcheck disable=SC2016 # $REVIEW_DIR はワークフローの文字そのものを探す（展開しない）
  grep -qF 'ls -la "$REVIEW_DIR"' "$WF"
  grep -q 'permission_denials' "$WF"
  grep -q 'steps.claude.outputs.execution_file' "$WF"
}

@test "診断は tool_input を切り詰め、jq が失敗したら execution_file の先頭を出す" {
  grep -qF '.[0:300]' "$WF"
  # shellcheck disable=SC2016
  grep -qF 'head -c 2000 "$EXECUTION_FILE"' "$WF"
}
