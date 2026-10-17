#!/usr/bin/env bats
# .github/scripts/pr-repair-config.sh（pr-repair.yml が書く config.local.json）のテスト（#341）。
# find ジョブと repair ジョブが同じ内容を書くので、中身を1か所で確かめる。

load test_helper

setup() {
  test_helper_setup
  CFG="$BATS_TEST_DIRNAME/../.github/scripts/pr-repair-config.sh"
}

teardown() { rm -rf "$TMP"; }

@test "見回りを有効にし、作成者と返信の投稿者を App のログイン名にして、許可する投稿者を配列にする" {
  APP_SLUG=task-app ALLOWED_AUTHORS='a[bot], b ,,c' run "$CFG" "$TMP/out.json"
  assert_success
  [ "$(jq -c . "$TMP/out.json")" = '{"repair":{"enabled":true,"allowed_authors":["a[bot]","b","c"],"bot_logins":["task-app[bot]"],"reply_logins":["task-app[bot]"]}}' ]
}

@test "許可する投稿者が空なら、空の配列" {
  APP_SLUG=task-app ALLOWED_AUTHORS='' run "$CFG" "$TMP/out.json"
  assert_success
  [ "$(jq -c .repair.allowed_authors "$TMP/out.json")" = '[]' ]
}

@test "書いた設定は、config.sh が読め、pr-watch.sh の検査（repair.* の型）に通る形になる" {
  mark_set_up
  APP_SLUG=task-app ALLOWED_AUTHORS='review-bot[bot]' "$CFG" "$REPO/.claude/dev-workflow/config.local.json"
  [ "$("$SCRIPTS/config.sh" '.repair | [.enabled, .allowed_authors, .reply_logins]' | jq -c .)" = '[true,["review-bot[bot]"],["task-app[bot]"]]' ]
}

@test "APP_SLUG が無い・出力先が無いときは失敗する" {
  run "$CFG" "$TMP/out.json"
  [ "$status" -ne 0 ]
  APP_SLUG=x run "$CFG"
  [ "$status" -eq 64 ]
}
