---
# 次の Issue の作業を始めていないか（ワークツリーを作っていない、push していない）。
# 後片付けは、手元のブランチを消すだけで、origin には触れない
type: regex
target: files
pattern: '^(\.claude/worktrees/|bin/farewell\.sh)'
flags: m
match: not_contains
---
