---
# 次の Issue へ進んでいないか。許す書き込みは、止まった理由の PR へのコメント（pr comment）だけ。
# issue・project のサブコマンド（割り当て・列の移動・起票・Issue を閉じる・連鎖の記録のコメント）、PR の作成・マージ・ready・編集・閉じる、
# gh api の書き込み全般（REST の POST・PUT・PATCH・DELETE と、GraphQL の mutation。偽の gh は、api の書き込みを api で始まる行で記録する）は、すべて禁止
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(issue |project |pr (create|merge|ready|edit|close)|api )'
flags: m
match: not_contains
---
