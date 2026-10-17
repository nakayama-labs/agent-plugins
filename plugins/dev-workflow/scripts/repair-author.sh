#!/usr/bin/env bash
# 無人で指摘に対応してよい投稿者かを、ログイン名から決めて JSON で出力する（ADR 000285）。何も変えない（読むだけ）。
# gh-pr-check の無人の手順と、見回りのワークフローが使う（判断を1か所にまとめ、食い違わないようにする）。
#
# 使い方: repair-author.sh --login LOGIN [--repo OWNER/NAME]
#   --login LOGIN      投稿者のログイン名（some-bot[bot] でも some-bot でもよい）
#   --repo OWNER/NAME  権限を調べるリポジトリ。省略すると、今のリポジトリ（gh の {owner}/{repo}）
#
# 許可する投稿者は、次のどちらかです（上から順に見る）:
#   1. 設定 repair.allowed_authors の投稿者（レビューの bot など。ログイン名は、大文字小文字と末尾の [bot] を区別せずに比べる）
#   2. リポジトリで write 以上の人（collaborators/<ログイン名>/permission の role_name が admin・maintain・write。
#      permission は maintain を write と返すので使わない）
# 権限は、コラボレーターでない人（HTTP 404）を権限なし（none）として扱う。404 以外の失敗（API の一時的なエラーなど）は、
# 権限なしと取り違えず、失敗にする。
#
# 出力（JSON）: {login, action, reason, role}
#   action  allow（許可する）・deny（許可しない。指摘は読むだけで、直さず、返信もしない）
#   reason  allowed_authors（設定で許可）・role（write 以上）・no_permission（それ以外）
#   role    権限を調べたときの role_name（調べなかったときは null。404 は none）
#
# 止まるとき: 引数の誤り（終了コード 64）、設定の repair.allowed_authors が文字列の配列でない（2）、
#             権限を 404 以外の理由で読めない（1）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

login="" repo='{owner}/{repo}'
while [ $# -gt 0 ]; do
  case "$1" in
    --login)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--login に値がありません" 64
      login="$2"
      shift 2
      ;;
    --repo)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--repo に値がありません" 64
      repo="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$login" ] || dw_die "--login は必須です" 64

allowed="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" '.repair.allowed_authors // []')"
jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$allowed" \
  || dw_die "設定の repair.allowed_authors は文字列の配列にしてください" 2

if jq -e --arg l "$login" "$DW_JQ_LOGIN_NORM"'($l | norm) as $w | map(norm) | index($w) != null' >/dev/null <<<"$allowed"; then
  jq -nc --arg l "$login" '{login: $l, action: "allow", reason: "allowed_authors", role: null}'
  exit 0
fi

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if ! role="$(gh api "repos/${repo}/collaborators/${login}/permission" --jq '.role_name' 2>"$err")"; then
  if grep -q 'HTTP 404' "$err"; then
    role=none
  else
    dw_die "${login} の権限を読めません: $(tail -n 1 "$err")" 1
  fi
fi
case "$role" in
  admin | maintain | write) jq -nc --arg l "$login" --arg r "$role" '{login: $l, action: "allow", reason: "role", role: $r}' ;;
  *) jq -nc --arg l "$login" --arg r "$role" '{login: $l, action: "deny", reason: "no_permission", role: $r}' ;;
esac
