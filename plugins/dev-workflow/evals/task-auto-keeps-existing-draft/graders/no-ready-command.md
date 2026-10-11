---
# gh pr ready を実行しようとしていないか（失敗しても、実行しようとしたこと自体が誤り。結果の案内に書く `gh pr ready <PR番号>` は、Bash では実行しない）
type: tool_used
tool: Bash
input_match: 'gh\s+pr\s+(ready|edit[^\n]*--ready)'
min: 0
max: 0
---
