#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、export がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。ワークフローは $FIX/workflows/ に置いたファイルを、GitHub 上のブランチにあるものとして返す。
# gh api repos/<リポジトリ>/contents/.github/workflows?ref=<ブランチ> は、$FIX/workflows のファイルの一覧を返し、
# ディレクトリが無ければ 404 にする。gh api -H ... repos/<リポジトリ>/contents/<パス>?ref=<ブランチ> は、そのファイルを返す。
# どちらも、パスを $CALLS に1行ずつ記録する。FAKE_FAIL があれば、一覧を 403 で失敗させる。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api -H")
    printf '%s\n' "$4" >>"$CALLS"
    f="${4#repos/*/*/contents/.github/workflows/}"
    cat "$FIX/workflows/${f%%\?*}"
    ;;
  "api "*)
    printf '%s\n' "$2" >>"$CALLS"
    if [ -n "${FAKE_FAIL:-}" ]; then echo 'gh: Forbidden (HTTP 403)' >&2; exit 1; fi
    [ -d "$FIX/workflows" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    for f in "$FIX/workflows"/*; do
      [ -e "$f" ] || continue
      n="$(basename "$f")"
      jq -n --arg n "$n" '{name: $n, path: (".github/workflows/" + $n), type: "file"}'
    done | jq -s .
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

# 使い方: workflow <ファイル名>（本文は標準入力）
workflow() {
  mkdir -p "$FIX/workflows"
  cat >"$FIX/workflows/$1"
}

run_check() {
  run_script merge-group-check.sh "$@"
  printf '%s\n' "$output"
}

@test "必須のチェックのジョブがあるワークフローが merge_group で動かなければ not_running に入れる" {
  setup_fake_gh
  workflow ci.yml <<'YML'
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: merge_group
        run: echo merge_group
  test-result:
    runs-on: ubuntu-latest
YML
  workflow queue.yaml <<'YML'
on:
  merge_group:
jobs:
  lint:
    runs-on: ubuntu-latest
YML
  run_check --branch main --check test-result --check lint
  assert_success
  assert_equal "$(jq -c .not_running <<<"$output")" '[{"check":"test-result","workflows":[".github/workflows/ci.yml"],"reason":"on"}]'
  assert_equal "$(jq -c .unknown <<<"$output")" '[]'
  assert_equal "$(jq -c .workflows <<<"$output")" '[".github/workflows/ci.yml",".github/workflows/queue.yaml"]'
}

@test "on: の書き方（1行・配列・引用符・コメント）を読み分ける" {
  setup_fake_gh
  workflow a.yml <<'YML'
on: merge_group
jobs:
  a:
    runs-on: ubuntu-latest
YML
  workflow b.yml <<'YML'
"on": [pull_request, merge_group]
jobs:
  b:
    runs-on: ubuntu-latest
YML
  workflow c.yml <<'YML'
on:
  pull_request:
  # merge_group:
jobs:
  c:
    if: github.event_name == 'merge_group'
    runs-on: ubuntu-latest
YML
  workflow d.yml <<'YML'
on:
  pull_request: {}
  merge_group:
    types: [checks_requested]
env:
  merge_group: x
jobs:
  d:
    runs-on: ubuntu-latest
YML
  workflow e.yml <<'YML'
on:
  pull_request:
env:
  merge_group: x
jobs:
  e:
    runs-on: ubuntu-latest
YML
  run_check --branch main --check a --check b --check c --check d --check e
  assert_success
  assert_equal "$(jq -c '[.not_running[].check]' <<<"$output")" '["c","e"]'
}

@test "チェックの名前を、ジョブの name・matrix・再利用するワークフローと突き合わせ、式を含む name とは比べない" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: pull_request
jobs:
  build:
    name: "Build app"   # 表示名
    runs-on: ubuntu-latest
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
  e2e:
    name: E2E (${{ matrix.browser }})
    runs-on: ubuntu-latest
  call:
    uses: ./.github/workflows/reusable.yml
YML
  run_check --branch main --check "Build app" --check "test (macos-latest)" --check "E2E (firefox)" \
    --check "call / inner" --check build --check "codecov/patch"
  assert_success
  assert_equal "$(jq -c '[.not_running[].check]' <<<"$output")" \
    '["Build app","call / inner","test (macos-latest)"]'
  # ${{ }} の式を含む name: とは比べない。name: があるジョブ（build）は ID では当てない
  assert_equal "$(jq -c .unknown <<<"$output")" '["E2E (firefox)","build","codecov/patch"]'
}

@test "式を含む name: のジョブは、関係の無いチェックにも、それらしいチェックにも当てない" {
  setup_fake_gh
  workflow nightly.yml <<'YML'
on: schedule
jobs:
  build:
    name: ${{ matrix.target }}
    runs-on: ubuntu-latest
  pack:
    name: "${{ matrix.os }}・${{ matrix.arch }}"
    runs-on: ubuntu-latest
  test:
    name: テスト (${{ matrix.os }})
    runs-on: ubuntu-latest
YML
  run_check --branch main --check "CodeRabbit" --check "レビュー・CodeRabbit" --check "テスト (linux)"
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],["CodeRabbit","テスト (linux)","レビュー・CodeRabbit"]]'
}

@test "GitHub の名付けのきまりどおり、name: があるジョブは name だけと、無いジョブは ID と比べる" {
  setup_fake_gh
  workflow nightly.yml <<'YML'
on: schedule
jobs:
  build:
    name: ${{ matrix.target }}
    runs-on: ubuntu-latest
  lint:
    name: Lint
    runs-on: ubuntu-latest
  test:
    runs-on: ubuntu-latest
YML
  run_check --branch main --check build --check "build (x)" --check lint --check Lint --check test
  assert_success
  assert_equal "$(jq -c '[[.not_running[].check], .unknown]' <<<"$output")" '[["Lint","test"],["build","build (x)","lint"]]'
}

@test "引用符の中の # はコメントとして消さない" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: pull_request # merge_group は使わない
jobs:
  a:
    name: "Build #1" # 表示名
    runs-on: ubuntu-latest
  b:
    name: 'Test #2'
    runs-on: ubuntu-latest
  c:
    name: Bob's build # コメント
    runs-on: ubuntu-latest
YML
  run_check --branch main --check "Build #1" --check "Test #2" --check "Bob's build"
  assert_success
  assert_equal "$(jq -c '[[.not_running[].check], .unknown]' <<<"$output")" '[["Bob'"'"'s build","Build #1","Test #2"],[]]'
}

@test "引用符の中のエスケープを読み、元の文字に戻して比べる" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: pull_request
jobs:
  a:
    name: 'It''s #1' # コメント
    runs-on: ubuntu-latest
  b:
    name: "Say \"hi #2\"" # コメント
    runs-on: ubuntu-latest
  c:
    name: "back\\slash"
    runs-on: ubuntu-latest
YML
  run_check --branch main --check "It's #1" --check 'Say "hi #2"' --check 'back\slash'
  assert_success
  assert_equal "$(jq -c '.unknown' <<<"$output")" '[]'
  assert_equal "$(jq -r '.not_running | length' <<<"$output")" 3
}

@test "同じ名前のジョブが複数のワークフローにあれば、どれかが merge_group で動けば動くとみなす" {
  setup_fake_gh
  printf 'on: pull_request\njobs:\n  lint:\n    runs-on: x\n' | workflow a.yml
  printf 'on:\r\n  merge_group:\r\njobs:\r\n  lint:\r\n    runs-on: x\r\n' | workflow b.yml
  run_check --branch main --check lint
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],[]]'
}

@test "指定したブランチのワークフローを読む（/ を含む名前はエンコードする）" {
  setup_fake_gh
  printf 'on: pull_request\njobs:\n  lint:\n    runs-on: x\n' | workflow ci.yml
  run_check --branch release/v1 --repo org/app --check lint
  assert_success
  assert_equal "$(cat "$CALLS")" "$(printf '%s\n' 'repos/org/app/contents/.github/workflows?ref=release%2Fv1' \
    'repos/org/app/contents/.github/workflows/ci.yml?ref=release%2Fv1')"
  assert_equal "$(jq -r .branch <<<"$output")" release/v1
}

@test "--repo が無ければ今いるリポジトリを読み、チェックが無ければ何も読まない" {
  setup_fake_gh
  printf 'on: pull_request\njobs:\n  lint:\n    runs-on: x\n' | workflow ci.yml
  run_check --branch main --check lint
  assert_equal "$(head -n 1 "$CALLS")" 'repos/{owner}/{repo}/contents/.github/workflows?ref=main'
  : >"$CALLS"
  run_check --branch main
  assert_success
  assert_equal "$(jq -c '[.workflows, .not_running, .unknown]' <<<"$output")" '[[],[],[]]'
  assert_equal "$(cat "$CALLS")" ""
}

@test "ワークフローが無ければ、すべてのチェックを unknown にする" {
  setup_fake_gh
  run_check --branch main --check lint
  assert_success
  assert_equal "$(jq -c '[.workflows, .not_running, .unknown]' <<<"$output")" '[[],[],["lint"]]'
}

@test "ワークフローの一覧を読めなければ、理由を伝えて止まる" {
  setup_fake_gh
  export FAKE_FAIL=1
  run_check --branch main --check lint
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: gh: Forbidden (HTTP 403)"
}

@test "--branch が無ければ使い方の誤りで止まる" {
  setup_fake_gh
  run_check --check lint
  assert_failure 64
}

@test "--checks-json の名前も合わせて確かめ、利用者に伝える文を messages に出す" {
  setup_fake_gh
  printf 'on: pull_request\njobs:\n  lint:\n    runs-on: x\n  test:\n    runs-on: x\n' | workflow ci.yml
  run_check --branch main --check lint --checks-json '["test", "codecov", "lint"]'
  assert_success
  assert_equal "$(jq -c '[[.not_running[].check], .unknown]' <<<"$output")" '[["lint","test"],["codecov"]]'
  assert_equal "$(jq -r .messages.not_running <<<"$output")" \
    "必須のチェックのうち lint（.github/workflows/ci.yml）、test（.github/workflows/ci.yml）は、merge_group のイベントで動きません。マージキューのチェックが「待ち」のまま残り、PR がマージされません。ワークフローの on: に merge_group を足してください"
  assert_equal "$(jq -r .messages.unknown <<<"$output")" \
    "必須のチェック codecov は、main のどのワークフローのジョブか分からないので、merge_group のイベントで動くか確かめられません"
  # 当てはまるチェックが無ければ null
  run_check --branch main
  assert_equal "$(jq -c .messages <<<"$output")" '{"not_running":null,"unknown":null}'
}

@test "--checks-json が文字列の配列でなければ使い方の誤りで止まる" {
  setup_fake_gh
  run_check --branch main --checks-json '{"a": 1}'
  assert_failure 64
  run_check --branch main --checks-json '[1]'
  assert_failure 64
}

@test "ジョブの if: で merge_group を除いていれば、if を直す理由で not_running に入れる" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: [pull_request, merge_group]
jobs:
  a:
    if: github.event_name != 'merge_group'
    runs-on: ubuntu-latest
  b:
    if: ${{ github.event_name == 'pull_request' }}
    runs-on: ubuntu-latest
  c:
    if: "'MERGE_GROUP' != github.event_name" # 文字列は大文字と小文字を区別しない
    runs-on: ubuntu-latest
  d:
    if: always() && (github.event_name != 'merge_group')
    runs-on: ubuntu-latest
  e:
    if: >-
      !cancelled() &&
      github.event_name == 'push'
    runs-on: ubuntu-latest
YML
  run_check --branch main --check a --check b --check c --check d --check e
  assert_success
  assert_equal "$(jq -c '[.not_running[] | [.check, .reason, .workflows[]]]' <<<"$output")" \
    '[["a","if",".github/workflows/ci.yml"],["b","if",".github/workflows/ci.yml"],["c","if",".github/workflows/ci.yml"],["d","if",".github/workflows/ci.yml"],["e","if",".github/workflows/ci.yml"]]'
  assert_equal "$(jq -c .unknown <<<"$output")" '[]'
  run_check --branch main --check a
  assert_equal "$(jq -r .messages.not_running <<<"$output")" \
    "必須のチェックのうち a（.github/workflows/ci.yml）は、ジョブ（または needs: で頼るジョブ）の if: で merge_group のイベントを除いています。飛ばされたジョブのチェックは成功とみなされるので、マージキューは CI を動かさないまま PR をマージします。ジョブの if: を直してください"
}

@test "merge_group で真になると分かる if: と、イベントに関わらない if: のジョブは動くとみなす" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: [pull_request, merge_group]
jobs:
  a:
    if: always()
    runs-on: ubuntu-latest
  b:
    if: ${{ github.event_name == 'merge_group' && !cancelled() }}
    runs-on: ubuntu-latest
  c:
    if: (github.event_name != 'push')
    runs-on: ubuntu-latest
  d:
    if: needs.x.outputs.docs_only != 'true' && contains(vars.TARGETS, 'a && b')
    needs: x
    runs-on: ubuntu-latest
  x:
    runs-on: ubuntu-latest
YML
  run_check --branch main --check a --check b --check c --check d
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],[]]'
}

@test "読み切れない if: のジョブは、動くとみなさず unknown に入れる" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: [pull_request, merge_group]
jobs:
  a:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
  b:
    if: github.event_name == 'merge_group' || github.event_name == 'push'
    runs-on: ubuntu-latest
  c:
    if: contains(fromJSON('["push", "pull_request"]'), github.event_name)
    runs-on: ubuntu-latest
  d:
    if: startsWith(github.ref, 'refs/heads/main')
    runs-on: ubuntu-latest
YML
  run_check --branch main --check a --check b --check c --check d --check codecov
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],["a","b","c","codecov","d"]]'
  assert_equal "$(jq -r .messages.unknown <<<"$output")" \
    "必須のチェック codecov は、main のどのワークフローのジョブか分からないので、merge_group のイベントで動くか確かめられません。必須のチェック a、b、c、d は、ジョブ（または needs: で頼るジョブ）の if: から、merge_group のイベントで CI が動くかを判定できません"
}

@test "needs: でたどれるジョブの if: も確かめ、always() などの門番のジョブは、頼るジョブが除かれていれば unknown にする" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: [pull_request, merge_group]
jobs:
  build:
    if: github.event_name != 'merge_group'
    runs-on: ubuntu-latest
  test:
    needs: build
    runs-on: ubuntu-latest
  gate:
    if: always()
    needs: [lint, "test"]
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  gate2:
    needs:
      - lint
      - draft
    runs-on: ubuntu-latest
  draft:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
  gate3:
    needs: [lint, missing]
    runs-on: ubuntu-latest
  gate4:
    needs: lint
    runs-on: ubuntu-latest
  gate5:
    needs:
    - lint
    - test
    runs-on: ubuntu-latest
  gate6:
    if: ${{ !cancelled() }}
    needs: [lint]
    runs-on: ubuntu-latest
  gate7:
    if: failure() || github.event_name == 'push'
    needs: build
    runs-on: ubuntu-latest
YML
  run_check --branch main --check test --check gate --check gate2 --check gate3 --check gate4 --check gate5 \
    --check gate6 --check gate7
  assert_success
  # test・gate5 は暗黙の success() で、頼るジョブ（build）が飛ばされると飛ばされる。gate5 は needs: と同じ深さのリスト
  assert_equal "$(jq -c '[[.not_running[] | [.check, .reason]], .unknown]' <<<"$output")" \
    '[[["gate5","if"],["test","if"]],["gate","gate2","gate3","gate7"]]'
}

@test "on: に merge_group が無いワークフローは、if: に関わらず on を直す理由にする" {
  setup_fake_gh
  workflow ci.yml <<'YML'
on: pull_request
jobs:
  a:
    if: github.event_name != 'merge_group'
    runs-on: ubuntu-latest
YML
  run_check --branch main --check a
  assert_success
  assert_equal "$(jq -c '.not_running' <<<"$output")" '[{"check":"a","workflows":[".github/workflows/ci.yml"],"reason":"on"}]'
}

@test "同じ名前のジョブのどれかが merge_group で動けば、ほかのジョブが if: で除かれていても動くとみなす" {
  setup_fake_gh
  printf 'on: merge_group\njobs:\n  lint:\n    if: github.event_name == '"'"'push'"'"'\n    runs-on: x\n' | workflow a.yml
  printf 'on: merge_group\njobs:\n  lint:\n    runs-on: x\n' | workflow b.yml
  run_check --branch main --check lint
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],[]]'
}

@test "このリポジトリのワークフロー（docs だけの変更で飛ばすジョブと、always() の門番のジョブ）は動くとみなす" {
  setup_fake_gh
  workflow lint.yml <"$BATS_TEST_DIRNAME/../.github/workflows/lint.yml"
  workflow test.yml <"$BATS_TEST_DIRNAME/../.github/workflows/test.yml"
  run_check --branch main --check lint-result --check test-result
  assert_success
  assert_equal "$(jq -c '[.not_running, .unknown]' <<<"$output")" '[[],[]]'
}

@test "チェックの名前に絵文字があっても（4096 バイトを超えても）壊さずに、そのまま結果に出す" {
  # 標準入力の jq -R -s は、約 4096 バイトの読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊す
  setup_fake_gh
  workflow ci.yml <<'YML'
on:
  merge_group:
jobs:
  lint:
    runs-on: ubuntu-latest
YML
  name="$(emoji_text 1500)"
  run_check --branch main --check "$name" --check lint
  assert_success
  assert_equal "$(jq -r --arg n "$name" '[.. | strings | select(. == $n)] | length > 0' <<<"$output")" true
}
