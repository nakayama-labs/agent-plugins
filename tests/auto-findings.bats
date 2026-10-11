#!/usr/bin/env bats

load test_helper

setup() {
  test_helper_setup
}

# 記録のファイル（$TMP/f.json）を、引数の JSON で作る
write_ledger() { printf '%s\n' "$1" >"$TMP/f.json"; }

run_findings() { run_script auto-findings.sh --file "$TMP/f.json" "$@"; }

@test "全件に起票した番号か理由があり、件数が合えば、内訳を出力する" {
  write_ledger '[
    {"summary":"bin/greet.sh:4 誤字","disposition":"filed","issue":99},
    {"summary":"a.sh:1 重複","disposition":"duplicate","issue":12},
    {"summary":"b.sh:2 破壊的","disposition":"breaking","reason":"設定の名前が変わる"},
    {"summary":"c.sh:3 上限","disposition":"limit","reason":"max_new_issues に達した"},
    {"summary":"d.sh:4 失敗","disposition":"failed","reason":"issue-create.sh が失敗した"}]'
  run_findings --expect 5
  assert_success
  assert_equal "$(jq -c '[.total, .expected, .filed, .duplicates, .counts]' <<<"$output")" \
    '[5,5,[99],[12],{"filed":1,"duplicate":1,"breaking":1,"limit":1,"failed":1}]'
}

@test "範囲外の指摘が無いときは、空の配列と --expect 0 で通る" {
  write_ledger '[]'
  run_findings --expect 0
  assert_success
  assert_equal "$(jq -c '[.total, .filed]' <<<"$output")" '[0,[]]'
}

@test "番号も理由も無い指摘があると止まり、その指摘の位置と要約を伝える（1行）" {
  write_ledger '[{"summary":"ok","disposition":"filed","issue":99},{"summary":"x.sh:9 起票し忘れ","disposition":"filed"}]'
  run_findings --expect 2
  assert_failure 2
  assert_output --partial '2 件目（x.sh:9 起票し忘れ）'
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
}

@test "起票しなかった扱いに理由が無い・空白だけだと止まる" {
  for d in breaking limit failed; do
    write_ledger "[{\"summary\":\"s\",\"disposition\":\"$d\"}]"
    run_findings --expect 1
    assert_failure 2
    assert_output --partial 'reason に起票しなかった理由がありません'
    write_ledger "[{\"summary\":\"s\",\"disposition\":\"$d\",\"reason\":\"  \"}]"
    run_findings --expect 1
    assert_failure 2
  done
}

@test "filed・duplicate は番号が正の整数でないと止まる（0・文字列・小数）" {
  for v in 0 '"99"' 1.5 null; do
    write_ledger "[{\"summary\":\"s\",\"disposition\":\"duplicate\",\"issue\":$v}]"
    run_findings --expect 1
    assert_failure 2
    assert_output --partial 'Issue の番号がありません'
  done
}

@test "理由だけでは filed にならない（起票した扱いには番号が要る）" {
  write_ledger '[{"summary":"s","disposition":"filed","reason":"起票した"}]'
  run_findings --expect 1
  assert_failure 2
}

@test "扱いが決まっていない・使えない値の指摘は止まる" {
  write_ledger '[{"summary":"s"}]'
  run_findings --expect 1
  assert_failure 2
  assert_output --partial 'disposition が使えない値です'
  write_ledger '[{"summary":"s","disposition":"pending","issue":3}]'
  run_findings --expect 1
  assert_failure 2
  write_ledger '[{"summary":"","disposition":"filed","issue":3}]'
  run_findings --expect 1
  assert_failure 2
  assert_output --partial 'summary が空です'
  write_ledger '["文字列"]'
  run_findings --expect 1
  assert_failure 2
}

@test "記録の件数が、数え直した数と違うと止まる（書き出し忘れ。空の記録でも）" {
  write_ledger '[]'
  run_findings --expect 1
  assert_failure 2
  assert_output --partial '記録は 0 件ですが、レビューの一覧から数え直すと 1 件です'
  write_ledger '[{"summary":"s","disposition":"filed","issue":99}]'
  run_findings --expect 0
  assert_failure 2
  run_findings --expect 08
  assert_failure 2
}

@test "記録のファイルが無い・配列でない・JSON でないと止まる" {
  run_script auto-findings.sh --file "$TMP/none.json" --expect 0
  assert_failure 64
  write_ledger '{"a":1}'
  run_findings --expect 0
  assert_failure 2
  printf 'not json' >"$TMP/f.json"
  run_findings --expect 0
  assert_failure 2
}

@test "--file・--expect が無い・--expect が整数でないと止まる" {
  write_ledger '[]'
  run_script auto-findings.sh --expect 0
  assert_failure 64
  run_script auto-findings.sh --file "$TMP/f.json"
  assert_failure 64
  run_findings --expect abc
  assert_failure 64
  run_findings --expect -1
  assert_failure 64
  run_findings --bogus
  assert_failure 64
}

@test "--help は使い方を出す" {
  run_script auto-findings.sh --help
  assert_success
  assert_output --partial '使い方: auto-findings.sh --file PATH --expect N'
}

@test "disposition が文字列でない値（配列など）は、使えない値として終了コード 2・1行で止まる" {
  for v in '["filed"]' '{"a":1}' 1 true; do
    write_ledger "[{\"summary\":\"s\",\"disposition\":$v,\"issue\":3,\"reason\":\"r\"}]"
    run_findings --expect 1
    assert_failure 2
    assert_output --partial 'disposition が使えない値です'
    assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
  done
}

@test "--expect に桁数の多い巨大な値を渡しても、1行のエラーで止まる" {
  write_ledger '[]'
  run_findings --expect 100000000000000000000
  assert_failure 64
  assert_output --partial '--expect'
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
  # 先頭の 0 が多くても、数としては小さい値なので通る
  run_findings --expect 0000000000000000000000
  assert_success
}

@test "summary に改行があっても、エラーのメッセージは1行になる" {
  write_ledger '[{"summary":"a.sh:1\n二行目","disposition":"filed"},{"summary":"b.sh:2","disposition":"limit"}]'
  run_findings --expect 2
  assert_failure 2
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
  assert_output --partial 'a.sh:1 二行目'
}

@test "記録のファイルに JSON が複数連なっていると、1行のエラーで止まる" {
  printf '[]\n[1]\n' >"$TMP/f.json"
  run_findings --expect 0
  assert_failure 2
  assert_output --partial '1つの JSON の配列'
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
  printf '[]\n[]\n' >"$TMP/f.json"
  run_findings --expect 0
  assert_failure 2
  printf '' >"$TMP/f.json"
  run_findings --expect 0
  assert_failure 2
}

@test "同じ summary の指摘が複数あると（前後の空白を除いて比べる）、1行のエラーで止まる" {
  write_ledger '[{"summary":"a.sh:1 誤字","disposition":"filed","issue":9},{"summary":" a.sh:1 誤字\n","disposition":"limit","reason":"r"}]'
  run_findings --expect 2
  assert_failure 2
  assert_output --partial 'summary が重複'
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
}
