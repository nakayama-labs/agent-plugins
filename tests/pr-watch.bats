#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 判定の表（PR の状態 × 入力 → action と reasons）。上から順に最初に当てはまったもの。このファイルのテストは、表の全行を確かめる。
#
#   PR の状態 / 入力                                           action    reasons
#   state が OPEN でない（MERGED・CLOSED）                      idle      not_open
#   ドラフト                                                    idle      draft
#   フォークからの PR                                           idle      fork
#   マージキューに入っている                                    wait      in_merge_queue
#   mergeable が CONFLICTING、または merge_state が DIRTY       conflict  conflicting
#   merge_state が BEHIND                                       conflict  behind
#   CI の失敗                                                   act       ci_failed
#   返事の無い resolved でないスレッド                          act       unresolved_threads
#   変更の要求か本文のあるレビューで、作者の後のコメントが無い  act       unanswered_reviews
#   作者以外の PR のコメントで、作者の後のコメントが無い        act       unanswered_comments
#   CI が実行中                                                 wait      ci_pending
#   担当の skill がある投稿者の最初のレビュー待ち（60 分まで）  wait      awaiting_review:<投稿者>
#   mergeable が UNKNOWN                                        wait      mergeable_unknown
#   どれでもない（CI が全部成功・チェックが無い）               idle      nothing_to_do
#   （wait・nothing_to_do には、次の理由を続けて足す）
#   返事待ちの項目がある                                        -         awaiting_replies
#   merge_state が CLEAN でない（UNKNOWN・コンフリクトを除く）  -         merge_blocked
#
# 偽の gh。
# - gh pr view [番号] --json ...   $FIX/pr-view.json を返す
# - gh api graphql                クエリに PrQueue があれば（common.sh の dw_merge_queue_state）$FIX/queue.json、PrWatch があれば $FIX/watch.json、無ければ（PrThreads）$FIX/PrThreads.json を返す
# - gh api --paginate --slurp repos/.../issues/N/comments?... は $FIX/api-comments.json、.../pulls/N/commits?... は $FIX/api-commits.json を返す（無ければ失敗）
# - それ以外（書き込みを含む）は、$CALLS に「WRITE <引数>」を記録して失敗する
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo me/demo ;; # pr-feedback.sh が使う
  "pr view") echo "READ pr view" >>"$CALLS"; cat "$FIX/pr-view.json" ;;
  "api graphql")
    body="$(cat)"
    if [ "$(jq -r '.query | contains("query PrQueue")' <<<"$body")" = true ]; then
      echo "READ PrQueue $(jq -r .variables.url <<<"$body")" >>"$CALLS"; cat "$FIX/queue.json"
    elif [ "$(jq -r '.query | contains("query PrWatch")' <<<"$body")" = true ]; then
      echo "READ PrWatch $(jq -r .variables.url <<<"$body")" >>"$CALLS"; cat "$FIX/watch.json"
    else
      echo "READ PrThreads" >>"$CALLS"; cat "$FIX/PrThreads.json"
    fi
    ;;
  "api --paginate")
    case "$4" in
      *"/comments?"*) echo "READ api-comments" >>"$CALLS"; cat "$FIX/api-comments.json" ;;
      *"/commits?"*) echo "READ api-commits" >>"$CALLS"; cat "$FIX/api-commits.json" ;;
      *) echo "WRITE $*" >>"$CALLS"; exit 1 ;;
    esac
    ;;
  *) echo "WRITE $*" >>"$CALLS"; echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  # 今は PR を作ってから 10 分後（2026-10-01T00:10:00Z）
  export PR_WATCH_NOW=1790813400
  : >"$FIX/threads"
  pr_view '{}'
  watch '{}'
  queue_state '{}'
  write_threads
}

# PR の JSON を作る。使い方: pr_view <既定の値に上書きするオブジェクト（jq の式）>
pr_view() {
  jq -n "$1 as \$o | "'{number: 5, url: "https://github.com/me/demo/pull/5", title: "feat: x", state: "OPEN", isDraft: false,
    author: {login: "me"}, headRefName: "feat/5-x", headRefOid: "abc", baseRefName: "main", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
    reviewDecision: "", reviews: [], comments: [], statusCheckRollup: []} + $o' >"$FIX/pr-view.json"
}

# GraphQL（PrWatch）の応答を作る。使い方: watch <既定の値に上書きするオブジェクト（jq の式）>
# 既定は、2026-10-01T00:00:00Z に作った、フォークでなく、キューにも入っていない、レビューの無い PR
watch() {
  jq -n "$1 as \$o | "'{data: {resource: ({createdAt: "2026-10-01T00:00:00Z", isCrossRepository: false,
    reviews: {nodes: []}} + $o)}}' >"$FIX/watch.json"
}

# GraphQL（PrQueue。dw_merge_queue_state が読むマージキューの状態）の応答を作る。使い方: queue_state <既定の値に上書きするオブジェクト（jq の式）>
# 既定は、キューが有効で、キューに並んでおらず、キューの出入りのイベントも無い。今は 2026-10-01T00:10:00Z（PR_WATCH_NOW）
queue_state() {
  jq -n "$1 as \$o | "'{data: {resource: ({isMergeQueueEnabled: true, mergeQueueEntry: null, timelineItems: {nodes: []}} + $o)}}' >"$FIX/queue.json"
}

# スレッドを1つ足す（write_threads で応答にする）。コメントは [[投稿者, 本文], ...]
thread() {
  jq -nc --argjson c "$1" '{isResolved: false, isOutdated: false, path: "a.sh", line: 3,
    comments: {nodes: [$c | to_entries[] | {databaseId: (100 + .key), author: {login: .value[0]}, body: .value[1],
      url: "https://github.com/me/demo/pull/5#discussion_r\(100 + .key)", createdAt: "2026-10-01T00:00:0\(.key)Z"}]}}' >>"$FIX/threads"
}

write_threads() {
  jq -sc '{data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}' \
    "$FIX/threads" >"$FIX/PrThreads.json"
  : >"$FIX/threads"
}

# レビュー・PR のコメントの編集の時刻（lastEditedAt）を、スレッドの GraphQL の応答（PrThreads.json）に足す。write_threads の後に呼ぶ。
# 使い方: last_edited <レビューか PR のコメントの id> <時刻>
last_edited() {
  jq -c --arg id "$1" --arg t "$2" '.data.repository.pullRequest.comments.nodes += [{id: $id, lastEditedAt: $t}]' \
    "$FIX/PrThreads.json" >"$FIX/PrThreads.json.new"
  mv "$FIX/PrThreads.json.new" "$FIX/PrThreads.json"
}

check_ok() { echo '{__typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "SUCCESS", workflowName: "CI", detailsUrl: "u"}'; }

# 実行して、action と reasons を確かめる。使い方: expect <action> <reasons の JSON>
expect() {
  run_script pr-watch.sh --pr 5
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" "[\"$1\",$2]"
}

@test "表: OPEN でない PR（MERGED・CLOSED）は idle で not_open" {
  setup_fake_gh
  for s in MERGED CLOSED; do
    pr_view "{state: \"$s\", statusCheckRollup: [{__typename: \"CheckRun\", name: \"t\", status: \"COMPLETED\", conclusion: \"FAILURE\"}]}"
    expect idle '["not_open"]'
  done
}

@test "表: ドラフトの PR は idle で draft（指摘や失敗があっても対象外）" {
  setup_fake_gh
  pr_view '{isDraft: true, mergeable: "CONFLICTING"}'
  expect idle '["draft"]'
}

@test "表: フォークからの PR は idle で fork" {
  setup_fake_gh
  watch '{isCrossRepository: true}'
  expect idle '["fork"]'
}

@test "表: マージキューに入っている PR は wait で in_merge_queue（CI が実行中でも）" {
  setup_fake_gh
  queue_state '{mergeQueueEntry: {state: "QUEUED", position: 1}}'
  pr_view "{statusCheckRollup: [{__typename: \"CheckRun\", name: \"t\", status: \"IN_PROGRESS\"}]}"
  expect wait '["in_merge_queue"]'
}

# pr-merge-status.sh・branch-status.sh と同じ判定（dw_merge_queue_state の queued）にそろえる（#381）
@test "表: キューに入れた直後（まだ mergeQueueEntry に出ていない）も、merged で外れた直後（PR がまだ OPEN）も、wait で in_merge_queue" {
  setup_fake_gh
  pr_view "{statusCheckRollup: [{__typename: \"CheckRun\", name: \"t\", status: \"IN_PROGRESS\"}]}"
  # 5 分前（00:05）に入れたイベントだけがある
  queue_state '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:05:00Z"}]}}'
  expect wait '["in_merge_queue"]'
  # merged の理由で外れた（マージの直前）
  queue_state '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:05:00Z"}, {__typename: "RemovedFromMergeQueueEvent", reason: "merged", createdAt: "2026-10-01T00:09:00Z"}]}}'
  expect wait '["in_merge_queue"]'
}

@test "表: キューから外れたままの PR と、入れてから待つ時間を過ぎても並びに出ない PR は、キューの外として扱う。キューが無効なら並んでいても外" {
  setup_fake_gh
  pr_view '{}'
  queue_state '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:01:00Z"}, {__typename: "RemovedFromMergeQueueEvent", reason: "merge_conflict", createdAt: "2026-10-01T00:02:00Z"}]}}'
  expect idle '["nothing_to_do"]'
  # 入れてから 10 分以上たっても並びに出ていない
  queue_state '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-09-30T23:50:00Z"}]}}'
  run_script pr-watch.sh --pr 5
  assert_success
  assert_output --partial "warn: マージキューに入れたイベントの後"
  assert_equal "$(grep -v '^warn: ' <<<"$output" | jq -c '[.action, .reasons]')" '["idle",["nothing_to_do"]]'
  queue_state '{isMergeQueueEnabled: false, mergeQueueEntry: {state: "QUEUED", position: 1}}'
  expect idle '["nothing_to_do"]'
}

@test "表: コンフリクト（CONFLICTING・DIRTY）は conflict で conflicting" {
  setup_fake_gh
  pr_view '{mergeable: "CONFLICTING", mergeStateStatus: "DIRTY"}'
  expect conflict '["conflicting"]'
  pr_view '{mergeStateStatus: "DIRTY"}'
  expect conflict '["conflicting"]'
}

@test "表: base_branch に遅れている（BEHIND）は conflict で behind" {
  setup_fake_gh
  pr_view '{mergeStateStatus: "BEHIND"}'
  expect conflict '["behind"]'
}

@test "表: コンフリクトは CI の失敗や指摘より先に扱う" {
  setup_fake_gh
  pr_view '{mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", statusCheckRollup: [{__typename: "CheckRun", name: "t", status: "COMPLETED", conclusion: "FAILURE"}]}'
  expect conflict '["conflicting"]'
}

@test "表: CI の失敗は act で ci_failed（失敗したチェックの名前を details に出す）" {
  setup_fake_gh
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE"},
    {__typename: "CheckRun", name: "test", status: "IN_PROGRESS"}]}'
  expect act '["ci_failed"]'
  assert_equal "$(jq -c .details.failed_checks <<<"$output")" '["lint"]'
}

@test "表: 返事の無いスレッドは act で unresolved_threads。作者が返事をしたスレッドは数えない" {
  setup_fake_gh
  thread '[["alice","直してください"]]'
  write_threads
  expect act '["unresolved_threads"]'
  assert_equal "$(jq -c .details.unanswered <<<"$output")" '{"threads":1,"reviews":0,"comments":0}'
  thread '[["alice","直してください"],["me","直しました"]]'
  write_threads
  expect idle '["nothing_to_do","awaiting_replies"]'
}

@test "表: 変更の要求か本文のあるレビューは、作者のコメントが後に無ければ act で unanswered_reviews" {
  setup_fake_gh
  pr_view '{reviewDecision: "CHANGES_REQUESTED", reviews: [{id: "R1", author: {login: "alice"}, state: "CHANGES_REQUESTED", body: "", submittedAt: "2026-10-01T00:05:00Z"}]}'
  expect act '["unanswered_reviews"]'
  # 本文の無い変更の要求は、作者が後で別の相手にコメントしても、変更の要求のあいだは act のまま（#357）
  pr_view '{reviewDecision: "CHANGES_REQUESTED", reviews: [{id: "R1", author: {login: "alice"}, state: "CHANGES_REQUESTED", body: "", submittedAt: "2026-10-01T00:05:00Z"}],
    comments: [{id: "C1", author: {login: "me"}, body: "@bob 答えました", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  expect act '["unanswered_reviews"]'
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "COMMENTED", body: "質問です", submittedAt: "2026-10-01T00:05:00Z"}]}'
  expect act '["unanswered_reviews"]'
  # 作者が後でコメントしていれば、対応済み
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "COMMENTED", body: "質問です", submittedAt: "2026-10-01T00:05:00Z"}],
    comments: [{id: "C1", author: {login: "me"}, body: "答えました", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  expect idle '["nothing_to_do","awaiting_replies"]'
  # 本文の無い承認・コメントは、対応が要らない
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "APPROVED", body: "", submittedAt: "2026-10-01T00:05:00Z"},
    {id: "R2", author: {login: "alice"}, state: "COMMENTED", body: "", submittedAt: "2026-10-01T00:05:00Z"}]}'
  expect idle '["nothing_to_do"]'
}

@test "表: 返事の後に編集されたレビュー本文・PR のコメント、時刻が null のものは act（#357）" {
  setup_fake_gh
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "COMMENTED", body: "質問です", submittedAt: "2026-10-01T00:05:00Z"}],
    comments: [{id: "C1", author: {login: "me"}, body: "答えました", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  write_threads
  expect idle '["nothing_to_do","awaiting_replies"]'
  last_edited R1 2026-10-01T00:07:00Z
  expect act '["unanswered_reviews"]'
  pr_view '{comments: [{id: "C1", author: {login: "bob"}, body: "なぜ？", createdAt: "2026-10-01T00:05:00Z", url: "u"},
    {id: "C2", author: {login: "me"}, body: "理由です", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  write_threads
  last_edited C1 2026-10-01T00:07:00Z
  expect act '["unanswered_comments"]'
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "COMMENTED", body: "質問です", submittedAt: null}],
    comments: [{id: "C2", author: {login: "me"}, body: "別の話です", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  write_threads
  expect act '["unanswered_reviews"]'
}

@test "表: 作者以外の PR のコメントは、作者のコメントが後に無ければ act で unanswered_comments" {
  setup_fake_gh
  pr_view '{comments: [{id: "C1", author: {login: "bob"}, body: "なぜ？", createdAt: "2026-10-01T00:05:00Z", url: "u"}]}'
  expect act '["unanswered_comments"]'
  pr_view '{comments: [{id: "C1", author: {login: "bob"}, body: "なぜ？", createdAt: "2026-10-01T00:05:00Z", url: "u"},
    {id: "C2", author: {login: "me"}, body: "理由です", createdAt: "2026-10-01T00:06:00Z", url: "u"}]}'
  expect idle '["nothing_to_do","awaiting_replies"]'
}

@test "表: act の理由は、当てはまるものをすべて並べる" {
  setup_fake_gh
  thread '[["alice","直してください"]]'
  write_threads
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "t", status: "COMPLETED", conclusion: "FAILURE"}],
    comments: [{id: "C1", author: {login: "bob"}, body: "なぜ？", createdAt: "2026-10-01T00:05:00Z", url: "u"}]}'
  expect act '["ci_failed","unresolved_threads","unanswered_comments"]'
}

@test "表: CI が実行中なら wait で ci_pending" {
  setup_fake_gh
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "t", status: "IN_PROGRESS"}]}'
  expect wait '["ci_pending"]'
  pr_view '{statusCheckRollup: [{__typename: "StatusContext", context: "ext", state: "PENDING"}]}'
  expect wait '["ci_pending"]'
}

@test "表: 担当の skill がある投稿者の最初のレビューが無ければ wait で awaiting_review。付けば待たない" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view "{statusCheckRollup: [$(check_ok)]}"
  expect wait '["awaiting_review:coderabbitai[bot]"]'
  assert_equal "$(jq -c .details.waiting_for <<<"$output")" '["coderabbitai[bot]"]'
  # レビューが付いた（本文が空のレビューでも、到着として数える。gh は [bot] を除いた名前を返す）
  watch '{reviews: {nodes: [{author: {login: "coderabbitai"}}]}}'
  expect idle '["nothing_to_do"]'
}

@test "表: 最初のレビューを待つのは、PR を作ってから 60 分まで" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  PR_WATCH_NOW=1790816399 expect wait '["awaiting_review:coderabbitai[bot]"]'
  PR_WATCH_NOW=1790816400 expect idle '["nothing_to_do"]'
}

@test "表: マージできるかを GitHub が計算中（UNKNOWN）なら wait で mergeable_unknown" {
  setup_fake_gh
  pr_view '{mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN"}'
  expect wait '["mergeable_unknown"]'
}

@test "表: CI が全部成功、またはチェックが無く、対応する指摘が無ければ idle で nothing_to_do" {
  setup_fake_gh
  expect idle '["nothing_to_do"]'
  pr_view "{statusCheckRollup: [$(check_ok)], mergeStateStatus: \"BLOCKED\", reviewDecision: \"REVIEW_REQUIRED\"}"
  expect idle '["nothing_to_do","merge_blocked"]'
}

# gh-pr-check の手順1の表（終えるか・伝えること）。action・reasons・respond の組み合わせを確かめる。
# 手順1は、respond が true なら指摘・質問・CI の失敗の一覧（手順2以降）へ進み、false なら何も変えずに終えて reasons を伝える。
#
#   PR の状態 / 入力                                       action    reasons                                         respond
#   OPEN でない（失敗した CI・指摘があっても）              idle      not_open                                         false
#   コメントも CI の失敗も無い、マージできる（CLEAN）       idle      nothing_to_do                                    false
#   コメントが無く、CI が実行中                             wait      ci_pending                                       false
#   コメントが無く、マージできない（BLOCKED）               idle      nothing_to_do, merge_blocked                     false
#   コメントが無く、CI が実行中で、BLOCKED                  wait      ci_pending, merge_blocked                        false
#   本文の無い承認だけ                                      idle      nothing_to_do                                    false
#   返事待ちの項目だけ（返事をしていないものは無い）        idle      nothing_to_do, awaiting_replies                  true
#   返事待ちの項目があり、CI が実行中で、BLOCKED            wait      ci_pending, awaiting_replies, merge_blocked      true
#   返事をしていない PR のコメント                          act       unanswered_comments                              true
#   CI の失敗                                               act       ci_failed                                        true
#   コンフリクトで、返事をしていない PR のコメント          conflict  conflicting                                      true
#   ドラフトで、返事をしていない PR のコメント              idle      draft                                            true
#   フォークで、CI の失敗                                   idle      fork                                             true
#   マージキューにあり、返事をしていない PR のコメント      wait      in_merge_queue                                   true
expect_check() {
  run_script pr-watch.sh --pr 5
  assert_success
  assert_equal "$(jq -c '[.action, .reasons, .respond]' <<<"$output")" "[\"$1\",$2,$3]"
}

@test "表（gh-pr-check の手順1）: 終えるか（respond）と伝えること（reasons）の組み合わせ" {
  setup_fake_gh
  failed='{__typename: "CheckRun", name: "t", status: "COMPLETED", conclusion: "FAILURE"}'
  running='{__typename: "CheckRun", name: "t", status: "IN_PROGRESS"}'
  bob_c='{id: "C1", author: {login: "bob"}, body: "なぜ？", createdAt: "2026-10-01T00:05:00Z", url: "u"}'
  me_c='{id: "C2", author: {login: "me"}, body: "理由です", createdAt: "2026-10-01T00:06:00Z", url: "u"}'

  pr_view "{state: \"CLOSED\", statusCheckRollup: [$failed], comments: [$bob_c]}"
  expect_check idle '["not_open"]' false
  pr_view '{}'
  expect_check idle '["nothing_to_do"]' false
  pr_view "{statusCheckRollup: [$running]}"
  expect_check wait '["ci_pending"]' false
  pr_view '{mergeStateStatus: "BLOCKED"}'
  expect_check idle '["nothing_to_do","merge_blocked"]' false
  pr_view "{mergeStateStatus: \"BLOCKED\", statusCheckRollup: [$running]}"
  expect_check wait '["ci_pending","merge_blocked"]' false
  pr_view '{reviews: [{id: "R1", author: {login: "alice"}, state: "APPROVED", body: "", submittedAt: "2026-10-01T00:05:00Z"}]}'
  expect_check idle '["nothing_to_do"]' false

  pr_view "{comments: [$bob_c, $me_c]}"
  expect_check idle '["nothing_to_do","awaiting_replies"]' true
  pr_view "{mergeStateStatus: \"BLOCKED\", statusCheckRollup: [$running], comments: [$bob_c, $me_c]}"
  expect_check wait '["ci_pending","awaiting_replies","merge_blocked"]' true
  pr_view "{comments: [$bob_c]}"
  expect_check act '["unanswered_comments"]' true
  pr_view "{statusCheckRollup: [$failed]}"
  expect_check act '["ci_failed"]' true

  # action が act でなくても、指摘や CI の失敗があれば respond は true（無人の見回りの対象外・待ちの PR でも、手元では対応する）
  pr_view "{mergeable: \"CONFLICTING\", mergeStateStatus: \"DIRTY\", comments: [$bob_c]}"
  expect_check conflict '["conflicting"]' true
  pr_view "{isDraft: true, comments: [$bob_c]}"
  expect_check idle '["draft"]' true
  watch '{isCrossRepository: true}'
  pr_view "{statusCheckRollup: [$failed]}"
  expect_check idle '["fork"]' true
  watch '{}'
  queue_state '{mergeQueueEntry: {state: "QUEUED", position: 1}}'
  pr_view "{comments: [$bob_c]}"
  expect_check wait '["in_merge_queue"]' true
}

@test "--pr を省略すると今のブランチの PR を見る。PR の番号が正しくなければ使い方の誤りで止まる" {
  setup_fake_gh
  run_script pr-watch.sh
  assert_success
  assert_equal "$(jq -r .pr.number <<<"$output")" 5
  run_script pr-watch.sh --pr abc
  assert_failure 64
  run_script pr-watch.sh --pr
  assert_failure 64
}

@test "何も書き込まない（gh は読む呼び出しだけ）" {
  setup_fake_gh
  thread '[["alice","直してください"]]'
  write_threads
  run_script pr-watch.sh --pr 5
  assert_success
  run grep -c '^WRITE ' "$CALLS"
  assert_output 0
  run grep -c '^READ ' "$CALLS"
  refute_output 0
}

@test "GraphQL を読めなければ、1行のメッセージで止まる" {
  setup_fake_gh
  echo '{"data": {"resource": null}}' >"$FIX/watch.json"
  run_script pr-watch.sh --pr 5
  assert_failure 1
  assert_output --partial "PR #5 のマージキューの状態を読めません"
}

@test "表: reviews が空でも、スレッドの投稿者が handlers に当たれば（大文字小文字・[bot] の違いを無視）到着とみなし、待たない" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"CodeRabbitAI[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  thread '[["coderabbitai","直してください"],["me","直しました"]]'
  write_threads
  expect idle '["nothing_to_do","awaiting_replies"]'
  assert_equal "$(jq -c .details.waiting_for <<<"$output")" '[]'
}

@test "表: コンフリクトと遅れが両方なら conflict で conflicting と behind" {
  setup_fake_gh
  pr_view '{mergeable: "CONFLICTING", mergeStateStatus: "BEHIND"}'
  expect conflict '["conflicting","behind"]'
}

@test "表: CI 実行中・mergeable UNKNOWN・レビュー待ちが重なれば、wait の理由を並べる" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view '{mergeable: "UNKNOWN", statusCheckRollup: [{__typename: "CheckRun", name: "t", status: "IN_PROGRESS"}]}'
  expect wait '["ci_pending","awaiting_review:coderabbitai[bot]","mergeable_unknown"]'
}

@test "表: レビュー待ちの間でも、CI が失敗していれば act で ci_failed" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "t", status: "COMPLETED", conclusion: "FAILURE"}]}'
  expect act '["ci_failed"]'
}

@test "pr-feedback.sh が失敗したら、その終了コードとメッセージを伝えて止まる" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": []}}' >"$REPO/.claude/dev-workflow/config.json"
  run_script pr-watch.sh --pr 5
  assert_failure 1
  assert_output --partial "pr_check.handlers"
}

@test "PrWatch の GraphQL 呼び出しが失敗したら、マージキューの状態を読めないと伝えて止まる" {
  setup_fake_gh
  rm "$FIX/watch.json"
  run_script pr-watch.sh --pr 5
  assert_failure 1
  assert_output --partial "PR #5 のマージキューの状態を読めません"
}

@test "PrQueue の GraphQL 呼び出しが失敗したら、理由を1行で伝えて止まる（キューの外とはみなさない）" {
  setup_fake_gh
  rm "$FIX/queue.json"
  run_script pr-watch.sh --pr 5
  assert_failure 1
  assert_output --partial "PR #5 のマージキューの状態を読めません: "
}

@test "環境に DW_QUEUE_NOW が残っていても、PR_WATCH_NOW があればそれでキューの時刻を判定する（時計を 2 つにしない。#381）" {
  setup_fake_gh
  pr_view '{}'
  # 5 分前（00:05）に入れたイベントだけがある。今は 00:10（PR_WATCH_NOW）なので、キューの中。DW_QUEUE_NOW が勝てば、1 日後で並びに出ていない扱いになる
  queue_state '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:05:00Z"}]}}'
  DW_QUEUE_NOW=1790899800 run_script pr-watch.sh --pr 5
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["wait",["in_merge_queue"]]'
}

@test "下書き・閉じた・フォークの PR は、キューの状態を読めなくても idle を返す（キューの状態は読まない。#381）" {
  setup_fake_gh
  rm "$FIX/queue.json"
  pr_view '{isDraft: true}'
  expect idle '["draft"]'
  pr_view '{state: "CLOSED"}'
  expect idle '["not_open"]'
  pr_view '{}'
  watch '{isCrossRepository: true}'
  expect idle '["fork"]'
  run grep -c '^READ PrQueue ' "$CALLS"
  assert_output 0
}

@test "不明な引数は 64 で止まり、--help は使い方を出して 0 で終わる" {
  setup_fake_gh
  run_script pr-watch.sh --bogus
  assert_failure 64
  assert_output --partial "不明な引数です: --bogus"
  run_script pr-watch.sh --help
  assert_success
  assert_output --partial "使い方: pr-watch.sh"
}

@test "マージキューの状態は、PR の URL で引く" {
  setup_fake_gh
  run_script pr-watch.sh --pr 5
  assert_success
  run grep '^READ Pr\(Watch\|Queue\) ' "$CALLS"
  assert_line "READ PrWatch $(jq -r .url "$FIX/pr-view.json")"
  assert_line "READ PrQueue $(jq -r .url "$FIX/pr-view.json")"
}

@test "指摘やコメントの本文が長くても（引数の長さの上限の 128 KiB を超えても）止まらない" {
  setup_fake_gh
  long_text "$TMP/long"
  jq --rawfile b "$TMP/long" '.comments = [{id: "C1", author: {login: "bob"}, body: $b, createdAt: "2026-10-01T00:05:00Z", url: "u"}]' \
    "$FIX/pr-view.json" >"$TMP/v.json"
  mv "$TMP/v.json" "$FIX/pr-view.json"
  expect act '["unanswered_comments"]'
}

# --- #340: repair.*（ADR 000285・000340） ---

# 設定 repair.* を書く。使い方: repair_cfg <repair のオブジェクト（JSON）>
repair_cfg() {
  jq -n --argjson r "$1" '{repair: $r}' >"$REPO/.claude/dev-workflow/config.json"
}

# PR のコメントの応答（api-comments.json）を作る。使い方: api_comments <[[投稿者, 本文, 時刻], ...]>
api_comments() {
  jq -c '[[to_entries[] | {id: (900 + .key), user: {login: .value[0]}, body: .value[1], created_at: .value[2]}]]' <<<"$1" >"$FIX/api-comments.json"
  echo '[[]]' >"$FIX/api-commits.json"
}

failed_head() {
  pr_view "{headRefOid: \"abcdef1\", statusCheckRollup: [{__typename: \"CheckRun\", name: \"t\", status: \"COMPLETED\", conclusion: \"FAILURE\"}]}"
}

run_marker() { printf '<!-- dev-workflow:repair-run head=%s --> 実行ログ' "$1"; }

@test "stop: 今の head の repair-run が repair.max_fix_attempts 未満なら act、以上なら stop で same_failure（ci_failed を続ける）" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 2}'
  api_comments "[[\"app[bot]\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"]]"
  expect act '["ci_failed"]'
  api_comments "[[\"app[bot]\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"], [\"app\", \"$(run_marker ABCDEF1)\", \"2026-10-01T00:02:00Z\"]]"
  expect stop '["same_failure","ci_failed"]'
  # 同じ head での試行が上限に達していても、respond は変わらない（gh-pr-check が一覧へ進む）
  assert_equal "$(jq -r .respond <<<"$output")" true
}

@test "stop: head が進んだ repair-run の回数が repair.max_pushes_per_pr 以上なら stop で push_limit。ほかの指摘の理由も並べる" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_pushes_per_pr": 2}'
  api_comments "[[\"app\", \"$(run_marker 1111111)\", \"2026-10-01T00:01:00Z\"]]"
  expect act '["ci_failed"]'
  api_comments "[[\"app\", \"$(run_marker 1111111)\", \"2026-10-01T00:01:00Z\"], [\"app\", \"$(run_marker 2222222)\", \"2026-10-01T00:02:00Z\"], [\"app\", \"$(run_marker 2222222)\", \"2026-10-01T00:03:00Z\"]]"
  thread '[["alice","直してください"]]'
  write_threads
  expect stop '["push_limit","ci_failed","unresolved_threads"]'
}

@test "stop: 別の head の repair-run は、この head での試行に数えない" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 1, "max_pushes_per_pr": 5}'
  api_comments "[[\"app\", \"$(run_marker 1111111)\", \"2026-10-01T00:01:00Z\"]]"
  expect act '["ci_failed"]'
}

@test "stop: repair.reply_logins 以外の投稿者の repair-run と、再開の起点より前の repair-run は数えない" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 1, "allowed_authors": ["alice"]}'
  api_comments "[[\"mallory\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"]]"
  expect act '["ci_failed"]'
  # 許可した投稿者の新しいコメント（再開の起点）より前の repair-run は数えない
  api_comments "[[\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"], [\"alice\", \"もう一度見てください\", \"2026-10-01T00:05:00Z\"]]"
  expect act '["ci_failed"]'
  # repair-done の後の repair-run だけ数える
  api_comments "[[\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"], [\"app\", \"<!-- dev-workflow:repair-done sha=abcdef1 at=x -->\", \"2026-10-01T00:02:00Z\"], [\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:03:00Z\"]]"
  expect stop '["same_failure","ci_failed"]'
}

@test "stop: 人の push（committer が reply_logins でないコミット）の後の repair-run だけ数える" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 1}'
  api_comments "[[\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"]]"
  echo '[[{"sha": "abcdef1", "parents": [], "committer": {"login": "alice"}, "commit": {"committer": {"date": "2026-10-01T00:05:00Z"}}}]]' >"$FIX/api-commits.json"
  expect act '["ci_failed"]'
}

@test "stop: ci_failed が無ければ、repair-run が上限を超えていても stop にしない" {
  setup_fake_gh
  pr_view '{headRefOid: "abcdef1"}'
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 1}'
  api_comments "[[\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"]]"
  thread '[["alice","直してください"]]'
  write_threads
  expect act '["unresolved_threads"]'
}

@test "stop: repair.enabled が false か reply_logins が空か、コメントを読めないときは、数えずに act" {
  setup_fake_gh
  failed_head
  api_comments "[[\"app\", \"$(run_marker abcdef1)\", \"2026-10-01T00:01:00Z\"]]"
  repair_cfg '{"enabled": false, "reply_logins": ["app"], "max_fix_attempts": 1}'
  expect act '["ci_failed"]'
  repair_cfg '{"enabled": true, "reply_logins": [], "max_fix_attempts": 1}'
  expect act '["ci_failed"]'
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "max_fix_attempts": 1}'
  rm "$FIX/api-comments.json"
  expect act '["ci_failed"]'
}

@test "対応済み: repair.reply_logins の返信（マーカーの to が一致し、後の時刻）は、スレッド・レビュー・PR のコメントを対応が要る指摘に数えない" {
  setup_fake_gh
  repair_cfg '{"reply_logins": ["app"]}'
  # スレッド（先頭のコメントの ID は 100）。持ち主 alice の最後のコメント（101）への返信
  thread '[["alice","直してください"],["alice","もう1つ"],["app","<!-- dev-workflow:repair-reply to=100 -->\n直しました"]]'
  write_threads
  expect act '["unresolved_threads"]'
  thread '[["alice","直してください"],["alice","もう1つ"],["app","<!-- dev-workflow:repair-reply to=101 -->\n直しました"]]'
  write_threads
  expect idle '["nothing_to_do"]'
  # マーカーだけで、投稿者が reply_logins でなければ対応済みにしない
  thread '[["alice","直してください"],["mallory","<!-- dev-workflow:repair-reply to=100 -->\n直しました"]]'
  write_threads
  expect act '["unresolved_threads"]'
  # PR のコメントとレビュー本文
  pr_view '{comments: [{id: "C1", author: {login: "bob"}, body: "質問です", createdAt: "2026-10-01T00:01:00Z"},
    {id: "C2", author: {login: "app"}, body: "<!-- dev-workflow:repair-reply to=C1 -->\n答えです", createdAt: "2026-10-01T00:02:00Z"}],
    reviews: [{id: "R1", author: {login: "bob"}, state: "COMMENTED", body: "指摘", submittedAt: "2026-10-01T00:01:00Z"}]}'
  write_threads
  expect act '["unanswered_reviews"]'
  pr_view '{comments: [{id: "C1", author: {login: "bob"}, body: "質問です", createdAt: "2026-10-01T00:01:00Z"},
    {id: "C2", author: {login: "app"}, body: "<!-- dev-workflow:repair-reply to=C9 -->\n別の指摘への返信", createdAt: "2026-10-01T00:02:00Z"}]}'
  expect act '["unanswered_comments"]'
}

@test "レビュー待ち: レート制限を知らせるコメントは到着に数えない" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"rev[bot]": "rev-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view "{comments: [{id: \"C1\", author: {login: \"rev\"}, body: \"<!-- This is an auto-generated comment: rate limited by rev.ai -->\\n上限です\", createdAt: \"2026-10-01T00:02:00Z\"}, {id: \"C2\", author: {login: \"me\"}, body: \"確認しました\", createdAt: \"2026-10-01T00:03:00Z\"}], statusCheckRollup: [$(check_ok)]}"
  expect wait '["awaiting_review:rev[bot]","awaiting_replies"]'
  # 上限以外のコメントは到着
  pr_view "{comments: [{id: \"C1\", author: {login: \"rev\"}, body: \"指摘なし\", createdAt: \"2026-10-01T00:02:00Z\"}, {id: \"C2\", author: {login: \"me\"}, body: \"確認しました\", createdAt: \"2026-10-01T00:03:00Z\"}], statusCheckRollup: [$(check_ok)]}"
  run_script pr-watch.sh --pr 5
  assert_success
  assert_equal "$(jq -c .reasons <<<"$output")" '["nothing_to_do","awaiting_replies"]'
}

@test "レビュー待ち: repair.wait_for_reviewers の投稿者も待つ。待つ時間は repair.review_wait_minutes" {
  setup_fake_gh
  repair_cfg '{"wait_for_reviewers": ["rev"], "review_wait_minutes": 5}'
  pr_view "{statusCheckRollup: [$(check_ok)]}"
  # 作ってから 10 分たっていて、5 分の上限を過ぎている
  expect idle '["nothing_to_do"]'
  repair_cfg '{"wait_for_reviewers": ["rev"], "review_wait_minutes": 15}'
  expect wait '["awaiting_review:rev"]'
}

@test "レビュー待ち: 無人の push の後は、その push より後に今の head へ付く増分のレビューも待つ" {
  setup_fake_gh
  repair_cfg '{"enabled": true, "reply_logins": ["app"], "wait_for_reviewers": ["rev"], "review_wait_minutes": 60}'
  pr_view "{headRefOid: \"abcdef1\", statusCheckRollup: [$(check_ok)]}"
  api_comments '[]'
  # 00:08 に無人の実行が push して head になった。最初のレビューは 00:03（古い head）
  echo '[[{"sha": "abcdef1", "parents": [], "committer": {"login": "app[bot]"}, "commit": {"committer": {"date": "2026-10-01T00:08:00Z"}}}]]' >"$FIX/api-commits.json"
  watch '{reviews: {nodes: [{author: {login: "rev"}, submittedAt: "2026-10-01T00:03:00Z", commit: {oid: "0000000"}}]}}'
  expect wait '["awaiting_review:rev"]'
  # push の後でも、古い head へのレビューは到着に数えない
  watch '{reviews: {nodes: [{author: {login: "rev"}, submittedAt: "2026-10-01T00:09:00Z", commit: {oid: "0000000"}}]}}'
  expect wait '["awaiting_review:rev"]'
  # push の後に、今の head へ付いたら待たない
  watch '{reviews: {nodes: [{author: {login: "rev"}, submittedAt: "2026-10-01T00:09:00Z", commit: {oid: "abcdef1"}}]}}'
  expect idle '["nothing_to_do"]'
  # 待つ時間は push の時刻から数える（00:08 から 60 分）
  watch '{}'
  PR_WATCH_NOW=1790816879 expect wait '["awaiting_review:rev"]'
  PR_WATCH_NOW=1790816880 expect idle '["nothing_to_do"]'
}

@test "repair.enabled が true でも、何も書き込まない" {
  setup_fake_gh
  failed_head
  repair_cfg '{"enabled": true, "reply_logins": ["app"]}'
  api_comments '[]'
  run_script pr-watch.sh --pr 5
  assert_success
  run grep -c '^WRITE ' "$CALLS"
  assert_output 0
  run grep -c '^READ api-' "$CALLS"
  assert_output 2
}

@test "action が stop になる値は、--help の表に書いてある" {
  run_script pr-watch.sh --help
  assert_output --partial "stop"
  assert_output --partial "same_failure"
  assert_output --partial "push_limit"
}

@test "表: pr に merge_state が出る（gh-pr-check の見回りが、マージできるかを言うため）" {
  setup_fake_gh
  pr_view '{mergeStateStatus: "BLOCKED"}'
  run_script pr-watch.sh --pr 5
  assert_success
  assert_equal "$(jq -r .pr.merge_state <<<"$output")" BLOCKED
  pr_view '{}'
  run_script pr-watch.sh --pr 5
  assert_equal "$(jq -r .pr.merge_state <<<"$output")" CLEAN
}

@test "repair.* の型が正しくなければ、repair を含むメッセージで止まる" {
  setup_fake_gh
  for c in '{"enabled": "yes"}' '{"max_fix_attempts": "3"}' '{"reply_logins": "app"}'; do
    repair_cfg "$c"
    run_script pr-watch.sh --pr 5
    assert_failure
    assert_output --partial "repair"
  done
}

# jq 1.7 は、オブジェクトの値に「(…) + …」を括弧で包まずに書くと読めない（1.8 は読めるので、手元の jq が新しいと気づかない。CI の jq で落ちた）
@test "scripts の jq で、オブジェクトの値に書いた (…) + … は、全体を括弧で包む（jq 1.7 が読めない）" {
  run awk '
    /^[[:space:]]*\{?[a-z_]+: \(/ {
      line = $0; sub(/^[[:space:]]*\{?[a-z_]+: /, "", line)
      depth = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) break }
      }
      if (depth == 0 && substr(line, i + 1) ~ /^[[:space:]]*\+/) { print FILENAME ":" FNR ": " $0; bad = 1 }
    }
    END { exit bad }
  ' "$BATS_TEST_DIRNAME"/../plugins/dev-workflow/scripts/*.sh
  assert_success
}
