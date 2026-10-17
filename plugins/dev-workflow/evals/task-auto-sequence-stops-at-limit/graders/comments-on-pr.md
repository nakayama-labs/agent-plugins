---
# 止まった理由を、直前の PR #30 にコメントしたか（偽の gh が、書き込みとして .fake-gh/writes に記録する）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^pr comment (#?30|https://github\.com/me/demo/pull/30)( |$)'
flags: m
match: contains
---
