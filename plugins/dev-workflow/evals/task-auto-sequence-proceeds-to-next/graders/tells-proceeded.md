---
type: llm
---

The chain of automatic runs (task-auto-sequence) has a limit of 3 Issues per chain. The chain record on the first Issue (#5) lists Issues #5 and #7, so there is room for one more. Pull request #30 for Issue #7 has been merged. Issue #8 is the first Issue in Todo.

PASS if the reply says the merged pull request #30 was cleaned up (its branch or worktree was removed and the base branch updated), says the chain moved on to Issue #8 and opened a pull request for it with task-auto, and reports the chain state (the chain id c1 and the Issues processed so far, including #8, or the count against the limit of 3).
FAIL if the reply says the chain stopped before starting Issue #8, says it merged or enqueued a pull request, or does not mention a pull request for Issue #8.
---
