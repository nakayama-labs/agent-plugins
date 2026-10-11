---
status: "accepted"
date: 2026-10-11
issue: 381
---

# マージキューを使うかは、GraphQL の repository.mergeQueue(branch:) で読む（pr-create.sh・doctor.sh）。pr-watch.sh のキューの中かは dw_merge_queue_state にそろえる

## 背景と課題

マージキューの判定が、スクリプトの間でそろっていなかった。

* `pr-create.sh`（`merge_queue`）と `doctor.sh`（キューか strict かの案内）は、キューを使うかを、REST のブランチのルール（`rules/branches` に `merge_queue` があるか。`dw_merge_queue_enabled`）で決めていた。`rules/branches` はルールセットのルールだけを返し、古いブランチ保護の「Require merge queue」でキューを有効にしたリポジトリでは、キューを使っていても false になる。PR を出した後の案内が「キューに入れる」でなく「main が進んだら取り込む」になり、`doctor.sh` はキューも strict も無いと警告し、キューの `merge_group` の確認も飛ばす（#373）
* `pr-watch.sh` は、キューの中かを `mergeQueueEntry` が null でないかだけで決めていた。入れた直後（まだ `mergeQueueEntry` に出ていない）と、merged で外れた直後（マージの直前）は、キューの外として扱い、`pr-merge-status.sh`・`branch-status.sh`（`dw_merge_queue_state` の `queued`。[ADR 000323](000323-read-merge-queue-state-via-graphql.md)）と食い違っていた（#372）

[ADR 000323](000323-read-merge-queue-state-via-graphql.md) は、PR を引いて読む `pr-merge-status.sh`・`branch-status.sh` のキューを使うか（`enabled`）を `isMergeQueueEnabled` にそろえ、`pr-create.sh`・`doctor.sh` の読み方は変えないとした。この 2 つは PR を引かない（PR が無くても、マージ先のブランチだけで読む）ので、`isMergeQueueEnabled` は使えない。

## 判断の決め手

* ルールセットでも古いブランチ保護でも、キューを有効にしていれば、使うと判定できること
* PR が無くても（`pr-create.sh` が PR を作る前、`doctor.sh`）、マージ先のブランチだけで判定できること
* スクリプトの間で、キューの中か・使うかの判定がそろうこと
* GraphQL は他に手段が無いところだけに使うこと（[ADR 000089](000089-prefer-gh-and-rest-over-graphql.md)）

## 検討した案

* GraphQL の `repository.mergeQueue(branch: ベースブランチ)` で、キューを使うかを読む（`pr-create.sh`・`doctor.sh`）。`pr-watch.sh` のキューの中かは `dw_merge_queue_state` の `queued` を使う
* REST のブランチのルール（`rules/branches`）に加えて、REST のブランチ保護の情報（`branches/<ブランチ>` の `protection`）からもキューを読む
* 今のまま、ルールだけで読む（古いブランチ保護のキューは見落とす）

## 判断の結果

選んだ案：「GraphQL の `repository.mergeQueue(branch: ベースブランチ)` で、キューを使うかを読む」。理由は、決め手のうち、古いブランチ保護のキューも、PR が無い場面も満たす唯一の案だから。ブランチ保護の情報（REST）にはキューの設定が出ない。キューの有無は、`gh pr view` にも REST にも無く、ADR 000089 の「他に手段が無いとき」に当たる。

* `common.sh` に `dw_merge_queue_for_branch <owner/repo> <ブランチ>` を足す。`repository.mergeQueue(branch:)` が返れば true、null なら false を出す。応答に errors が 1 件でもあれば、部分的な失敗をキュー無しと読まないよう、読めないものとして扱う。`{owner}/{repo}` は gh が今のリポジトリに置き換える。読めなければ、理由を 1 行で標準エラーに出して非 0 を返す
* `pr-create.sh` は、`merge_queue` をこの関数で読む。読めなければ、`doctor.sh` と同じく、ルールセットのルール（`dw_merge_queue_enabled`）で代える。それも読めなければ null にして止めない
* `doctor.sh` は、キューを使うかをこの関数で読む。読めなければ、ルールセットのキュー（`rules/branches`）で代える（GraphQL を読めないだけで、キューの案内を消さないため）。必須のチェックの有無と strict の判定は、これまでどおりルールセットと古いブランチ保護で決める
* `pr-watch.sh` は、キューの中かを `dw_merge_queue_state` の `queued` で決める（入れた直後・merged で外れた直後もキューの中）。見るのは `queued` だけなので、外れた後の push は読まない（フォークとして渡す）。キューの状態を読めなければ、理由を 1 行で伝えて止まる（PrWatch の問い合わせを読めないときと同じ）
* `dw_merge_queue_enabled`（ルールだけで読む）は、`pr-merge-status.sh`・`branch-status.sh` が `dw_merge_queue_state` を読めないときの代わりにだけ残す（ADR 000323 のとおり。GraphQL を読めないときに、同じ GraphQL でやり直しても読めないため）

### 結果として起きること

* 良い点：古いブランチ保護でキューを有効にしたリポジトリでも、`pr-create.sh` の案内と `doctor.sh` の確認が、キューを使うものとして動く
* 良い点：`pr-watch.sh` が、入れた直後・merged で外れた直後にも、キューの結果を待つ（`wait`）。無人の見回りが、キューの中の PR に触らない
* 悪い点：`pr-create.sh`・`doctor.sh` の GraphQL の呼び出しが 1 回増える（`doctor.sh` は、REST のルールの読み込みも残る）。`pr-watch.sh` は GraphQL の問い合わせが 1 回増える
* 悪い点：偽の gh のテストでは、`MergeQueueForBranch` と `PrQueue` の GraphQL の答えを用意する

### 確認

* `tests/pr-create.bats`・`tests/doctor.bats`：ルールセットにキューが無く、GraphQL にだけキューがあるリポジトリで、キューを使うと判定する。GraphQL を読めないときの扱いも確かめる
* `tests/pr-watch.bats`：入れた直後・merged で外れた直後が `in_merge_queue` になり、外れたまま・キューが無効の PR はキューの外として扱う

## 補足

[ADR 000323](000323-read-merge-queue-state-via-graphql.md) の「`pr-create.sh`・`doctor.sh` の読み方（ルール）は、この ADR では変えない」を、この ADR で変える（ADR 000323 の他の判断は変えない）。
