#!/usr/bin/env bash
# pr-repair.yml が、無人で直す対象の PR を選ぶ（Claude を動かす前の判定。何も書き込まない）。ADR 000285・000411。
#
# 使い方: pr-repair-select.sh [--pr N]... [--sender LOGIN]
#   --pr N          この PR だけを調べる（何度も指定できる）。省略すると、開いている PR をすべて調べる
#   --sender LOGIN  イベントで起動したときの、コメント・レビューの投稿者。許可した投稿者でなければ、何も選ばない
#                   （許可は repair-author.sh が決める：設定 repair.allowed_authors の投稿者、またはリポジトリの write 以上の人。無人の実行そのもの APP_LOGIN は許可しない）
#
# 環境変数:
#   GITHUB_REPOSITORY  <所有者>/<名前>（必須）
#   BOT_LOGINS         自動で作った PR の作成者として認める GitHub App のログイン名（, 区切り。必須）
#   APP_LOGIN          無人の実行を動かす GitHub App のログイン名（--sender がこれなら選ばない。ループを防ぐ）
#   SCRIPTS_DIR        plugins/dev-workflow/scripts の場所（既定：このファイルから見た場所）
#
# 「自動で作った PR」は、開いていて、下書きでなく、head がこのリポジトリのブランチ（フォークでない）で、作成者が BOT_LOGINS の
# どれかであるもの。本文は書き換えられるので、見分けには使わない（作成者と head は人が偽れない）。
# さらに、PR が閉じる Issue（本文の Closes #N）が1つに決まり、その Issue が保留の列（status.hold）に無いものだけを対象にする
# （保留の列にあるのは、無人の実行が止まった PR。人が戻すまで触れない。止まるときに移す列が無ければ、何も選ばない）。
# 選んだ PR に pr-watch.sh --pr N を実行し、action が act・conflict・stop のものだけを出力する。
#
# 出力（JSON の配列）: [{pr, issue, branch, head_sha, action, reasons}]。選ばれたものが無ければ []
# 1つの PR を調べられなかったとき（pr-watch.sh の失敗など）は、その PR を飛ばし、標準エラーに1行を出して続ける。
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY が必要です}"
: "${BOT_LOGINS:?BOT_LOGINS が必要です}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(CDPATH='' cd "$(dirname "$0")/../../plugins/dev-workflow/scripts" && pwd)}"
# shellcheck source=/dev/null # 場所は SCRIPTS_DIR で決まる
. "$SCRIPTS_DIR/lib/common.sh"

# ログイン名を比べる形にする。規則は pr-watch.sh・pr-feedback.sh と同じ（DW_JQ_LOGIN_NORM：大文字小文字と末尾の [bot] を区別しない）。
# ここで規則を書き直さず、同じ定義を使う。PR の作成者は REST（user.login。app[bot] の綴り）で読むので、gh pr view の綴りは扱わない
norm() { jq -rn --arg l "$1" "$DW_JQ_LOGIN_NORM"'$l | norm'; }
# , 区切りのログイン名の一覧に、ログイン名があるか
in_list() {
  local want item
  want="$(norm "$1")"
  [ -n "$want" ] || return 1
  # 区切りの前後の空白は除く
  while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$item" ] || [ "$(norm "$item")" != "$want" ] || return 0
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  return 1
}

prs=() sender=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "--pr に値がありません" >&2; exit 64; }
      prs+=("${2#\#}")
      shift 2
      ;;
    --sender)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "--sender に値がありません" >&2; exit 64; }
      sender="$2"
      shift 2
      ;;
    -h | --help)
      LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"
      exit 0
      ;;
    *) echo "不明な引数です: $1" >&2; exit 64 ;;
  esac
done

# 指摘に対応してよい投稿者か。判断は repair-author.sh（設定 repair.allowed_authors・write 以上の権限）に任せる。
# 権限を読めないとき（404 以外の失敗）は、権限なしと取り違えず、ここも失敗にする（set -e で止まる）
# 結果はログインごとに覚えて、同じ実行の中で同じログインに repair-author.sh（権限の API）を何度も呼ばない。
# 失敗は覚えない（exit 1 で止まる）。ログイン名の形でない値（終了コード 64）は deny として覚える。連想配列は bash 3.2 に無いので、「<小文字のログイン名> <allow|deny>」の行の文字列で持つ
allow_cache=""
is_allowed() {
  local key out action line rc
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  line="$(printf '%s' "$allow_cache" | grep -F -x -e "${key} allow" -e "${key} deny" || true)"
  if [ -n "$line" ]; then
    [ "${line##* }" = allow ]
    return
  fi
  # 終了コード 64（ログイン名の形でない値）は、見回り全体を止めず、許可しない扱いにする。API の失敗（1 など）は止める
  rc=0
  out="$("$SCRIPTS_DIR/repair-author.sh" --login "$1" --repo "$GITHUB_REPOSITORY")" || rc=$?
  if [ "$rc" -eq 64 ]; then
    echo "ログイン名の形でない投稿者 ${1} は、許可しない扱いにします" >&2
    out='{"action": "deny"}'
  elif [ "$rc" -ne 0 ]; then
    exit 1
  fi
  action="$(jq -r .action <<<"$out")"
  allow_cache="${allow_cache}${key} ${action}"$'\n'
  [ "$action" = allow ]
}

if [ -n "$sender" ]; then
  if [ -n "${APP_LOGIN:-}" ] && [ "$(norm "$sender")" = "$(norm "$APP_LOGIN")" ]; then
    echo "投稿者 ${sender} は無人の実行そのものなので、選びません" >&2
    echo '[]'
    exit 0
  fi
  if ! is_allowed "$sender"; then
    echo "投稿者 ${sender} は、許可した投稿者でも write 以上の人でもないので、選びません" >&2
    echo '[]'
    exit 0
  fi
fi

hold_col="$("$SCRIPTS_DIR/config.sh" '.status.hold // empty')"
if [ -z "$hold_col" ]; then
  echo "保留の列（status.hold）が設定されていません。止まるときに移す列が無いので、何も選びません" >&2
  echo '[]'
  exit 0
fi

if [ "${#prs[@]}" -eq 0 ]; then
  while IFS= read -r n; do
    prs+=("$n")
  done < <(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls?state=open&per_page=100" --jq '.[].number')
fi

selected='[]'
for n in ${prs[@]+"${prs[@]}"}; do
  pull="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${n}")" || { echo "PR #${n} を読めないので飛ばします" >&2; continue; }
  # 開いていて、下書きでなく、head が同じリポジトリのブランチ
  if ! jq -e --arg r "$GITHUB_REPOSITORY" '.state == "open" and (.draft | not)
      and (((.head.repo.full_name // "") | ascii_downcase) == ($r | ascii_downcase))' >/dev/null <<<"$pull"; then
    echo "PR #${n} は、開いていない・下書き・フォークのどれかなので飛ばします" >&2
    continue
  fi
  author="$(jq -r '.user.login // ""' <<<"$pull")"
  if ! in_list "$author" "$BOT_LOGINS"; then
    echo "PR #${n} の作成者 ${author} は、自動で PR を作る App ではないので飛ばします" >&2
    continue
  fi
  # PR が閉じる Issue が1つに決まらないときは、止まるときに理由を書く先が無いので、無人では直さない
  issues="$(jq -c '[(.body // "") | scan("(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[[:space:]]+#([0-9]+)") | .[0] | tonumber] | unique' <<<"$pull")"
  if [ "$(jq 'length' <<<"$issues")" -ne 1 ]; then
    echo "PR #${n} が閉じる Issue を1つに決められないので飛ばします（${issues}）" >&2
    continue
  fi
  issue="$(jq -r '.[0]' <<<"$issues")"
  # 保留の列にある Issue の PR は、人が戻すまで触れない（止まった PR を見回りのたびに止め直さない）
  if ! items="$(gh issue view "$issue" --repo "$GITHUB_REPOSITORY" --json projectItems --jq '[.projectItems[]?.status.name // empty]')"; then
    echo "Issue #${issue} の列を読めないので、PR #${n} を飛ばします" >&2
    continue
  fi
  if jq -e --arg h "$hold_col" 'index($h) != null' >/dev/null <<<"$items"; then
    echo "Issue #${issue} は保留の列（${hold_col}）にあるので、PR #${n} を飛ばします" >&2
    continue
  fi
  if ! watch="$("$SCRIPTS_DIR/pr-watch.sh" --pr "$n")"; then
    echo "PR #${n} の状態を判定できないので飛ばします" >&2
    continue
  fi
  action="$(jq -r '.action' <<<"$watch")"
  case "$action" in
    act | conflict | stop) ;;
    *) continue ;;
  esac
  # CI の失敗が無く、返事をしていない指摘だけで act のときは、その指摘を付けた人が許可した投稿者のときだけ対象にする
  # （許可していない人のコメントで、見回りのたびに Claude を動かさない）。指摘の投稿者を読めないときは、対象にする
  if [ "$action" = act ] && ! jq -e '.reasons | index("ci_failed")' >/dev/null <<<"$watch"; then
    if fb="$("$SCRIPTS_DIR/pr-feedback.sh" --pr "$n" 2>/dev/null)"; then
      open_authors="$(jq -r '.feedback[] | select([.threads[].needs_attention, .reviews[].needs_attention, .comments[].needs_attention] | any) | .author' <<<"$fb")"
      any_allowed=false
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        if is_allowed "$a"; then any_allowed=true; break; fi
      done <<<"$open_authors"
      if [ "$any_allowed" != true ]; then
        echo "PR #${n} の返事をしていない指摘は、許可していない投稿者のものだけなので飛ばします" >&2
        continue
      fi
    fi
  fi
  selected="$(jq -c --argjson w "$watch" --argjson p "$pull" --argjson n "$n" --argjson i "$issue" \
    '. + [{pr: $n, issue: $i, branch: $p.head.ref, head_sha: $p.head.sha, action: $w.action, reasons: $w.reasons}]' <<<"$selected")"
done

printf '%s\n' "$selected"
