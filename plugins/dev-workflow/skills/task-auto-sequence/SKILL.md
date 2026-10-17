---
name: task-auto-sequence
description: マージされた PR の後片付けを確認なしで行い、task-next の先頭の Issue を task-auto で PR まで進める（連鎖）。1回で進める件数の上限（auto.chain.max）と止める手段（設定を false にする・PR のラベル no-auto-merge）で止まり、止まる条件では状態を報告して止まる（task-auto が止まったときは、Issue にコメントして保留の列に移す）。設定 auto.enabled・auto.merge.enabled・auto.chain.enabled をすべて有効にしたリポジトリでだけ動く。「マージされたので次の Issue へ進めて」「#30 の PR がマージされたら、続きを自動で進めて」のように、マージの後に次の Issue まで任せたいときに使う。
argument-hint: "<マージされた PR の番号> [--first <連鎖の最初の Issue>] [--chain-id <連鎖の id>]"
---

# マージの後に、次の Issue へ進める（連鎖）

マージされた PR の後片付け（task-finish）、次の Issue の選択（task-next）、着手から PR の作成まで（task-auto）を、ユーザーの承認や入力なしでつなぐ。1回の実行で、マージされた1件の後片付けと、次の1件の PR の作成までを行う。その PR がマージされたら、もう一度この手順で続ける（実行ごとに別のジョブで進む。ADR 000411）。

条件と歯止めの正本は ADR 000411（承認の条件だけは ADR 000412）。このスキルは、PR をマージしない（マージキューへの投入は別の仕組みが行う）。有効にしていないリポジトリでは、何もせずに終わり、今のスキルの振る舞い（確認を取る）は変えない。

決まり:

- **AskUserQuestion は使わない**。下の「確認の代わりに決めること」に無い確認や、決めきれない場面に当たったら、聞かずに「止まる」で止まる
- GitHub に書き込むのは、連鎖の記録のコメント（`chain-record.sh`）・止まった理由の PR へのコメント・task-auto が書き込むもの（task-auto の SKILL.md のとおり）だけ。PR のマージ・キューへの投入・Issue を閉じること・親の Issue を閉じること・強制 push はしない
- 次の Issue に進む前に、その Issue を連鎖の記録に先に足す。記録できなければ、進めずに終える（件数の数え間違いで、上限を超えないため）
- 連鎖の件数・止める手段・止まる条件は、このスキルの手順と `chain-decide.sh` の表が決める。ここで独自に変えない

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/chain-decide.sh`：次の Issue へ進んでよいか（`next`・`wait`・`stop`）を、値だけから判断の表で決める。何も変えない（`--help` で使い方と表）
- `${CLAUDE_PLUGIN_ROOT}/scripts/chain-record.sh`：進めた Issue の記録を、連鎖の最初の Issue のコメントから読み、`--add` で足す（`--help` で使い方）
- `${CLAUDE_PLUGIN_ROOT}/scripts/next-tasks.sh`：Todo の Issue から、次に着手すべきもの（`next`。親・待ち・保留を除く先頭）を出す。何も変えない（task-next と同じ）
- `${CLAUDE_PLUGIN_ROOT}/scripts/auto-check.sh`：Issue を task-auto で進められるか（`action` が `proceed`）を決める。何も変えない
- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：設定を読む
- `${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh`・`issue-branches.sh`・`main-root.sh`：task-finish の手順2で使う

## 確認の代わりに決めること

task-finish と task-auto の確認に当たったら、次のとおりに答える。この表に無い確認は、止まる。

| スキル・場面 | 今のスキルの確認 | このスキルの答え |
|---|---|---|
| task-finish 手順1 | 確かなブランチが複数ある・`action` が `cleanup` でない（`cleanup_candidate`・`ask_close` など） | 片付けずに止まる（PR のブランチ名が分かっているので、`headRefName` のブランチで片付ける。それでも決まらなければ止まる） |
| task-finish 手順2 | git が無視するファイルを消してよいか | 消さずに止まる |
| task-finish 手順2 | 未コミットの変更・PR に入っていないコミットなどで `cleanup.sh` が止まった | 変更を捨てずに止まる |
| task-finish 手順5 | 子がすべて閉じた親を閉じるか | 閉じない。親の番号を結果で伝える（親を閉じるかは人が決める） |
| task-finish 手順6 | `/clear` を勧める | 勧めない（対話ではない） |
| task-auto | task-auto の「確認の代わりに決めること」の表のとおり | task-auto の SKILL.md に従う |
| どの場面でも | 上に無い確認・判断できない問い | 止まる |

## 止まる

次のどれかに当たったら、次の Issue へ進まずに終える。

- `chain-decide.sh` が `stop` を返した（設定が無効・記録を読めない・`no-auto-merge`・PR がマージされず閉じた・待つ時間の超過・件数の上限・次の Issue が無い・次の Issue を task-auto で進められない）
- 後片付けが止まった（上の表）
- 連鎖の記録に足せなかった
- 次の Issue の task-auto が止まった（保留の列に移した。task-auto の「止まる」）
- 実行が失敗した（スクリプトが止まり、手順に直し方が書かれていない）

止まるときは、次のとおりにする。

1. 設定が無効（`chain_disabled`・`auto_disabled`・`merge_disabled`）なら、何も書き込まずに、無効なので何もしなかったことと、有効にする設定（`auto.enabled`・`auto.merge.enabled`・`auto.chain.enabled`）を伝えて終える
2. それ以外で、止まった理由を残す。コメントの本文を一時ファイルに書く（言語は設定の `language` に従う。止まった理由・連鎖の id・これまでに進めた Issue（`chain-record.sh` の `issues`）と件数・続けるには何を直してどう再開するか（人が原因を直してから、`/dev-workflow:task-auto-sequence` か task-auto を手で起動し直す。自動では再開しない））。`gh pr comment <PR番号> --body-file <ファイル>` で、直前の PR にコメントする。task-auto が止まったときは、task-auto が Issue にコメントして保留の列に移すので、それに加えて PR にコメントしなくてよい（結果で伝える）
3. ユーザーに、止まった理由・連鎖の id・進めた Issue の一覧と件数（上限）・残したもの（ワークツリーとブランチが残っていれば、その場所）を伝える

## 手順

### 1. 対象を決める

引数の最初の番号を、マージされた PR の番号として使う（`30` でも `#30` でもよい）。`--first`（連鎖の最初の Issue）と `--chain-id`（連鎖の id）があれば読む。PR の番号が無ければ、依頼の文章から番号を読む。それでも分からなければ、何もせずに、番号を付けて頼み直すよう伝えて終える（聞かない）。

`gh pr view <PR番号> --json number,state,isCrossRepository,headRefName,createdAt,labels,closingIssuesReferences` で PR を読む。

- フォークからの PR（`isCrossRepository` が true）は対象外。何もせずに終える
- PR が閉じる Issue（`closingIssuesReferences`）が1つに決まらなければ、止まる（連鎖の最初の Issue と、次に記録する Issue を決められない）。その番号を「この PR の Issue」とする
- `--first` が無ければ、新しい連鎖を始める。「この PR の Issue」を最初の Issue とし、連鎖の id を決める（`date -u +%Y%m%dT%H%M%S` の出力に `-` と4桁の乱数を付けたもの。例：`20261008T101500-4821`）。`--chain-id` が無くて `--first` だけがあるときは、止まる（記録を探せない）

### 2. 設定と連鎖の状態を読む

`config.sh` で、設定 `auto.enabled`・`auto.merge.enabled`・`auto.chain.enabled`・`auto.chain.max`・`auto.chain.wait_minutes` を読む。整数でない・範囲外の値（`max`・`wait_minutes` が1以上の整数でない）なら、何も変えずに、設定の誤りとして伝えて終える。

連鎖の記録を読む。

- 既にある連鎖（`--first` がある）：`chain-record.sh --first <最初の Issue> --chain-id <連鎖の id>` を実行し、`count` と `issues` を覚える。失敗したら記録を読めなかったとする（`record_readable` は false）
- 新しい連鎖：まだ記録は無い。最初の Issue の1件を進めた扱いとして、`count` は 1、`record_readable` は true とする（記録は手順4で足す）

PR の経過時間（分）は `jq -n --arg t "<createdAt>" '(now - ($t | fromdateiso8601)) / 60 | floor'` で求める（PR を出して task-auto が終わった時刻の代わりに、PR の作成時刻を使う）。ラベル `no-auto-merge` が `labels` にあるかを見る。

### 3. 次へ進んでよいかを決める

`chain-decide.sh` に、次の JSON を標準入力で渡す。

```json
{"chain_enabled": …, "auto_enabled": …, "merge_enabled": …, "max": …, "wait_minutes": …, "record_readable": …, "count": …, "pr_state": "<MERGED・OPEN・CLOSED>", "no_auto_merge": …, "waited_minutes": …, "next": null, "next_action": null}
```

出力の `action` と `reason` に従う。

- `stop` で `reason` が `no_next` 以外：「止まる」で止まる。PR がマージ済み（`pr_state` が MERGED）で、設定が有効（`chain_disabled`・`auto_disabled`・`merge_disabled` のどれでもない）なら、先に手順4の後片付けだけを行ってから止まる
- `wait`：PR がまだマージされていない。何も書き込まずに、PR の番号・経過時間・待つ上限（`wait_minutes`）を伝えて終える。PR がマージされたら、同じ引数でもう一度実行するよう伝える
- `stop` で `reason` が `no_next`、または、次の Issue をまだ決めていない：次の手順で次の Issue を決めてから、もう一度 `chain-decide.sh` を実行する（`next` と `next_action` を入れる）。`next` で終わりでない `stop`・`wait` は上のとおり

次の Issue の決め方（task-next と同じ）：`next-tasks.sh` を実行し、出力の `next`（待ち・親の Issue・保留を除いた、Todo の先頭の1件）を次の Issue とする。無ければ `next` は null。`next` の Issue に `auto-check.sh --issue <番号>` を実行し、`action` を `next_action` とする（`proceed` のときだけ進める）。`next-tasks.sh`・`auto-check.sh` が失敗したら、止まる。

### 4. マージされた PR の後片付けをする

PR が MERGED のときだけ行う（OPEN・CLOSED では何もしない）。task-finish の手順に従い、上の「確認の代わりに決めること」のとおりに答える。

1. `main-root.sh` の `main_root` に `cd` する（削除するワークツリーの外に出る）
2. PR のブランチ（`headRefName`）で、`cleanup.sh --branch <ブランチ>` を実行する。マージ済みなので、キューを待たない（task-finish の手順2-1は行わない）
3. 止まったら（task-finish の手順2のエラー）、変更を捨てずに「止まる」で止まる。`base_branch` を最新にできていなければ、次の Issue へ進まない
4. 結果を伝える（task-finish の手順3）。PR が閉じる Issue が開いたままなら、そのことも伝える。子がすべて閉じた親は閉じず、番号を伝える

手順3で `next` になったときは、後片付けが済んでから手順5へ進む。

### 5. 次の Issue を記録して、task-auto で進める

手順3で `chain-decide.sh` が `next` を返したときだけ行う。

1. 連鎖の記録に足す。新しい連鎖なら、先に最初の Issue を足す：`chain-record.sh --first <最初の Issue> --chain-id <連鎖の id> --add <最初の Issue>`。続けて、次の Issue を足す：`chain-record.sh --first <最初の Issue> --chain-id <連鎖の id> --add <次の Issue>`。失敗したら、進めずに「止まる」で止まる（記録できなかった Issue は進めない）
2. `/dev-workflow:task-auto`（Skill ツールの `task-auto`）を、次の Issue の番号で実行し、その手順に従う。確認の代わりに、task-auto の「確認の代わりに決めること」のとおりに決める
3. task-auto が止まったとき（保留の列に移した）は、連鎖も終える（「止まる」の手順3だけ行う。task-auto が Issue にコメントしている）

### 6. 結果を伝える

次を伝える。

- 後片付けしたこと（マージされた PR・削除したワークツリーとブランチ・`base_branch` の更新）
- 連鎖の id・最初の Issue・これまでに進めた Issue の一覧と件数（`count`／`max`）
- 次の Issue で作った PR の番号と URL（task-auto の結果）。task-auto の結果の「自動で決めたこと」の要点も添える
- 続け方：その PR がマージされたら、`/dev-workflow:task-auto-sequence <次の PR の番号> --first <最初の Issue> --chain-id <連鎖の id>` で続けられる。上限に達していれば、次の Issue へは進まないこと
- 止まったときは、止まった理由と、人が直してから手で起動し直すこと（自動では再開しない）
