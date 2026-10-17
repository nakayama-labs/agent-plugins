---
# 次の Issue の作業を始めていないか（ワークツリーを作っていない、push していない）
type: regex
target: files
pattern: '^(\.claude/worktrees/|bin/farewell\.sh)'
flags: m
match: not_contains
---
