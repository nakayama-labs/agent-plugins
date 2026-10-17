#!/usr/bin/env bats
# eval の偽の gh（tests/eval/bin/gh・fake-gh.sh）のテスト

load test_helper

# 表は、ケースの準備と同じ処理（scaffold.bash の fake_gh_init・fake_gh_read・fake_gh_write）で作る
load ../plugins/dev-workflow/evals/lib/scaffold

setup() {
  test_helper_setup
  FAKE_GH="$BATS_TEST_DIRNAME/eval/bin/gh"
  fake_gh_init
}

# 標準入力は空にする（--input - で読む呼び出しが、入力を待たないように）
run_fake_gh() {
  run "${TEST_BASH:-bash}" "$FAKE_GH" "$@" </dev/null
}

# 標準入力から JSON を渡して gh api graphql を呼ぶ。使い方: graphql_stdin <JSON> [gh の引数（api graphql の後）]...
graphql_stdin() {
  local body="$1"
  shift
  # shellcheck disable=SC2016 # 子の bash に展開させるため、シングルクォートで渡す
  run "${TEST_BASH:-bash}" -c 'printf "%s" "$1" | "$0" "${@:2}"' "$FAKE_GH" "$body" api graphql "$@"
}

writes() { cat .fake-gh/writes; }
nwrites() { wc -l <.fake-gh/writes | tr -d ' '; }

@test "read の行に当たる呼び出しに応答を返し、calls に記録して、writes には記録しない" {
  fake_gh_read 'issue list*' '[{"number": 1}]'
  run_fake_gh issue list --state open --json number
  assert_success
  assert_output '[{"number": 1}]'
  assert_equal "$(cat .fake-gh/calls)" "issue list --state open --json number"
  assert_equal "$(writes)" ""
}

@test "write の行に当たる呼び出しは、応答を返し、writes にも記録する" {
  fake_gh_write 'issue create*' 'https://github.com/me/demo/issues/99'
  run_fake_gh issue create --title t
  assert_success
  assert_output 'https://github.com/me/demo/issues/99'
  assert_equal "$(writes)" "issue create --title t"
}

@test "どの行にも当たらない呼び出しは、書き込みとして記録してから失敗する" {
  fake_gh_read 'issue list*' '[]'
  run_fake_gh pr status
  assert_failure
  assert_output --partial "応答が用意されていない呼び出しです: gh pr status"
  assert_equal "$(cat .fake-gh/calls)" "pr status"
  assert_equal "$(writes)" "pr status"
}

@test "合うパターンが複数あれば、上の行を使う（read か write も上の行で決まる）" {
  fake_gh_read 'issue view 1 *' '{"number": 1}'
  fake_gh_write 'issue view *' '{"number": 0}'
  run_fake_gh issue view 1 --json number
  assert_output '{"number": 1}'
  assert_equal "$(nwrites)" 0
  run_fake_gh issue view 2 --json number
  assert_output '{"number": 0}'
  assert_equal "$(nwrites)" 1
}

@test "-q と --jq の式を応答に当てる" {
  fake_gh_read 'repo view*' '{"nameWithOwner": "me/demo"}'
  run_fake_gh repo view --json nameWithOwner -q .nameWithOwner
  assert_success
  assert_output "me/demo"
  run_fake_gh repo view --json nameWithOwner --jq .nameWithOwner
  assert_output "me/demo"
  run_fake_gh repo view --json nameWithOwner --jq=.nameWithOwner
  assert_output "me/demo"
}

@test "終了コードが 0 でない応答は、標準エラーに出して、その終了コードで終わる" {
  fake_gh_read 'pr view*' 'no pull requests found' 1
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>/dev/null"
  assert_failure 1
  assert_output ""
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>&1 >/dev/null"
  assert_output "no pull requests found"
}

@test "gh api graphql は、クエリの渡し方によらず、操作名で表を引く" {
  fake_gh_read 'api graphql TodoItems' '{"data": {"r": 1}}'
  fake_gh_write 'api graphql *' '{"data": {}}'
  # shellcheck disable=SC2016 # GraphQL の変数（$n）なので展開させない
  graphql_stdin '{"query": "query TodoItems($n: Int!) { x }", "variables": {"n": 4}}' --input -
  assert_success
  assert_output '{"data": {"r": 1}}'
  printf '%s' '{"query": "mutation FromFile { x }"}' >m.json
  printf '%s' 'mutation FromAt { x }' >m.graphql
  run_fake_gh api graphql --input m.json
  run_fake_gh api graphql --raw-field=query='mutation Raw { x }'
  run_fake_gh api graphql -F query=@m.graphql
  run_fake_gh api -H 'X-Github-Next-Global-ID: 1' graphql -fquery='mutation Attached { x }'
  assert_equal "$(head -n 1 .fake-gh/calls)" 'api graphql TodoItems {"n":4}'
  assert_equal "$(cut -d' ' -f3 .fake-gh/writes | tr '\n' ' ')" "FromFile Raw FromAt Attached "
}

@test "gh api graphql は、複数行の mutation でも、操作名が分からなくても、read の行に当たらなければ書き込みとする" {
  fake_gh_read 'api graphql TodoItems' '{"data": {}}'
  fake_gh_write 'api graphql *' '{"data": {}}'
  run_fake_gh api graphql -f query='mutation {
  updateProjectV2ItemFieldValue(input:
    {projectId: "P"}) { projectV2Item { id } }
}'
  assert_success
  # -f の @ は、ファイルとして読まない（gh と同じ）。操作名は分からない
  run_fake_gh api graphql -f query=@m.graphql
  assert_success
  assert_equal "$(nwrites)" 2
  assert_equal "$(cut -d' ' -f1-3 .fake-gh/writes | sort -u)" "api graphql "
}

@test "gh api graphql の記録は、variables がオブジェクトでなくても残り、-f・-F の値も残す" {
  fake_gh_write 'api graphql *' '{"data": {}}'
  graphql_stdin '{"query": "mutation SetField { x }", "variables": []}' --input -
  assert_success
  run_fake_gh api graphql -f query='mutation AddItem { x }' -F itemId=IT1 -F number=5
  assert_success
  assert_equal "$(writes)" "$(printf '%s\n' 'api graphql SetField {}' 'api graphql AddItem {} itemId=IT1 number=5')"
}

@test "gh api は、graphql が値のオプションにあっても、エンドポイントが graphql でなければ REST として扱う" {
  fake_gh_write 'api -X POST repos/me/demo/labels*' '{}'
  run_fake_gh api -X POST repos/me/demo/labels -f name=x -H graphql
  assert_success
  assert_equal "$(writes)" "api -X POST repos/me/demo/labels -f name=x -H graphql"
}

@test "gh issue view・gh pr view は、番号・#番号・URL の指定を番号にそろえ、オプションの位置によらず表を引く" {
  fake_gh_read 'issue view 7' '{"title": "seven"}'
  fake_gh_read 'issue view 7 *' '{"title": "seven"}'
  fake_gh_read 'pr view 2 *' '{"title": "two"}'
  local args
  for args in "7" "#7" "https://github.com/me/demo/issues/7" "https://github.com/me/demo/issues/7/" \
    "https://github.com/me/demo/issues/7#issuecomment-1" "7 --json title" "--json title 7" "-R me/demo 7 --json title"; do
    # shellcheck disable=SC2086 # 引数に分けるため、クォートしない
    run_fake_gh issue view $args
    assert_success
    assert_equal "$(jq -r .title <<<"$output")" "seven"
  done
  for args in "2 --json title" "#2 --json title" "https://github.com/me/demo/pull/2 --json title"; do
    # shellcheck disable=SC2086
    run_fake_gh pr view $args
    assert_success
    assert_equal "$(jq -r .title <<<"$output")" "two"
  done
  # 70 は 7 の行に当たらない
  run_fake_gh issue view 70
  assert_failure
  assert_equal "$(nwrites)" 1
}

@test "標準入力で本文を渡す呼び出しは、標準入力を読み捨てる（パイプの書き手が失敗しない）" {
  fake_gh_write 'issue edit*' ''
  fake_gh_write 'api -X POST*' '{}'
  # shellcheck disable=SC2016 # 子の bash に展開させるため、シングルクォートで渡す
  run "${TEST_BASH:-bash}" -c 'set -o pipefail; head -c 1000000 /dev/zero | tr "\0" a | "$0" issue edit 1 --body-file -' "$FAKE_GH"
  assert_success
  # shellcheck disable=SC2016
  run "${TEST_BASH:-bash}" -c 'set -o pipefail; head -c 1000000 /dev/zero | tr "\0" a | "$0" api -X POST repos/me/demo/issues --input -' "$FAKE_GH"
  assert_success
}

@test "書き込みのしるしがあれば、read の行に当たっても書き込みとする（REST）" {
  # しるしだけを確かめるため、どの api の呼び出しにも当たる read の行にする
  fake_gh_read 'api *' '{"login": "me"}'
  run_fake_gh api user
  assert_equal "$(nwrites)" 0
  run_fake_gh api user -X PATCH -f bio=x
  run_fake_gh api user/repos -f name=x
  run_fake_gh api --method=post user/repos
  run_fake_gh api user -XDELETE
  run_fake_gh api user --input body.json
  assert_equal "$(nwrites)" 5
  # GET と HEAD は読むだけ
  run_fake_gh api -X GET user
  run_fake_gh api --method head user
  assert_equal "$(nwrites)" 5
}

@test "書き込みのしるしがあれば、read の行に当たっても書き込みとする（GraphQL の mutation・読めないクエリ）" {
  fake_gh_read 'api graphql TodoItems' '{"data": {}}'
  run_fake_gh api graphql -f query='query TodoItems { x }'
  assert_equal "$(nwrites)" 0
  run_fake_gh api graphql -f query='mutation TodoItems { x }'
  run_fake_gh api graphql -f query='mutation { addComment(input: {body: "query TodoItems"}) { x } }'
  run_fake_gh api graphql -f query='# query TodoItems
mutation { x }'
  run_fake_gh api graphql --input missing.json
  assert_equal "$(nwrites)" 4
}

@test "書き込みのしるしのある api の呼び出しは、表に無くても {} で成功したように答える" {
  run_fake_gh api repos/me/demo/issues -f title=x
  assert_success
  assert_output '{}'
  run_fake_gh api repos/me/demo/issues/1 -X PATCH -f state=closed
  assert_success
  assert_equal "$(nwrites)" 2
  # しるしの無い api の呼び出しは、表に無ければ失敗する（書き込みとしても記録する）
  run_fake_gh api repos/me/demo/unknown
  assert_failure
  assert_equal "$(nwrites)" 3
}

@test "-F body=@- のように @- で標準入力を読む呼び出しも、標準入力を読み捨てる" {
  # shellcheck disable=SC2016 # 子の bash に展開させるため、シングルクォートで渡す
  run "${TEST_BASH:-bash}" -c 'set -o pipefail; head -c 1000000 /dev/zero | tr "\0" a | "$0" api repos/me/demo/issues/1/comments -F body=@-' "$FAKE_GH"
  assert_success
  assert_output '{}'
}

@test "番号の無い gh pr view の鍵は、空白を1つにする" {
  fake_gh_read 'pr view --json*' '{"number": 2}'
  run_fake_gh pr view --json number
  assert_success
  assert_output '{"number": 2}'
}

@test "下のディレクトリ（ワークツリーなど）から呼んでも、上の .fake-gh を使う" {
  fake_gh_read 'issue list*' '[]'
  mkdir -p .claude/worktrees/feat/1-x
  cd .claude/worktrees/feat/1-x
  run_fake_gh issue list
  assert_success
  assert_output '[]'
  assert_equal "$(cat "$REPO/.fake-gh/calls")" "issue list"
}

@test ".fake-gh/routes が見つからなければ失敗する" {
  rm -rf .fake-gh
  run_fake_gh issue list
  assert_failure
  assert_output --partial ".fake-gh/routes が見つかりません"
}

@test "gh pr create の本文を、渡し方（--body-file・-F・--body-file=・標準入力・--body・-b）によらず .fake-gh/pr-body に残す" {
  fake_gh_write 'pr create*' 'https://github.com/me/demo/pull/98'
  printf '本文の1行目\n起票した Issue：#99\n' >"$TMP/body.md"
  local a
  for a in --body-file -F; do
    rm -f .fake-gh/pr-body
    run_fake_gh pr create --base main "$a" "$TMP/body.md"
    assert_success
    assert_equal "$(cat .fake-gh/pr-body)" "$(cat "$TMP/body.md")"
  done
  rm -f .fake-gh/pr-body
  run_fake_gh pr create "--body-file=$TMP/body.md"
  assert_success
  assert_equal "$(cat .fake-gh/pr-body)" "$(cat "$TMP/body.md")"
  # 標準入力から読む（読み捨てずに残す）
  rm -f .fake-gh/pr-body
  # shellcheck disable=SC2016 # 子の bash に展開させるため、シングルクォートで渡す
  run "${TEST_BASH:-bash}" -c '"$0" pr create --body-file - <"$1"' "$FAKE_GH" "$TMP/body.md"
  assert_success
  assert_equal "$(cat .fake-gh/pr-body)" "$(cat "$TMP/body.md")"
  for a in --body -b; do
    rm -f .fake-gh/pr-body
    run_fake_gh pr create "$a" "直接の本文"
    assert_success
    assert_equal "$(cat .fake-gh/pr-body)" "直接の本文"
  done
  rm -f .fake-gh/pr-body
  run_fake_gh pr create "--body=直接の本文"
  assert_equal "$(cat .fake-gh/pr-body)" "直接の本文"
}

@test "gh pr create 以外の本文（gh api の -F・gh issue create --body-file）は、.fake-gh/pr-body に残さない" {
  printf 'x' >"$TMP/body.md"
  fake_gh_write 'issue create*' 'https://github.com/me/demo/issues/99'
  run_fake_gh issue create --body-file "$TMP/body.md"
  assert_success
  run_fake_gh api -X POST repos/me/demo/pulls -F "body=@$TMP/body.md"
  assert_success
  [ ! -e .fake-gh/pr-body ] || fail "pr create 以外で pr-body ができました: $(cat .fake-gh/pr-body)"
}

@test "本文の無い gh pr create は、前の gh pr create の本文を .fake-gh/pr-body に残さない" {
  fake_gh_write 'pr create*' 'https://github.com/me/demo/pull/98'
  printf '前の本文\n' >"$TMP/body.md"
  run_fake_gh pr create --base main --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(cat .fake-gh/pr-body)" "前の本文"
  run_fake_gh pr create --base main --fill
  assert_success
  [ ! -e .fake-gh/pr-body ] || fail "前の本文が残っています: $(cat .fake-gh/pr-body)"
}

@test "gh issue comment の本文（--body-file の - かファイル）を、writes の行の最後に1行にして添える。--body は引数として行に入る" {
  fake_gh_write 'issue comment*' ''
  printf '1行目\n2行目 chain=c1 issue=8\n' | "${TEST_BASH:-bash}" "$FAKE_GH" issue comment 5 --body-file - >/dev/null
  printf '本文のファイル\n' >"$TMP/c.md"
  run_fake_gh issue comment 6 --body-file "$TMP/c.md"
  assert_success
  run_fake_gh issue comment 7 --body "引数の本文"
  assert_success
  assert_equal "$(writes)" "$(printf '%s\n' 'issue comment 5 --body-file - body: 1行目 2行目 chain=c1 issue=8' "issue comment 6 --body-file ${TMP}/c.md body: 本文のファイル" 'issue comment 7 --body 引数の本文')"
}

@test "GraphQL の mutation のクエリを .fake-gh/mutations に残し、writes の行は変えない。mutation でないクエリは残さない" {
  fake_gh_read 'api graphql Read' '{}'
  run_fake_gh api graphql -f query='mutation Merge { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'
  assert_success
  run_fake_gh api graphql -f query='query Read { viewer { login } }'
  assert_success
  assert_equal "$(writes)" "api graphql Merge {}"
  run grep -c 'mergePullRequest' .fake-gh/mutations
  assert_output 1
  run grep -c 'viewer' .fake-gh/mutations
  assert_output 0
}
