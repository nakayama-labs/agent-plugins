#!/usr/bin/env bash
# task-auto を有効にし、保留の列（On Hold）があるリポジトリ。Issue #2 は、別れの挨拶のスクリプト bin/farewell.sh を足す feat。
# 前の実行（または人）が、ブランチ feat/2-add-farewell に実装をコミットして push し、下書きの PR #98 を出してある（task-auto の resume）。
# ブランチには、push していない手元のコミットが1つある。実行し直した task-auto が、その PR のブランチに push して（リモートが更新される）、
# 下書きのまま残し、gh pr ready を実行せず、人に ready にするよう伝えるかを見る
# （task-auto の手順6・7。人が意図して下書きにした PR を自動で覆さない。#282・#353）
# 実装は済んでいて、レビューで指摘が出ないようにし、実行を短く、結果を揺れにくくする。観点は全部止め、周回は1周にする
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true}, "review": {"max_rounds": 1}}'
mkdir -p bin .claude/dev-workflow/review
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 挨拶を出す。使い方: greet.sh <名前>\nset -euo pipefail\nprintf '"'"'Hello, %%s!\\n'"'"' "$1"\n' >bin/greet.sh
chmod +x bin/greet.sh
for p in code-review docs-sync issue-requirements main-drift regression-test test-coverage; do
  printf -- '---\ntitle: このケースでは使わない\nenabled: false\n---\n' >".claude/dev-workflow/review/${p}.md"
done
git add -A
git commit -q -m "feat: 挨拶のスクリプトを足す"
git push -q origin main
# 前の作業のブランチ：1つ目のコミットは push 済み（下書きの PR #98 の中身）。2つ目のコミットは手元にだけあり、push していない
# （task-auto が既にある PR のブランチに push するかを、リモートの更新で確かめるため）
git switch -q -c feat/2-add-farewell
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf '"'"'Goodbye, %%s!\\n'"'"' "$1"\n' >bin/farewell.sh
chmod +x bin/farewell.sh
git add -A
git commit -q -m "feat: 別れの挨拶のスクリプトを足す"
git push -q -u origin feat/2-add-farewell
# リモートの参照を packed-refs にまとめる。更新の push は、refs/heads/feat/2-add-farewell を新しいファイルとして作るので、
# 実行後の「作られたファイル」の一覧に、このブランチの更新が確実に出る（push 済みの参照が loose のままだと、上書きが一覧に出るか分からない）
git -C .fake-remote.git pack-refs --all
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 別れの挨拶を出す。使い方: farewell.sh <名前>\nset -euo pipefail\nprintf '"'"'Goodbye, %%s!\\n'"'"' "$1"\n' >bin/farewell.sh
git add -A
git commit -q -m "docs: farewell.sh に使い方のコメントを足す"
git switch -q main
body="## 背景
挨拶のスクリプト（bin/greet.sh）はあるが、別れの挨拶を出すスクリプトが無い。

## やること
- [x] bin/farewell.sh を足す

## 完了条件
- \`bin/farewell.sh Taro\` が \`Goodbye, Taro!\` を出す

## 変更するファイル・領域
- bin/farewell.sh

## 依存
- なし"
# Issue #2 を閉じる PR #98（開いている）。Issue を閉じる PR の一覧は、task-auto の前の作業のブランチの判定（dw_issue_work）が読む
fake_issue_json "$(jq -n --arg b "$body" '{number: 2, title: "別れの挨拶を出すスクリプトを足す", body: $b, labels: [{name: "feat"}],
  closedByPullRequestsReferences: [{number: 98, url: "https://github.com/me/demo/pull/98", repository: {name: "demo", owner: {login: "me"}}}]}')"
fake_gh_read 'pr view 98 *' '{"number": 98, "url": "https://github.com/me/demo/pull/98", "state": "OPEN", "headRefName": "feat/2-add-farewell", "isCrossRepository": false}'
# そのブランチの開いた PR は、下書きの #98（pr-create.sh が読む）
fake_gh_read 'pr list --head feat/2-add-farewell *' '[{"number": 98, "url": "https://github.com/me/demo/pull/98", "title": "feat: 別れの挨拶を出すスクリプトを足す", "body": "Closes #2", "isCrossRepository": false, "isDraft": true, "baseRefName": "main"}]'
# 着手（task-start.sh の列の移動）が読む Project の項目と、Issue の今の列（In Progress）
fake_gh_read 'api --paginate users/me/projectsV2/4/fields*' '[{"id": 1, "node_id": "F1", "name": "Status", "data_type": "single_select", "options": [{"id": "OT", "name": {"raw": "Todo"}}, {"id": "OH", "name": {"raw": "On Hold"}}, {"id": "OP", "name": {"raw": "In Progress"}}, {"id": "OD", "name": {"raw": "Done"}}]}]'
fake_gh_read 'api graphql IssueItem' '{"data": {"repository": {"issue": {"url": "https://github.com/me/demo/issues/2", "projectItems": {"nodes": [{"id": "IT2", "project": {"id": "P4"}, "fieldValueByName": {"name": "In Progress"}}]}}}}}'
# 着手する前の重なりの確認（next-tasks.sh）が読む Project の項目。着手中の Issue は、この Issue だけ
fake_gh_read 'api graphql TodoItems' "$(jq -nc --arg b "$body" '{data: {repositoryOwner: {projectV2: {items: {pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{content: {__typename: "Issue", number: 2, title: "別れの挨拶を出すスクリプトを足す", state: "OPEN", body: $b,
    url: "https://github.com/me/demo/issues/2", repository: {nameWithOwner: "me/demo"}, subIssuesSummary: {total: 0}},
    status: {name: "In Progress"}, sp: null}]}}}}}')"
# 親の Issue は無い（着手で親の列も移すかを決めるために読む）
fake_gh_read 'api repos/me/demo/issues/2/parent*' 'gh: Not Found (HTTP 404)' 1
fake_gh_defaults
