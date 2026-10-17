#!/usr/bin/env bash
# task-auto・無人のマージ・連鎖を有効にし（連鎖の上限 auto.chain.max は 3）、保留の列（On Hold）があるリポジトリ。
# 連鎖の最初の Issue #5 の記録には、連鎖 c1 で進めた Issue として #5 と #7 の2件がある（上限の手前）。
# #7 の PR #30 は、マージされている（ブランチ feat/7-add-greet は main に取り込み済み）。Todo の先頭は #8（別れの挨拶のスクリプトを足す feat）。
# マージの後の続きを頼まれたら、PR #30 の後片付けをし、#8 を連鎖の記録に足してから、task-auto で #8 の PR の作成まで進めるかを見る
# （task-auto-sequence の手順3〜5。PR のマージ・キューへの投入はしない。ADR 000411）
# 実行を短く、結果を揺れにくくするため、レビューの観点は全部止め、周回は1周にする
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true, "merge": {"enabled": true}, "chain": {"enabled": true, "max": 3}}, "review": {"max_rounds": 1}}'
mkdir -p bin .claude/dev-workflow/review
for p in code-review docs-sync issue-requirements main-drift regression-test test-coverage; do
  printf -- '---\ntitle: このケースでは使わない\nenabled: false\n---\n' >".claude/dev-workflow/review/${p}.md"
done
git add -A
git commit -q -m "chore: レビューの観点を止める"
git push -q origin main
# #7 の作業のブランチ：main に取り込み済み（先頭が同じ）で、origin にもある
git switch -q -c feat/7-add-greet
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 挨拶を出す。使い方: greet.sh <名前>\nset -euo pipefail\nprintf '"'"'Hello, %%s!\\n'"'"' "$1"\n' >bin/greet.sh
chmod +x bin/greet.sh
git add -A
git commit -q -m "feat: 挨拶のスクリプトを足す"
git push -q -u origin feat/7-add-greet
git switch -q main
git merge -q --ff-only feat/7-add-greet
git push -q origin main
tip="$(git rev-parse HEAD)"
fake_issue_json "$(jq -n '{number: 5, title: "最初の Issue", labels: [{name: "feat"}], state: "CLOSED", body: "## やること\n- [x] 何か",
  comments: [
    {body: "<!-- dev-workflow:task-auto-sequence chain=c1 issue=5 -->\n連鎖（c1）で Issue #5 を進めました。"},
    {body: "<!-- dev-workflow:task-auto-sequence chain=c1 issue=7 -->\n連鎖（c1）で Issue #7 を進めました。"}]}')"
fake_issue_json "$(jq -n '{number: 7, title: "挨拶のスクリプトを足す", labels: [{name: "feat"}], state: "CLOSED", comments: []}')"
body="## 背景
挨拶のスクリプト（bin/greet.sh）はあるが、別れの挨拶を出すスクリプトが無い。

## やること
- [ ] bin/farewell.sh を足す

## 完了条件
- \`bin/farewell.sh Taro\` が \`Goodbye, Taro!\` を出す

## 変更するファイル・領域
- bin/farewell.sh

## 依存
- なし"
fake_issue_json "$(jq -n --arg b "$body" '{number: 8, title: "別れの挨拶を出すスクリプトを足す", labels: [{name: "feat"}], comments: [], body: $b}')"
pr="$(jq -nc --arg tip "$tip" '{number: 30, url: "https://github.com/me/demo/pull/30", state: "MERGED", mergedAt: "2026-10-17T01:00:00Z",
  createdAt: "2026-10-17T00:00:00Z", headRefName: "feat/7-add-greet", headRefOid: $tip, baseRefName: "main", isCrossRepository: false,
  labels: [], closingIssuesReferences: [{number: 7, repository: {name: "demo", owner: {login: "me"}}}]}')"
fake_gh_read 'pr view 30' "$pr"
fake_gh_read 'pr view 30 *' "$pr"
# #7 のブランチで探す呼び出し（後片付け）にだけマージ済みの PR を返し、ほかのブランチ（#8 のブランチなど）と一覧（開いている PR の読み取りなど）には空を返す
fake_gh_read 'pr list*--head feat/7-add-greet *' "[${pr}]"
# 次の Issue の選択（next-tasks.sh）と着手（task-start.sh）が読む Project の項目。Todo は #8 だけで、着手中の Issue は無い
fake_gh_read 'api graphql TodoItems' "$(jq -nc --arg b "$body" '{data: {repositoryOwner: {projectV2: {items: {pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{content: {__typename: "Issue", number: 8, title: "別れの挨拶を出すスクリプトを足す", state: "OPEN", body: $b,
    url: "https://github.com/me/demo/issues/8", repository: {nameWithOwner: "me/demo"}, subIssuesSummary: {total: 0}},
    status: {name: "Todo"}, sp: null}]}}}}}')"
fake_gh_read 'api --paginate repos/me/demo/issues/8/dependencies/blocked_by*' '[]'
fake_gh_read 'api --paginate users/me/projectsV2/4/fields*' '[{"id": 1, "node_id": "F1", "name": "Status", "data_type": "single_select", "options": [{"id": "OT", "name": {"raw": "Todo"}}, {"id": "OH", "name": {"raw": "On Hold"}}, {"id": "OP", "name": {"raw": "In Progress"}}, {"id": "OD", "name": {"raw": "Done"}}]}]'
fake_gh_read 'api graphql IssueItem' '{"data": {"repository": {"issue": {"url": "https://github.com/me/demo/issues/8", "projectItems": {"nodes": [{"id": "IT8", "project": {"id": "P4"}, "fieldValueByName": {"name": "Todo"}}]}}}}}'
fake_gh_read 'api repos/me/demo/issues/8/parent*' 'gh: Not Found (HTTP 404)' 1
fake_gh_read 'api repos/me/demo/issues/8' '{"number": 8, "parent_issue_url": null}'
fake_gh_defaults
