---
type: llm
---

Pull request #98 for Issue #2 already existed as a draft before this run (opened by an earlier run or a person). The automatic run (task-auto) must push to it only, leave it a draft, not mark it ready, and tell the human to mark it ready for review (for example with `gh pr ready 98`) because many automatic reviews skip drafts.

PASS if the reply says the automatic run used the existing pull request #98 and left it as a draft, and tells the human to mark it ready for review (or that it is the human's decision to do so).
FAIL if the reply says it marked the pull request ready, says it opened a new pull request, says the pull request is open for review without being a draft, or does not mention that the draft needs to be made ready by a human.
