#!/usr/bin/env bats
# repair-run-count.sh：無人の push の回数を、repair-run のマーカーの head から数える（ADR 000339）。値だけで決める

load test_helper

setup() {
  test_helper_setup
  A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  C=cccccccccccccccccccccccccccccccccccccccc
}

# 使い方: comments <本文>... → gh pr view --json comments の形（投稿者 bot、時刻は 1 分ずつ後）
comments() {
  jq -n '{comments: ($ARGS.positional | to_entries
    | map({author: {login: "bot"}, body: .value, createdAt: ("2026-10-10T00:0\(.key):00Z")}))}' --args "$@"
}
run_mark() { printf '<!-- dev-workflow:repair-run head=%s -->\n\n## 代わりに決めたこと\n' "$1"; }
count() { run_script repair-run-count.sh "$@" <"$TMP/in.json"; }

@test "push していない回（head が今の head と同じ）は数えない（#332）" {
  # A から B へ push した回と、B で push に失敗した回（PR の head は B のまま）
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads, .not_pushed, .runs]' <<<"$output")" "[1,[\"$A\"],1,2]"
}

@test "コメントを付けた後に push の前で止まった回だけなら、0 回" {
  comments "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[0,1]'
}

@test "同じ head の repair-run が重なっても、1 回と数える（失敗した後に同じ sha から push し直した）" {
  comments "$(run_mark "$A")" "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$C"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[2,[\"$A\",\"$B\"]]"
}

@test "head の無い古い形式は、1 つを 1 回と数える" {
  comments '<!-- dev-workflow:repair-run -->' '<!-- dev-workflow:repair-run -->' "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .legacy, .runs]' <<<"$output")" '[3,2,3]'
}

@test "sha の大文字と小文字は区別しない" {
  comments "$(run_mark "$(tr a-f A-F <<<"$A")")" >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -r .count <<<"$output")" 0
}

@test "本文の先頭に無いマーカー（引用など）と、ほかのマーカーは数えない" {
  comments "> $(run_mark "$A")" "前置き $(run_mark "$A")" '<!-- dev-workflow:repair-done sha=x -->' '<!-- dev-workflow:repair-runx -->' >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .runs]' <<<"$output")" '[0,0]'
}

@test "--logins を渡すと、その投稿者のコメントだけを数える" {
  jq -n --arg a "$(run_mark "$A")" --arg b "$(run_mark "$B")" '{comments: [
    {author: {login: "bot"}, body: $a, createdAt: "2026-10-10T00:00:00Z"},
    {author: {login: "someone"}, body: $b, createdAt: "2026-10-10T00:01:00Z"}]}' >"$TMP/in.json"
  count --head "$C" --logins 'other,bot'
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[1,[\"$A\"]]"
}

@test "--since より後のコメントだけを数える（再開の起点）" {
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$C" --since 2026-10-10T00:00:30Z
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[1,[\"$B\"]]"
}

@test "gh api の出力（配列、--paginate --slurp の配列の配列）も読める" {
  jq -n --arg a "$(run_mark "$A")" --arg b "$(run_mark "$B")" '[[
    {user: {login: "bot"}, body: $a, created_at: "2026-10-10T00:00:00Z"}],
    [{user: {login: "bot"}, body: $b, created_at: "2026-10-10T00:01:00Z"}]]' >"$TMP/in.json"
  count --head "$B" --logins bot
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[1,1]'
}

@test "repair-run が無ければ 0 回" {
  comments '人のコメント' >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"count":0,"pushed_heads":[],"legacy":0,"other_pushed":0,"not_pushed":0,"runs":0}'
}

@test "コメントが長くても（引数の長さの上限の 128 KiB を超えても）数える" {
  # 入力を作る側も引数の上限に当たるので、本文はファイルから読ませる
  { run_mark "$A"; head -c 140000 /dev/zero | tr '\0' x; } >"$TMP/long.md"
  jq -n --rawfile b "$TMP/long.md" '{comments: [{author: {login: "bot"}, body: $b, createdAt: "2026-10-10T00:00:00Z"}]}' >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -r .count <<<"$output")" 1
}

@test "--head が無い・16 進でない・--since が時刻でない・不明な引数・入力が違うときは 64 で止まる" {
  comments >"$TMP/in.json"
  count
  assert_failure 64
  count --head xyz
  assert_failure 64
  count --head "$A" --since yesterday
  assert_failure 64
  count --head "$A" --nope
  assert_failure 64
  count --head
  assert_failure 64
  echo '{"x":1}' >"$TMP/in.json"
  count --head "$A"
  assert_failure 64
  echo 'not json' >"$TMP/in.json"
  count --head "$A"
  assert_failure 64
}

# 使い方: comments_at <ログイン> <時刻> <本文> [<ログイン> <時刻> <本文>]... → gh pr view の形（GraphQL の形）
comments_at() {
  jq -n '{comments: [$ARGS.positional as $p | range(0; $p | length; 3) | $p[.:.+3] | {author: {login: .[0]}, createdAt: .[1], body: .[2]}]}' --args "$@"
}

@test "--logins は、app と app[bot] の綴りの違いと大文字小文字を問わずに照らす（gh pr view と gh api の両方の形）" {
  # gh pr view（GraphQL）では login が app
  comments_at app 2026-10-10T00:00:00Z "$(run_mark "$A")" >"$TMP/view.json"
  # gh api（REST）では login が app[bot]
  jq -n --arg a "$(run_mark "$A")" '[[{user: {login: "app[bot]"}, body: $a, created_at: "2026-10-10T00:00:00Z"}]]' >"$TMP/api.json"
  for f in view api; do
    for l in 'app[bot]' app 'App[Bot]'; do
      run_script repair-run-count.sh --head "$B" --logins "$l" <"$TMP/$f.json"
      assert_success
      assert_equal "$(jq -r .count <<<"$output")" 1
    done
  done
  run_script repair-run-count.sh --head "$B" --logins 'other[bot]' <"$TMP/api.json"
  assert_equal "$(jq -r .count <<<"$output")" 0
}

@test "--logins の区切りの前後の空白は除く" {
  comments_at app 2026-10-10T00:00:00Z "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$B" --logins 'other,  app ,x'
  assert_success
  assert_equal "$(jq -r .count <<<"$output")" 1
}

@test "短い sha と長い sha は、前方一致で同じとみなす" {
  # マーカーが短く、今の head が長い → push していない回
  comments "$(run_mark "${B:0:7}")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[0,1]'
  # マーカーが長く、--head が短い
  comments "$(run_mark "$B")" >"$TMP/in.json"
  count --head "${B:0:12}"
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[0,1]'
}

@test "head の値ごとにまとめるのは完全に一致するものだけ（先頭が同じ別のコミットを1つにまとめない）" {
  # abcdef1 と、abcdef1 で始まる別の 40 文字の sha は、別のコミットかもしれないので2回と数える
  other=abcdef1999999999999999999999999999999999
  comments "$(run_mark abcdef1)" "$(run_mark "$other")" "$(run_mark ABCDEF1)" >"$TMP/in.json"
  count --head "$C"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[2,[\"abcdef1\",\"$other\"]]"
}

@test "7 文字未満の sha：--head なら 64 で止まり、マーカーなら1つを1回と数える" {
  comments >"$TMP/in.json"
  count --head abcdef
  assert_failure 64
  comments "$(run_mark "${B:0:6}")" "$(run_mark "${B:0:6}")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .legacy, .not_pushed]' <<<"$output")" '[2,2,0]'
}

@test "--since：小数の秒と時差のある日時を読んで比べる" {
  comments_at bot 2026-10-10T08:59:59.5+09:00 "$(run_mark "$A")" \
    bot 2026-10-10T00:00:00.250Z "$(run_mark "$B")" \
    bot 2026-10-09T19:30:01-0430 "$(run_mark "$C")" >"$TMP/in.json"
  # 起点 2026-10-10T00:00:00Z：A は 23:59:59.5Z（前）、B は 00:00:00.25Z（後）、C は 00:00:01Z（後）
  count --head 1111111111111111111111111111111111111111 --since 2026-10-10T09:00:00+09:00
  assert_success
  assert_equal "$(jq -c '.pushed_heads' <<<"$output")" "[\"$B\",\"$C\"]"
  count --head 1111111111111111111111111111111111111111 --since 2026-10-10T00:00:00.1Z
  assert_equal "$(jq -c '.pushed_heads' <<<"$output")" "[\"$B\",\"$C\"]"
}

@test "--since：日時が読めない・欠けているコメントは、落とさずに数える" {
  jq -n --arg a "$(run_mark "$A")" --arg b "$(run_mark "$B")" --arg c "$(run_mark "$C")" '{comments: [
    {author: {login: "bot"}, body: $a, createdAt: "yesterday"},
    {author: {login: "bot"}, body: $b},
    {author: {login: "bot"}, body: $c, createdAt: "2026-01-01T00:00:00Z"}]}' >"$TMP/in.json"
  count --head 1111111111111111111111111111111111111111 --since 2026-10-10T00:00:00Z
  assert_success
  assert_equal "$(jq -c '.pushed_heads' <<<"$output")" "[\"$A\",\"$B\"]"
}

@test "--since：ありえない日時と、範囲の外の時差は 64 で止まる。範囲の中の時差は読む" {
  comments >"$TMP/in.json"
  for t in 2026-13-01T00:00:00Z 2026-00-10T00:00:00Z 2026-10-32T00:00:00Z 2026-10-10T25:00:00Z 2026-10-10T00:60:00Z \
    2026-10-10T00:00:00+15:00 2026-10-10T00:00:00+09:60 2026-10-10T00:00:00-1500; do
    count --head "$A" --since "$t"
    assert_failure 64
    assert_output --partial "--since は ISO 8601 の時刻"
  done
  for t in 2026-10-10T00:00:00+14:00 2026-10-10T00:00:00-1200 2026-10-10T00:00:00+05:45; do
    count --head "$A" --since "$t"
    assert_success
  done
}

@test "--since：コメントの日時がありえない値（13 月・25 時・範囲の外の時差）でも止まらず、数える側に倒す" {
  comments_at bot 2026-13-01T00:00:00Z "$(run_mark "$A")" \
    bot 2026-10-10T25:00:00Z "$(run_mark "$B")" \
    bot 2026-10-10T00:00:00+15:00 "$(run_mark "$C")" \
    bot 2026-01-01T00:00:00Z "$(run_mark 1234567890123456789012345678901234567890)" >"$TMP/in.json"
  count --head 1111111111111111111111111111111111111111 --since 2026-10-10T00:00:00Z
  assert_success
  assert_equal "$(jq -c '.pushed_heads' <<<"$output")" "[\"$A\",\"$B\",\"$C\"]"
}

# 使い方: commit <sha> <親の sha> <committer のログイン> ... → gh api の pulls/<番号>/commits の形（配列の配列）
commits_json() {
  jq -n '[[$ARGS.positional as $p | range(0; $p | length; 3) | $p[.:.+3] | {sha: .[0], parents: [{sha: .[1]}], committer: (if .[2] == "" then null else {login: .[2]} end)}]]' --args "$@"
}
BOT_LOGINS='bot[bot]'  # comments() の投稿者は bot

@test "bot など人以外の push で head が進んだ回は、無人の push が失敗していても数えない（#348）" {
  # A の上に別の bot が B を push した（無人の実行は A から push しようとして失敗し、PR の head は B）
  comments "$(run_mark "$A")" >"$TMP/in.json"
  commits_json "$B" "$A" 'other[bot]' >"$TMP/commits.json"
  count --head "$B" --logins "$BOT_LOGINS" --commits "$TMP/commits.json"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads, .other_pushed]' <<<"$output")" '[0,[],1]'
}

@test "head が進んだ先のコミットの committer が無人の実行なら数える（大文字小文字と [bot] は問わない）" {
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  commits_json "$B" "$A" 'Bot' "$C" "$B" 'other[bot]' >"$TMP/commits.json"
  count --head "$C" --logins "$BOT_LOGINS" --commits "$TMP/commits.json"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads, .other_pushed]' <<<"$output")" "[1,[\"$A\"],1]"
}

@test "進んだ先のコミットが一覧に無い・committer が読めないときは、数える側に倒す" {
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  commits_json "$C" "$B" '' >"$TMP/commits.json"
  count --head "$C" --logins "$BOT_LOGINS" --commits "$TMP/commits.json"
  assert_success
  assert_equal "$(jq -c '[.count, .other_pushed]' <<<"$output")" '[2,0]'
}

@test "--commits が無ければ、head が進んだ回をすべて数える（今までどおり）" {
  comments "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$B" --logins "$BOT_LOGINS"
  assert_success
  assert_equal "$(jq -c '[.count, .other_pushed]' <<<"$output")" '[1,0]'
}

@test "--commits が配列でない・ファイルが無いときは 64 で止まる" {
  comments "$(run_mark "$A")" >"$TMP/in.json"
  echo '{}' >"$TMP/commits.json"
  count --head "$B" --commits "$TMP/commits.json"
  assert_failure 64
  count --head "$B" --commits "$TMP/none.json"
  assert_failure 64
}
