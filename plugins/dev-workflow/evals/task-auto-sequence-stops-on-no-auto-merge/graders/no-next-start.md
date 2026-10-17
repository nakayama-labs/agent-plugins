---
# 次の Issue へ進んでいないか（割り当て・列の移動・起票・Issue を閉じる・PR の作成・マージをしていない）。
# 連鎖の記録のコメント（issue comment）も足さない（進めないので、記録する Issue が無い）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(issue |project |pr (create|merge|ready|edit)|api -X POST)'
flags: m
match: not_contains
---
