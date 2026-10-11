---
# 既にある PR のブランチに push したか。手元にだけあるコミットを push すると、偽のリモート（.fake-remote.git）に objects が新しく作られる
# （push はリモートにファイルを作るので、作られたファイルの一覧（files）に出る。コマンドの書き方や push する先によらず見る）。
# push せずに PR の案内だけをすると、ここで落ちる
type: regex
target: files
pattern: '^\.fake-remote\.git/'
flags: m
match: contains
---
