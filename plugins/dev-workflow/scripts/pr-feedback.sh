#!/usr/bin/env bash
# PR の状態（CI・レビュー・マージできるか）と、付いた指摘・質問（未解決のスレッド・レビュー本文・PR のコメント）を、
# 投稿者ごとにまとめて JSON で出力する。何も変えない（読むだけ）。gh-pr-check スキルと、それが呼ぶ担当の skill
# （リポジトリが置いた、レビューの bot の担当の skill など）が使う。出力の形を変えるときは、担当の skill の手順も確かめる。
#
# 使い方: pr-feedback.sh [--pr N]
#   --pr N   PR の番号（#N でもよい）。省略すると今のブランチの PR
#
# 出力（JSON）:
#   pr         number・url・title・state・draft・author・head（ブランチ名）・head_sha・base・mergeable・merge_state・review_decision
#              （merge_state は GitHub の mergeStateStatus。review_decision は無ければ null）
#   checks     state（failure・pending・success・none）と、failed・pending（name・workflow・url の配列）、total
#   handlers   設定の pr_check.handlers（投稿者 → 担当する skill の名前）
#   feedback   投稿者ごとの配列。author・handler（担当する skill。無ければ null）・threads・reviews・comments
#     threads   resolved でないスレッド。id（先頭のコメントの ID。返信に使う）・path・line・outdated・url・
#               comments（author・body・created_at・url）・replied・needs_attention
#     reviews   レビュー。本文のあるものと、承認（APPROVED）・変更の要求（CHANGES_REQUESTED）。id・state・body・submitted_at・commit・
#               replied・needs_attention
#     comments  PR のコメント（スレッドの外）。id・body・created_at・url・replied・needs_attention
#   own_comments  PR の作者の PR のコメント（id・body・created_at・url）。どのコメントに返信済みかの判断に使う
#   counts     threads・reviews・comments の合計と、unanswered・awaiting（下の「意味」）
#   needs_attention  返事をしていないものが1つでもあるか（下の「意味」）
#
# 意味（needs_attention・replied・counts.unanswered・counts.awaiting の正本。SKILL.md・設計書・README は、ここを参照するだけにして、意味を書き写さない）:
#   replied          返事が済んでいるか。
#                    - スレッド：スレッドの持ち主（PR の作者以外で、決まりの規則で選んだ書き手）の最後のコメントの後に、PR の作者が書いている
#                      （持ち主の返事待ち）
#                    - レビュー本文・PR のコメント：作成・提出の時刻の後に PR の作者の PR のコメントがあり、かつ、その後に編集されていない
#                      （時刻だけで決めた目安で、誰への返事かは見ない。対応済みにするかは AI が own_comments と照らして決める）。
#                      時刻が無いもの（submitted_at・created_at が null）、返事の後に編集されたもの、本文の無い変更の要求は、
#                      返事済みにしない
#   needs_attention  項目ごとの「返事をしていない」目印。スレッドとコメントは replied でないこと。レビューは、replied でなく、
#                    本文があるか変更の要求であること（本文の無い承認は数えない）。本文の無い変更の要求は、返事で済ませられないので、
#                    同じ人の後の APPROVED・CHANGES_REQUESTED・DISMISSED のレビューが無いあいだ（今も有効なあいだ）true になる
#   counts.unanswered  needs_attention が true の項目の件数（threads・reviews・comments ごと）
#   counts.awaiting  返事待ちの項目の件数。replied が true で、本文のあるレビュー・変更の要求・スレッド・コメントのもの（本文の無い承認は数えない）
#   needs_attention（トップレベル）  counts.unanswered のどれかが 1 以上か。true なら対応なしで終えない目印。false でも対応が要らない
#                    とは限らない（replied は目安で、返事待ちの項目もある）。CI の失敗は含めない（checks を見る）
#
# 決まり:
#   - PR の作者のレビュー・コメントは feedback に数えない（自分の返信やメモなので。コメントは own_comments に出す）。
#     PR の作者のコメントだけのスレッドは数えない
#   - スレッドは、PR の作者以外の書き手に、担当の skill が無い人が1人でもいれば、その中で最後に書いた人の分にする
#     （書いた順番によらない。bot のスレッドに人が質問を書いたとき、bot の担当の skill は人のコメントを扱わないので、
#     bot の分にすると誰も答えない）。作者以外の書き手がすべて担当のある投稿者なら、その中で最後に書いた人の分にする
#   - 投稿者と handlers のキーは、大文字と小文字、末尾の [bot] を区別せずに照らす（gh は some-bot[bot] を some-bot と返す）
#   - 返事をしていないか（needs_attention）は、投稿者の名前によらず、時刻だけで決める（意味は上の「意味」）。diff の外の指摘は
#     レビュー本文にあってスレッドが無く、counts.threads に現れないので、スレッドの件数だけで「未解決なし」と決めない（#279）
#   - 編集の時刻（lastEditedAt）は gh pr view に無いので、スレッドと同じ GraphQL の呼び出しで、新しい方の 100 件のレビュー・PR の
#     コメントについて読む（bot は、後の push で同じコメントを編集して指摘を足すことがあり、作成の時刻は変わらないため。#357）
#   - スレッドの resolved の状態は gh にも REST にも無いので、そこだけ GraphQL で読む（設計書 §10）。
#     1つのスレッドのコメントは先頭の 100 件まで読む
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--pr に値がありません" 64
      pr="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
# スキルの引数の #5 も受け、先頭の 0 をそろえる（dw_number。Issue の番号と同じ受け取り方）
[ -z "$pr" ] || pr="$(dw_number --pr "$pr" PR)"

settings="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" '{handlers: (.pr_check.handlers // {}), old_key: has("pr_respond")}')"
handlers="$(jq -c .handlers <<<"$settings")"
# 改名前のキーは使われない。黙って担当の skill に任せなくなるので知らせる（doctor.sh も警告する）
if [ "$(jq -r .old_key <<<"$settings")" = true ]; then
  dw_warn "設定のキー pr_respond は使われません。pr_check に改めてください（担当の skill に任せるには pr_check.handlers が要ります）"
fi
jq -e 'type == "object" and all(.[]; type == "string" and . != "")' >/dev/null <<<"$handlers" \
  || dw_die "設定の pr_check.handlers は、投稿者を担当する skill の名前に対応させるオブジェクトにしてください"

fields=number,url,title,state,isDraft,author,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision,reviews,comments,statusCheckRollup
if [ -n "$pr" ]; then
  view="$(gh pr view "$pr" --json "$fields" 2>&1)" || dw_die "PR #${pr} を読めません: $view"
else
  view="$(gh pr view --json "$fields" 2>&1)" || dw_die "今のブランチの PR を読めません（--pr で番号を指定してください）: $view"
fi

number="$(jq -r .number <<<"$view")"
nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || dw_die "リポジトリを読めません"

# resolved でないスレッドを読む。resolved の状態は gh のサブコマンドにも REST にも無いので GraphQL で読み、ページを辿る
# GraphQL の変数（$owner など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
query='query PrThreads($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    comments(last: 100) { nodes { id lastEditedAt } }
    reviews(last: 100) { nodes { id lastEditedAt } }
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        isResolved isOutdated path line
        comments(first: 100) { nodes { databaseId author { login } body url createdAt } }
      }
    }
  } }
}'
threads='[]' after="" edits='{}'
while :; do
  vars="$(jq -nc --arg o "${nwo%%/*}" --arg n "${nwo#*/}" --argjson num "$number" --arg a "$after" \
    '{owner: $o, name: $n, number: $num} + (if $a == "" then {} else {after: $a} end)')"
  page="$(dw_gql "$query" "$vars" 2>&1)" || dw_die "PR #${number} のスレッドを読めません: $page"
  jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 <<<"$page" \
    || dw_die "PR #${number} のスレッドを読めません: $page"
  # 編集の時刻（id → lastEditedAt）は、どのページにも同じものが付いてくるので、最初のページのものを使う
  [ -n "$after" ] || edits="$(jq -c '[.data.repository.pullRequest | ((.comments.nodes // [])[], (.reviews.nodes // [])[])
    | select(.lastEditedAt != null) | {key: .id, value: .lastEditedAt}] | from_entries' <<<"$page")"
  # スレッドの本文は長くなりうるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
  threads="$(printf '%s\n' "$threads" "$page" \
    | jq -sc '.[0] + [.[1].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)]')"
  [ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$page")" = true ] || break
  # カーソルが空か前回と同じなら、同じページを読み続けてしまう（無限ループ）ので止める
  next_after="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' <<<"$page")"
  { [ -n "$next_after" ] && [ "$next_after" != "$after" ]; } \
    || dw_die "PR #${number} のスレッドのページ送りが進みません"
  after="$next_after"
done

# PR とスレッドは本文を含んで長くなりうるので、引数ではなく標準入力で渡す（引数1つの長さには上限がある）
# jq の変数（$h など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
printf '%s\n' "$view" "$threads" "$edits" | jq -s --argjson handlers "$handlers" "$DW_JQ_LOGIN_NORM"'
  def login: (.author.login // "ghost");
  # レビュー・PR のコメントが、時刻 $t より後に編集されたか（編集の時刻は .[2] の id → lastEditedAt）
  def edited_after($edits; $t): (($edits[.id // ""] // "") > $t);
  .[0] as $v | .[1] as $threads | .[2] as $edits
  | ($v.author.login // "" | norm) as $me
  | ($handlers | to_entries | map({key: (.key | norm), value}) | from_entries) as $h

  # CI のチェック。CheckRun（Actions など）と StatusContext（外部のコミットの状態）をそろえる
  | [($v.statusCheckRollup // [])[]
      | if .__typename == "StatusContext" then
          {name: .context, workflow: null, url: .targetUrl,
           failed: (.state | IN("FAILURE", "ERROR")), pending: (.state | IN("PENDING", "EXPECTED"))}
        else
          {name, workflow: (.workflowName // null), url: .detailsUrl,
           failed: (.status == "COMPLETED" and (.conclusion | IN("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"))),
           pending: (.status != "COMPLETED")}
        end] as $checks
  | ($checks | map(select(.failed) | {name, workflow, url})) as $failed
  | ($checks | map(select(.pending) | {name, workflow, url})) as $pending

  | [$threads[]
      | {path, line, outdated: .isOutdated,
         comments: [.comments.nodes[] | {author: login, body, created_at: .createdAt, url, id: .databaseId}]}
      | [.comments[] | select(.author | norm != $me)] as $others
      | (([$others[] | select($h[.author | norm] == null)] | last) // ($others | last)) as $by
      | select($by != null)
      # 持ち主と PR の作者が、それぞれ最後に書いたコメントの位置（書いていなければ -1）
      | ([.comments | to_entries[] | select(.value.author | norm == ($by.author | norm)) | .key] | last) as $by_at
      | ([.comments | to_entries[] | select(.value.author | norm == $me) | .key] | last // -1) as $me_at
      | ($me_at > $by_at) as $replied
      | {author: $by.author, item: {id: .comments[0].id, path, line, outdated, url: .comments[0].url,
          comments: .comments, replied: $replied, needs_attention: ($replied | not)}}] as $t
  # PR の作者の PR のコメントの、最後の時刻（無ければ ""）。レビュー本文・PR のコメントは、この時刻以前に作られ、
  # この時刻より後に編集されていなければ、返事済みとする。時刻が null のものは返事済みにしない
  | ([($v.comments // [])[] | select((login | norm) == $me) | .createdAt] | max // "") as $last_own
  | ($v.reviews // []) as $all_reviews
  | [$all_reviews | to_entries[] | .key as $i | .value
      | select((login | norm) != $me)
      | select((.body // "") != "" or (.state | IN("APPROVED", "CHANGES_REQUESTED")))
      | (.body // "") as $body
      | ($body == "" and .state == "CHANGES_REQUESTED") as $bodyless_cr
      # 本文の無い変更の要求が今も有効か：同じ人の、後の APPROVED・CHANGES_REQUESTED・DISMISSED のレビューが無い
      # （reviewDecision は、必須レビューのルールが無いリポジトリでは null なので使わない）
      | (login | norm) as $who
      | ([$all_reviews[$i + 1:][] | select((login | norm) == $who and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))] | length == 0) as $latest
      | (($bodyless_cr | not) and $last_own != "" and .submittedAt != null and .submittedAt <= $last_own and (edited_after($edits; $last_own) | not)) as $replied
      | {author: login, item: {id, state, body: (.body // ""), submitted_at: .submittedAt, commit: (.commit.oid // null),
          replied: $replied,
          needs_attention: (if $bodyless_cr then $latest
                            else (($replied | not) and $body != "") end)}}] as $r
  | [($v.comments // [])[]
      | select((login | norm) != $me)
      | ($last_own != "" and .createdAt != null and .createdAt <= $last_own and (edited_after($edits; $last_own) | not)) as $replied
      | {author: login, item: {id, body, created_at: .createdAt, url, replied: $replied, needs_attention: ($replied | not)}}] as $c
  | {threads: ([$t[] | select(.item.needs_attention)] | length),
     reviews: ([$r[] | select(.item.needs_attention)] | length),
     comments: ([$c[] | select(.item.needs_attention)] | length)} as $unanswered
  # 返事待ち。replied が true で、本文のあるレビュー・変更の要求・スレッド・コメントの数（本文の無い承認は数えない）
  | ([$t[], $c[] | select(.item.replied)] + [$r[] | select(.item.replied and (.item.body != "" or .item.state == "CHANGES_REQUESTED"))] | length) as $awaiting

  | {
      pr: {number: $v.number, url: $v.url, title: $v.title, state: $v.state, draft: $v.isDraft,
           author: ($v.author.login // null), head: $v.headRefName, head_sha: $v.headRefOid, base: $v.baseRefName,
           mergeable: $v.mergeable, merge_state: $v.mergeStateStatus,
           review_decision: (if ($v.reviewDecision // "") == "" then null else $v.reviewDecision end)},
      checks: {state: (if ($failed | length) > 0 then "failure" elif ($pending | length) > 0 then "pending"
                       elif ($checks | length) > 0 then "success" else "none" end),
               failed: $failed, pending: $pending, total: ($checks | length)},
      handlers: $handlers,
      feedback: ([$t[], $r[], $c[] | .author] | unique_by(norm) | map(. as $a | {
        author: $a,
        handler: ($h[$a | norm] // null),
        threads: [$t[] | select(.author | norm == ($a | norm)) | .item],
        reviews: [$r[] | select(.author | norm == ($a | norm)) | .item],
        comments: [$c[] | select(.author | norm == ($a | norm)) | .item]})),
      own_comments: [($v.comments // [])[] | select((login | norm) == $me) | {id, body, created_at: .createdAt, url}],
      counts: {threads: ($t | length), reviews: ($r | length), comments: ($c | length), unanswered: $unanswered, awaiting: $awaiting},
      needs_attention: ($unanswered | add > 0)
    }'
