#!/usr/bin/env bash
# task-auto・無人のマージ・連鎖を有効にし（連鎖の上限 auto.chain.max は 2）、保留の列（On Hold）があるリポジトリ。
# 連鎖の最初の Issue #5 の記録には、連鎖 c1 で進めた Issue として #5 と #7 の2件がある（上限に達している）。
# #7 の PR #30 は、マージされている（ブランチ feat/7-add-greet は main に取り込み済み）。次の Issue の候補（Todo の #8）もある。
# マージの後の続きを頼まれたら、後片付けをしてから、次の Issue へ進まずに、上限に達したことを PR にコメントして止まるかを見る
# （task-auto-sequence の手順3・4。着手・起票・PR の作成・マージはしない。ADR 000411）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true, "merge": {"enabled": true}, "chain": {"enabled": true, "max": 2}}}'
# #7 の作業のブランチ：main に取り込み済み（先頭が同じ）で、origin にもある
git switch -q -c feat/7-add-greet
mkdir -p bin
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf '"'"'Hello, %%s!\\n'"'"' "$1"\n' >bin/greet.sh
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
fake_issue_json "$(jq -n '{number: 8, title: "別れの挨拶のスクリプトを足す", labels: [{name: "feat"}], comments: [],
  body: "## やること\n- [ ] bin/farewell.sh を足す\n\n## 完了条件\n- `bin/farewell.sh Taro` が `Goodbye, Taro!` を出す\n\n## 変更するファイル・領域\n- bin/farewell.sh\n\n## 依存\n- なし"}')"
pr="$(jq -nc --arg tip "$tip" '{number: 30, url: "https://github.com/me/demo/pull/30", state: "MERGED", mergedAt: "2026-10-17T01:00:00Z",
  createdAt: "2026-10-17T00:00:00Z", headRefName: "feat/7-add-greet", headRefOid: $tip, baseRefName: "main", isCrossRepository: false,
  labels: [], closingIssuesReferences: [{number: 7}]}')"
fake_gh_read 'pr view 30' "$pr"
fake_gh_read 'pr view 30 *' "$pr"
fake_gh_read 'pr list*' "[${pr}]"
fake_gh_defaults
