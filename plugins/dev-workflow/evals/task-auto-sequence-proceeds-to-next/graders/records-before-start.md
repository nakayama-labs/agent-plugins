---
# 次の Issue #8 を、連鎖の最初の Issue #5 のコメントに足してから、#8 に着手したか（偽の gh が、書き込みを .fake-gh/writes に記録する）。
# 着手は、Issue #8 の項目（IT8）の列の移動で見る。記録より先に着手すると、記録できないまま進んだことになる（ADR 000411）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^issue comment (#?5|https://github\.com/me/demo/issues/5)( |$)[^\n]*\n[\s\S]*?^project item-edit .*--id IT8'
flags: m
match: contains
---
