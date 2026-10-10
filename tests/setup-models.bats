#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

TEAM=.claude/dev-workflow/config.json
LOCAL=.claude/dev-workflow/config.local.json

# 標準エラーの警告の後ろに出る JSON だけを取り出す
# macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
json_of() { printf '%s\n' "$1" | LC_ALL=C sed -n '/^{/,$p'; }

@test "オプションが無ければ、どの層でも決めていないことを出力し、何も書かない" {
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .review.layers, .file, .changed]' <<<"$output")" '[null,false,[],null,false]'
  [ ! -e "$TEAM" ] && [ ! -e "$LOCAL" ]
}

@test "null に決めた層があれば、オフに決めたとみなす" {
  echo '{"review": {"model": null}}' >"$LOCAL"
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, (.review.layers | map(.layer))]' <<<"$output")" '[null,true,["local"]]'
}

@test "team の層には、ほかの項目を残してリポジトリの config.json に書き、config.sh に効く" {
  echo '{"language": "en", "review": {"max_rounds": 5}}' >"$TEAM"
  run_script setup/setup-models.sh --review-model sonnet --scope team
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .changed, .file]' <<<"$output")" \
    "[\"sonnet\",true,true,\"$REPO/$TEAM\"]"
  assert_equal "$(jq -c . "$TEAM")" '{"language":"en","review":{"max_rounds":5,"model":"sonnet"}}'
  run_script config.sh .review.model
  assert_output sonnet
}

@test "ユーザーの層（~/.claude/dev-workflow/config.json）で決めた値は、導入したリポジトリでだけ決めたとみなす" {
  echo '{"review": {"model": "opus"}}' >"$WORKFLOW_USER_DIR/config.json"
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .review.layers]' <<<"$output")" '[null,false,[]]'
  mark_set_up
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .review.layers]' <<<"$output")" \
    "[\"opus\",true,[{\"layer\":\"user\",\"file\":\"$WORKFLOW_USER_DIR/config.json\",\"model\":\"opus\"}]]"
  # リポジトリの層に書けば、ユーザーの層より優先される（効かないという警告は出さない）
  run_script setup/setup-models.sh --review-model sonnet --scope local
  assert_success
  refute_output --partial "効きません"
  assert_equal "$(json_of "$output" | jq -c '[.review.model, [.review.layers[].layer]]')" '["sonnet",["user","local"]]'
}

@test "ユーザーの層（~/.claude/dev-workflow/config.json）には書けない" {
  echo '{"review": {"model": "opus"}}' >"$WORKFLOW_USER_DIR/config.json"
  run_script setup/setup-models.sh --review-model sonnet --scope user
  assert_failure 64
  assert_output --partial "--scope は local・team のどちらかにしてください: user"
  assert_equal "$(jq -c . "$WORKFLOW_USER_DIR/config.json")" '{"review":{"model":"opus"}}'
}

@test "local の層には、ワークツリーの中でもメインのワークツリーの config.local.json に書く" {
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script setup/setup-models.sh --review-model fable --scope local
  assert_success
  assert_equal "$(jq -c . "$REPO/$LOCAL")" '{"review":{"model":"fable"}}'
  [ ! -e "$TMP/wt/$LOCAL" ]
  run_script config.sh .review.model
  assert_output fable
}

@test "off は null を書き、セッションと同じモデルに戻す" {
  echo '{"review": {"model": "opus"}}' >"$LOCAL"
  run_script setup/setup-models.sh --review-model off --scope local
  assert_success
  assert_equal "$(jq -c . "$LOCAL")" '{"review":{"model":null}}'
  assert_equal "$(json_of "$output" | jq -c '[.review.model, .review.decided, .changed]')" '[null,true,true]'
}

@test "既に同じ値なら書き直さない" {
  printf '{ "review" : { "model" : "haiku" } }\n' >"$TEAM"
  before="$(cat "$TEAM")"
  run_script setup/setup-models.sh --review-model haiku --scope team
  assert_success
  assert_equal "$(jq -c '[.changed, .actions]' <<<"$output")" '[false,[]]'
  assert_equal "$(cat "$TEAM")" "$before"
}

@test "キーが無い層に off を選ぶと、null を書く（決めていないことと区別する）" {
  echo '{"review": {"max_rounds": 2}}' >"$TEAM"
  run_script setup/setup-models.sh --review-model off --scope team
  assert_success
  assert_equal "$(jq -c . "$TEAM")" '{"review":{"max_rounds":2,"model":null}}'
  assert_equal "$(jq -r .changed <<<"$output")" true
}

@test "dry-run では書かずに、予定だけを出力する" {
  run_script setup/setup-models.sh --review-model opus --scope team --dry-run
  assert_success
  [ ! -e "$TEAM" ]
  assert_equal "$(jq -c '[.dry_run, .changed, .review.model, (.actions | length)]' <<<"$output")" '[true,true,"opus",1]'
  assert_equal "$(jq -r '.actions[0]' <<<"$output")" "$REPO/$TEAM の review.model を opus にする"
}

@test "上位の層が別の値を決めていれば、書いても効かないことを警告する" {
  echo '{"review": {"model": "haiku"}}' >"$LOCAL"
  run_script setup/setup-models.sh --review-model opus --scope team
  assert_success
  assert_output --partial "warn: $REPO/$LOCAL の review.model（haiku）が優先されるので、書いた値は効きません"
  assert_equal "$(json_of "$output" | jq -r .review.model)" haiku
}

@test "使えないモデル・層の指定の誤りは、使い方の誤り（64）で止まり、何も書かない" {
  run_script setup/setup-models.sh --review-model gpt --scope team
  assert_failure 64
  assert_output --partial "--review-model は off か opus・sonnet・haiku・fable のどれかにしてください: gpt"
  run_script setup/setup-models.sh --review-model opus
  assert_failure 64
  assert_output --partial "--scope（local・team）が要ります"
  run_script setup/setup-models.sh --review-model opus --scope repo
  assert_failure 64
  run_script setup/setup-models.sh --scope team
  assert_failure 64
  [ ! -e "$TEAM" ]
}

@test "ワークツリーに自分の config.local.json があれば、config.sh が読むのと同じそのファイルに書く" {
  echo '{"review": {"model": "fable"}}' >"$LOCAL"
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  mkdir -p .claude/dev-workflow
  echo '{"review": {"model": "haiku"}}' >"$LOCAL"
  run_script setup/setup-models.sh --review-model opus --scope local
  assert_success
  assert_equal "$(jq -c . "$TMP/wt/$LOCAL")" '{"review":{"model":"opus"}}'
  assert_equal "$(jq -c . "$REPO/$LOCAL")" '{"review":{"model":"fable"}}'
  assert_equal "$(json_of "$output" | jq -r .review.model)" opus
  run_script config.sh .review.model
  assert_output opus
}

@test "local に書くとき、git に無視されていなければ警告し、local_git に出す" {
  run_script setup/setup-models.sh --review-model opus --scope local
  assert_success
  assert_output --partial "が git に無視されていません。.gitignore に足してください"
  assert_equal "$(json_of "$output" | jq -r .local_git)" not_ignored
  echo .claude/dev-workflow/config.local.json >.gitignore
  run_script setup/setup-models.sh --review-model opus --scope local
  assert_success
  refute_output --partial "無視されていません"
  assert_equal "$(jq -r .local_git <<<"$output")" ignored
  # team に書くときは確かめない
  run_script setup/setup-models.sh --review-model opus --scope team
  assert_equal "$(jq -c .local_git <<<"$output")" null
}

@test "リポジトリの層の設定ファイルが壊れていれば、何も書かずに止まる" {
  echo '{bad' >"$LOCAL"
  run_script setup/setup-models.sh --review-model opus --scope team
  assert_failure 2
  assert_output --partial "JSON のオブジェクトとして読めません: $REPO/$LOCAL"
  [ ! -e "$TEAM" ]
}

@test "コミット済みの config.local.json は、.gitignore に書いてあっても、追跡を外すよう警告する" {
  echo '{}' >"$LOCAL"
  git add "$LOCAL"
  git -c user.name=t -c user.email=t@example.com commit -q -m local
  echo .claude/dev-workflow/config.local.json >.gitignore
  run_script setup/setup-models.sh --review-model opus --scope local
  assert_success
  assert_output --partial "がコミットされています。git rm --cached .claude/dev-workflow/config.local.json で追跡を外し"
  assert_equal "$(json_of "$output" | jq -r .local_git)" tracked
}

@test "書く層の review がオブジェクトでなければ、dry-run のときから止まり、何も書かない" {
  echo '{"review": "x"}' >"$TEAM"
  for opt in --dry-run ""; do
    run_script setup/setup-models.sh --review-model opus --scope team $opt
    assert_failure 2
    assert_output --partial "$REPO/$TEAM の review がオブジェクトではないので、review.model を書けません"
  done
  assert_equal "$(cat "$TEAM")" '{"review": "x"}'
  [ ! -e "$TEAM.tmp" ]
}

@test "ホームのリポジトリでは、ユーザーの層のファイルに書かずに止まる。読むだけなら層を出さない" {
  make_home_repo
  echo '{"review": {"model": "opus"}}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"review": {"model": "haiku"}}' >"$WORKFLOW_USER_DIR/config.local.json"
  for scope in team local; do
    run_script setup/setup-models.sh --review-model sonnet --scope "$scope"
    assert_failure 2
    assert_output --partial "ホームのリポジトリ"
    run_script setup/setup-models.sh --review-model sonnet --scope "$scope" --dry-run
    assert_failure 2
  done
  assert_equal "$(jq -c . "$WORKFLOW_USER_DIR/config.json")" '{"review":{"model":"opus"}}'
  assert_equal "$(jq -c . "$WORKFLOW_USER_DIR/config.local.json")" '{"review":{"model":"haiku"}}'
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.decided, .review.layers]' <<<"$output")" '[false,[]]'
}

@test "層のモデル名に絵文字があっても（4096 バイトを超える1行でも）壊さずに読む" {
  # 標準入力の jq -Rsc は、行の先頭から約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す。
  # 設定ファイルのパスの長さで位置が変わるので、先頭の ASCII の長さをずらして確かめる
  for k in 0 1 2 3 4 5; do
    model="$(printf 'x%.0s' $(seq 1 $((k + 1))))$(emoji_text 1500)"
    jq -n --arg m "$model" '{review: {model: $m}}' >"$LOCAL"
    run_script setup/setup-models.sh
    assert_success
    assert_equal "$(jq -r '.review.layers[0].model' <<<"$output")" "$model"
  done
}
