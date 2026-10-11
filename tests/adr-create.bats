#!/usr/bin/env bats

load test_helper

TEMPLATES="$(cd "$BATS_TEST_DIRNAME/../plugins/dev-workflow/templates/adr" && pwd)"

@test "既定では docs/adr/<Issue 番号を6桁に0埋め>-<名前>.md に、テンプレートから ADR を作る" {
  run_script adr-create.sh --issue 107 --name "Use MADR" --template full
  assert_success
  assert_equal "$(jq -c '[.path, .template, .issue, .date, .superseded, .dry_run]' <<<"$output")" \
    "[\"docs/adr/000107-use-madr.md\",\"full\",107,\"$(date +%F)\",[],false]"
  [ -f docs/adr/000107-use-madr.md ] || fail "ファイルがありません"
}

@test "front matter の date と issue だけを置き換え、残りはテンプレートのまま" {
  run_script adr-create.sh --issue 7 --name x --template full
  assert_success
  assert_equal "$(sed -n 's/^date: //p;s/^issue: //p' docs/adr/000007-x.md)" "$(printf '%s\n7' "$(date +%F)")"
  diff <(grep -v -e '^date:' -e '^issue:' "$TEMPLATES/adr-template.md") <(grep -v -e '^date:' -e '^issue:' docs/adr/000007-x.md)
}

@test "4つのテンプレートのどれでも作れ、date と issue が入る" {
  for t in full minimal bare bare-minimal; do
    run_script adr-create.sh --issue 1 --name "t-$t" --template "$t"
    assert_success
    assert_equal "$(sed -n '/^---$/,/^---$/{s/^issue: *//p;}' "docs/adr/000001-t-$t.md")" "1"
    assert_equal "$(sed -n '/^---$/,/^---$/{s/^date: *//p;}' "docs/adr/000001-t-$t.md")" "$(date +%F)"
  done
}

@test "1つの Issue から、名前を変えて2つ以上作れる" {
  run_script adr-create.sh --issue 5 --name first --template minimal
  assert_success
  run_script adr-create.sh --issue 5 --name second --template minimal
  assert_success
  [ -f docs/adr/000005-first.md ] && [ -f docs/adr/000005-second.md ] || fail "2つ作れていません"
}

@test "名前は小文字の英数字と - に整える（日本語は消える）" {
  run_script adr-create.sh --issue 3 --name "ADR を Use: MADR 4.0" --template bare
  assert_success
  assert_equal "$(jq -r .path <<<"$output")" "docs/adr/000003-adr-use-madr-4-0.md"
}

@test "名前に英数字が無ければ止まる" {
  run_script adr-create.sh --issue 3 --name "判断" --template bare
  assert_failure 64
  assert_output --partial "英数字がありません"
  [ ! -e docs/adr ] || fail "ディレクトリを作っています"
}

@test "同じファイル名があれば上書きせず終了コード 3 で止まる" {
  mkdir -p docs/adr
  echo keep >docs/adr/000002-dup.md
  run_script adr-create.sh --issue 2 --name dup --template full
  assert_failure 3
  assert_equal "$(cat docs/adr/000002-dup.md)" keep
}

@test "置き場所を adr.dir で変えられる" {
  echo '{"adr": {"dir": "doc/decisions/"}}' >.claude/dev-workflow/config.json
  run_script adr-create.sh --issue 9 --name x --template minimal
  assert_success
  assert_equal "$(jq -r .path <<<"$output")" "doc/decisions/000009-x.md"
  [ -f doc/decisions/000009-x.md ] || fail "ファイルがありません"
}

@test "adr.dir が絶対パスや .. を含むときは止まる" {
  for d in /tmp/adr ../adr a/../../adr "" /; do
    echo "{\"adr\": {\"dir\": \"$d\"}}" >.claude/dev-workflow/config.json
    run_script adr-create.sh --issue 9 --name x --template minimal
    assert_failure 2
    assert_output --partial "adr.dir"
  done
}

@test "ワークツリーの中で実行すると、そのワークツリーに作る" {
  git -C "$REPO" worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script adr-create.sh --issue 1 --name x --template full
  assert_success
  [ -f "$TMP/wt/docs/adr/000001-x.md" ] || fail "ワークツリーにありません"
  [ ! -e "$REPO/docs/adr" ] || fail "メインのワークツリーに作っています"
}

@test "--dry-run は何も作らず、することを出力する" {
  run_script adr-create.sh --issue 4 --name x --template full --dry-run
  assert_success
  assert_equal "$(jq -c '[.path, .dry_run]' <<<"$output")" '["docs/adr/000004-x.md",true]'
  [ ! -e docs/adr ] || fail "ディレクトリを作っています"
}

@test "置き換える ADR は status の行だけを superseded by <新しい ADR> に書き換える" {
  run_script adr-create.sh --issue 10 --name old --template full
  assert_success
  cp docs/adr/000010-old.md "$TMP/before.md"
  run_script adr-create.sh --issue 11 --name new --template full --supersedes 000010-old.md
  assert_success
  assert_equal "$(jq -c .superseded <<<"$output")" '["docs/adr/000010-old.md"]'
  assert_equal "$(sed -n 's/^status: //p' docs/adr/000010-old.md)" '"superseded by 000011-new"'
  diff <(grep -v '^status:' "$TMP/before.md") <(grep -v '^status:' docs/adr/000010-old.md)
}

@test "置き換える ADR は、リポジトリのルートからのパスでも、複数でも指定できる" {
  for n in 10 11; do run_script adr-create.sh --issue "$n" --name "o$n" --template minimal; done
  run_script adr-create.sh --issue 12 --name new --template minimal --supersedes docs/adr/000010-o10.md --supersedes 000011-o11.md
  assert_success
  assert_equal "$(grep -c 'superseded by 000012-new' docs/adr/000010-o10.md docs/adr/000011-o11.md | tr '\n' ' ')" \
    "docs/adr/000010-o10.md:1 docs/adr/000011-o11.md:1 "
}

@test "置き換える ADR が無い、または status が無いときは、何も作らず書き換えずに終了コード 4 で止まる" {
  run_script adr-create.sh --issue 10 --name old --template full
  printf '# no front matter\n' >docs/adr/000001-plain.md
  cp docs/adr/000010-old.md "$TMP/before.md"
  run_script adr-create.sh --issue 12 --name new --template full --supersedes 000010-old.md --supersedes 000001-plain.md
  assert_failure 4
  run_script adr-create.sh --issue 12 --name new --template full --supersedes 000010-old.md --supersedes missing.md
  assert_failure 4
  [ ! -e docs/adr/000012-new.md ] || fail "ADR を作っています"
  diff "$TMP/before.md" docs/adr/000010-old.md
}

@test "--dry-run では置き換える ADR も書き換えない" {
  run_script adr-create.sh --issue 10 --name old --template full
  cp docs/adr/000010-old.md "$TMP/before.md"
  run_script adr-create.sh --issue 11 --name new --template full --supersedes 000010-old.md --dry-run
  assert_success
  diff "$TMP/before.md" docs/adr/000010-old.md
}

@test "引数の誤りは終了コード 64" {
  run_script adr-create.sh --name x --template full
  assert_failure 64
  run_script adr-create.sh --issue abc --name x --template full
  assert_failure 64
  run_script adr-create.sh --issue 1234567 --name x --template full
  assert_failure 64
  run_script adr-create.sh --issue 1 --name x
  assert_failure 64
  run_script adr-create.sh --issue 1 --name x --template huge
  assert_failure 64
  run_script adr-create.sh --issue 1 --name x --template full --bogus
  assert_failure 64
}

@test "先頭が 0 の Issue 番号は、8進数ではなく10進数として扱う" {
  run_script adr-create.sh --issue 08 --name x --template full
  assert_success
  assert_equal "$(jq -c '[.path, .issue]' <<<"$output")" '["docs/adr/000008-x.md",8]'
  assert_equal "$(sed -n 's/^issue: //p' docs/adr/000008-x.md)" 8
  run_script adr-create.sh --issue 010 --name y --template full
  assert_success
  assert_equal "$(jq -c '[.path, .issue]' <<<"$output")" '["docs/adr/000010-y.md",10]'
  assert_equal "$(sed -n 's/^issue: //p' docs/adr/000010-y.md)" 10
}

@test "7桁以上や、10進数にすると桁があふれる極端に長い Issue 番号は、終了コード 64 で止まる（6桁までは作れる）" {
  run_script adr-create.sh --issue 18446744073709551616 --name x --template full
  assert_failure 64
  run_script adr-create.sh --issue 1000000 --name x --template full
  assert_failure 64
  run_script adr-create.sh --issue 0000100 --name x --template full
  assert_success
  assert_equal "$(jq -r .path <<<"$output")" "docs/adr/000100-x.md"
  run_script adr-create.sh --issue 999999 --name x --template full
  assert_success
  assert_equal "$(jq -r .path <<<"$output")" "docs/adr/999999-x.md"
  # Issue #0 は無いので、0 だけの番号は止まる（ほかのスクリプトと同じ dw_issue_number）
  run_script adr-create.sh --issue 0000 --name x --template full
  assert_failure 64
  assert_output --partial "--issue には Issue の番号を指定してください: 0000"
}

@test "--issue は #12 の形でも受ける（ほかのスクリプトと同じ dw_issue_number）" {
  run_script adr-create.sh --issue '#8' --name x --template full
  assert_success
  assert_equal "$(jq -r .path <<<"$output")" "docs/adr/000008-x.md"
}

@test "置き換える ADR の front matter が閉じていなければ、何も作らず書き換えずに終了コード 4 で止まる" {
  mkdir -p docs/adr
  printf -- '---\ntitle: x\n\n# 本文\nstatus: accepted\n' >docs/adr/000001-open.md
  cp docs/adr/000001-open.md "$TMP/before.md"
  run_script adr-create.sh --issue 12 --name new --template full --supersedes 000001-open.md
  assert_failure 4
  [ ! -e docs/adr/000012-new.md ] || fail "ADR を作っています"
  diff "$TMP/before.md" docs/adr/000001-open.md
}

@test "置き換える ADR に書き込めなければ、何も作らず、一時ファイルも残さずに終了コード 4 で止まる" {
  [ "$(id -u)" -ne 0 ] || skip "root は読み取り専用のファイルにも書ける"
  run_script adr-create.sh --issue 10 --name old --template full
  mkdir "$TMP/tmpdir"
  chmod a-w docs/adr/000010-old.md
  TMPDIR="$TMP/tmpdir" run_script adr-create.sh --issue 11 --name new --template full --supersedes 000010-old.md
  chmod u+w docs/adr/000010-old.md
  assert_failure 4
  [ ! -e docs/adr/000011-new.md ] || fail "ADR を作っています"
  assert_equal "$(ls -A "$TMP/tmpdir")" ""
}

@test "置き換える ADR の書き換えが途中で失敗したら、書き換え済みの ADR と、新しい ADR が残ることを知らせる" {
  for n in 10 11; do run_script adr-create.sh --issue "$n" --name "o$n" --template minimal; done
  # 2つ目の書き戻し（一時ファイルを cat する）だけを失敗させる偽の cat
  mkdir "$TMP/bin" "$TMP/tmpdir"
  cat >"$TMP/bin/cat" <<FAKE
#!/bin/sh
case "\$1" in
  "$TMP"/tmpdir/adr-create.*)
    echo x >>"$TMP/cat-calls"
    [ "\$(wc -l <"$TMP/cat-calls")" -ge 2 ] && exit 1
    ;;
esac
exec /bin/cat "\$@"
FAKE
  chmod +x "$TMP/bin/cat"
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmpdir" run_script adr-create.sh --issue 12 --name new --template minimal \
    --supersedes 000010-o10.md --supersedes 000011-o11.md
  assert_failure 1
  assert_output --partial "000011-o11.md"
  assert_output --partial "docs/adr/000012-new.md は残っています"
  assert_output --partial "すでに書き換えた ADR: docs/adr/000010-o10.md"
  assert_equal "$(sed -n 's/^status: //p' docs/adr/000010-o10.md)" '"superseded by 000012-new"'
  assert_equal "$(ls -A "$TMP/tmpdir")" ""
}

@test "--date で front matter の date を判断をした日にできる（出力の date も同じ）" {
  run_script adr-create.sh --issue 1 --name x --template full --date 2025-01-09
  assert_success
  assert_equal "$(jq -r .date <<<"$output")" "2025-01-09"
  assert_equal "$(sed -n '/^---$/,/^---$/{s/^date: *//p;}' docs/adr/000001-x.md)" "2025-01-09"
}

@test "--date は、うるう年の2月29日を受け付ける" {
  run_script adr-create.sh --issue 1 --name x --template minimal --date 2024-02-29 --dry-run
  assert_success
  run_script adr-create.sh --issue 1 --name x --template minimal --date 2000-02-29 --dry-run
  assert_success
}

@test "--date が YYYY-MM-DD の形でない、または暦にない日なら、何も作らず終了コード 64 で止まる" {
  for d in 2025-1-09 2025/01/09 20250109 2025-01-09x 2025-13-01 2025-00-10 2025-04-31 2025-02-29 1900-02-29 2025-01-00 2025-08-08x; do
    run_script adr-create.sh --issue 1 --name x --template full --date "$d"
    assert_failure 64
    assert_output --partial "--date"
  done
  run_script adr-create.sh --issue 1 --name x --template full --date
  assert_failure 64
  [ ! -e docs/adr ] || fail "ディレクトリを作っています"
}

@test "設定を読めなければ止まる" {
  echo '{' >.claude/dev-workflow/config.json
  run_script adr-create.sh --issue 1 --name x --template full
  assert_failure 2
  assert_output --partial "設定を読めません"
}

@test "改行が \r\n で先頭に BOM がある ADR も置き換えられ、status の行の改行と、ほかの行はそのまま残す" {
  mkdir -p docs/adr
  printf -- '\357\273\277---\r\nstatus: "accepted"\r\nissue: 3\r\n---\r\n\r\n# 古い\r\nstatus: 本文の行\r\n' >docs/adr/000003-old.md
  run_script adr-create.sh --issue 11 --name new --template minimal --supersedes 000003-old.md
  assert_success
  printf -- '\357\273\277---\r\nstatus: "superseded by 000011-new"\r\nissue: 3\r\n---\r\n\r\n# 古い\r\nstatus: 本文の行\r\n' >"$TMP/expected"
  run cmp "$TMP/expected" docs/adr/000003-old.md
  assert_success
}

# minimal のテンプレートにも「補足」の節がある（#379）。一部だけ変える ADR のリンクが、変えられた側の逆引きに出る
@test "minimal の2つのテンプレートには「補足」の節がある" {
  for t in adr-template-minimal.md adr-template-bare-minimal.md; do
    grep -q '^## 補足$' "$TEMPLATES/$t" || fail "$t に「補足」の節がありません"
  done
}

@test "minimal・bare-minimal で一部だけ変える ADR を書くと、変えられた側の cited_in_supplements に出る" {
  for t in minimal bare-minimal; do
    run_script adr-create.sh --issue 10 --name "old-$t" --template full
    assert_success
    run_script adr-create.sh --issue 11 --name "part-$t" --template "$t"
    assert_success
    printf '\n[ADR 000010](000010-old-%s.md) の一部を変える。\n' "$t" >>"docs/adr/000011-part-$t.md"
    run_script adr-list.sh
    assert_success
    assert_equal "$(jq -c --arg p "docs/adr/000010-old-$t.md" '.adrs[] | select(.path == $p) | .cited_in_supplements' <<<"$output")" \
      "[\"docs/adr/000011-part-$t.md\"]"
    rm -f docs/adr/*.md
  done
}

write_proposed() {
  mkdir -p docs/adr
  printf -- '---\nstatus: %s\ndate: 2020-01-01\nissue: 3\ndecision-makers: x\n---\n\n# 題\n\nstatus: 本文の行\ndate: 本文の日\n' "${1:-\"proposed\"}" >docs/adr/000003-p.md
}

@test "--accept は proposed の ADR の status と date の2行だけを書き換える" {
  write_proposed
  cp docs/adr/000003-p.md "$TMP/before.md"
  run_script adr-create.sh --accept 000003-p.md --date 2026-10-11
  assert_success
  assert_equal "$(jq -c '[.path, .status, .date, .accepted, .dry_run]' <<<"$output")" '["docs/adr/000003-p.md","accepted","2026-10-11",true,false]'
  assert_equal "$(sed -n '2,3p' docs/adr/000003-p.md)" "$(printf 'status: "accepted"\ndate: 2026-10-11')"
  diff <(grep -v -e '^status: "proposed"' -e '^date: 2020' "$TMP/before.md") <(grep -v -e '^status: "accepted"' -e '^date: 2026' docs/adr/000003-p.md)
}

@test "--accept は --date を省くと今日の日付にし、リポジトリのルートからのパスでも指定でき、引用符の無い proposed も読む" {
  write_proposed proposed
  run_script adr-create.sh --accept docs/adr/000003-p.md
  assert_success
  assert_equal "$(sed -n '2,3p' docs/adr/000003-p.md)" "$(printf 'status: "accepted"\ndate: %s' "$(date +%F)")"
}

@test "--accept は proposed でない ADR では、何も書き換えずに終了コード 4 で止まる" {
  for s in '"accepted"' '"superseded by 000005-x"' '"proposed-ish"'; do
    write_proposed "$s"
    cp docs/adr/000003-p.md "$TMP/before.md"
    run_script adr-create.sh --accept 000003-p.md
    assert_failure 4
    diff "$TMP/before.md" docs/adr/000003-p.md
  done
}

@test "--accept は ADR が無い、front matter が閉じていない、status か date の行が無いときも、書き換えずに終了コード 4 で止まる" {
  run_script adr-create.sh --accept missing.md
  assert_failure 4
  mkdir -p docs/adr
  printf -- '---\nstatus: "proposed"\ndate: 2020-01-01\n' >docs/adr/000001-open.md
  printf -- '---\nstatus: "proposed"\n---\n' >docs/adr/000002-nodate.md
  printf -- '---\ndate: 2020-01-01\n---\n' >docs/adr/000004-nostatus.md
  printf '# plain\n' >docs/adr/000005-plain.md
  for f in 000001-open 000002-nodate 000004-nostatus 000005-plain; do
    cp "docs/adr/$f.md" "$TMP/before.md"
    run_script adr-create.sh --accept "$f.md"
    assert_failure 4
    diff "$TMP/before.md" "docs/adr/$f.md"
  done
}

@test "--accept --dry-run は書き換えない" {
  write_proposed
  cp docs/adr/000003-p.md "$TMP/before.md"
  run_script adr-create.sh --accept 000003-p.md --dry-run
  assert_success
  assert_equal "$(jq -c '[.status, .dry_run]' <<<"$output")" '["accepted",true]'
  diff "$TMP/before.md" docs/adr/000003-p.md
}

@test "--accept は --issue・--name・--template・--supersedes と一緒には使えず、--date の誤りも止める（終了コード 64）" {
  write_proposed
  run_script adr-create.sh --accept 000003-p.md --issue 3
  assert_failure 64
  run_script adr-create.sh --accept 000003-p.md --supersedes 000003-p.md
  assert_failure 64
  run_script adr-create.sh --accept 000003-p.md --date 2026-02-30
  assert_failure 64
  assert_equal "$(sed -n 2p docs/adr/000003-p.md)" 'status: "proposed"'
}

@test "--accept は改行が \r\n で先頭に BOM がある ADR も採択でき、2行の改行と、ほかの行はそのまま残す" {
  mkdir -p docs/adr
  printf -- '\357\273\277---\r\nstatus: "proposed"\r\ndate: 2020-01-01\r\n---\r\n\r\n# 題\r\nstatus: 本文の行\r\n' >docs/adr/000003-p.md
  run_script adr-create.sh --accept 000003-p.md --date 2026-10-11
  assert_success
  printf -- '\357\273\277---\r\nstatus: "accepted"\r\ndate: 2026-10-11\r\n---\r\n\r\n# 題\r\nstatus: 本文の行\r\n' >"$TMP/expected"
  run cmp "$TMP/expected" docs/adr/000003-p.md
  assert_success
}

@test "--accept は、末尾に改行の無い ADR に改行を足さず、書き換えるのは status と date の2行だけにする" {
  mkdir -p docs/adr
  printf -- '---\nstatus: "proposed"\ndate: 2020-01-01\n---\n\n# 題\n\n本文' >docs/adr/000003-p.md
  run_script adr-create.sh --accept 000003-p.md --date 2026-10-11
  assert_success
  printf -- '---\nstatus: "accepted"\ndate: 2026-10-11\n---\n\n# 題\n\n本文' >"$TMP/expected"
  run cmp "$TMP/expected" docs/adr/000003-p.md
  assert_success
  # 末尾が改行のファイルは、改行を残す
  printf -- '---\nstatus: "proposed"\ndate: 2020-01-01\n---\n' >docs/adr/000004-q.md
  run_script adr-create.sh --accept 000004-q.md --date 2026-10-11
  assert_success
  printf -- '---\nstatus: "accepted"\ndate: 2026-10-11\n---\n' >"$TMP/expected"
  run cmp "$TMP/expected" docs/adr/000004-q.md
  assert_success
}
