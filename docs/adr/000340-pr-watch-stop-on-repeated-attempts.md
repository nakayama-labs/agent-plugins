---
status: "accepted"
date: 2026-10-17
issue: 340
---

# pr-watch.sh は、同じ head で試した repair-run の数が上限に達したら、act でなく stop を返す

## 背景と課題

`pr-watch.sh` は状態を持たず、PR の今の状態だけから `action` を決める。CI のチェックが失敗している（`ci_failed`）間は、直らない限り、同じ head_sha で呼ぶたびに `act` を返す。無人の見回り（[ADR 000285](000285-unattended-pr-repair-scope.md)）が直そうとして失敗し続けても、手元の見回り（[ADR 000340 のシェルのループ](000340-pr-check-watch-by-background-shell-loop.md)）を繰り返しても、判定は変わらず、`act` が毎回返る。

ADR 000285 は、同じ失敗を直す回数の上限（`repair.max_fix_attempts`、既定 3）と、1つの PR への無人の push の上限（`repair.max_pushes_per_pr`、既定 5）を決めた。しかし、push の回数は、head が進んだ `repair-run` だけを数える（[ADR 000339](000339-unattended-repair-push-scope-and-run-cou.md)）。直そうとして push の前で止まった回は head が進まないので、何度試しても数えられず、上限に達しない。

CI の失敗が直らないとき、同じ head で `act` を返し続けないために、何回試したかをどこから読み、上限に達したら何を返すか。「同じ失敗」をどの単位で数えるか。

## 判断の決め手

* 同じ head で、直らない `act` を返し続けないこと
* 状態を新しく足さないこと（ADR 000285 は、見回りの状態を「止まった」「終えた」の2つに絞っている）
* `pr-watch.sh` が、ログを読まずに、PR のコメントの値だけで速く返せること
* 判断が `pr-watch.sh` の1か所にあり、無人の見回りと手元の見回りで食い違わないこと
* 呼ぶ側が、`act`（対応する）と、上限に達して止まるべき状態を、見分けられること

## 検討した案

試した回数の読み方

* PR のコメントの `repair-run` のマーカーを、`pr-watch.sh` が読む
* 「この head で CI の失敗を直そうとした」ことを表す、新しい種類のマーカーを足す
* `pr-watch.sh` は状態を持たず、呼ぶ側が回数を覚える

上限に達したときの返し方

* 新しい `action` の `stop` を返す
* `idle` を返し、`reasons` に理由を足す

「同じ失敗」の単位

* 今の head の sha を持つ `repair-run` の数
* チェックの名前と、正規化した先頭のエラー行まで比べる

## 判断の結果

選んだ案：試した回数は「`repair-run` のマーカーを、`pr-watch.sh` が読む」、上限に達したときは「新しい `action` の `stop` を返す」、「同じ失敗」は「今の head の sha を持つ `repair-run` の数」。理由は、状態を足さず、ログも読まずに、PR のコメントの値だけで `act` の繰り返しを止められ、判断を `pr-watch.sh` の1か所に置けるから。

* `pr-watch.sh` は、`ci_failed` の `act` を返すとき、PR のコメントから `repair-run` を数える（`repair-run-count.sh` の考え方を使う。投稿者は `repair.reply_logins`、数える起点は ADR 000285 の再開の起点以降）。
  * **この head での試行**：マーカーの `head=<sha>` が今の head と同じ `repair-run` の数。直そうとして push に至らなかった回も含めて、コメントの数をそのまま数える（ADR 000339 の push の回数は、同じ sha を1回にまとめるが、試行は1つ1つ数える）
  * **push の回数**：ADR 000339 の数え方のとおり（head が進んだ `repair-run` を、sha ごとに1回）
* 上限は、次のどちらかに達したとき。
  * この head での試行が `repair.max_fix_attempts` 以上 → 理由 `same_failure`
  * push の回数が `repair.max_pushes_per_pr` 以上 → 理由 `push_limit`
* 上限に達したら、`ci_failed` があっても `act` を返さず、`action` を `stop` にして、`reasons` に `same_failure` か `push_limit` を入れる（理由の名前は ADR 000339 の止まった理由の種類と同じ）。ほかに対応が要る指摘（`unresolved_threads` など）があっても、`ci_failed` が上限に達していれば `stop` を返す。理由には、上限に達したものと、残っている対応が要るものを、並べて入れる
* `stop` の扱いは、呼ぶ側が分ける。無人の見回りは、Issue にコメントして保留の列に移して止まる（`repair-stopped` の印は ADR 000339 のとおり）。手元の見回りは、止まって状態を報告する（対応が要るかは人が決める）
* 人の push で head が進めば、この head での試行は 0 に戻る（今の head の sha を持つ `repair-run` が無いため）。push の回数のリセットは、ADR 000285 の再開の起点のとおり
* `repair.*` の設定が無い（`repair.enabled` が false）、またはコメントを読めないときは、試行を数えず、これまでどおり `act` を返す。数えられないときに、止めずに対応を促す側に倒す

### 結果として起きること

* 良い点：同じ head で、直らない `act` が、上限の回数を超えて返らない
* 良い点：状態は PR のコメントのマーカーだけで、ファイルやラベルを足さない
* 良い点：判定は `pr-watch.sh` の1か所で、無人の見回りと手元の見回りが同じ値を見る
* 悪い点：`action` の値が1つ増えるので、`pr-watch.sh` を使う gh-pr-check と見回りの分け方を、合わせて直す
* 悪い点：「同じ失敗」を head の sha で数えるので、別のチェックの別の失敗でも、同じ head なら合算される。head が進んだ後に同じチェックが同じ失敗を続けても、この head での試行は 0 に戻る。その場合は、push の回数の上限（`push_limit`）が止める
* 悪い点：`pr-watch.sh` が PR のコメントを読むようになるので、API の呼び出しが1回増える

### 確認

`tests/pr-watch.bats` で、次を偽の `gh` で確かめる。同じ head の `repair-run` が上限未満なら `act`、上限以上なら `stop`（`same_failure`）を返すこと。head が進んだ `repair-run` が `repair.max_pushes_per_pr` 以上なら `stop`（`push_limit`）を返すこと。head が違う `repair-run` を、この head での試行に数えないこと。再開の起点より前の `repair-run` を数えないこと。`repair.reply_logins` 以外の投稿者の `repair-run` を数えないこと。`ci_failed` が無いときは、`repair-run` があっても `stop` を返さないこと。`repair.enabled` が false のときは試行を数えず `act` を返すこと。gh-pr-check の SKILL.md のテストで、`stop` のときの分け方が書かれていることを確かめる。

## 各案の長所と短所

### PR のコメントの `repair-run` のマーカーを、`pr-watch.sh` が読む

* 良い点：無人の実行が push の前に付ける既存のマーカーなので、状態が増えない
* 良い点：CI のログを読まず、コメントの値だけで数えられる
* 悪い点：`repair-run` を付けない手元の対応（人が直す）は数えられない。ただし、人が push すれば head が進んで数え直しになる

### 新しい種類のマーカーを足す

* 良い点：「CI の失敗を直そうとした」という意味が、マーカーの名前に表れる
* 悪い点：書く側（無人の実行・手元の対応）の手順が増え、ADR 000285 の状態の決まりを広げる

### `pr-watch.sh` は状態を持たず、呼ぶ側が回数を覚える

* 良い点：`pr-watch.sh` は変わらない
* 悪い点：呼ぶ側ごとに数え方がばらつく
* 悪い点：完了条件の「`pr-watch.sh` が `act` を返し続けない」を、bats で確かめられない

### 新しい `action` の `stop` を返す

* 良い点：`act` と区別でき、呼ぶ側が「止まって報告」「保留の列へ」と分けられる
* 悪い点：`action` の値が増え、呼ぶ側の分け方を直す必要がある

### `idle` を返し、`reasons` に理由を足す

* 良い点：`action` の値が増えない
* 悪い点：`idle` は「マージできる状態」にも使うので、見回りが「終わった」と取り違えるおそれがある

### 今の head の sha を持つ `repair-run` の数

* 良い点：ログを読まず、値だけで数えられ、head が進めば数え直しになる
* 悪い点：別の失敗でも、同じ head なら合算される

### チェックの名前と先頭のエラー行まで比べる

* 良い点：ADR 000285 の「同じ失敗」の定義に忠実で、正確
* 悪い点：`pr-watch.sh` が CI のログを読む必要があり、状態を持たず速く返す性質が崩れる

## 補足

* 見回りの方式（背景のシェルのループ）は [別の ADR](000340-pr-check-watch-by-background-shell-loop.md) で決めた。ループは `wait` 以外で終了するので、`stop` でも終了し、Claude に戻る
* ADR 000285 の「同じ失敗」（チェックの名前と先頭のエラー行）は、無人の修復の中で、ローカルのテストや lint が通らないときの上限の判定にそのまま使う。この ADR が変えるのは、`pr-watch.sh` が `act` を返し続けるかの判定だけで、ADR 000285 の定義は変えない
* 「対応済み」（返信のマーカーと `repair.reply_logins`）による指摘の判定と、最初のレビュー待ち・増分のレビュー待ち・レート制限のコメントを到着に数えない扱いは、ADR 000285 が決めたとおりで、この ADR では変えない
