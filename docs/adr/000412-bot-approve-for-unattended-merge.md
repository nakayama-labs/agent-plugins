---
status: "accepted"
date: 2026-10-16
issue: 412
---

# 無人のマージの承認は、bot の approve（CodeRabbit か Claude のレビューのワークフロー）が最新の head に付いていることを条件にする

## 背景と課題

[ADR 000411](000411-unattended-merge-and-chain-guardrails.md) は、無人でマージしてよい条件の承認を、「bot が付けた Claude のレビュー（コメント）が最新の head に付き、未解決の指摘が残っていないこと」とした。GitHub の approve は人の approve（`auto.merge.require_human_approval`）だけで、bot の approve は数えないと決めている。

この決め方には2つの問題がある。

* Claude のレビューは、CodeRabbit が上限に当たったときと、レビューしないまま時間が経ったときの代わりにしか動かない（`.github/workflows/claude-review.yml`）。CodeRabbit が普通に動いている PR には Claude のレビューが付かないので、000411 の承認の条件を満たせない。
* レビューの結果がコメントの文章で、「指摘なし」かどうかを機械で読むには、文章の形に頼ることになる。GitHub の approve の状態（APPROVED・CHANGES_REQUESTED）なら、どのレビュアーが最新の head に何を出したかを、API で確かめられる。

承認の条件に、bot の approve を使えるようにしたい。どの bot の approve を、どういう条件で数えるか。

## 判断の決め手

* CodeRabbit が普通に動いている PR も、代わりに Claude がレビューした PR も、同じ形（approve）で承認が読めること
* 古い head への approve や、偽装できる approve を数えないこと
* 人の approve を必須にする設定（`require_human_approval`）の意味を変えないこと
* CodeRabbit の有料の機能（試用期間後に使えるか不明。#160）に、無人マージが全面的に依存しないこと

## 検討した案

* bot の approve は数えない（000411 のまま）
* CodeRabbit の approve だけを数える
* Claude のレビューのワークフローの approve だけを数える
* CodeRabbit か Claude のレビューのワークフローのどちらかの approve を数える

## 判断の結果

選んだ案：「CodeRabbit か Claude のレビューのワークフローのどちらかの approve を数える」。理由は、CodeRabbit が動いているときは CodeRabbit の approve で、動かないときは代わりの Claude のレビューの approve で、どちらでも承認が同じ形で読め、CodeRabbit のプランに無人マージが縛られないから。

000411 の「マージしてよい状態」のうち、Claude のレビューの条件を次に置き換える。ほかの条件（対象・設定・必須のチェック・スレッドの解決・止める印・マージの方法・連鎖の歯止め）と、人の approve（`require_human_approval`）の扱いは、000411 のままにする。

* PR の最新の head に対する、次のどちらかの approve が1件以上あること。
  * `coderabbitai[bot]` の approve。CodeRabbit の設定 `reviews.request_changes_workflow` を true にしたときに付く（対応が要る指摘に Request changes を付け、最新のコミットのレビュー済み・必須のスレッドが resolved・Pre-Merge Checks が通る・head が変わっていないときに approve する）。
  * `github-actions[bot]` の approve。`claude-review.yml` が、Claude のレビューが指摘なしのときに、レビューした head を指して付ける。指摘があるときは付けない。
* 数える approve は、そのレビュアーの最新のレビューの状態が approved で、そのレビューの対象のコミットが PR の最新の head であるもの。push の後は数えない（レビューし直す）。
* 最新の状態が changes requested のレビュアーが1人でもいれば（人も bot も）、マージしない。
* `github-actions[bot]` の approve は、`claude-review.yml` だけが付け、PR の作成者が bot のとき（task-auto の PR など。無人のマージの対象と同じ）に限る。人が作った PR は、本文や差分に仕込んだ指示で Claude に「指摘なし」と書かせて自分の PR を approve させられるおそれがあるので、approve しない。そのワークフローは、review.md の中身が「指摘はありません」の1行だけのときに限って approve する。ほかの文章（指摘の一覧など）のときは付けない。
* 人の approve を数えるときの決まり（write 以上・bot の approve は人の approve に数えない）は、000411 のとおり。`require_human_approval` が true のときは、bot の approve に加えて人の approve も要る。
* `claude-review.yml` の approve は、GitHub Actions の `GITHUB_TOKEN` で付ける（新しい GitHub App は作らない）。task-auto の PR は task-auto の GitHub App が作るので、作成者と approve の主が別になり、GitHub の「自分の PR は approve できない」の制約に当たらない。ただし、リポジトリの設定「Allow GitHub Actions to create and approve pull requests」が有効でないと、approve は失敗する。

### 結果として起きること

* 良い点：CodeRabbit が動いている PR も、Claude が代わりにレビューした PR も、承認を approve の状態で同じように読める。
* 良い点：CodeRabbit のプランが使えなくなっても、Claude のレビューの approve で無人マージの条件を満たせる（ただし、Claude のレビューは CodeRabbit が動かないときの代わりにしか動かないので、CodeRabbit が動かない状況が続く場合は、動く条件を見直す）。
* 悪い点：Claude が書いた PR を、Claude がレビューして approve する。bot の PR の本文や差分に紛れた指示で Claude が誘導されるおそれは、作成者が bot の PR に絞ることで、無人マージの対象の範囲に限っている。独立した確認ではないので、人の目を通す必要があるリポジトリは `require_human_approval` を true にする。
* 悪い点：リポジトリの設定（Actions が PR を approve できる）と、CodeRabbit の設定（`request_changes_workflow`）が要る。どちらも欠けると approve が付かず、無人ではマージされない（安全側に倒れる）。

### 確認

`claude-review.yml` の approve の付与を bats で確かめる（指摘なしのときだけ approve する・指摘があるときは付けない・作成者が bot でない PR には付けない・レビューした head を指す・head が変わっていたら付けない）。マージの判定が bot の approve を数える部分（最新の head・最新の状態・changes requested）は、000411 の後続の子の Issue で、判定のスクリプトの bats で確かめる。

## 各案の長所と短所

### bot の approve は数えない（000411 のまま）

* 良い点：変更が要らない。
* 悪い点：CodeRabbit が普通に動いている PR は、Claude のレビューが付かないので、承認の条件を満たせない。
* 悪い点：Claude のレビューの結果が文章で、機械で読む形が決まっていない。

### CodeRabbit の approve だけを数える

* 良い点：独立した別のレビュアーの approve で、確認として強い。
* 悪い点：Pro プランの機能で、試用期間後に使えるか分からない（#160）。使えなければ、無人マージが止まる。
* 悪い点：CodeRabbit が上限に当たったときは、approve が付かない。

### Claude のレビューのワークフローの approve だけを数える

* 良い点：プランに依存しない。
* 悪い点：CodeRabbit が動いている PR には Claude のレビューが付かないので、approve も付かない。

### CodeRabbit か Claude のレビューのワークフローのどちらかの approve を数える

* 良い点：どちらかが動けば承認が読める。
* 悪い点：Claude のレビューは書いた Claude が見るので、独立した確認ではない。

## 補足

* [ADR 000411](000411-unattended-merge-and-chain-guardrails.md) の「マージしてよい状態」のうち、Claude のレビュー（コメント）の条件だけを、この ADR の bot の approve の条件に置き換える。000411 は書き換えない。それ以外の条件と、000411 の bot の approve を人の approve に数えない決まりは変えない。
* 出典：Issue #412（https://github.com/nakayama-labs/agent-plugins/issues/412）、親の Issue #410（https://github.com/nakayama-labs/agent-plugins/issues/410）、CodeRabbit の試用期間後のプラン（#160）。
