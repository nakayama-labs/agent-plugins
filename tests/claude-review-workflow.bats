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
  range="$(sed -n '/^        id: claude/,/^      - name:/p' "$WF")"
  # 範囲が空だと何も確かめずに通るので、範囲にプロンプトの review.md の指定があることを先に確かめる
  [[ "$range" == *'.claude-review/review.md'* ]]
  [[ "$range" != *REVIEW_DIR* ]]
}

@test "review.md が無いときの失敗は、ディレクトリの内容と拒否された操作を出す" {
  # shellcheck disable=SC2016 # $REVIEW_DIR はワークフローの文字そのものを探す（展開しない）
  grep -qF 'ls -la "$REVIEW_DIR"' "$WF"
  grep -q 'permission_denials' "$WF"
  grep -q 'steps.claude.outputs.execution_file' "$WF"
}

# ワークフローから、jq のフィルタ（変数 $1 に代入している複数行の文字列）を取り出す
extract_filter() {
  awk -v name="$1" '
    index($0, name "=\x27") { sub(".*" name "=\x27", ""); on = 1 }
    on { if (sub(/\x27$/, "")) { print; exit } print }
  ' "$WF"
}

@test "診断のフィルタは、拒否された操作の tool_name と300文字に切った tool_input を出す" {
  filter="$(extract_filter denials_filter)"
  long="$(printf 'x%.0s' $(seq 1 500))"
  echo "[{\"type\":\"system\"},{\"type\":\"result\",\"permission_denials\":[{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/a\",\"content\":\"$long\"}}]}]" >"$TMP/exec.json"
  run jq -c "$filter" "$TMP/exec.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tool_name <<<"$output")" = Write ]
  [ "$(jq -r '.tool_input | length' <<<"$output")" = 300 ]
}

@test "想定外の形（オブジェクト）では、診断のフィルタは失敗し、形のフィルタは中身を出さない" {
  filter="$(extract_filter denials_filter)"
  shape="$(extract_filter shape_filter)"
  echo '{"prompt":"SECRET-PROMPT","x":1}' >"$TMP/exec.json"
  if jq -c "$filter" "$TMP/exec.json" 2>/dev/null; then return 1; fi
  run jq -c "$shape" "$TMP/exec.json"
  [ "$status" -eq 0 ]
  [ "$output" = '"object"' ]
  [[ "$output" != *SECRET* ]]
  # 生の先頭を出す書き方は使わない
  if grep -q 'head -c' "$WF"; then return 1; fi
}
