#!/usr/bin/env bats
# repair-author.sh（無人で指摘に対応してよい投稿者か）のテスト（#341、ADR 000285）。
# 設定 repair.allowed_authors・権限（write 以上・read・コラボレーターでない・API の失敗）の組み合わせを、偽の gh で確かめる。

load test_helper

setup() {
  test_helper_setup
  mark_set_up
  mkdir -p "$TMP/bin" "$TMP/fix"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >>"$TMP/calls"
who="${2##*/collaborators/}"; who="${who%%/*}"
if [ -f "$TMP/fix/role-$who" ]; then cat "$TMP/fix/role-$who"
elif [ -f "$TMP/fix/error-$who" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1
else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
SH
  chmod +x "$TMP/bin/gh"
  export TMP PATH="$TMP/bin:$PATH"
  : >"$TMP/calls"
  echo '{"repair": {"allowed_authors": ["Review-Bot[bot]"]}}' >"$REPO/.claude/dev-workflow/config.json"
}

teardown() { rm -rf "$TMP"; }

@test "設定 repair.allowed_authors の投稿者は、大文字小文字と [bot] の有無によらず許可し、権限は調べない" {
  for l in 'review-bot[bot]' 'REVIEW-BOT' 'Review-Bot[bot]'; do
    run "$SCRIPTS/repair-author.sh" --login "$l"
    assert_success
    [ "$(jq -r '[.action, .reason, .role] | @tsv' <<<"$output")" = $'allow\tallowed_authors\t' ] || fail "$l: $output"
  done
  [ ! -s "$TMP/calls" ]
}

@test "write 以上の人（admin・maintain・write）は許可する" {
  for r in admin maintain write; do
    echo "$r" >"$TMP/fix/role-person"
    run "$SCRIPTS/repair-author.sh" --login person --repo me/demo
    assert_success
    [ "$(jq -r '[.action, .reason, .role] | @tsv' <<<"$output")" = "allow	role	$r" ] || fail "$r: $output"
  done
  grep -q 'repos/me/demo/collaborators/person/permission' "$TMP/calls"
}

@test "triage・read の人は許可しない" {
  for r in triage read; do
    echo "$r" >"$TMP/fix/role-person"
    run "$SCRIPTS/repair-author.sh" --login person
    assert_success
    [ "$(jq -r '[.action, .reason, .role] | @tsv' <<<"$output")" = "deny	no_permission	$r" ] || fail "$r: $output"
  done
}

@test "コラボレーターでない人（404）は権限なし（none）として許可しない" {
  run "$SCRIPTS/repair-author.sh" --login stranger
  assert_success
  [ "$(jq -r '[.action, .role] | @tsv' <<<"$output")" = $'deny\tnone' ]
}

@test "404 以外で権限を読めないときは、権限なしと取り違えず失敗にする" {
  touch "$TMP/fix/error-flaky"
  run "$SCRIPTS/repair-author.sh" --login flaky
  [ "$status" -eq 1 ]
  [[ "$output" == *'権限を読めません'* ]]
}

@test "設定が無ければ、許可するのは write 以上の人だけ" {
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  echo write >"$TMP/fix/role-person"
  run "$SCRIPTS/repair-author.sh" --login person
  [ "$(jq -r .action <<<"$output")" = allow ]
  run "$SCRIPTS/repair-author.sh" --login 'review-bot[bot]'
  [ "$(jq -r .action <<<"$output")" = deny ]
}

@test "設定 repair.allowed_authors が文字列の配列でなければ終了コード 2" {
  echo '{"repair": {"allowed_authors": "x"}}' >"$REPO/.claude/dev-workflow/config.json"
  run "$SCRIPTS/repair-author.sh" --login person
  [ "$status" -eq 2 ]
}

@test "引数の誤りは終了コード 64" {
  run "$SCRIPTS/repair-author.sh"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/repair-author.sh" --login
  [ "$status" -eq 64 ]
  run "$SCRIPTS/repair-author.sh" --nope
  [ "$status" -eq 64 ]
}

@test "--login がログイン名の形（英数字・ハイフン・_ 、bot は末尾に [bot]）でなければ、API を呼ばずに終了コード 64" {
  for l in '../x' 'a/b' 'a b' '-a' '_a' 'a;b' 'a[bot]x' 'a?b=1' '[bot]' 'a.b' 'a%2Fb' 'a[bot' 'あ'; do
    run "$SCRIPTS/repair-author.sh" --login "$l"
    [ "$status" -eq 64 ] || fail "${l}: status ${status}"
  done
  [ ! -s "$TMP/calls" ]
}

@test "--login が有効な形（_ を含む Enterprise Managed User・数字だけ・末尾のハイフン・[bot]）なら、API を呼んで判定する" {
  for l in alice_acme a1 123 a-b a- a_b_c 'a-b[bot]' A; do
    run "$SCRIPTS/repair-author.sh" --login "$l"
    assert_success
    [ "$(jq -r .action <<<"$output")" = deny ] || fail "${l}: $output"
  done
  [ "$(grep -c 'permission' "$TMP/calls")" = 8 ]
  echo write >"$TMP/fix/role-alice_acme"
  run "$SCRIPTS/repair-author.sh" --login alice_acme
  [ "$(jq -r .action <<<"$output")" = allow ]
}
