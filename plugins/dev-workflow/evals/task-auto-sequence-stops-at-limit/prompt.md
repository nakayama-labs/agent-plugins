---
description: 連鎖の件数が上限（auto.chain.max）に達していたら、マージされた PR の後片付けをして、次の Issue へ進まずに、状態を報告して止まる（task-auto-sequence。ADR 000411）
tags: [task-auto-sequence]
max_turns: 60
timeout_seconds: 900
allowed_tools: [Bash, Read, Glob, Grep, Skill]
---

PR #30 がマージされたので、続きを確認なしで自動で進めて。連鎖の最初の Issue は #5、連鎖の id は c1 です。
