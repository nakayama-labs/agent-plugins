#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。gh label list は $FIX/labels.json を返し、
# gh label create / delete と gh api -X PATCH は引数を $CALLS に1行ずつ記録する。
# gh repo view は、リポジトリを指定すれば repo.json、指定しなければ（今いるリポジトリ）here.json を返す。
# 別のリポジトリのファイル（gh api .../contents/<パス>）は $FIX/remote/<パス> を返し、無ければ 404 にする。
# $FIX/remote/<パス>.err があれば、その内容を標準エラーに出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
record() {
  printf '%s' "$1" >>"$CALLS"
  shift
  printf ' [%s]' "$@" >>"$CALLS"
  echo >>"$CALLS"
}
case "$1 $2" in
  "repo view")
    case "${3:-}" in
      "" | -*) f=here.json ;;
      *) f=repo.json ;;
    esac
    [ -f "$FIX/$f" ] || f=repo.json
    jq -r "$q" "$FIX/$f"
    ;;
  "label list") cat "$FIX/labels.json" ;;
  "label create" | "label delete") shift; record "$@" ;;
  "api -X") shift 2; record edit "$@" ;;
  "api -H")
    path="${4#repos/*/*/contents/}"
    if [ -f "$FIX/remote/$path.err" ]; then cat "$FIX/remote/$path.err" >&2; exit 1
    elif [ -f "$FIX/remote/$path" ]; then cat "$FIX/remote/$path"
    else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  printf '%s\n' '{"nameWithOwner": "me/demo"}' >"$FIX/repo.json"
  current '[]'
}

# 使い方: current <リポジトリにある今のラベルの配列>
current() { printf '%s\n' "$1" >"$FIX/labels.json"; }

# GitHub が新しいリポジトリに付ける既定のラベル
github_defaults() {
  jq -c 'map({name: ., color: "ededed", description: ""})' <<<'["accessibility", "bug", "documentation",
    "duplicate", "enhancement", "good first issue", "help wanted", "invalid", "question", "wontfix"]'
}

run_setup() {
  run "${TEST_BASH:-bash}" "$SCRIPTS/setup/setup-labels.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }

# 変更を伴う呼び出しが1つも無いことを確かめる。あれば記録を表示して失敗する
assert_no_calls() {
  if [ -s "$CALLS" ]; then
    fail "$(printf '呼ばれないはずの操作が呼ばれました:\n%s' "$(cat "$CALLS")")"
  fi
}

@test "新しいリポジトリでは type ラベル 9 個と breaking を作り、既定のラベルを削除する" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup
  assert_success
  assert_equal "$(called create)" 10
  assert_equal "$(called delete)" 10
  assert_equal "$(called edit)" 0
  grep -qF 'create [feat] [-R] [me/demo] [--color] [0e8a16] [--description] [新しい機能]' "$CALLS"
  grep -qF 'create [breaking] [-R] [me/demo] [--color] [b60205] [--description] [破壊的変更（type とは別に付ける）]' "$CALLS"
  grep -qF 'delete [good first issue] [-R] [me/demo] [--yes]' "$CALLS"
  assert_equal "$(jq -c '.labels | [(.created | length), (.deleted | length), .unchanged]' <<<"$json")" '[10,10,0]'
}

@test "既定の accessibility ラベルは、定義に無ければ削除し、あれば削除しない" {
  setup_fake_gh
  current '[{"name": "accessibility", "color": "ededed", "description": ""}]'
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  assert_success
  assert_equal "$(called delete)" 1
  grep -qF 'delete [accessibility] [-R] [me/demo] [--yes]' "$CALLS"

  : >"$CALLS"
  printf '%s\n' '[{"name": "accessibility", "color": "ededed"}]' >labels.json
  run_setup --file labels.json
  assert_success
  assert_equal "$(called delete)" 0
}

@test "定義と同じラベルは変更しない（2回目の実行では何もしない）" {
  setup_fake_gh
  current "$(jq -c 'map(.color |= ascii_upcase)' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/labels.json")"
  run_setup
  assert_success
  assert_no_calls
  assert_equal "$(jq -r .labels.unchanged <<<"$json")" 10
  assert_equal "$(jq -c .actions <<<"$json")" '[]'
}

@test "色・説明・大文字小文字が違うラベルだけ既存の名前を指定して更新する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "#0E8A16", "description": "新機能"},
    {"name": "fix", "color": "d73a4a"}]' >labels.json
  current '[{"name": "Feat", "color": "0e8a16", "description": "新機能"},
    {"name": "fix", "color": "000000", "description": ""}]'
  run_setup --file labels.json
  assert_success
  assert_equal "$(called create)" 0
  assert_equal "$(called edit)" 2
  grep -qF 'edit [PATCH] [repos/me/demo/labels/Feat] [-f] [new_name=feat] [-f] [color=0e8a16] [-f] [description=新機能]' "$CALLS"
  grep -qF 'edit [PATCH] [repos/me/demo/labels/fix] [-f] [new_name=fix] [-f] [color=d73a4a] [-f] [description=]' "$CALLS"
}

@test "--keep-defaults では既定のラベルを削除しない" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup --keep-defaults
  assert_success
  assert_equal "$(called delete)" 0
}

@test "定義にあるラベルと、既定以外のラベルは削除しない" {
  setup_fake_gh
  printf '%s\n' '[{"name": "Bug", "color": "d73a4a"}]' >labels.json
  current '[{"name": "bug", "color": "d73a4a", "description": ""},
    {"name": "wontfix", "color": "ffffff", "description": ""},
    {"name": "priority: high", "color": "ff0000", "description": ""}]'
  run_setup --file labels.json
  assert_success
  assert_equal "$(called delete)" 1
  grep -qF 'delete [wontfix]' "$CALLS"
}

@test "dry-run では変更せず、予定の操作だけを出力する" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup --dry-run
  assert_success
  assert_no_calls
  assert_equal "$(jq -r .dry_run <<<"$json")" true
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "ラベル「feat」を作成する"
  assert_equal "$(jq -r '.actions[-1]' <<<"$json")" "既定のラベル「wontfix」を削除する"
}

@test "リポジトリの .claude/dev-workflow/labels.json があれば、既定の定義より優先する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/dev-workflow/labels.json
  run_setup
  assert_success
  assert_equal "$(called create)" 1
  assert_equal "$(jq -r .file <<<"$json")" "$REPO/.claude/dev-workflow/labels.json"
}

@test "更新する既存のラベルの名前は URL エンコードする" {
  setup_fake_gh
  printf '%s\n' '[{"name": "priority: high", "color": "ff0000"}]' >labels.json
  current '[{"name": "Priority: High", "color": "ff0000", "description": ""}]'
  run_setup --file labels.json
  assert_success
  grep -qF 'edit [PATCH] [repos/me/demo/labels/Priority%3A%20High]' "$CALLS"
}

@test "--repo で別のリポジトリを指定したら、そのリポジトリの定義と設定を使う" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/dev-workflow/labels.json
  mkdir -p "$FIX/remote/.claude/dev-workflow"
  printf '%s\n' '[{"name": "story", "color": "111111"}]' >"$FIX/remote/.claude/dev-workflow/labels.json"
  printf '%s\n' '{"labels": {"types": ["story", "spike"]}}' >"$FIX/remote/.claude/dev-workflow/config.json"
  run_setup --repo me/demo
  assert_success
  assert_equal "$(called create)" 1
  grep -qF 'create [story] [-R] [me/demo]' "$CALLS"
  assert_equal "$(jq -r .file <<<"$json")" "me/demo:.claude/dev-workflow/labels.json"
  assert_output --partial "定義に無いラベルがあります: spike"
}

@test "別のリポジトリに定義が無ければ、プラグインの既定を使う" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/dev-workflow/labels.json
  run_setup --repo me/demo
  assert_success
  assert_equal "$(called create)" 10
  assert_regex "$(jq -r .file <<<"$json")" '/defaults/labels\.json$'
}

@test "--repo が今いるリポジトリと同じなら、手元の定義を使う" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/dev-workflow/labels.json
  run_setup --repo me/demo
  assert_success
  assert_equal "$(called create)" 1
  assert_equal "$(jq -r .file <<<"$json")" "$REPO/.claude/dev-workflow/labels.json"
}

@test "別のリポジトリの定義を 404 以外の理由で読めなければ、変更せずに止まる" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  mkdir -p "$FIX/remote/.claude/dev-workflow"
  echo 'gh: Server Error (HTTP 502)' >"$FIX/remote/.claude/dev-workflow/labels.json.err"
  run_setup --repo me/demo
  assert_failure
  assert_output --partial "me/demo の .claude/dev-workflow/labels.json を読めません"
  assert_no_calls
}

@test "設定の type ラベルが定義に無ければ警告する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  assert_success
  assert_output --partial "定義に無いラベルがあります: fix, refactor"
}

@test "定義に breaking ラベルが無ければ警告し、あれば警告しない" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  assert_success
  assert_output --partial "定義に breaking ラベルがありません（無いと破壊的変更の Issue を起票できません。labels.json に足してください）"
  run_setup
  assert_success
  refute_output --partial "breaking ラベルがありません"
}

@test "定義の色が 6 桁でなければエラーになる" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "red"}]' >labels.json
  run_setup --file labels.json
  assert_failure 2
  assert_output --partial "ラベルの定義を読めません"
  assert_no_calls
}

@test "名前が大文字小文字違いで重複していればエラーになる" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}, {"name": "Feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  assert_failure 2
  assert_output --partial "ラベルの名前が重複しています: feat"
}

@test "定義のファイルが無ければエラーになる" {
  setup_fake_gh
  run_setup --file nothing.json
  assert_failure 2
}

@test "オプションの値が無ければ終了コード 64" {
  setup_fake_gh
  run_setup --file
  assert_failure 64
  assert_output --partial "--file に値がありません"
}

@test "--help は使い方を表示する" {
  setup_fake_gh
  run_setup --help
  assert_success
  assert_output --partial "--keep-defaults"
  refute_output --partial "set -euo"
}

@test "ホームのリポジトリでは、ユーザーの層の labels.json をリポジトリのラベルの定義として読まない" {
  setup_fake_gh
  make_home_repo
  current "$(github_defaults)"
  printf '%s\n' '[{"name": "only-home", "color": "000000"}]' >"$WORKFLOW_USER_DIR/labels.json"
  run_setup --dry-run
  assert_success
  assert_equal "$(jq -r '.labels.created | index("only-home")' <<<"$json")" null
  assert_equal "$(jq -r '.labels.created | index("feat") != null' <<<"$json")" true
}

@test "labels.types が文字列の配列でなければ、ラベルに触れずに、設定の誤りの1行と終了コード 2 で止まる" {
  setup_fake_gh
  current "$(github_defaults)"
  local v
  for v in '"xfeat"' null 5 '["feat", null]'; do
    echo "{\"labels\": {\"types\": $v}}" >.claude/dev-workflow/config.local.json
    run_setup
    assert_failure 2
    assert_output "error: labels.types（$(jq -nc "$v")）が文字列の配列ではありません。設定を直してください"
    assert_no_calls
  done
}
