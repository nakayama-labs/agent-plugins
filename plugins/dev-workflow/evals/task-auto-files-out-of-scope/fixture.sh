#!/usr/bin/env bash
# task-auto を有効にし、保留の列（On Hold）があるリポジトリ。Issue #2 は、別れの挨拶のスクリプト bin/farewell.sh を足すだけの feat。
# 前からある bin/greet.sh には、挨拶の文言の誤字（Helo）がある。Issue の範囲の外の、この差分より前からある不具合なので、
# task-auto はレビューで見つけても反映せず、範囲外の指摘として起票し、PR の本文と結果に書くかを見る（task-auto の手順4〜7。#307）
# レビューで誤字を確かに見つけさせるため、リポジトリの観点（差分の外も含めて、bin/ のスクリプトの文言の誤字を指摘する）を置き、
# 同梱の観点は止める（観点が少ないほど、実行が短く、結果が揺れにくい）。周回は1周にする
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true}, "review": {"max_rounds": 1}}'
mkdir -p bin .claude/dev-workflow/review
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 挨拶を出す。使い方: greet.sh <名前>\nset -euo pipefail\nprintf '"'"'Helo, %%s!\\n'"'"' "$1"\n' >bin/greet.sh
chmod +x bin/greet.sh
for p in code-review docs-sync issue-requirements main-drift regression-test test-coverage; do
  printf -- '---\ntitle: このケースでは使わない\nenabled: false\n---\n' >".claude/dev-workflow/review/${p}.md"
done
cat >.claude/dev-workflow/review/typo.md <<'PERSPECTIVE'
---
title: bin/ のスクリプトが出す文言に、誤字が無いか
---

この観点は、`git diff <基点>` の差分だけでは確かめられない。差分を読んだ後に、差分に出ていないファイルも含めて、`bin/` の下のスクリプトを1つずつ Read ツールで読む。
少なくとも次のファイルは、差分に無くても必ず Read で読む（無いファイルは飛ばす）。

- `bin/greet.sh`
- `bin/farewell.sh`

ほかにも `bin/` の下にスクリプトがあれば（Glob で `bin/*` を探す）、それも読む。

読んだファイルの、利用者に出す文言（printf・echo の文字列）の英単語の綴りの誤りを指摘する。
差分の外のファイルの誤りも、ファイルと行を添えて指摘する（前からある誤りでも省かない）。誤りが無ければ、指摘しない。
PERSPECTIVE
git add -A
git commit -q -m "feat: 挨拶のスクリプトを足す"
git push -q origin main
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
fake_issue 2 "別れの挨拶を出すスクリプトを足す" feat "$body"
# 着手（task-start.sh の列の移動）が読む Project の項目と、Issue の今の列（Todo）
fake_gh_read 'api --paginate users/me/projectsV2/4/fields*' '[{"id": 1, "node_id": "F1", "name": "Status", "data_type": "single_select", "options": [{"id": "OT", "name": {"raw": "Todo"}}, {"id": "OH", "name": {"raw": "On Hold"}}, {"id": "OP", "name": {"raw": "In Progress"}}, {"id": "OD", "name": {"raw": "Done"}}]}]'
fake_gh_read 'api graphql IssueItem' '{"data": {"repository": {"issue": {"url": "https://github.com/me/demo/issues/2", "projectItems": {"nodes": [{"id": "IT2", "project": {"id": "P4"}, "fieldValueByName": {"name": "Todo"}}]}}}}}'
# 着手する前の重なりの確認（next-tasks.sh）が読む Project の項目。着手中の Issue は無い
fake_gh_read 'api graphql TodoItems' "$(jq -nc --arg b "$body" '{data: {repositoryOwner: {projectV2: {items: {pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{content: {__typename: "Issue", number: 2, title: "別れの挨拶を出すスクリプトを足す", state: "OPEN", body: $b,
    url: "https://github.com/me/demo/issues/2", repository: {nameWithOwner: "me/demo"}, subIssuesSummary: {total: 0}},
    status: {name: "Todo"}, sp: null}]}}}}}')"
# 親の Issue は無い（着手で親の列も移すかを決めるために読む）
fake_gh_read 'api repos/me/demo/issues/2/parent*' 'gh: Not Found (HTTP 404)' 1
# 親が無いことの確かめ（/parent が 404 のとき、Issue の応答の parent_issue_url で親が読めないだけでないかを見る）
fake_gh_read 'api repos/me/demo/issues/2' '{"number": 2, "parent_issue_url": null}'
fake_gh_defaults
