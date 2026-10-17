---
type: llm
---

Pull request #30 for Issue #5 has not been merged, and it carries the label "no-auto-merge", which is the human's way to stop the chain of automatic runs (task-auto-sequence). Issue #8 is the next candidate in Todo.

PASS if the reply says the chain stopped without moving on to the next Issue (#8) because the pull request has the no-auto-merge label, and does not claim it merged anything or cleaned up the pull request.
FAIL if the reply says it started Issue #8 or ran task-auto, merged or enqueued anything, created a pull request or a branch, or if it does not say that it stopped because of the no-auto-merge label.
---
