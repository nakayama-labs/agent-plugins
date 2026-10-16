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
  [[ "$line" != *'env.REVIEW_DIR'* ]] || return 1
  [[ "$line" != *'//'* ]] || return 1
  [[ "$line" != *'**'* ]] || return 1
  [[ "$line" == *'Write(/.claude-review/review.md)'* ]] || return 1
  [[ "$line" == *'Edit(/.claude-review/review.md)'* ]]
}

@test "REVIEW_DIR は、許可の規則が指す .claude-review ディレクトリと同じ" {
  grep -qE 'REVIEW_DIR: \$\{\{ github.workspace \}\}/\.claude-review$' "$WF"
}

@test "プロンプトは review.md を相対パスで指し、絶対パスの REVIEW_DIR を使わない" {
  grep -q '\.claude-review/review\.md' "$WF"
  range="$(sed -n '/^        id: claude/,/^      - name:/p' "$WF")"
  # 範囲が空だと何も確かめずに通るので、範囲にプロンプトの review.md の指定があることを先に確かめる
  [[ "$range" == *'.claude-review/review.md'* ]] || return 1
  [[ "$range" != *REVIEW_DIR* ]]
}

@test "review.md が無いときの失敗は、ディレクトリの内容と拒否された操作を出す" {
  # shellcheck disable=SC2016 # $REVIEW_DIR はワークフローの文字そのものを探す（展開しない）
  grep -qF 'ls -la "$REVIEW_DIR"' "$WF"
  grep -q 'permission_denials' "$WF"
  grep -q 'steps.claude.outputs.execution_file' "$WF"
}

# ワークフローから、jq のフィルタ（変数 $1 に代入している複数行の文字列）を取り出す。
# 引用符は awk に -v で渡す（\x27 の解釈は awk の実装で違うため）。取り出せなければテストを落とす
extract_filter() {
  local out
  out="$(awk -v name="$1" -v q="'" '
    !on && index($0, name "=" q) { sub(".*" name "=" q, ""); on = 1 }
    on { if (substr($0, length($0), 1) == q) { print substr($0, 1, length($0) - 1); exit } print }
  ' "$WF")"
  [ -n "$out" ] || { echo "フィルタ $1 を取り出せません" >&2; return 1; }
  printf '%s\n' "$out"
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
  [[ "$output" != *SECRET* ]] || return 1
  # 生の先頭を出す書き方は使わない
  if grep -q 'head -c' "$WF"; then return 1; fi
}

@test "配列の途中の要素が想定外でも、診断は前の要素の内容を出さず、形だけを出す" {
  # ワークフローの手順と同じく、フィルタの出力を変数に取り、成功したときだけ出す
  filter="$(extract_filter denials_filter)"
  shape="$(extract_filter shape_filter)"
  echo '[{"type":"result","permission_denials":[{"tool_name":"Write","tool_input":"SECRET-PROMPT"}]},"oops"]' >"$TMP/exec.json"
  if jq -c "$filter" "$TMP/exec.json" >/dev/null 2>&1; then return 1; fi
  run jq -c "$shape" "$TMP/exec.json"
  [ "$status" -eq 0 ]
  [ "$output" = '["object","string"]' ]
  # ワークフローが、成功したときだけ変数から出す書き方になっている
  # shellcheck disable=SC2016
  grep -qF 'if denials=$(jq -c "$denials_filter" "$EXECUTION_FILE"); then' "$WF"
}

# 見回りが、CodeRabbit がコメントだけで結果（指摘なしを含む）を返した PR を未レビューと数えない（#404）
@test "見回りは、CodeRabbit のレビューも、上限以外のコメントも無い PR だけを拾う" {
  reviews="$(extract_filter reviews_filter)"
  comments="$(extract_filter comments_filter)"
  [ "$(echo '[]' | jq -s "$reviews")" = 0 ]
  [ "$(echo '[]' | jq -s "$comments")" = 0 ]
  # 指摘なしをコメントで返した（PR #403 の形）
  c='[{"user":{"login":"coderabbitai[bot]"},"body":"No actionable comments were generated."}]'
  [ "$(echo "$c" | jq -s "$comments")" = 1 ]
  # 上限のコメントはレビューではないので数えない
  r='[{"user":{"login":"coderabbitai[bot]"},"body":"rate limited by coderabbit.ai"}]'
  [ "$(echo "$r" | jq -s "$comments")" = 0 ]
  # 別の人のコメントは数えない
  o='[{"user":{"login":"someone"},"body":"LGTM"}]'
  [ "$(echo "$o" | jq -s "$comments")" = 0 ]
  # PR のレビューは従来どおり数える
  [ "$(echo '[{"user":{"login":"coderabbitai[bot]"}}]' | jq -s "$reviews")" = 1 ]
}

@test "見回りは、レビューの件数とコメントの件数の両方が0のときだけ PR を選ぶ" {
  # shellcheck disable=SC2016
  grep -qF 'issues/${n}/comments' "$WF"
  # shellcheck disable=SC2016
  grep -qF 'if [ "$reviewed" -eq 0 ] && [ "$commented" -eq 0 ]; then' "$WF"
}

@test "見回りは、レビューがあるときはコメントを取らない（reviewed が 0 のときだけ取る）" {
  # shellcheck disable=SC2016
  grep -qF 'commented=0' "$WF"
  # shellcheck disable=SC2016
  range="$(sed -n '/^              if \[ "\$reviewed" -eq 0 \]; then$/,/^              fi$/p' "$WF")"
  # shellcheck disable=SC2016
  [[ "$range" == *'issues/${n}/comments'* ]]
}
