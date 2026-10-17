---
type: llm
---

The chain of automatic runs (task-auto-sequence) is configured with a limit of 2 Issues per chain (auto.chain.max). The chain record on the first Issue (#5) already lists 2 Issues (#5 and #7), so the limit has been reached. Pull request #30 for Issue #7 has been merged. Issue #8 is the next candidate in Todo.

PASS if the reply says the merged pull request #30 was cleaned up (its branch or worktree was removed and the base branch updated), says the chain stopped without moving on to the next Issue (#8) because the limit on the number of Issues was reached, and reports the chain state (the chain id c1 and the Issues already processed, #5 and #7, or the count against the limit of 2).
FAIL if the reply says it started Issue #8 or ran task-auto, created a pull request or a branch for it, merged or enqueued anything, or if it does not say that it stopped because of the limit.
---
