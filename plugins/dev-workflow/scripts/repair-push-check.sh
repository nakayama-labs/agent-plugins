#!/usr/bin/env bash
# 無人で push する前に、push で origin に入る変更のパスを機械的に確かめる（ADR 000285「無人で push する条件」）。
#
# 止めるパス（無人で変えてはいけないパス。この一覧が正本で、SKILL.md・設計書は、ここを参照する。ADR 000339）:
#   - リポジトリ直下の .github という名前そのものと、.github/ 以下のすべて（workflows だけでなく、workflow が呼ぶ
#     actions・scripts や CODEOWNERS などでも、CI と権限に影響するため）
#   - どの階層の .claude という名前そのものと、どの階層の .claude/ 以下も（入れ子の .claude/ も、そのディレクトリで動く
#     Claude の権限と設定に影響するため）
#   - 名前そのもの（ファイル・シンボリックリンク・サブモジュール）も止めるのは、中身を差し替えられるため
#   - 大文字と小文字は区別しない（区別しないファイルシステムでは、.Claude/ も .claude/ として読まれるため）
#   - NTFS（Windows）で同じ名前になる別名も、同じ名前として止める（#356）。パスの各階層について、末尾の点と空白を除いた名前
#     （.claude. や ".github "）と、8.3 形式の短い名前（.claude は CLAUDE~1、.github は GITHUB~1。~ の後の数字は問わない）を、
#     .claude・.github と同じに扱う
#   - 入れ子の .github/（docs/.github/ など）は、GitHub が読まないので止めない
# push の対象に、止めるパスの変更が含まれていたら、push してはいけない（ok が false）。
# 何も変えない（読むだけ。push もしない）。
#
# 使い方: repair-push-check.sh --base-branch B [--branch X]
#   --base-branch B  取り込んだブランチ（branch-status.sh の出力の base。例: main）。origin/B と同じ内容のパスは、取り込んだ main の変更なので数えない
#   --branch X       push するブランチ。省略すると今のブランチ。origin/X があれば、それとの差を見る。
#                    origin/X が無い（初回の push）ときは、origin/B との差（PR の変更の全体）を見る
#
# 出力（JSON）: {ok, forbidden（止める理由になるパス）, compared_with（差を取った相手）}
#
# 止まるとき: 引数の誤り・detached HEAD で --branch が無い（終了コード 64）、origin/B が無い・git diff に失敗した（2）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require git jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

base="" branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-branch | --branch)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      if [ "$1" = --base-branch ]; then base="$2"; else branch="$2"; fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$base" ] || dw_die "--base-branch は必須です" 64
if [ -z "$branch" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  # detached HEAD では push するブランチが決まらない
  [ "$branch" != HEAD ] || dw_die "detached HEAD です。--branch で push するブランチを指定してください" 64
fi

git rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null \
  || dw_die "origin/${base} がありません（git fetch origin ${base} を先に実行してください）" 2

if git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null; then
  against="origin/${branch}"
else
  against="origin/${base}"
fi

forbidden='[]'
# プロセス置換の中の git diff の失敗は while に伝わらず、空入力（禁止パスなし）と読まれるので、先にファイルへ取って確かめる
diff_file="$(mktemp "${TMPDIR:-/tmp}/repair-push-check.XXXXXX")"
lower_file="$(mktemp "${TMPDIR:-/tmp}/repair-push-check.XXXXXX")"
trap 'rm -f "$diff_file" "$lower_file"' EXIT
git diff --name-only --no-renames -z "$against" HEAD >"$diff_file" \
  || dw_die "git diff に失敗しました（${against} と HEAD の差を取れません）" 2
# 照らすための、小文字にした写し。bash 3.2 には ${var,,} が無いので、全体を1回の tr で変える（NUL の区切りはそのまま残る）。
# LC_ALL=C で、ASCII の英字だけを変える（バイト数が変わらず、元のパスと1対1に並ぶ）
LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' <"$diff_file" >"$lower_file" \
  || dw_die "パスを小文字にできませんでした" 2
# パスに改行が入っていても壊れないよう -z で読む。元のパス（出力に使う）と、小文字の写し（照らすのに使う）を並べて読む
# NTFS で同じ名前になる別名を、元の名前にそろえる。階層ごとに、末尾の点と空白を除き、8.3 形式の短い名前（claude~1・github~2）を
# .claude・.github に直す（小文字にした後のパスを渡す）。bash 3.2 で動くよう、パラメータ展開とループだけで書く
# 結果は変数 norm_path に入れる（$(...) は末尾の改行を落とすため）
ntfs_norm() {
  local rest="$1" comp
  norm_path=""
  while :; do
    case "$rest" in
      */*) comp="${rest%%/*}"; rest="${rest#*/}" ;;
      *) comp="$rest"; rest="" ;;
    esac
    while :; do
      case "$comp" in
        *. | *" ") comp="${comp%?}" ;;
        *) break ;;
      esac
    done
    case "$comp" in
      claude~*[!0-9]*) ;;
      claude~[0-9]*) comp=.claude ;;
      github~*[!0-9]*) ;;
      github~[0-9]*) comp=.github ;;
    esac
    norm_path="${norm_path:+${norm_path}/}${comp}"
    [ -n "$rest" ] || break
  done
}

while IFS= read -r -d '' path && IFS= read -r -d '' lower <&3; do
  ntfs_norm "$lower"
  case "$norm_path" in
    .github | .github/* | .claude | .claude/* | */.claude | */.claude/*) ;;
    *) continue ;;
  esac
  # 取り込んだ base_branch と同じ内容なら、このブランチの変更ではない
  if git --literal-pathspecs diff --quiet --no-renames "origin/${base}" HEAD -- "$path"; then
    continue
  fi
  forbidden="$(jq -c --arg p "$path" '. + [$p]' <<<"$forbidden")"
done <"$diff_file" 3<"$lower_file"

jq -n --argjson f "$forbidden" --arg c "$against" '{ok: ($f | length == 0), forbidden: $f, compared_with: $c}'
