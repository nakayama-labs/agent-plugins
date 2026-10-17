#!/usr/bin/env bash
# PR を見回すときに、今すぐ Claude を動かして直すべきかを、PR の今の状態だけから決めて JSON で出力する。
# 何も変えない（読むだけ）。状態は持たない（前回の結果を覚えない）ので、後から人が push したり指摘が付いたりすれば、
# 次に呼んだときに自動で変わる。対応するものが無い回で Claude を動かさないために、先にこのスクリプトで決める（#286）。
#
# 使い方: pr-watch.sh [--pr N]
#   --pr N   PR の番号（#N でもよい）。省略すると今のブランチの PR
#
# 出力（JSON）:
#   pr        number・url・state・draft・head_sha・merge_state（GitHub の mergeStateStatus。CLEAN ならマージできる）
#   action    idle（何もしない）・wait（待つ）・act（対応する）・conflict（コンフリクトを直す）・stop（上限に達したので止まる）のどれか
#   reasons   action の理由（文字列の配列。下の表）
#   respond   gh-pr-check の手順1が、指摘・質問・CI の失敗の一覧（手順2以降）へ進むか（true）、何も変えずに終えるか（false）。
#             OPEN の PR で、CI が失敗しているか、返事をしていない指摘があるか、返事待ちの項目がある（awaiting_replies が 1 以上）ときだけ true。
#             action とは別に決める（action は無人の見回り用で、ドラフト・フォーク・キュー・コンフリクトの PR では指摘に触れないため）
#   details   failed_checks（失敗したチェックの名前）・unanswered（返事をしていない指摘の数。threads・reviews・comments）・
#             awaiting_replies（返事待ちの項目の数）・waiting_for（最初のレビューを待っている投稿者）
#
# 判定（上から順に最初に当てはまったもの。ただし act の理由は、当てはまるものをすべて並べる）:
#   1. idle  not_open      PR が OPEN でない（マージ済み・閉じた）
#            draft         ドラフトの PR（対象外）
#            fork          フォークからの PR（対象外。push できない）
#   2. wait  in_merge_queue  マージキューに入っている（キューの結果を待つ）
#   3. conflict  conflicting  main などとコンフリクトしている（mergeable が CONFLICTING、または merge_state が DIRTY）
#                behind       PR のマージ先に遅れている（merge_state が BEHIND）
#   4. act   ci_failed             CI のチェックが失敗している
#            unresolved_threads    resolved でないスレッドで、PR の作者がまだ返事をしていないものがある
#            unanswered_reviews    変更の要求か本文のあるレビューで、その後に PR の作者のコメントが無いものがある
#            unanswered_comments   PR のコメント（作者以外）で、その後に PR の作者のコメントが無いものがある
#      stop  same_failure          ci_failed で、今の head_sha の repair-run（PR のコメントのマーカー）が repair.max_fix_attempts 以上
#            push_limit            ci_failed で、head が進んだ repair-run の回数が repair.max_pushes_per_pr 以上
#                                  （ADR 000340。理由には、上限に達したものに続けて、act の理由もすべて並べる。repair.enabled が false か、
#                                  repair.reply_logins が空か、コメントを読めないときは、数えずに act のまま）
#   5. wait  ci_pending            CI が実行中
#            awaiting_review:<投稿者>  設定の pr_check.handlers と repair.wait_for_reviewers の投稿者（レビューの bot など）の
#                                  最初のレビューが、まだ付いていない。無人の push（repair.reply_logins の committer の head）の後は、
#                                  その push より後に今の head へ付く増分のレビューも待つ。レート制限を知らせるコメント
#                                  （本文に <!-- ... rate limited by ... --> がある）は到着に数えない
#                                  （基準の時刻から repair.review_wait_minutes（既定 60）分たつまで待つ。障害などで際限なく待たないため）
#            mergeable_unknown     GitHub がマージできるかを計算中（mergeable が UNKNOWN）
#   6. idle  nothing_to_do  上のどれでもない（CI が全部通るか無く、対応する指摘も無い）
#
#   5 と 6 の理由には、次のものを続けて足す（ユーザーに伝えることを表す。action は変えない）:
#            awaiting_replies      返事待ちの項目がある（PR の作者が返事をして、相手の返事を待っている。pr-feedback.sh の
#                                  counts.awaiting。意味は pr-feedback.sh --help）
#            merge_blocked         merge_state が CLEAN でない（BLOCKED など。コンフリクトと遅れは conflict で扱う）
#
# 決まり:
#   - 対応が要る指摘（unresolved_threads・unanswered_reviews・unanswered_comments）は、pr-feedback.sh の
#     needs_attention を使う（判定を1か所にまとめ、gh-pr-check と食い違わないようにする）。ここで足すのは ADR 000285 の「対応済み」だけで、
#     repair.reply_logins の投稿者が、マーカー <!-- dev-workflow:repair-reply to=<コメントの ID> --> を付けて、そのコメントより後に
#     返信したものは、対応済みとして数えない。マーカー付きの返信そのものも、指摘に数えない
#   - マージキューの状態は、OPEN で、下書きでなく、フォークでない PR のときだけ読む（それ以外は idle になるので、読めなくても止めない）
#   - 材料は pr-feedback.sh の出力と、GraphQL で読む作成時刻・フォークか・レビューの投稿者（PR の URL から引く）、
#     マージキューの状態（common.sh の dw_merge_queue_state。キューの中かは pr-merge-status.sh・branch-status.sh と同じ判定。
#     入れた直後と、merged で外れた直後も、キューの中として扱う。ADR 000323・000381）
#     （マージキューの状態は gh pr view に無い。設計書 §10）
#   - テストのため、環境変数 PR_WATCH_NOW（UNIX 秒）で今の時刻を差し替えられる
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
[ -z "$pr" ] || pr="$(dw_number --pr "$pr" PR)"

# pr-feedback.sh のエラー（終了コードと1行のメッセージ）はそのまま伝える
if [ -n "$pr" ]; then
  fb="$("$BASH" "$DW_SCRIPTS_DIR/pr-feedback.sh" --pr "$pr")" || exit $?
else
  fb="$("$BASH" "$DW_SCRIPTS_DIR/pr-feedback.sh")" || exit $?
fi
number="$(jq -r .pr.number <<<"$fb")"
# マージキューの状態などは gh pr view にも REST にも無いので GraphQL で読む（設計書 §10）。PR の URL から引くので、
# リポジトリの所有者と名前を別に調べなくてよい（branch-status.sh と同じ）。
# reviews は新しい方の 100 件だけ見る。超えても、待つのは PR を作ってから 60 分までなので害は小さい
# shellcheck disable=SC2016 # GraphQL の変数（$url）を bash に展開させないため、シングルクォートで書く
res="$(dw_gql 'query PrWatch($url: URI!) {
    resource(url: $url) {
      ... on PullRequest {
        createdAt isCrossRepository
        reviews(last: 100) { nodes { author { login } submittedAt commit { oid } } }
      }
    }
  }' "$(jq -c '{url: .pr.url}' <<<"$fb")" 2>&1)" \
  || dw_die "PR #${number} のマージキューの状態を読めません: $res"
jq -e '.data.resource | type == "object" and has("createdAt")' >/dev/null 2>&1 <<<"$res" \
  || dw_die "PR #${number} のマージキューの状態を読めません: $res"

now="${PR_WATCH_NOW:-$(date -u +%s)}"

# キューの中かは、pr-merge-status.sh・branch-status.sh と同じ判定（common.sh の dw_merge_queue_state の queued。ADR 000323）にそろえる。
# mergeQueueEntry だけで見ると、入れた直後（まだ mergeQueueEntry に出ていない）と、merged で外れた直後（マージの直前）を
# キューの外として扱ってしまう。見るのは queued だけなので、外れた後の push を読まないよう、フォークとして渡す。
# 今の時刻は PR_WATCH_NOW があればそれにそろえる（環境に残った DW_QUEUE_NOW には負けない。時計を 2 つにしない）
[ -z "${PR_WATCH_NOW:-}" ] || export DW_QUEUE_NOW="$PR_WATCH_NOW"
dw_check_queue_now
# 対象外の PR（not_open・draft・fork。判定の 1）は、ここで 1 か所に決め、下の jq でもこれを使う。
# キューの状態は、対象の PR（idle_reason が空）のときだけ読む。対象外は idle になるので、読めなくても止めない（読まずに queued=false 相当にする）
idle_reason="$(jq -r --argjson g "$(jq -c '.data.resource' <<<"$res")" \
  'if .pr.state != "OPEN" then "not_open" elif .pr.draft then "draft" elif $g.isCrossRepository then "fork" else "" end' <<<"$fb")"
mq='{"queued": false}'
if [ -z "$idle_reason" ]; then
  qerr="$(mktemp)"
  mq="$(dw_merge_queue_state "$(jq -r .pr.url <<<"$fb")" "" true 2>"$qerr")" \
    || { reason="$(tail -n 1 "$qerr")"; rm -f "$qerr"; dw_die "PR #${number} のマージキューの状態を読めません: $reason"; }
  cat "$qerr" >&2
  rm -f "$qerr"
fi

# 設定 repair.*（既定は defaults/workflow.json）。ADR 000285・000340
cfg="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" '{
  enabled: (.repair.enabled // false), logins: (.repair.reply_logins // []), allowed: (.repair.allowed_authors // []),
  wait: (.repair.wait_for_reviewers // []), wait_min: (.repair.review_wait_minutes // 60),
  max_fix: (.repair.max_fix_attempts // 3), max_push: (.repair.max_pushes_per_pr // 5)}')"
jq -e '.enabled | type == "boolean"' >/dev/null 2>&1 <<<"$cfg" || dw_die "設定の repair.enabled は true か false にしてください"
jq -e '([.logins, .allowed, .wait] | all(type == "array" and all(.[]; type == "string"))) and ([.wait_min, .max_fix, .max_push] | all(type == "number"))' >/dev/null 2>&1 <<<"$cfg" \
  || dw_die "設定の repair.* の型が正しくありません（reply_logins・allowed_authors・wait_for_reviewers は文字列の配列、review_wait_minutes・max_fix_attempts・max_pushes_per_pr は数）"
jq -e '(.wait_min >= 0) and ([.max_fix, .max_push] | all(. >= 1 and . == floor))' >/dev/null 2>&1 <<<"$cfg" \
  || dw_die "設定の repair.* の範囲が正しくありません（review_wait_minutes は 0 以上、max_fix_attempts と max_pushes_per_pr は 1 以上の整数）"

# 試した回数（同じ head_sha の repair-run と、head が進んだ回数。ADR 000340）と、無人の push の時刻は、repair.enabled が true で、
# repair.reply_logins があるときだけ、PR のコメントとコミットから読む。読めなければ数えない（act のまま）
ctx_counts=null
push_at=""
if [ "$(jq -r '.enabled and (.logins | length > 0)' <<<"$cfg")" = true ]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/pr-watch.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  purl="$(jq -r .pr.url <<<"$fb")"
  rest="${purl#*://}"
  rest="${rest#*/}"
  nwo="${rest%/pull/*}"
  head_sha="$(jq -r .pr.head_sha <<<"$fb")"
  logins_csv="$(jq -r '.logins | join(",")' <<<"$cfg")"
  commits_ok=false
  if gh api --paginate --slurp "repos/${nwo}/pulls/${number}/commits?per_page=100" >"$work/commits.json" 2>/dev/null \
    && jq -e 'type == "array"' "$work/commits.json" >/dev/null 2>&1; then
    commits_ok=true
  fi
  if gh api --paginate --slurp "repos/${nwo}/issues/${number}/comments?per_page=100" >"$work/comments.json" 2>/dev/null \
    && jq -e 'type == "array"' "$work/comments.json" >/dev/null 2>&1; then
    [ "$commits_ok" = true ] || echo '[]' >"$work/commits.json"
    printf '%s\n' "$fb" >"$work/fb.json"
    # 再開の起点（ADR 000285）：最新の repair-done、人の push（committer が reply_logins でないコミット）、許可した投稿者の最新の指摘のうち、最も新しい時刻
    # shellcheck disable=SC2016
    since="$(jq -r --slurpfile c "$work/comments.json" --slurpfile k "$work/commits.json" --argjson cfg "$cfg" "$DW_JQ_LOGIN_NORM"'
      ($cfg.logins | map(norm)) as $L | ($cfg.allowed | map(norm)) as $A
      | [$c[0][] | if type == "array" then .[] else . end | select(type == "object")] as $ic
      | [$k[0][] | if type == "array" then .[] else . end | select(type == "object")] as $kc
      | ([$ic[] | select((.user.login // "" | norm) | IN($L[])) | select((.body // "") | test("^\\s*<!-- dev-workflow:repair-done")) | .created_at]
         + [$kc[] | select((.committer.login // "") != "" and ((.committer.login | norm) | IN($L[]) | not)) | .commit.committer.date]
         + [$ic[] | select((.user.login // "" | norm) | IN($A[])) | select((.body // "") | test("^\\s*<!-- dev-workflow:") | not) | .created_at]
         + [.feedback[] | select((.author | norm) | IN($A[])) | (.threads[].comments[] | select((.author | norm) | IN($A[])) | .created_at), (.reviews[].submitted_at // empty), (.comments[].created_at // empty)]
        ) | map(select(. != null)) | max // ""' "$work/fb.json")"
    run_args=(--head "$head_sha" --logins "$logins_csv")
    [ -z "$since" ] || run_args+=(--since "$since")
    [ "$commits_ok" != true ] || run_args+=(--commits "$work/commits.json")
    if rc="$("$BASH" "$DW_SCRIPTS_DIR/repair-run-count.sh" "${run_args[@]}" <"$work/comments.json" 2>/dev/null)"; then
      ctx_counts="$(jq -c '{attempts: .not_pushed, pushes: .count}' <<<"$rc")"
    fi
    if [ "$commits_ok" = true ]; then
      # 無人の push で今の head になったか（head のコミットの committer が reply_logins のとき、その時刻）
      push_at="$(jq -r --argjson cfg "$cfg" --arg head "$head_sha" "$DW_JQ_LOGIN_NORM"'
        ($cfg.logins | map(norm)) as $L
        | [.[] | if type == "array" then .[] else . end | select(type == "object")
           | select((.sha // "" | ascii_downcase) as $s | $s != "" and ($s | startswith($head | ascii_downcase)))
           | select((.committer.login // "" | norm) | IN($L[])) | .commit.committer.date] | last // ""' "$work/commits.json")"
    fi
  fi
fi
ctx="$(jq -nc --argjson cfg "$cfg" --argjson counts "$ctx_counts" --arg push_at "$push_at" '{cfg: $cfg, counts: $counts, push_at: $push_at}')"

# 指摘とコメントは本文を含んで長くなりうるので、引数ではなく標準入力で渡す（引数1つの長さには上限がある）
# jq の変数（$f など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
printf '%s\n' "$fb" "$res" | jq -s --argjson mq "$mq" --arg idle_reason "$idle_reason" --argjson now "$now" --argjson ctx "$ctx" "$DW_JQ_LOGIN_NORM"'
  .[0] as $f | .[1].data.resource as $g
  | ($ctx.cfg) as $cfg
  | ($f.pr) as $p
  # 対応済み（ADR 000285）：repair.reply_logins の投稿者が、マーカー <!-- dev-workflow:repair-reply to=<ID> --> を付けて、
  # そのコメントより後に返信したものは、対応が要る指摘に数えない。マーカーそのものを付けた返信も、指摘に数えない
  | ($cfg.logins | map(norm)) as $L
  | def reply_to: if (.body // "") | test("^\\s*<!-- dev-workflow:repair-reply to=[^ ]+ -->") then ((.body | capture("^\\s*<!-- dev-workflow:repair-reply to=(?<to>[^ ]+) -->")) | .to) else null end;
  def is_reply($author): (($author | norm) | IN($L[])) and (reply_to != null);
  ([ ($f.feedback[] | .author as $a | ((.threads[].comments[]), .comments[]) | select(is_reply($a)) | {to: reply_to, at: .created_at}),
     ($f.own_comments[] | select(is_reply($p.author // "")) | {to: reply_to, at: .created_at}) ]) as $replies
  | def answered($id; $at): any($replies[]; .to == ($id | tostring) and ($at == null or .at >= $at));
  ($p.author // "" | norm) as $me
  | [ $f.feedback[] | .author as $a | .threads[]
      | select(.needs_attention)
      | ([.comments[] | select((.author | norm) != $me and (is_reply(.author) | not))] | last) as $t
      | select($t == null or ($t.id != null and answered($t.id; $t.created_at)) | not) ] as $open_threads
  | [ $f.feedback[] | .author as $a | .reviews[]
      | select(.needs_attention) | select(answered(.id; .submitted_at) | not) ] as $open_reviews
  | [ $f.feedback[] | .author as $a | .comments[]
      | select(.needs_attention) | select(is_reply($a) | not) | select(answered(.id; .created_at) | not) ] as $open_comments
  | ($open_threads | length) as $n_threads
  | ($open_reviews | length) as $n_reviews
  | ($open_comments | length) as $n_comments
  # 最初のレビューを待つ投稿者。担当の skill がある投稿者と repair.wait_for_reviewers の投稿者のうち、基準の時刻より後に
  # 今の head へのレビュー・スレッド・コメントのどれも付けていない人。基準の時刻は、PR の作成時刻。無人の push で今の head になっていれば、
  # その push の時刻（増分のレビュー。レビューは今の head に付いたものだけ数える）。レート制限を知らせるコメントは到着に数えない
  | ($g.createdAt) as $created
  | (if $ctx.push_at != "" then $ctx.push_at else $created end) as $base
  | ($ctx.push_at != "") as $incremental
  | def after($t): $t == null or $t >= $base;
  def rate_limited: (.body // "") | test("<!--[^>]*rate limited by[^>]*-->");
  def same_head($oid): $oid != null and (($oid | ascii_downcase) as $o | ($p.head_sha | ascii_downcase) as $h | ($o | startswith($h)) or ($h | startswith($o)));
  ([$g.reviews.nodes[] | select(.author.login != null)
     | select(after(.submittedAt))
     | select(($incremental | not) or same_head(.commit.oid // null))
     | .author.login | norm]
   + [$f.feedback[] | .author as $a
      | ((.threads[].comments[] | select(rate_limited | not) | select(after(.created_at))),
         (.reviews[] | select(after(.submitted_at))),
         (.comments[] | select(rate_limited | not) | select(after(.created_at)))) | $a | norm]
  ) as $arrived
  | (($now - ($base | fromdateiso8601)) < ($cfg.wait_min * 60)) as $in_wait_window
  | (([$f.handlers | keys[]] + $cfg.wait) | unique_by(norm)) as $waiters
  | (if $in_wait_window then [$waiters[] | select(norm as $k | $arrived | index($k) | not)] else [] end) as $waiting_for
  # 返事待ちの項目の数も pr-feedback.sh が決める（counts.awaiting。意味は pr-feedback.sh --help）
  | ($f.counts.awaiting) as $n_awaiting
  | ($p.merge_state) as $ms
  | ($ctx.counts) as $cn
  | ([if $cn != null and $cn.attempts >= $cfg.max_fix then "same_failure" else empty end,
      if $cn != null and $cn.pushes >= $cfg.max_push then "push_limit" else empty end]) as $limits
  | ([if $n_awaiting > 0 then "awaiting_replies" else empty end, if $ms != "CLEAN" and $ms != "UNKNOWN" then "merge_blocked" else empty end]) as $notes
  | (if $idle_reason != "" then {action: "idle", reasons: [$idle_reason]}
     elif $mq.queued then {action: "wait", reasons: ["in_merge_queue"]}
     elif $p.mergeable == "CONFLICTING" or $ms == "DIRTY" or $ms == "BEHIND" then
       {action: "conflict", reasons: ([if $p.mergeable == "CONFLICTING" or $ms == "DIRTY" then "conflicting" else empty end,
                                       if $ms == "BEHIND" then "behind" else empty end])}
     elif $f.checks.state == "failure" or $n_threads > 0 or $n_reviews > 0 or $n_comments > 0 then
       {action: (if $f.checks.state == "failure" and ($limits | length) > 0 then "stop" else "act" end),
        reasons: (($limits | if $f.checks.state == "failure" then . else [] end) + [if $f.checks.state == "failure" then "ci_failed" else empty end,
                                  if $n_threads > 0 then "unresolved_threads" else empty end,
                                  if $n_reviews > 0 then "unanswered_reviews" else empty end,
                                  if $n_comments > 0 then "unanswered_comments" else empty end])}
     elif $f.checks.state == "pending" or ($waiting_for | length) > 0 or $p.mergeable == "UNKNOWN" then
       {action: "wait", reasons: ([if $f.checks.state == "pending" then "ci_pending" else empty end,
                                   ($waiting_for[] | "awaiting_review:" + .),
                                   if $p.mergeable == "UNKNOWN" then "mergeable_unknown" else empty end] + $notes)}
     else {action: "idle", reasons: (["nothing_to_do"] + $notes)} end) as $d
  | {pr: {number: $p.number, url: $p.url, state: $p.state, draft: $p.draft, head_sha: $p.head_sha, merge_state: $p.merge_state},
     action: $d.action, reasons: $d.reasons,
     respond: ($p.state == "OPEN" and ($f.checks.state == "failure" or $n_threads > 0 or $n_reviews > 0 or $n_comments > 0 or $n_awaiting > 0)),
     details: {failed_checks: [$f.checks.failed[].name],
               unanswered: {threads: $n_threads, reviews: $n_reviews, comments: $n_comments},
               awaiting_replies: $n_awaiting,
               waiting_for: $waiting_for}}'
