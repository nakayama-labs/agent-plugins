---
# 既にある PR #98 に push するだけで、新しい PR を作っていないか
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^pr (create|merge|close)( |$)'
flags: m
match: not_contains
---
