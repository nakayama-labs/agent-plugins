---
description: 連鎖の件数が上限の手前なら、マージされた PR の後片付けをして、次の Issue を連鎖の記録に足してから、task-auto で PR の作成まで進める（task-auto-sequence。ADR 000411）
tags: [task-auto-sequence]
max_turns: 200
timeout_seconds: 2400
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill, Agent]
---

PR #30 がマージされたので、続きを確認なしで自動で進めて。連鎖の最初の Issue は #5、連鎖の id は c1 です。
