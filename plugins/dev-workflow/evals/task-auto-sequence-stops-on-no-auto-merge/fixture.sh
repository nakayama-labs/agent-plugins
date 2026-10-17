#!/usr/bin/env bash
# task-auto・無人のマージ・連鎖を有効にし（上限 auto.chain.max は 3）、保留の列（On Hold）があるリポジトリ。
# 連鎖の最初の Issue #5 の記録には、連鎖 c1 で進めた Issue として #5 の1件だけがある（上限には達していない）。
# #5 の PR #30 は、まだマージされておらず、止める印（ラベル no-auto-merge）が付いている。次の Issue の候補（Todo の #8）もある。
# 続きを頼まれたら、後片付けも次の Issue への着手もせずに、止める印が付いていることを PR にコメントして止まるかを見る
# （task-auto-sequence の手順3。止める手段の2つ目。ADR 000411）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true, "merge": {"enabled": true}, "chain": {"enabled": true, "max": 3}}}'
fake_issue_json "$(jq -n '{number: 5, title: "挨拶のスクリプトを足す", labels: [{name: "feat"}], comments: [
    {body: "<!-- dev-workflow:task-auto-sequence chain=c1 issue=5 -->\n連鎖（c1）で Issue #5 を進めました。"}]}')"
fake_issue_json "$(jq -n '{number: 8, title: "別れの挨拶のスクリプトを足す", labels: [{name: "feat"}], comments: [],
  body: "## やること\n- [ ] bin/farewell.sh を足す\n\n## 完了条件\n- `bin/farewell.sh Taro` が `Goodbye, Taro!` を出す\n\n## 変更するファイル・領域\n- bin/farewell.sh\n\n## 依存\n- なし"}')"
pr="$(jq -nc '{number: 30, url: "https://github.com/me/demo/pull/30", state: "OPEN", mergedAt: null,
  createdAt: "2026-10-17T00:00:00Z", headRefName: "feat/5-add-greet", headRefOid: "0000000000000000000000000000000000000000",
  baseRefName: "main", isCrossRepository: false, labels: [{name: "feat"}, {name: "no-auto-merge"}], closingIssuesReferences: [{number: 5}]}')"
fake_gh_read 'pr view 30' "$pr"
fake_gh_read 'pr view 30 *' "$pr"
fake_gh_read 'pr list*' "[${pr}]"
fake_gh_defaults
