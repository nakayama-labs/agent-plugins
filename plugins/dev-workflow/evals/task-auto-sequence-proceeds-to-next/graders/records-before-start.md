---
# 次の Issue #8 を、連鎖の最初の Issue #5 のコメント（連鎖 c1 の印 chain=c1 issue=8 を含むもの）に足してから、#8 に着手したか。
# 偽の gh が、書き込みを .fake-gh/writes に記録し、issue comment には本文（--body-file のとき）を行の最後に添える（--body は引数として行に入る）。#5 への別のコメントでは通らない。
# 着手は、Issue #8 の項目（IT8）の列の移動で見る。記録より先に着手すると、記録できないまま進んだことになる（ADR 000411）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^issue comment (#?5|https://github\.com/me/demo/issues/5)( |$)[^\n]*chain=c1 issue=8 -->[^\n]*\n[\s\S]*?^project item-edit .*--id IT8'
flags: m
match: contains
---
