---
# 既にある PR のブランチ feat/2-add-farewell に push したか。準備で、リモートの参照を packed-refs にまとめてあるので、
# このブランチへの push は、偽のリモート（.fake-remote.git）に refs/heads/feat/2-add-farewell を新しいファイルとして作る
# （作られたファイルの一覧（files）に出る）。別のブランチやタグへの push、objects だけが増える場合には当たらない。
# push せずに PR の案内だけをすると、ここで落ちる
type: regex
target: files
pattern: '^\.fake-remote\.git/refs/heads/feat/2-add-farewell$'
flags: m
match: contains
---
