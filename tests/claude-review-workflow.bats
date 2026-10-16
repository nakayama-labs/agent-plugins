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

# --- 見回り（find ジョブの schedule の run）を、偽の gh で実際に動かして確かめる（#404）---

# find ジョブの「レビューする PR を選ぶ」の run のスクリプトを取り出す（インデント10字を除く）。取り出せなければ落とす
extract_find_script() {
  local out
  out="$(awk '
    !on && /^        id: find$/ { f = 1 }
    f && !on && /^        run: \|$/ { on = 1; next }
    on { if ($0 != "" && substr($0, 1, 10) != "          ") exit; print substr($0, 11) }
  ' "$WF")"
  [ -n "$out" ] || { echo "find の run を取り出せません" >&2; return 1; }
  printf '%s\n' "$out"
}

# 偽の gh：api --paginate のパスを $CALLS に記録し、PR の一覧と、PR ごとのレビュー・コメントを $FIX から返す
setup_patrol() {
  FIX="$TMP/fix"; CALLS="$TMP/calls"
  export FIX CALLS GITHUB_REPOSITORY=me/demo EVENT_NAME=schedule STALE_MINUTES=60 GITHUB_OUTPUT="$TMP/out"
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"; : >"$GITHUB_OUTPUT"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "api --paginate" ] || { echo "unexpected gh: $*" >&2; exit 1; }
path="$3"
echo "$path" >>"$CALLS"
case "$path" in
  *"/pulls?state=open"*) cat "$FIX/pulls.json" ;;
  */pulls/*/reviews) n="${path#*/pulls/}"; n="${n%/reviews}"; cat "$FIX/reviews-$n.json" 2>/dev/null || echo '[]' ;;
  */issues/*/comments) n="${path#*/issues/}"; n="${n%/comments}"; cat "$FIX/comments-$n.json" 2>/dev/null || echo '[]' ;;
  *) echo "unexpected path: $path" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  # PR 1〜4 は、作ってから十分に経つ、同じリポジトリの、下書きでない PR
  echo '[[1,2,3,4,5]]' | jq -c '.[0] | map({number: ., draft: false, created_at: "2020-01-01T00:00:00Z",
    head: {ref: "feature/x", repo: {full_name: "me/demo"}}})' >"$FIX/pulls.json"
  # 2：CodeRabbit のレビューがある
  echo '[{"user":{"login":"coderabbitai[bot]"}}]' >"$FIX/reviews-2.json"
  # 3：レビューは無いが、指摘なしの要約をコメントで返した（PR #403 の形）
  echo '[{"user":{"login":"coderabbitai[bot]"},"body":"No actionable comments were generated."}]' >"$FIX/comments-3.json"
  # 4：上限のコメントだけ
  echo '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->  > Rate limit exceeded"}]' >"$FIX/comments-4.json"
  # 5：上限の文言を引用しただけの要約のコメント（PR #407 の形）。レビュー済みと数える
  echo '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai --> the text rate limited by coderabbit.ai is quoted"}]' >"$FIX/comments-5.json"
}

run_patrol() {
  extract_find_script >"$TMP/find.sh"
  bash "$TMP/find.sh"
}

@test "見回りは、CodeRabbit のレビューも上限以外のコメントも無い PR（1・4）だけを選び、上限の文言を引用しただけの要約のコメントがある 5 は選ばない" {
  setup_patrol
  run_patrol
  [ "$(sed -n 's/^prs=//p' "$GITHUB_OUTPUT")" = '[1,4]' ]
}

@test "見回りは、CodeRabbit のレビューがある PR の comments を取らない" {
  setup_patrol
  run_patrol
  # 2 にはレビューがあるので comments を呼ばない。レビューが無い 1・3・4 は呼ぶ
  if grep -q '/issues/2/comments' "$CALLS"; then return 1; fi
  grep -q '/issues/1/comments' "$CALLS"
  grep -q '/issues/3/comments' "$CALLS"
  grep -q '/issues/4/comments' "$CALLS"
}

@test "見回りは、コメント取得を常に行うように壊すと、レビューがある PR の comments を取って落ちる（テストの確認）" {
  setup_patrol
  # 取得の条件（if [ "$reviewed" -eq 0 ]; then ... fi）を外した版を作る
  extract_find_script | awk '
    /^ *if \[ "\$reviewed" -eq 0 \]; then$/ && !d { d = 1; next }
    d == 1 && /^ *fi$/ { d = 2; next }
    { print }' >"$TMP/broken.sh"
  bash "$TMP/broken.sh"
  grep -q '/issues/2/comments' "$CALLS"
}

@test "issue_comment の起動は、本文が上限の目印で始まるコメントだけで、本文のどこかの部分一致では起動しない" {
  cond="$(sed -n '/^  find:/,/runs-on/p' "$WF")"
  [[ "$cond" == *"startsWith(github.event.comment.body, '<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->')"* ]] || return 1
  [[ "$cond" != *"contains(github.event.comment.body"* ]]
}

@test "上限の文言の部分一致（contains）で上限のコメントを判定する箇所は無い" {
  run grep -rnE 'contains\(.*rate limited by coderabbit' "$WF"
  [ "$status" -eq 1 ]
}
