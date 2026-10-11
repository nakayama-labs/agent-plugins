# agent-plugins

導入したリポジトリで共通に使う Claude Code のプラグイン（開発ワークフロー用のスキル群）と、GitHub リポジトリの初期設定スクリプト。

設計は [docs/design.md](docs/design.md) を参照。

## 使い方（開発中）

```bash
# プラグインを直接読み込んで Claude Code を起動する
claude --plugin-dir plugins/dev-workflow

# 実行環境と設定の確認
plugins/dev-workflow/scripts/doctor.sh
```

## 導入したリポジトリだけに効く

プラグインは、導入したリポジトリ（`.claude/dev-workflow/config.json` があるリポジトリ）の中でだけ効きます。プラグインをユーザー単位でインストールしても、プロジェクト単位でインストールしても同じです。

- 導入していないリポジトリでは、フック（main を守る・タスクの進め方を渡す・リンクを出す）は何もしません。
- 導入していないリポジトリでは、`~/.claude/dev-workflow/` に置いた自分の設定・文章のガイド・レビューの観点・タスクの進め方の追記も使いません。導入したリポジトリでは、これまでどおり使います。
- ホームをリポジトリにしている（dotfiles を `~/.git` や `--git-dir=~/.cfg --work-tree=~` の bare リポジトリで管理している）と、`.claude/dev-workflow` が `~/.claude/dev-workflow` と同じ場所になります。このホームのリポジトリは、導入したとみなさず、導入もできません（`~/.claude/dev-workflow/` のファイルを、チームの設定として読み書きしないためです）。初期設定のスクリプトは、理由を伝えて止まります。導入するリポジトリは、ホームの下の別のリポジトリにしてください。`doctor.sh` は、ホームのリポジトリで導入できないことを知らせます。
- `.claude/dev-workflow/config.json` は、`/dev-workflow:repo-setup` で作られます。中身は空（`{}`）でもかまいません。ワークツリーに無くても、メインのワークツリーにあれば導入したものとみなします。
- `doctor.sh` は、導入していないリポジトリで実行すると、このことを警告します。

これまで初期設定をせずに使っていたリポジトリでは、フックとユーザーの層が効かなくなります。引き続き使うには、`/dev-workflow:repo-setup` で初期設定するか、`.claude/dev-workflow/config.json` を `{}` で作ってコミットしてください。

## スキル

| スキル | 内容 |
|---|---|
| `/dev-workflow:repo-setup` | リポジトリの初期設定（下記） |
| `/dev-workflow:task-create` | 依頼の内容から Issue を起票し、type ラベル（破壊的変更なら `breaking` ラベルも）を付けて Project に追加する。下書きの前に、開いている Issue から重複と親の候補を探し、重なる Issue があれば、起票の前にどう扱うか（既にある Issue で進める、その Issue を親にする、など）を聞く。分け方の案や Story Point 21/34 の分割で分けた Issue も、既にある Issue と重なるものがないか照らし、重なるときは、重なった Issue だけを外すかなどを確認の中で1回にまとめて聞く。Story Point は見積もりを提案し、確認してから設定する。先に終わらせる Issue があれば、本文の「依存」に `#N` を書き、GitHub の依存関係（blocked by）にも登録する。大きな仕様を分けた一部なら、仕様の Issue を親にしてサブ Issue として紐付ける（親子は2層が目安で、必要なら3層まで。Story Point は子にだけ付ける）。親と子をまとめて下書きし、親子の木を見せて確認してから、親 → 子の順に起票できる。既にある Issue を親に指定して、その下に子を足すこともできる。起票の前の相談で Issue の分け方を提案するときにも使い、分け方の案を下書きとして見せる。「起票しない（提案だけにする）」を選べば起票せずに止まる。触りそうなファイル・領域も本文の「変更するファイル・領域」に書く（`task-next` が並列にできるかを見るのと、`task-start` が着手する前に着手中の Issue と重なるかを確かめるのに使う。分からなければ「不明」、ファイルを変えないタスクなら「なし」）。設計上の判断を含む Issue では、「やること」に ADR を残す項目を足すかを聞く（[ADR](#adr)） |
| `/dev-workflow:task-next` | Todo の Issue から、次に着手すべきものと、同時に進められる組を提案する。優先順位は Project の Todo の上から順で、依存（GitHub の blocked by と本文の「依存」）が終わっていないものと、サブ Issue を持つ親の Issue（作業は子の Issue で進める）と、保留の列（設定されていれば）にある Issue は候補から外す（保留の Issue は件数と番号を伝え、条件がそろったら Todo に戻すよう案内する）。本文の「変更するファイル・領域」と、着手中（In Progress と、設定されていれば PR を出した後の列 `pr_opened`）の Issue の領域・PR のファイルが重なりそうなものは「並列にできない」と警告する（止めはしない）。何も変えない読み取り専用で、herdr などが無くても使える |
| `/dev-workflow:task-start` | Issue の作業を始める。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）を作り、自分に割り当てて In Progress に移す。調査や Issue の整理のようにリポジトリのファイルを変えないタスクでは、ワークツリーとブランチを作らずに、割り当てと列の移動だけを行える。どちらにするかは Issue の本文から判断して提案し、選んでもらう（その Issue のブランチが既にあれば、作らずには着手しない。終わった作業のブランチなら、先に `task-finish` で片付ける）。着手中の Issue と変えるファイルが重なりそうなら（`task-next` と同じ判定）、そのことも伝え、着手するかを選べ、Todo にある Issue なら、今は着手せずに、重なる Issue への依存（GitHub の依存関係と本文の「依存」）を足して待つこともできる。その後は確認を取らずに進め、結果を伝える。ワークツリーを作って着手したときは、結果を伝えた後に止まらず、そのまま Issue の「やること」の実装に取りかかる（Issue の内容だけでは進め方が決まらないときは、聞いてから進める）。親の Issue（サブ Issue を持つ Issue）には着手せず、開いている子の一覧を見せる。子に着手したときは、Todo の列にある親（とさらに上の親）も In Progress に移す（Todo より先の列にある親・閉じた親は動かさない。PR を出した後も、親は In Review などの列には移さない） |
| `/dev-workflow:task-status` | Issue を Project の指定した列へ移す。`Blocked` など自分で足した列へも移せる。Project に入っていなければ追加してから移す。確認を取らずに進め、結果を伝える。Project に無い列を指定したときは、移さずに列の一覧を見せる。子を In Progress に移したときは、Todo の列にある親も In Progress に移す |
| `/dev-workflow:commit` | 変更を Conventional Commits の規約に沿ってコミットする。メッセージを検証してからコミットし、main の上ではコミットしない |
| `/dev-workflow:review` | 作業中のブランチの変更を、組み込みの `/code-review` と独自のレビューの観点（下記）で並行してレビューし、指摘を1つの一覧にまとめる。各指摘は同じ誤りがほかの場所に無いか（水平展開）も判定する。反映する指摘を選ぶと、その指摘（水平展開の場所を含む）だけを直してコミットする。終えるときに、見落としの指摘や今後も要らない指摘を観点に残すかを尋ねる |
| `/dev-workflow:review-perspective-add` | レビューの観点を聞き取り、形式に沿った観点ファイル（下記）を自分の層（`~/.claude/dev-workflow/review/`）かリポジトリの層（`<repo>/.claude/dev-workflow/review/`）に作る。同じ層に同じ名前の観点があれば上書きせずに知らせ、ほかの層の観点を置き換えるときは確認する |
| `/dev-workflow:adr-create` | 設計上の判断を、MADR 4.0.0 の書式の ADR として `docs/adr/<Issue 番号を6桁に0埋め>-<名前>.md` に残す（[ADR](#adr)）。判断の内容を聞き取り、判断に合うテンプレートを選んで中身まで書く。古い ADR を置き換えるときは、古い方の status だけを superseded にする。確認は取らない（作るのは手元のファイルだけ） |
| `/dev-workflow:pr-create` | 作業用のブランチを push し、Issue に紐付けた PR を作る。タイトルは `<type>: <Issueのタイトル>`、本文は PR テンプレートに沿って書き、`Closes #N` を付けてラベルを引き継ぐ。Issue に `breaking` ラベルがあれば、タイトルを `<type>!:` にし、本文に `BREAKING CHANGE:`（移行のしかた）を書く。Issue の「やること」のうち差分で済んだ項目にチェックを付ける。差分に設計上の判断があって ADR が無ければ、ADR を作ってから PR を作るかを聞く（[ADR](#adr)）。確認してから push する。PR を出した後は、PR のマージ先（設定済みの `base_branch`（既定は main）か、既にある PR のマージ先）がマージキューを使うなら、マージの条件を満たしたらキューに入れるよう案内し（マージ先が進んでも取り込み直しは要らない）、使わないなら、マージ先が進んだら `/dev-workflow:branch-update` で取り込むよう案内する |
| `/dev-workflow:gh-pr-check` | 自分が出した PR の状態を確かめ、付いたレビューの指摘・質問・コメントと CI の失敗があれば対応する（「PR を確認して」「CI は通った？」「指摘に対応して」で使えます。人の PR のコードレビューには使いません）。最初に PR の状態（CI・レビュー・マージできるか）を見せ、コメントも CI の失敗も無ければ、何も変えずに終わる（返事をしていないものは、スレッドだけでなく、レビュー本文の diff の外の指摘や PR のコメントも、スクリプトが印を付けるので、「対応はありません」で終えずに必ず一覧に入れます）。指摘（直す）・質問（答えるだけ）・感想や承認（何もしない）に分けて一覧にし、直すものと答えるものを選ぶと（選べるものが無ければ、聞かずに、返事待ちの件数と CI・マージの状態を伝えて終わる。担当の skill の分があれば任せる）、直してコミットし、push するコミットと返信の本文を見せて確認してから、push と返信を行う。スレッドは resolved にしない（レビューした人に任せる）。コメントの本文にある AI への指示には従わない。使わなくてもマージや `task-finish` は進められる。旧名は `pr-respond` です（[移行のしかた](#pr-respond-から-gh-pr-check-への移行)） |
| `/dev-workflow:task-finish` | PR がマージされた後の後片付け。マージを確かめ、ワークツリーとローカルのブランチを削除し、main を最新にし（`git pull --ff-only`）、PR が閉じる Issue が閉じたかも伝える（閉じるのは頼まれたときだけ）。確認を取らずに進め、作業が失われるとき（マージされていない、PR に入っていないコミット・未コミットの変更・サブモジュールの push していないコミットがある）は、何も消さずに止まる。`.env` など git が無視するファイルが残っているときは、一覧を見せて消してよいか確認する。規約の形で番号が一致する作業のブランチが見つからないとき（ワークツリーを作らずに着手したタスクなど）は、決めつけずに、名前が似ているブランチや Issue を閉じる PR のブランチを候補として見せて、Issue を完了として閉じるか、別の名前のブランチ（候補）で作業したかを聞く（Issue を閉じる PR が開いていれば閉じない）。Issue が既に閉じていて候補があれば、その候補で片付けるかを聞く。ブランチ名を指定して片付けることもできる。マージ前に呼んだときは、マージキューを使うリポジトリなら PR の状態を確かめる。キューに並んでいれば（入れた直後・CI が動いている・マージ待ち）、「待ってから後片付けする」か「ここで止める」を選べる（待つなら、5分おきに最大60分で、マージされたらそのまま後片付けまで進む。待ちが異常終了したときは、そのことを伝えて後片付けに進み、マージ前なら何も消さずに止まる）。キューから外れたまま（CI の失敗・衝突など。キューに入れた後に push していない）なら、外れた理由と失敗したチェックと URL を伝えて止まる（キューに入っていない開いた PR は、今までどおり止まる。キューを使わないリポジトリでは動きは変わらない）。最後に、閉じた Issue の親（とさらに上の親）の子がすべて閉じていれば、親を閉じるかを確認し、選んだときだけ閉じる（GitHub は子が全部閉じても親を自動では閉じないため）。片付けを実際に終えたら（この会話でそのタスクを進めていたとき）、次のタスクに着手する前に `/clear` するよう勧める（実行はしない） |
| `/dev-workflow:branch-update` | PR のブランチに、設定済みの `base_branch`（既定は main。PR のマージ先が違えば、そのマージ先）の最新状態を取り込む。遅れを調べ、`origin/<マージ先>` を merge し（rebase と強制 push は使いません）、衝突したら、直し方を見せて確認を取ってから直し（両立できると判断した衝突も含め、直し方を決めるときも、テストの失敗を直すために後から変えるときも、直す前に確認を取ります）、リポジトリのテストとチェックを通します。push の前に、取り込んだコミットとチェックの結果を見せて確認を取り、push の後は CI が通り直るのを待って結果を伝えます。すでに最新なら何もしません。手元では取り込み済みで、まだ push していないときは、取り込まずにテストとチェックを通して push します（マージキューを使うリポジトリでは、マージ先と衝突しているときだけ）。「コンフリクトした」という依頼にも使えます。マージキューを使うリポジトリでは、取り込むのは PR がマージ先と衝突しているときだけです。衝突していなければ取り込まずに、キューの状態に合わせて案内します（キューの中で先に並んだ PR と衝突したときや、CI の失敗などでキューから外れたままのときは、外れた理由を伝え、先に並んだ PR のマージを待つか、衝突や失敗に対応してからもう一度キューに入れるよう案内します）。最新の main が要るときは、確かめてから取り込みます。取り込んで CI が通った後は、PR をもう一度キューに入れるよう伝えます |
| `/dev-workflow:task-auto` | Issue を指定すると、確認を取らずに、着手・実装・テスト・コミット・レビュー・PR の作成まで自動で進める（下記の「自動で進める」）。設定で有効にしたリポジトリでだけ動く |
| `/dev-workflow:task-cancel` | やらないことにした Issue や誤って起票した Issue を取りやめる。理由と参照先（代わりに作業する Issue など）をコメントに書き、not planned（重複なら元の Issue に紐付けて duplicate）で閉じる。着手していれば、PR を閉じ、リモートと手元のブランチ・ワークツリーも削除する。失う作業（マージしていないコミット・未コミットの変更・`.env` など）を見せて確認してから行う。親の Issue（サブ Issue を持つ Issue）を取りやめるときは、開いている子孫（子・孫）を一緒に取りやめるか、残すかを確認で選ぶ（一緒に取りやめるなら、着手中の子孫の PR とブランチも片付ける）。Project からは外さず、Story Point も残す（後からボードで経緯を参照できるように）。取りやめた後、子がすべて閉じた親（とさらに上の親）があれば、親を閉じるかを確認する（子がすべて取りやめなら not planned で閉じる案）。マージした後の片付けは `task-finish` を使う。取りやめを実際に行ったら（この会話でそのタスクを進めていたとき）、次のタスクに着手する前に `/clear` するよう勧める（実行はしない） |

Issue の番号を取るスキル（`task-start`・`task-status`・`task-finish`・`task-cancel`・`task-auto`）は、`/dev-workflow:task-start 12` や `/dev-workflow:task-start #12` のように、引数で番号を渡せます。`task-status` は `/dev-workflow:task-status 12 Blocked` のように、番号、列名の順に渡します。`task-finish` は、`/dev-workflow:task-finish fix-typo` のように、番号の代わりにブランチ名も渡せます（名前に Issue の番号を含まないブランチを片付けるとき）。引数が無ければ、依頼の文章から読み取ります。`gh-pr-check` は `/dev-workflow:gh-pr-check 42` のように PR の番号を渡せます（無ければ今のブランチの PR）。

`gh-pr-check` は、投稿者ごとに担当の skill を、設定（`.claude/dev-workflow/config.json`）の `pr_check.handlers` で指定できます。担当の skill がある投稿者の指摘は、その skill に任せます（PR の番号を引数にして呼びます）。設定が無ければ、すべて汎用の手順で扱います。投稿者の名前は、大文字と小文字、末尾の `[bot]` を区別しません。

次は、レビューの bot `some-reviewer[bot]` の担当を、リポジトリの skill `review-respond` にする例です。担当の skill の作り方は、下の「担当の skill を作る」を参照してください。

```json
{
  "pr_check": {
    "handlers": {
      "some-reviewer[bot]": "review-respond"
    }
  }
}
```

### 担当の skill を作る

担当の skill は、`.claude/skills/<名前>/SKILL.md`（リポジトリ。チームで共有できます）か `~/.claude/skills/<名前>/SKILL.md`（自分だけ）に置く普通の skill です。`<プラグイン>:<名前>` の形でプラグインの skill も指定できます。

1. **受け取るもの**：`gh-pr-check` が、Skill ツールで PR の番号だけを引数にして呼びます。それ以外は渡されないので、skill の中で PR の状態を読みます。
2. **自分の担当の分を読む**：`pr-feedback.sh --pr <PR番号>` を実行します（プラグインの `scripts/` にあり、読むだけで何も変えません）。出力の `feedback` は投稿者ごとの配列で、`author` が担当の投稿者のものだけを `jq` で取り出します。
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/pr-feedback.sh" --pr 12 \
     | jq '.feedback[] | select((.author | ascii_downcase | sub("\\[bot\\]$"; "")) == "some-reviewer")'
   ```
   比べる名前は小文字で書きます。`pr-feedback.sh` は、作者名を小文字にして末尾の `[bot]` を取り除いたもの（`ascii_downcase` と `sub("\\[bot\\]$"; "")`）で照らすので、例の `jq` も作者名を同じように正規化してから、小文字の名前と比べています。
   各要素には、返信待ちのスレッド（`threads`）、レビュー本文（`reviews`）、PR のコメント（`comments`）が入っています。各項目の `replied`・`needs_attention` ・`counts.unanswered`・`counts.awaiting` の意味は、`pr-feedback.sh --help` の「意味」を参照してください。diff の外の指摘はスレッドが無く `threads` に現れないので、`threads` だけを見て「指摘なし」としないでください。出力の全項目は、スクリプト冒頭のコメントにあります。
3. **投稿者の名前の調べ方**：PR に付いた指摘の投稿者は、`gh pr view <PR番号> --json comments,reviews --jq '[.comments[].author.login, .reviews[].author.login] | unique'` で分かります。設定のキーと `feedback[].author` は、大文字と小文字、末尾の `[bot]` を区別せずに照らされます（`gh` は bot の名前を `[bot]` なしで返します）。
4. **守る決まり**
   - 自分の担当の投稿者の分だけを扱います。ほかの投稿者の指摘や、人のコメントは、触らずに `gh-pr-check` の汎用の手順に任せます。
   - 直すものは、一覧にしてユーザーに選んでもらいます。勝手にすべてを直しません。
   - push と、スレッドへの返信は、内容を見せて承認を得てから行います。

書いたら `doctor.sh` を実行してください。`pr_check.handlers` の skill が、リポジトリにもユーザーにも見つからないと警告します（プラグインの skill は検査しません）。

### pr-respond から gh-pr-check への移行

`pr-respond` は `gh-pr-check` に改めました（PR の確認から対応までを1つのスキルにまとめたためです）。旧名の別名は残していません。

- `/dev-workflow:pr-respond` は呼べなくなりました。`/dev-workflow:gh-pr-check` を使ってください。
- 設定のキー `pr_respond.handlers` は `pr_check.handlers` に改めてください。旧キーのままだと、担当の skill への委譲が効かず、すべて汎用の手順で扱われます。`doctor.sh` は、旧キーが残っていると警告します。

```json
{
  "pr_check": {
    "handlers": {
      "some-reviewer[bot]": "review-respond"
    }
  }
}
```

### テストとチェックのコマンド

`branch-update`・`gh-pr-check`・`review` は、直した後や取り込んだ後に、テストとチェックを実行します。実行するコマンドは、次の順で決めます。

1. 設定（`.claude/dev-workflow/config.json`。自分だけなら `config.local.json`）の `checks.commands` があれば、それを順に実行します。空の配列（`[]`）は、実行するものが無いと決めたことになります。
2. 無ければ（既定は `null`）、リポジトリの手がかりから推測します。`plugins/dev-workflow/scripts/checks-commands.sh` が、CONTRIBUTING.md・package.json の scripts・Makefile のターゲット・CI の設定ファイル・`Cargo.toml` や `go.mod` などを JSON で出します。CONTRIBUTING.md が無くても使えます。
3. それでも分からなければ、ユーザーに聞きます。答えを設定に保存するかも聞き、保存すれば次からは聞きません（`checks-commands.sh --save --scope <local・team> --command "<コマンド>"`。実行するものが無いなら `--none`）。

```json
{
  "checks": {
    "commands": ["make lint", "make test"]
  }
}
```

### 自動で進める（task-auto）

`/dev-workflow:task-auto 12` のように Issue を指定すると、ユーザーの承認や入力なしで、Issue #12 から PR まで進めます。今のスキル（`task-start`・`commit`・`review`・`pr-create`）の手順をたどり、それぞれの確認には、決まった表のとおりに AI が代わりに答えます。実装・テスト・コミットはサブエージェントに任せ、レビューは `/dev-workflow:review` で行います。

既定では無効です。使うリポジトリでは、`.claude/dev-workflow/config.json`（自分だけなら `config.local.json`）で有効にし、保留の列（下記の「Project」）も作っておきます。

```json
{
  "auto": {
    "enabled": true,
    "max_fix_attempts": 3,
    "max_new_issues": 3
  }
}
```

- `max_fix_attempts`：テストや lint が通らないときに、直させる回数の上限です（既定 3）
- `max_new_issues`：1回の実行で起票する Issue の数の上限です（既定 3）。レビューの指摘のうち Issue の範囲外のものと、前からある不具合は、開いている Issue で重複を確かめてから起票します（Story Point は空欄にします）

- PR は draft にせず（設定 `pr.draft` が true でも）、レビューできる状態で作り、マージはしません。レビューの上限の周でも範囲内の指摘が出たときは、反映してコミットし、テストとチェックが通れば止まらずに PR を作ります（最後の反映はレビューされていないので、本文に書きます）。本文の「自動で決めたこと」の節に、ブランチ名・着手中の Issue との重なり・反映しなかった指摘とその理由・起票した Issue などを書きます
- 決めきれないときは、そこで止まり、理由とそれまでの判断を Issue にコメントして、Issue を保留の列に移します。ワークツリーとコミットは残すので、直してから Issue を Todo に戻し、もう一度実行するか（前の作業のブランチから続けます）、今のスキルで続けられます。止まるのは、`breaking` ラベルがあるとき、type ラベルが1つでないとき、「やること」や「完了条件」が無い・あいまいなとき、テストや lint が上限の回数直しても通らないとき、差分に ADR にすべき判断があるとき、などです
- 無効なら、何もせずに止まります。有効にしても、人が手で今のスキルを使うときは、今までどおり確認を取ります

GitHub Actions から動かすこともできます。このリポジトリでは、Issue にラベル `auto` を付けると `.github/workflows/task-auto.yml` が task-auto を実行し、PR を作ります（ラベルを付けた人が write 以上のときだけ動きます）。push と PR の作成に GitHub App のトークンを使うなど、設定の手順は [CONTRIBUTING.md](CONTRIBUTING.md) の「Issue から自動で PR を作る」にあります。ワークフローのひな形は、プラグインの `templates` にはまだ置いていません。App やシークレットの前提があり、実際に動かして確かめる前に形を固定しないためです。確かめた後に、別の Issue で切り出します。

## レビューの観点

`/dev-workflow:review` は、次の3つの層に置いた観点ファイル（1ファイルに1観点の Markdown）を合わせて使います。同じ名前の観点があれば、上の層のファイルが使われます。

1. `<repo>/.claude/dev-workflow/review/*.md`：リポジトリの観点（チームで共有する）
2. `~/.claude/dev-workflow/review/*.md`：自分の観点（導入したすべてのリポジトリで使う）
3. `plugins/dev-workflow/review/*.md`：プラグインに同梱する共通の観点

```markdown
---
title: 一覧に出す1行の説明（必須）
types: [fix]
paths: ["**/*.sh"]
issue: required
base_ahead: required
---

サブエージェントへのレビューの指示。何を確かめ、どう指摘するかを書く。
```

- 観点ファイルは `/dev-workflow:review-perspective-add` で作れます（手で書いても構いません）。
- レビューの観点の追加・修正は、そのきっかけになったタスクの PR に含め、別の Issue にはしません。`/dev-workflow:review-perspective-add` は、リポジトリの層の観点を今のタスクのワークツリーに作ります。同梱の観点 `issue-requirements` は、観点の追加・修正を範囲外の変更として指摘しません。
- 観点の名前はファイル名（`.md` を除く）です。小文字の英数字と `-` だけを使います。
- `title` 以外の `types`・`paths`・`issue`・`base_ahead` は、実行する条件です（任意。上の例はすべて書いたものです）。書くと、当てはまらない変更ではその観点を実行しません（サブエージェントを起動しないので、そのぶん速く安くなります）。書かなければ毎回実行し、複数書けばすべてに当てはまるときだけ実行します。`types` は Issue の type ラベル（Issue が無いか1つに決まらなければブランチ名の type）で判断し、type が分からなければその観点は実行しません。`paths` は `.gitignore` や GitHub Actions の `paths` と同じ書き方です（`*` は `/` をまたがず、`**/*.sh` でどこの `.sh` にも当たります。`!` で始めると除外で、`["!docs/**"]` は docs の下だけを変えたときは実行しません）。外した観点とその理由は、レビューの結果で伝えます。
- 一覧の各指摘には、なぜ起きたかと、その場所だけの誤り（局所）か設計や前提の誤り（構造）かが添えられます。構造の指摘には、根本を直す案も並びます。さらに、同じ書き方・同じ前提の場所を検索して水平展開の要否が判定され、同じ誤りが残っていればその場所も一覧に加わります（反映するときは、その場所も直して同じ検索で残りが無いことを確かめます）。
- 反映でコードの振る舞いが変わると（言い換えやコメントだけなら除く）、反映したコミットの差分を再レビューします。新しい指摘が無ければ終わります。周回の上限は設定の `review.max_rounds`（既定 3、最初のレビューを含む）です。上限の周でも指摘が出ると（何も反映しなかったときも）、もう1周するか終えるかを聞かれ、続ければ4周目以降も回せます。上限で終えた後も、「もう一度レビューして」でいつでも実行できます。
- 反映した直しの再レビューで、前の周と同じ場所や同じ種類の指摘が合わせて2回以上出ると「繰り返し」と印が付き、根本の原因とそれを直す案が示されます（その場所だけを直す案では済ませません）。
- 組み込みの `/code-review` も、同梱の観点 `code-review`（`builtin: code-review`）として扱います。止めたり条件を付けたりするのは、ほかの観点と同じです。
- レビューを終えるときに、レビューが見落としてユーザーが出した指摘があれば、それを観点に残すか（既にある観点を直すか、新しい観点を作るか）を尋ねます。反映しなかった指摘に、今後も要らないという理由（例：「この書き方はこのリポジトリでは許容」）を述べたときは、今後指摘しないようにするかを尋ねます。どちらも、選んだときだけ観点ファイルを作ったり直したりします。一般的なバグや、その場限りの好みは観点にしません。
- 今後指摘しないものは、その観点ファイルの「指摘しないこと」に書きます。`/code-review` の指摘は、上の層に `code-review.md`（`builtin: code-review`）を置き、本文の「## 指摘しないこと」の節に書きます。`/code-review` そのものは変わらず、`/dev-workflow:review` が一覧にまとめるときにこの節と照らして外し、外した件数を伝えます。
- 同梱の観点を使わないときは、上の層に同じ名前のファイルを置き、frontmatter に `enabled: false` と書きます（本文と `title` は省けます）。
- 使われる観点は `plugins/dev-workflow/scripts/review-perspectives.sh` で確かめられます。引数なしでは、層を合わせた観点の一覧（条件で外す前）が出ます。今の変更で使われる観点を見るには、`--auto` を付けます（review スキルと同じく、基点・マージ先・Issue・type をブランチから決め、`context` に出します。設定の `review.max_rounds` が1以上の整数でないときと、`review.model` が null か使えるモデルでないとき、`review.code_review_effort` が null か low・medium・high・xhigh・max でないときは止まります）。形式の誤ったファイルは警告を出して使いません。そのファイルと同じ名前の観点は、下の層にあっても使いません（`enabled: false` の書き間違いで、止めたつもりの観点が動かないようにするため）。

同梱の観点：

| 観点 | 内容 |
|---|---|
| `issue-requirements` | 変更が Issue の「やること」と「完了条件」を満たし、範囲外の変更が混ざっていないか（Issue があるときだけ） |
| `docs-sync` | 振る舞いの変更に合わせて、ドキュメントとコメントが直されているか |
| `regression-test` | 不具合の修正に、その不具合がもう一度起きないことを確かめるテストがあるか（type が `fix` のときだけ） |
| `test-coverage` | 機能の追加・リファクタリング・性能の改善で、変えた振る舞いを確かめるテストがあり、境界値や異常系も確かめ、実装の写しになっていないか（type が `feat`・`refactor`・`perf` のときだけ。テストの仕組みが無いリポジトリや、テストで確かめられない変更は指摘しない） |
| `main-drift` | ブランチを作った後にマージ先に入った変更と、このブランチの変更が食い違っていないか（マージ先が進んでいるときだけ） |
| `code-review` | 一般的なバグ。サブエージェントの代わりに、組み込みの `/code-review` を実行する |

## ADR

`/dev-workflow:adr-create` は、設計上の判断の「なぜ」を ADR（Architecture Decision Record）として残します。

- 書式は [MADR](https://github.com/adr/madr) 4.0.0 です。公式の4つのテンプレートを日本語に訳して、プラグインに同梱しています（`plugins/dev-workflow/templates/adr/`。元にした版とライセンスは同じ場所の `README.md`）。
- ADR は Issue ごとではなく、判断ごとに作ります。判断をした Issue でだけ作り、1つの Issue から2つ以上の ADR ができてもかまいません。過去の判断を後から残すときは、残す作業の Issue の PR で作り、ADR の `issue` と `date` を、判断をした Issue と日にします（`adr-create.sh` の `--issue`・`--date`）。
- ファイル名は `docs/adr/<Issue 番号を6桁に0埋め>-<短い名前>.md` です（例：`docs/adr/000107-use-madr.md`）。連番ではなく Issue 番号なので、ワークツリーで並行して作業しても名前がぶつかりません。
- テンプレートは判断に合わせて選びます。他の案と比べて選んだ判断・破壊的変更・元に戻しにくい判断は全部の節がある `adr-template.md`、記録しておけば足りる判断は `adr-template-minimal.md` です。説明のない2つ（`bare`）は、手で書く人向けです。
- 書き終えた ADR の本文は、後から書き換えません。例外は、置き換えたときの `status` の行（`superseded by <新しい ADR>` にします）と、`proposed` の ADR を採択するときの `status` と `date` の2つの行だけです。採択するときは、`status` を `accepted` に書き換え、`date` を採択した日（判断をした日）に更新します。それ以外では、`date` も判断をした日のまま変えません。
- 過去の判断を一部だけ変える・覆す新しい ADR は、「補足」に、その ADR へのリンクと、何を変えるかを書きます（MADR の判断 0009）。変えられる側の ADR は書き換えません。変えられた側から、変えている ADR を探すには、`adr-list.sh` の各 ADR の `cited_in_supplements`（「補足」の節からその ADR にリンクしているほかの ADR の一覧）を見ます。全部を覆すときは、今までどおり置き換え（`superseded`）にします。
- 置き場所は、設定（`.claude/dev-workflow/config.json`）の `adr.dir` で変えられます（既定は `docs/adr`。リポジトリのルートからの相対パス）。

```json
{ "adr": { "dir": "doc/decisions" } }
```

設計上の判断をしたときは、`/dev-workflow:task-create` と `/dev-workflow:pr-create` が ADR の作成を提案します。どちらも、それぞれの確認の質問の中で聞くので、確認は増えません。

- 他の案と比べて選んだ判断・破壊的変更・元に戻しにくい判断が、提案の対象です（基準は `adr-create` の SKILL.md の「ADR にすべき判断」）。
- `task-create` は、Issue に判断が含まれていれば、「やること」に「〜の判断を ADR に残す」を足した下書きを見せます。`pr-create` は、差分に判断があり、その Issue の ADR も、Issue のチェックリストの ADR の項目（「〜を ADR に残す」）も無ければ、ADR を作ってから PR を作るかを聞きます。ADR の項目が残っているのに ADR がまだ無ければ、提案ではなく、そのことを伝えて、PR の前に ADR を作れるようにします。
- その Issue の ADR（front matter の `issue` が同じ ADR）が既にあれば、提案しません。
- 断ると、Issue のチェックリスト（ふつうは「やること」）に `- [ ] ~~〜の判断を ADR に残す~~（不要）` が残り、その Issue では二度と提案しません。
- 提案そのものを止めるときは、設定の `adr.suggest` を `false` にします。

```json
{ "adr": { "suggest": false } }
```

## フック

### タスクの進め方

導入したリポジトリでは、セッションの始まり（起動・`/resume`・`/clear`・コンパクトの後）のたびに、タスクの進め方（Issue から始める → 着手 → 区切りごとのコミット → PR の前のローカルレビュー → PR →（指摘が付いたら対応）→ 後片付け、と取りやめ、リポジトリのファイルを変えないタスクの流れ（ワークツリーを作らずに着手し、`task-finish` で Issue を閉じる））と、それぞれで使うスキルを Claude に読み込ませます（`hooks/task-flow.sh`）。スキルは呼ばれたときにしか読み込まれないので、流れはいつも渡しておきます。会話が要約されても抜けません。

既定の流れは `plugins/dev-workflow/defaults/task-flow.md` です。次のファイルを置くと、既定の流れのあとに、この順で追記として渡します（後ろほど優先します）。

1. `~/.claude/dev-workflow/task-flow.md`：自分の追記（導入したすべてのリポジトリで使う）
2. `<repo>/.claude/dev-workflow/task-flow.md`：リポジトリの追記（チームで共有する）

渡すのは合わせて 1 万文字までです。超えた分は切り、読み直すファイルを Claude に知らせます。

### git の操作を守る

導入したリポジトリでは、Claude Code が Bash で次の git の操作をしようとしたときに止めます（`hooks/guard-git.sh`）。守るブランチは設定の `base_branch`（既定は main）です。

- base_branch の上での `git commit`
- base_branch への `git push`（base_branch の上で push 先を書かずに push するときを含む）
- 強制 push（`--force` / `-f` / `+<refspec>` / `--mirror`）。`--force-with-lease` は許可する
- 別のブランチで作った stash の取り出し・破棄（`git stash pop` / `apply` / `drop` / `branch`。stash を書かなければ `stash@{0}`）と、`git stash clear`。stash は全ワークツリーで共有されるので、別の作業の変更が混ざらないようにします。detached HEAD どうしでは、stash を作ったときの HEAD が今の HEAD と同じときだけ取り出せます。今のブランチで作った stash は取り出せます

また、規約（`branch.pattern`）に合わない名前でブランチを作ろうとしたとき（`git switch -c` / `git checkout -b` / `git branch <名前>` / `git worktree add -b` / commit-ish を書かない `git worktree add <パス>`（パスの最後の名前でブランチを作ります））は、コマンドは止めずに、使用者と Claude に警告します。

`cd`・`pushd`・`popd`（積んだ場所を、シェルと同じく追います）や `git -C`・`env -C`・`sudo -D` で移った先、`--git-dir`・`GIT_DIR` などで指した先（先頭の `~`・`$HOME` は、シェルと同じく展開します）のリポジトリ・ブランチで判断し、その先が導入していないリポジトリなら止めません。守るブランチ（`base_branch`）も、その先のリポジトリの設定から読みます。bare リポジトリのように作業ツリーが分からないリポジトリは、HEAD にチームの設定がコミットされているかで判断します。git がリポジトリを見つけられないとき（ディレクトリが分からない `cd -` の後など）は、今のブランチを読めないので、コミットと、push 先を書かない push（と `HEAD`・`@` への push）と、stash の取り出し・破棄（`git stash pop` / `apply` / `drop` / `branch`）は止めます。絶対パスの `cd` か `git -C` で対象を書き直してください。同じコマンドの中で `git init` で作るリポジトリ（`git init proj && cd proj && git commit` など）は、まだ導入していないので、ちょうどその場所で動く git は止めません（その配下や、`--git-dir`・`GIT_DIR` で別のリポジトリを指した git は、今までどおり調べます）。同じコマンドの中で `git clone` するリポジトリは、まだ無くて調べられないので、移った後のコミットなどは止めます（clone を先に実行してから、別のコマンドで操作してください）。まだ無いディレクトリへの `cd`（`mkdir d && cd d` など）は、`&&` でつないだ後ろでは移れたものとして追います（`mkdir build && cd build && cd .. && git commit` や `mkdir d && cd d && git init && git commit` は、今までどおり判断します）。ただし、その場所で `git init` していない git は、どのリポジトリに入るか分からないので、コミットなどを止めます。`;`・`||`・改行でつないだ後ろは、`cd` が失敗しても動くので、前に `git init`・`git clone` で作るディレクトリでなければ、移った先が分からないものとして扱います。前に付くコマンド（`timeout`・`nice`・`env`・`time`・`nohup`・`command`・`builtin`・`exec`・`sudo`・`stdbuf`・`setsid`・`ionice`・`chrt`・`taskset`・`flock`）は、そのオプションと位置引数（`timeout` の時間、`chrt` の優先度、`taskset` のマスク、`flock` のファイル）とともに飛ばして調べます。`sudo -i`・`sudo -R` は別の場所で動き、`sudo` の前に書いた `GIT_DIR` などは sudo の設定によって消えるか残るか決められないので、git を実行する場所が分からないものとして扱います。コマンドの文字列を簡易に解析するだけなので、`sh -c`・`xargs` などを通したコマンドや git の別名を通すと見逃します。コマンドの読み方は bash の振る舞いに合わせているので、zsh などでは、移った先を誤ることがあります（パイプラインの最後のコマンドが今のシェルで動くなど）。`case` の枝は、どれが動くか分からないので、すべて順に動いたものとして読みます。関数の定義の本体は、その場で動いたものとして読みます（定義しただけで呼ばないときも、本体の中の `cd` は外に効いたものとして読みます）。パイプラインの各コマンドや `&` で動かすコマンドの中で移った分は、シェルと同じく外に効かないものとして扱います（`{ }`・ループ・`if` などの複合コマンドは、全体を1つのコマンドとして扱います）。最後の守りは GitHub のルールセット（下記）です。

### PR や Issue のリンクを出す

導入したリポジトリでは、git の操作のあとに、関連する PR・Issue・CI のリンクを、使用者の画面に出します（`hooks/pr-link.sh`）。PR や Issue の画面を探さなくても、すぐ開けます。

| 操作 | 出すリンク |
| --- | --- |
| `git push`（`pr-create.sh` を含む） | 開いた PR（無ければ PR を作る URL）、紐付く Issue、PR の CI（checks。PR が無ければブランチの CI の実行ページ） |
| `git commit`（`commit.sh` を含む）、ブランチ・ワークツリーの作成（`git switch -c` など。`task-start.sh` を含む） | 紐付く Issue |
| `gh pr create`・`gh issue create`（`pr-create.sh`・`issue-create.sh` を含む） | 作った PR・Issue（標準出力から拾う） |

- 紐付く Issue は、ブランチ名（`branch.pattern` の `{issue_number}`）から分かります。ブランチを作るコマンドでは、作るブランチの Issue です。リモートにだけあるブランチを追跡ブランチとして作る `git switch <名前>` / `git checkout <名前>` / `git switch -t <リモート>/<名前>` / `git checkout -t <リモート>/<名前>` も含みます（コマンドの後に動くので、今作られたブランチ（ブランチの reflog が「Created from」の 1 行だけ）が対象で、前から手元にあるブランチへの切り替えと、手元にできなかったときは出しません。commit-ish を書かない `git worktree add <パス>` は、パスの最後の名前をブランチの名前にします。名前を拾えないときも出しません）。main など、Issue の番号が分からないブランチでは、ブランチから導くリンクは出しません。
- `cd`・`pushd`・`popd`・`git -C`・`env -C`・`sudo -D`・`--git-dir`・`GIT_DIR` などで別のリポジトリ・ブランチへ移った git のコマンドでは、移った先のリポジトリ・ブランチのリンクを出します。ただし、次のときは移った先を正しく追えません。
  - `cd sub && git push && cd ..`・`pushd sub && git push && popd` のように、後ろでまた移るコマンドでは、移る前のブランチで判断します。`cd -` の後の git のコマンドと、まだ無いディレクトリへの `cd`（失敗しています）の後ろの `&&` でつないだコマンドには、リンクを出しません。
  - プロジェクトのルートにいるときに、相対パスへ `cd` したコマンド（`cd ../other && git push`）には、リンクを出しません。プロジェクトの外へ移ると、Claude Code が今のディレクトリをプロジェクトのルートに戻すので、どこへ移ったのか分からないためです。絶対パスへの `cd` なら追えます。
  - `sh -c`・`xargs` などを通したコマンドや、git の別名を通したコマンドは見逃します（`timeout`・`env`・`sudo` などの前に付くコマンドは、guard-git と同じく飛ばして拾います）。
  - コマンドの読み方は、guard-git と同じく bash の振る舞いに合わせているので、zsh などでは移った先を誤ることがあります。`case` の枝や、関数の定義の本体の扱いも、guard-git と同じです。
  - パイプラインや `&` で動かすコマンドの中で移った分は、外に効かないものとして扱います。ただし、その中の相対パスへの `cd` は、外側と同じくたどりません（`( )` の中と違い、終わるまでサブシェルだと分からないためです）。
- スクリプト（`commit.sh`・`pr-create.sh`・`issue-create.sh`・`task-start.sh`）と `gh pr create`・`gh issue create` は、移った先を追わず、Claude Code の今のディレクトリのリポジトリ・ブランチで判断します。
- 同じリンクも、連続で毎回出します。
- `gh` が無い・失敗するなど、リンクを出せないときは、何も出さずに通します。操作は止まりません。
- 使用者には `systemMessage`、Claude には `additionalContext` で伝え、Claude は返答でもリンクに触れます。

## リポジトリの初期設定

Claude Code で `/dev-workflow:repo-setup` を実行すると、選択肢を聞き、予定を見せてから、以下をまとめて行います。スクリプトを直接実行することもできます。

`gh` に `project` スコープが必要です（`gh auth refresh -h github.com -s project` を普通のターミナルで実行）。

### まとめて行う

```bash
# ラベル・Project・マージ方法とルールセット・PR / Issue テンプレートを揃える（対象のリポジトリの中で実行）
plugins/dev-workflow/scripts/setup/setup-all.sh --dry-run
plugins/dev-workflow/scripts/setup/setup-all.sh
```

作ったファイル（テンプレート、`.claude/dev-workflow/config.json`）はコミットされません。main は守られるので、PR でマージしてください。

`/dev-workflow:repo-setup` では、レビューに使うモデルを決めていなければ、使うかどうかも聞かれます（下の「レビューに使うモデル」）。保留の列を設定していなければ、作るかどうかも聞かれます（下の「Project」）。

### ラベル

```bash
# type ラベル（feat / fix など）と breaking ラベルを作成・更新し、GitHub の既定のラベルを削除する
plugins/dev-workflow/scripts/setup/setup-labels.sh

# 既定のラベルを残す・変更せずに予定だけを確認する
plugins/dev-workflow/scripts/setup/setup-labels.sh --keep-defaults
plugins/dev-workflow/scripts/setup/setup-labels.sh --dry-run
```

定義は `plugins/dev-workflow/defaults/labels.json`。リポジトリに `.claude/dev-workflow/labels.json` を置くとそちらを使います（`--file` でも指定できます）。`--repo` で別のリポジトリを指定したときは、そのリポジトリの既定のブランチにある `.claude/dev-workflow/labels.json` を読みます。独自の `.claude/dev-workflow/labels.json` には `breaking` ラベルも定義してください（無いと破壊的変更の Issue を起票できないので、警告を出します）。

削除するのは、GitHub が新しいリポジトリに作る既定のラベル（`accessibility`・`bug`・`enhancement` など）のうち、定義に無いものだけです。既定のラベルを残したいときは、そのラベルを定義に書くか、`--keep-defaults` ですべて残してください。

### Project

```bash
# Project を作成（同じ名前があれば再利用）し、Story Point の追加・Issue の取り込みを行う
plugins/dev-workflow/scripts/setup/setup-project.sh --write-config

# 既存の Project に接続する
plugins/dev-workflow/scripts/setup/setup-project.sh --number 3 --write-config

# 保留の列（On Hold）も足し、設定の status.hold に書く
plugins/dev-workflow/scripts/setup/setup-project.sh --hold-column "On Hold" --write-config

# 変更せずに、行う予定の操作だけを確認する
plugins/dev-workflow/scripts/setup/setup-project.sh --dry-run
```

保留の列は、外の条件を待っていて今は着手できない Issue（例：試用期間が終わるまで着手できない）を置く列です。任意で、設定しなければ今までどおりに動きます。保留の列にある Issue は `/dev-workflow:task-next` の候補から外れ、件数と番号が伝えられます。列へ移すのも Todo に戻すのも `/dev-workflow:task-status` で行います（`/dev-workflow:task-status 12 hold`・`/dev-workflow:task-status 12 todo`）。`/dev-workflow:task-auto` が止まるときだけは、task-auto がこの列へ移します（上記の「自動で進める」）。保留の列の名前を変えるときは、Project の画面で列の名前を変え、`.claude/dev-workflow/config.json` の `status.hold` も同じ名前にしてください。`--hold-column` で別の列を足して切り替えるときは、今の保留の列に Issue が残っていると止まるので、先に新しい列へ移してください。

Project に組み込みの自動追加（Auto-add to project）は API で有効にできないため、スクリプトが表示する URL の画面で1回だけ手動で有効にしてください。

### マージ方法とルールセット

```bash
# スカッシュのみ許可・マージ後にブランチを自動削除し、main への直接 push・強制 push・削除を禁止する
plugins/dev-workflow/scripts/setup/setup-repo.sh

# マージに承認を1つ必要にする（付けなければ今の値のまま）
plugins/dev-workflow/scripts/setup/setup-repo.sh --require-approval 1
```

ルールセット「dev-workflow」は管理者も例外にしません。守るブランチは設定の `base_branch`（既定は main）です。

#### マージの前に CI を求める

別の PR が先にマージされて main が進んでも、前の PR の CI の結果は古いままです。単独では通る2つの PR が組み合わさって main が壊れることがあるので、チェックの成功と、PR が最新の main を取り込んでいること（マージキューを使うときは、キューを通すこと。下の「マージキューを使う」）を、ルールセットで求められます。

```bash
# lint-result と test-result の成功と、最新の main の取り込みを、マージの条件にする（マージキューを使っていれば、取り込みは求めない）
plugins/dev-workflow/scripts/setup/setup-repo.sh --required-check lint-result --required-check test-result
```

- `--required-check` は、`setup-all.sh` にも渡せます。繰り返し指定できます。
- 指定した名前の一覧で、必須のチェックを置き換えます。CI を足したり外したりしたときは、新しい一覧で実行し直します。付けなければ、ルールセットの必須のチェックの一覧には触れません。GitHub の設定画面で直した必須のチェックも、そのまま残ります。ただし、最新の main の取り込み（strict）は、マージキューの有無で決まります。キューを使っていれば、オプションが無くても外します。使っていなければ、`--required-check`・`--no-merge-queue` のときに求め、どちらも無ければ今のままです。
- チェックの名前は、チームの CI で決まるので、プラグインは決めません。CI が無いリポジトリや、まだ報告されたことのない名前を指定すると、チェックが「待ち」のまま残ってマージできなくなります。名前は、そのチェックが一度動いてから指定してください。
- 名前は、CI 全体の結果を1つにまとめる「門番のジョブ」にすることをおすすめします。ジョブを足しても、必須の名前は変わらずに済みます。ジョブごとに必須にすると、CI の変更のたびにこのコマンドを実行し直すことになります。
- マージキューを使うなら、必須のチェックを出すワークフローに `on: merge_group` が要ります。ドキュメントだけの変更で重いジョブを飛ばす判定は、`merge_group` では `github.event.merge_group.base_sha` との差で行ってください。詳しくは「マージキューを使う」を参照してください。
- `paths-ignore` などでワークフローが動かない PR（ドキュメントだけの変更など）は、そのチェックが報告されず、「待ち」のままマージできなくなります。`paths-ignore` はやめ、変更の範囲を見て重いジョブを `if` で飛ばしたうえで、門番のジョブは必ず動かして成功にしてください（このリポジトリの `.github/workflows/lint.yml`・`test.yml` が例です）。

#### マージキューを使う

最新の main の取り込みを求めると、別の PR がマージされるたびに、残りの PR へ main を取り込み直して CI を通し直すことになります。マージキューを使うと、キューが最新の main と組み合わせた結果で CI を動かして順にマージするので、取り込み直しが要らなくなります。

```bash
# マージキュー（スカッシュ）を使い、必須のチェックの「最新の main の取り込み」を外す
plugins/dev-workflow/scripts/setup/setup-repo.sh --merge-queue --required-check lint-result --required-check test-result

# マージキューを外し、必須のチェックには最新の main の取り込みを求める
plugins/dev-workflow/scripts/setup/setup-repo.sh --no-merge-queue
```

- マージキューは、Organization の公開リポジトリと、GitHub Enterprise Cloud の Organization の非公開リポジトリで使えます。個人のアカウントのリポジトリでは使えないので、`--merge-queue` は止まります。使えるかは、出力の `merge_queue.available` で分かります。
- 選び方：使えるリポジトリで PR を並列に進めるなら、マージキューをおすすめします。最新の main の取り込み（strict）では、別の PR がマージされるたびに、残りの PR へ main を取り込み直して CI を通し直します。キューなら取り込み直しは要らず、取り込むのは main とコンフリクトしたときだけです。strict は、キューを使えないリポジトリ（個人のアカウントなど）と、キューを使わないと決めたリポジトリで使います。必須のチェックと、strict またはキューを設定していれば、どちらの方式でも、古い main で通った CI の結果のままマージされることはありません（設定しないままだと、どちらも効きません）。
- `--merge-queue`・`--no-merge-queue` は、`setup-all.sh` にも渡せます。どちらも付けなければ、キューを今のまま使う・使わないままにします。
- 必須のチェックを求めるワークフローは、`merge_group` のイベントでも動くようにしてください（`on: merge_group`）。動かないと、キューのチェックが「待ち」のまま残ってマージされません。`setup-repo.sh` は、base_branch の `.github/workflows/` を読んで、必須のチェック（ほかのルールセットと古いブランチ保護が求めるものも含めます）のジョブがあるワークフローが `merge_group` で動くかを確かめ、出力の `merge_queue.merge_group` に出します（`--dry-run` でも、キューを使わないときも確かめます）。チェックの名前は、GitHub がジョブのチェックに付ける名前（`name:` があればその値、無ければジョブの ID）と突き合わせるので、どのジョブとも対応しない名前（外部のアプリのチェックなど）は確かめられません。`${{ }}` の式を含む `name:` のジョブ（matrix の値を名前に入れたものなど）とも突き合わせないので、そのチェックも確かめられません。確かめたいときは、式を含まない名前のジョブ（CI 全体の結果をまとめる門番のジョブなど）を必須のチェックにしてください。ジョブの `if:` で `merge_group` を除いていても（`if: github.event_name != 'merge_group'` など）、キューでは動きません。飛ばされたジョブのチェックは成功とみなされるので、キューは CI を動かさないまま PR をマージしてしまいます。そこで、必須のチェックのジョブと、そのジョブが `needs:` でたどれるジョブの `if:` も読み、`merge_group` を除いていれば「動かない」とし、ジョブの `if:` を直すよう案内します。`if: always()` などの門番のジョブが頼るジョブを除いているときは、門番は動くものの、CI を動かしたかは結果の確かめ方次第なので、「確かめられない」とします。出力の `merge_queue.merge_group.not_running` には、動かないチェックを、直す場所（`reason`。ワークフローの `on:` に `merge_group` が無ければ `on`、ジョブの `if:` で除いていれば `if`）と一緒に出します。`github.event_name` を `==`・`!=` で比べるだけの項は読み分けますが、それ以外に `github.event`・`github.head_ref`・`github.base_ref`・`github.ref`・`merge_group` を使う式（`github.event.pull_request.draft == false` など）は、動くか確かめられないとします。再利用するワークフローの、呼ばれる側のジョブの `if:` は読みません。キューを使うときは、動かないチェックと、確かめられないチェックを警告しますが、止めはしません。キューを使わないときは、警告せずに結果を出力に出すだけです。キューを使い始めた後は、`doctor.sh` が同じことを確かめます。
- `doctor.sh` は、main にマージキューと最新の main の取り込みのどちらが効いているかを表示します。main に必須のチェックが無いときは、CI が通らなくてもマージできるので警告し（マージキューを使っていても警告します。ルールセットだけでなく、古いブランチ保護の必須のチェックも見ます。古いブランチ保護にだけ必須のチェックがあるときは、strict かが分からないので、マージキューと最新の main の取り込みのどちらが効いているかは表示しません）、`/dev-workflow:repo-setup`（`setup-repo.sh --required-check`）で設定するよう案内します。CI の無いリポジトリでこの警告を止めるには、`.claude/dev-workflow/config.json` に `"require_status_checks": false` を書きます（個人の設定 `config.local.json` やユーザーの設定では止められません）。

### レビューに使うモデル

`/dev-workflow:review` のレビュー（観点ごとのサブエージェントと `/code-review`）を、セッションとは別のモデルで動かせます。使うかどうかは任意で、既定では使いません（いつもセッションと同じモデルで動きます）。セッションより下のモデルにして費用を抑えることも、セッションを Sonnet にしたままレビューだけ Opus で深く見ることもできます。

```bash
# このリポジトリで、自分のレビューを Opus で動かす（opus・sonnet・haiku・fable から選べます。config.local.json に書きます）
plugins/dev-workflow/scripts/setup/setup-models.sh --review-model opus --scope local

# チームで、レビューをセッションと同じモデルで動かすと決める（.claude/dev-workflow/config.json に書きます）
plugins/dev-workflow/scripts/setup/setup-models.sh --review-model off --scope team

# 今の設定と、どの層で決めてあるかを確かめる
plugins/dev-workflow/scripts/setup/setup-models.sh
```

- 書く層は、`local`（`.claude/dev-workflow/config.local.json`。自分だけ）か `team`（`.claude/dev-workflow/config.json`。コミットしてチームで共有します）です。設定ファイルの `review.model` を直接書いてもかまいません。
- `~/.claude/dev-workflow/config.json` に `review.model` を書くと、ほかの設定と同じく、導入したすべてのリポジトリに効きます（リポジトリの層で決めた値が優先されます）。`setup-models.sh` はユーザーの層には書きません。
- 契約や組織の制限で使えないモデルを指定すると、Claude Code が別のモデルに置き換えて動かします。
- 対象はレビューだけです。commit などの短いスキルは、別のモデルに任せる手間でかえって費用が増えるので、いつもセッションと同じモデルで動きます。
- 計った結果（[設計書 §7](docs/design.md#7-レビュー)）：費用の半分ほどはセッションのモデルで動く進行役の分なので、`sonnet` に下げても、レビュー1回の費用は17%ほどしか減りません。`haiku` はトークンを多く使うので `sonnet` より得にならず、時間は倍以上かかります。セッションを Sonnet にしたままレビューだけを `opus` にすると、セッションを Opus にしたときと同じくらいの費用で、レビューを Opus で行えます。
- `local` に書いたとき、`config.local.json` が git に無視されていなければ警告します。`.gitignore` に `.claude/dev-workflow/config.local.json` を足してください。既にコミットしてあるときは、`.gitignore` に書くだけでは追跡が外れないので、`git rm --cached .claude/dev-workflow/config.local.json` で外すよう警告します。
- `--review-model`・`--models-scope` は、`setup-all.sh` にも渡せます。

### レビューの /code-review の段階

`/dev-workflow:review` が呼ぶ組み込みの `/code-review` に渡す effort の段階（low・medium・high・xhigh・max）を、設定の `review.code_review_effort` で固定できます。既定（null）では段階を渡さないので、`/code-review` は、最後に手で打った段階を使い、一度も打っていなければセッションの今の effort を使います。そのため、セッションの effort を上げると、レビューの待ち時間が大きく変わります（過去の記録では、low で1回1分足らず、high で約2分、max で約33分でした。再レビューの周ごとに繰り返します）。

```json
{
  "review": {
    "code_review_effort": "low"
  }
}
```

- 設定すると、セッションの effort や前に打った段階に関係なく、1周目と再レビューの `/code-review` がその段階で動きます（`review.model` でサブエージェントに任せるときも同じです）。
- 自分だけ固定するなら、`.claude/dev-workflow/config.local.json`（このリポジトリだけ）か `~/.claude/dev-workflow/config.json`（導入したすべてのリポジトリ）に書きます。チームでそろえるなら `.claude/dev-workflow/config.json` に書きます。リポジトリの層で決めた値が優先されます。
- 誤った値（`ultra` を含みます）を書くと、レビューの前に1行のメッセージで止まります。
- review スキルが渡した段階は、手で打つ `/code-review` が後で使う「最後に打った段階」を変えないと見込んでいますが、実際に実行しては確かめていません（[設計書 §7](docs/design.md#7-レビュー)）。

## 開発

開発に参加するときの環境の準備・開発の流れ・テストは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。
