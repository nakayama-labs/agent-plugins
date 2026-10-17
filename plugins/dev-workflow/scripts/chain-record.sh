#!/usr/bin/env bash
# 連鎖（マージの後に次の Issue へ進める）で、進めた Issue の記録を、連鎖の最初の Issue のコメントから読み、必要なら足す（ADR 000411）。
# 記録は、最初の Issue のコメントの先頭の印（<!-- dev-workflow:task-auto-sequence chain=ID issue=N -->）で、進めた Issue ごとに
# 1件ずつ足す（コメントを書き換えず、足すだけにする。連鎖の実行は同時に1つだけで、足した分は消えない）。
# 件数は、その連鎖の id の印にある Issue の番号の数（重複は1件）で、最初の Issue も数える。
# 次の Issue へ進む前に、その Issue をここで先に記録する。記録できなければ、進めずに連鎖を終える（終了コード 1）。
# 同じ Issue を何度足しても、コメントは1件だけ（足し直さない）。
#
# 使い方: chain-record.sh --first N --chain-id ID [--add M] [--dry-run]
#   --first N       連鎖の最初の Issue の番号（#N でもよい）。記録のコメントはこの Issue に付ける
#   --chain-id ID   連鎖の id（英数字と . _ -。例: 20261008T101500-4821）。連鎖を始めるときに1つ決め、以後は同じ値を渡す
#   --add M         この Issue を進めた分として記録する（#M でもよい）。連鎖を始めるときは、最初の Issue を足す。省略すると読むだけ
#   --dry-run       コメントせず、行う予定の操作を出力する
#
# 止まるとき: --first・--chain-id が無い・--chain-id に使えない文字がある（終了コード 64）、--first・--add が PR の番号・
#             無い番号（2。--add の Issue は、足す前に読んで確かめる。何もコメントしない）、
#             最初の Issue を読めない・--add の Issue を読めない・コメントできない（1。連鎖は終える）
#
# 出力: {first, chain_id, issues（記録にある Issue の番号の配列。--add の分を含む。--dry-run では足す予定の分も含む）,
#        count（issues の数）, recorded（今回コメントしたか。dry-run ではする予定か）, dry_run}
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

first="" chain_id="" add="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --first | --chain-id | --add)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --first) first="$(dw_issue_number --issue "$2")" ;;
        --chain-id) chain_id="$2" ;;
        --add) add="$(dw_issue_number --issue "$2")" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$first" ] || dw_die "--first は必須です" 64
[ -n "$chain_id" ] || dw_die "--chain-id は必須です" 64
case "$chain_id" in *[!A-Za-z0-9._-]*) dw_die "--chain-id には英数字と . _ - だけを使ってください: ${chain_id}" 64 ;; esac

# PR の番号なら止まる（dw_read_issue）
found="$(dw_read_issue "$first" number,comments "最初の Issue")"
# 足す Issue が PR の番号・無い番号なら、コメントする前に止まる（記録に Issue でない番号が入らないように）
if [ -n "$add" ] && [ "$add" != "$first" ]; then
  dw_read_issue "$add" number "足す Issue" >/dev/null
fi
# コメントの先頭が印のものだけを数える（本文の途中に印を引用しただけのコメントは数えない）。番号は重複を1件にして、小さい順に並べる
issues="$(jq -c --arg id "$chain_id" '
  [.comments[]?.body
   | capture("^<!-- dev-workflow:task-auto-sequence chain=" + ($id | gsub("[.]"; "\\.")) + " issue=(?<n>[0-9]+) -->")?
   | .n | tonumber] | unique' <<<"$found")"

recorded=false
if [ -n "$add" ] && ! jq -e --argjson m "$add" 'index($m) != null' <<<"$issues" >/dev/null; then
  recorded=true
  if ! $dry_run; then
    language="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" .language)"
    if [ "$language" = ja ]; then
      text="連鎖（${chain_id}）で Issue #${add} を進めました。"
    else
      text="The chain (${chain_id}) proceeded with Issue #${add}."
    fi
    printf '<!-- dev-workflow:task-auto-sequence chain=%s issue=%s -->\n%s\n' "$chain_id" "$add" "$text" \
      | gh issue comment "$first" --body-file - >/dev/null \
      || dw_die "最初の Issue #${first} に連鎖の記録をコメントできませんでした"
  fi
  issues="$(jq -c --argjson m "$add" '. + [$m] | unique' <<<"$issues")"
fi

jq -n --argjson f "$first" --arg id "$chain_id" --argjson i "$issues" --argjson r "$recorded" --argjson d "$dry_run" \
  '{first: $f, chain_id: $id, issues: $i, count: ($i | length), recorded: $r, dry_run: $d}'
