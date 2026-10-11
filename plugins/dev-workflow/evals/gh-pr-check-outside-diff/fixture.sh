#!/usr/bin/env bash
# PR #5 は、行ごとの指摘（スレッド）が 0 件で、CI も通り、マージできる。ただし、レビュー本文に diff の外の指摘
# （bin/greet.sh の 3 行目の $1 を引用符で囲んでいない）があり、PR の作者はまだ返事をしていない。
# スレッドの件数だけを見て「対応はありません」と言わず、この指摘を報告するかを見る（#279）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo
mkdir -p bin
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\nset -euo pipefail\nname=$1\nprintf '"'"'Hello, %%s!\\n'"'"' "$name"\n' >bin/greet.sh
chmod +x bin/greet.sh
git add -A
git commit -q -m "feat: 挨拶のスクリプトを足す"
git push -q origin main
git switch -q -c docs/5-usage
# shellcheck disable=SC2016 # 書き出す文書の中身なので、展開させない
printf '# demo\n\n## 使い方\n\n`bin/greet.sh Taro` で挨拶を出します。\n' >README.md
git commit -q -am "docs: 使い方を書く"
git push -q -u origin docs/5-usage

# shellcheck disable=SC2016 # レビュー本文の中身なので、展開させない
review_body='**Actionable comments posted: 0**

<details>
<summary>⚠️ Outside diff range comments (1)</summary>

`bin/greet.sh` (line 3): `name=$1` は、引数が無いときに set -u で分かりにくいエラーになります。`name="${1:?名前を指定してください}"` のようにしてください。

</details>'
pr="$(jq -n --arg body "$review_body" '{number: 5, url: "https://github.com/me/demo/pull/5", title: "docs: 使い方を書く",
  state: "OPEN", isDraft: false, author: {login: "me"}, headRefName: "docs/5-usage", headRefOid: "abc123",
  baseRefName: "main", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "",
  reviews: [{id: "PRR_1", author: {login: "reviewer"}, authorAssociation: "MEMBER", state: "COMMENTED", body: $body,
    submittedAt: "2026-10-01T00:05:00Z", commit: {oid: "abc123"}}],
  comments: [],
  statusCheckRollup: [{__typename: "CheckRun", name: "test", workflowName: "Test", status: "COMPLETED",
    conclusion: "SUCCESS", detailsUrl: "https://github.com/me/demo/actions/runs/1/job/1"}],
  files: [{path: "README.md", additions: 4, deletions: 0}]}')"
fake_gh_read 'pr view*' "$pr"
# pr-watch.sh（gh-pr-check の手順1）が読むマージキューの状態など。フォークでなく、キューに入っていない（上の行が先に当たる）
fake_gh_read 'api graphql PrWatch*' '{"data": {"resource": {"createdAt": "2026-10-01T00:00:00Z", "isCrossRepository": false,
  "reviews": {"nodes": [{"author": {"login": "reviewer"}}]}}}}'
# キューの中かの判定（common.sh の dw_merge_queue_state）が読むキューの状態。キューは有効だが、並んでおらず、出入りのイベントも無い
fake_gh_read 'api graphql PrQueue*' '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": null,
  "timelineItems": {"nodes": []}}}}'
# resolved でないスレッドは無い（pr-feedback.sh の GraphQL）。プラグインが無いときに Claude が書くクエリにも、同じく空で答える
threads='{"data": {"repository": {"pullRequest": {"reviewThreads": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}}}'
fake_gh_read 'api graphql*' "$threads"
# プラグインが無いとき（比べるための実行）、Claude は REST でも読む。読むだけなので表で宣言する
fake_gh_read 'api *repos/me/demo/pulls/5/comments*' '[]'
fake_gh_read 'api *repos/me/demo/issues/5/comments*' '[]'
fake_gh_read 'api *repos/me/demo/pulls/5/reviews*' "$(jq -n --arg body "$review_body" \
  '[{id: 1, user: {login: "reviewer"}, state: "COMMENTED", body: $body, submitted_at: "2026-10-01T00:05:00Z", commit_id: "abc123"}]')"
fake_gh_defaults
