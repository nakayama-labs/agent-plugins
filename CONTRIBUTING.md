# 開発への参加

このリポジトリを開発する人向けの手順とルールです。プラグインの使い方は [README](README.md)、設計は [docs/design.md](docs/design.md) を参照してください。

## 環境の準備

必要なもの：`git`、`gh`、`jq`、`shellcheck`（CI と同じ版）、`bats`（bats-core）、`actionlint`（shellcheck と actionlint は、無ければ Docker で実行できます。下の「テストとチェック」）。bats を並列に実行するなら GNU `parallel` も使います。スキルの振る舞いを eval で確かめるなら、Claude Code（v2.1.269 以降）と、Linux では `bubblewrap`・`socat` も使います（下の「スキルの振る舞いを eval で確かめる」）

テストの補助ライブラリ（bats-support・bats-assert）は git submodule で同梱しています。

```bash
git submodule update --init   # 初回だけ
```

開発中のプラグインを Claude Code に読み込んで試す方法は、README の「使い方」を参照してください。

## 開発の流れ

このリポジトリ自身も dev-workflow プラグインのワークフローで開発します。

1. **Issue を起票します**（`/dev-workflow:task-create`）。作業はすべて Issue から始めます。
2. **着手します**（`/dev-workflow:task-start`）。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）ができるので、以後はその中で作業します。調査や Issue の整理のように、リポジトリのファイルを変えないタスクでは、ワークツリーを作らずに着手し、終わったら `/dev-workflow:task-finish` で Issue を閉じます（3〜4 は要りません）。
3. **コミットします**（`/dev-workflow:commit`）。全部を直し終えてから1回でコミットするのではなく、論理的な区切り（1つの変更を仕上げてテストが通ったところ）ごとにコミットします。
4. **PR を出します**（`/dev-workflow:pr-create`）。出す前に、下の「テストとチェック」がすべて通ることを確かめます。PR はマージキューに入れてマージします。main が先に進んでも、PR に main を取り込み直す必要はありません（下の「コミットと PR の規約」のマージの条件）。PR に指摘や質問が付いたら、`/dev-workflow:gh-pr-check` で対応します（下の「指摘に手元の Claude Code で対応する」）。
5. **後片付けをします**（`/dev-workflow:task-finish`）。PR がマージされたら、ワークツリーとローカルのブランチを削除し、main を最新にして、PR が閉じる Issue が閉じたかも伝えます。

レビューの観点（`.claude/dev-workflow/review/`）の追加・修正は、そのきっかけになったタスクの PR に含め、別の Issue にはしません。`/dev-workflow:review-perspective-add` は、今のタスクのワークツリーで実行します。

Issue をやめることにしたときは、`/dev-workflow:task-cancel` を使います。理由と参照先をコメントして not planned（重複なら duplicate）で閉じ、着手していれば PR を閉じて、ブランチとワークツリーも削除します。

### コミットと PR の規約

- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/v1.0.0/)（`<type>(<scope>): <要約>`）で書きます。type は `plugins/dev-workflow/defaults/workflow.json` の `commit.types` のどれかです。
- PR のタイトルは `<type>: <Issueのタイトル>` とし、本文に `Closes #<Issue番号>` を付けます。
- マージの条件：main のルールセットは、マージキューを通すことと、`lint-result` と `test-result` の成功と、レビューのスレッドがすべて resolved になっていることを求めます。resolved でないスレッドが1つでも残っている PR は、キューに入れられません（指摘への対応は、下の「指摘に手元の Claude Code で対応する」）。対象は行ごとの指摘のスレッドだけで、diff の外の指摘や Claude のレビューのコメントは含みません。PR の CI が通ったら、PR の「Merge when ready」か `gh pr merge <PR番号>` でキューに入れます。キューは、最新の main に、先に並んだ PR と自分の PR を重ねた一時的なブランチを作り、そこで CI（`merge_group` のイベント）を動かして、通った PR から順に main にマージします。そのため、別の PR が先にマージされて main が進んでも、PR に main を取り込み直す必要はありません。古い main で通った CI の結果のままマージすると、先にマージされた変更と組み合わさって main が壊れることがありますが（#108）、キューは組み合わせた後の結果で確かめるので、これを防げます。キューの CI が失敗した PR はキューから外れるので、直して push してから、もう一度キューに入れます。main との間でコンフリクトしたときだけ、PR に main を取り込んで直します（`/dev-workflow:branch-update`）。
- マージはスカッシュのみです（キューもスカッシュでマージします）。main への直接 push・強制 push はルールセットとフックで禁止されています。
- プラグインのラベルの定義（`plugins/dev-workflow/defaults/labels.json`）を変えた PR では、このリポジトリでも `plugins/dev-workflow/scripts/setup/setup-labels.sh` を実行して、ラベルを定義に揃えます。定義を変えても、既にあるリポジトリのラベルは変わらず、足したラベルが無いと起票などで止まります（`doctor.sh` が足りないラベルを知らせます）。
- プラグインのバージョンは release-please がリリース PR で上げます。`plugin.json` の `version` や `.release-please-manifest.json` を手で変えないでください。

## PR の自動レビュー

PR は、CodeRabbit（`.coderabbit.yaml`）が作ったときと、push のたびに（増分で）自動でレビューします。これは CodeRabbit の試用期間中だけの暫定の運用で、試用期間が終わったら、作ったときに1回だけレビューする運用に戻します（#160）。指摘への対応は、下の「指摘に手元の Claude Code で対応する」のとおり、返信で行います。CodeRabbit のレビューは1時間あたりの回数に上限があり、上限で失敗したレビューは自動では再試行されません。そこで、次のときは Claude が代わりにレビューして PR にコメントします（`.github/workflows/claude-review.yml`）。

- CodeRabbit が上限に引っかかったとき（`coderabbitai[bot]` の、本文が `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->` で始まるコメントがきっかけです。要約のコメントが上限の文言を引用していても起動しません）
- PR を作ってから1時間経っても CodeRabbit のレビューも、上限以外のコメント（指摘なしなどをコメントで返したもの）も無いとき（30分ごとに見回ります。障害など上限以外の理由で動かなかった場合も拾いますが、CodeRabbit が何もコメントしていないときに限ります。要約のコメントだけが付いてレビューが失敗した場合は拾えません）

Claude のレビューは、上限のコメントがきっかけのときは同じコミットに1回しか付きません（試用期間中は、push のたびに CodeRabbit のレビューが上限に当たりやすく、上限に当たった push のコミットごとに付くので、PR あたりの数が増えることがあります）。見回りは、その PR に Claude のレビューが1件でもあれば動かないので、CodeRabbit が動かない状況でも、レビューが際限なく付くことはありません。head が同じリポジトリの PR だけが対象で、フォークからの PR は対象外です。どちらのレビューも、この CONTRIBUTING.md と `plugins/dev-workflow/review/*.md`・`.claude/dev-workflow/review/*.md` のレビューの観点に沿って行います。ワークフローは必須のチェックではないので、失敗しても PR のマージは妨げません。

### 設定の手順

1. CodeRabbit の GitHub App をこのリポジトリに入れます（公開リポジトリは OSS プランで無料です）。
2. 手元で `claude setup-token` を実行して OAuth トークンを作り、リポジトリのシークレット `CLAUDE_CODE_OAUTH_TOKEN` に登録します。

### 指摘に手元の Claude Code で対応する

試用期間中は、push のたびに CodeRabbit が増分でレビューします（試用期間が終わったら、PR を作ったときの1回だけに戻します。#160）。指摘には返信して resolved にしていきます。この流れは、このリポジトリ専用の skill `.claude/skills/coderabbit-respond/`（プラグインには同梱しません）で行えます。PR に付いた指摘・質問には、プラグインの `/dev-workflow:gh-pr-check` でまとめて対応できます。このリポジトリでは、`.claude/dev-workflow/config.json` の `pr_check.handlers` で CodeRabbit（`coderabbitai[bot]`）の担当を `coderabbit-respond` にしているので、CodeRabbit の指摘は gh-pr-check から coderabbit-respond に任されます（人のレビューや CI の失敗は、gh-pr-check が汎用の手順で扱います）。CodeRabbit 固有の決まりは、この節が正本です。

- 試用期間中は、push のたびに自動でレビューされるので、`@coderabbitai review` は要りません。試用期間が終わったら、`@coderabbitai review` は使いません（1回ごとにレビューの上限を消費し、使った後の PR では、push のたびに増分のレビューが走って上限を消費するためです）。ただし、試用期間が終わった後でも、PR を作ったときのレビューが、障害などで付かなかったときだけ、1回使ってかまいません（Claude の見回りが拾うのを待たなくて済みます）。
- 指摘は `gh` で読みます。行ごとの指摘はスレッドで、diff の外の指摘はレビュー本文にあります。

  ```bash
  gh pr view <PR番号> --comments                                  # Claude のレビューと CodeRabbit の要約
  gh api repos/{owner}/{repo}/pulls/<PR番号>/comments             # CodeRabbit の行ごとの指摘
  ```

- 直した指摘は、そのスレッドに、直したコミットを添えて `@coderabbitai` 付きで返信します。CodeRabbit が現在のコードを読み、直っていれば resolved にします。チャットのメッセージは、PR のレビューとは別の上限です。
- diff の外の指摘はスレッドが無いので、PR のコメントに `@coderabbitai` を付けて、同じように確認させます。
- 直さない指摘は、理由を返信します。resolved にするのは、直したか、理由に合意できたものだけにします。resolved でないスレッドが残っていると、PR はマージできません（上の「コミットと PR の規約」のマージの条件）。
- `@coderabbitai resolve` でまとめて resolved にしません。

## Issue から自動で PR を作る

Issue にラベル `auto` を付けると、GitHub Actions が `/dev-workflow:task-auto` を実行し、着手から PR の作成まで自動で進めます（`.github/workflows/task-auto.yml`）。手元のセッションは要りません。マージは人が行います。

- 起動するのは、Issue に `auto` が付いた瞬間だけです（GitHub が送る `issues` の `labeled` イベントで起動し、ポーリングはしません）。ほかのラベルでは何もしません。
- ラベルを付けた人がこのリポジトリの write 以上のときだけ動きます。triage の人が付けても、動きません（ジョブは何もせずに終わります）。
- task-auto が止まったとき（保留の列に移したとき）は、理由が Issue のコメントに付き、実行は成功で終わります。実行そのものが失敗したときは、ワークフローが Issue にコメントします。もう一度動かすには、ラベルを外して付け直します。
- push と PR の作成は GitHub App のトークンで行います。`GITHUB_TOKEN` が作った PR や push では、lint・test が起動しないためです（[ADR 000057](docs/adr/000057-github-app-token-for-release.md)）。release-please とは別の App にして、権限を分けます。
- 実行のたびに、プランの使用量を消費します。Issue の本文は Claude が読むので、`auto` を付ける前に、本文に不審な指示が無いかを確かめてください。許可するツールは、リポジトリの編集・git・gh・テストの実行に絞っています。

### 設定の手順

1. Organization の Settings → Developer settings → GitHub Apps で、App を作ります。Webhook は無効、インストール先は自分のアカウント（Organization）だけにします。権限は次のとおりです。
   - Repository permissions：Contents・Issues・Pull requests を Read and write（Metadata は自動で Read-only）
   - Organization permissions：Projects を Read and write（列の移動に要ります。リポジトリの権限だけでは Project を操作できません）
2. App の ID と秘密鍵（.pem）を控え、App をこのリポジトリだけにインストールします。
3. リポジトリの Variables に `AUTO_APP_ID`（App の ID）を、Secrets に `AUTO_APP_PRIVATE_KEY`（秘密鍵の中身）を登録します。`CLAUDE_CODE_OAUTH_TOKEN` は、上の「PR の自動レビュー」の設定と共通です。
4. ラベルを作ります。`gh label create auto --description "Claude が自動で PR まで進める" --color 5319e7`。プラグインの既定のラベル（`labels.json`）には入れません（このリポジトリの運用のためのラベルです）。

task-auto は `auto.enabled` が true のリポジトリでしか動きません。このリポジトリでは `config.json` には書かず、ワークフローが実行のたびに個人の層（`config.local.json`。git の対象外）で有効にします。手元のセッションでは有効になりません。

## 書き方のルール

- **macOS 標準の bash 3.2 で動くように書きます**。連想配列（`declare -A`）、`mapfile` / `readarray`、`${var,,}` などの bash 4 以降の機能は使いません。スクリプトの先頭には `set -euo pipefail` を書きます。
- 日本語などの ASCII 以外の文字が変数の直後に続くときは、`"${var}」"` のように波括弧で囲みます（bash 3.2 は `"$var」"` の `」` のバイトまで変数名とみなします。CI で検査しています）。
- **スキルから呼ぶファイルは `plugins/dev-workflow/` の中に置きます**。プラグインとしてインストールされるのはこのディレクトリだけなので、外に置いたファイルは使う人の環境にありません。スキルからは `${CLAUDE_PLUGIN_ROOT}/scripts/...` のように参照します。
- **cd は `CDPATH='' cd ...` と書きます**。CDPATH を export した環境では、相対パス（`dirname` の結果など）への cd がパスを出力するので、置き場所が2行になって読み込みに失敗します。`CDPATH=''` の無い cd は、`tests/cdpath.bats` が見つけて失敗します。検査の対象のファイルは、そのテストの `CD_PATHS` です。絶対パスだと保証した cd や、メッセージの中に cd と書いただけの行は、そのテストの許可の一覧に理由を添えて足します。
- **shellcheck を通します**。警告を抑えるときは、理由をコメントに書きます。
- スクリプトの出力は JSON、エラーは終了コードと1行のメッセージにします。初期設定用のスクリプト（`scripts/setup/`）は `--dry-run` に対応します（設計書 §10）。

## テストのルール

- **スクリプトを変えたら、bats のテスト（`tests/*.bats`）を足します**。GitHub を使うスクリプトは、`gh` を偽物（`tests/fake_gh.bash` など）に置き換えて、GitHub に触れずに試します。
- **不具合を修正するときは、その不具合がもう一度起きないことを確かめるテストを必ず足します**。修正前のコードでは失敗し、修正後に通ることを確かめてからコミットします。
- **不具合を修正するときは、同じ原因の他の箇所も探します**。同じ書き方・同じ前提で書かれた場所を `git grep` などで検索し、同じ誤りが残っていれば同じ変更で直して、その分のテストも足します。直した後に、同じ検索をもう一度実行して残りが無いことを確かめます。

## テストとチェック

PR を出す前に、次がすべて通ることを確かめます。どれも CI でも実行します（shellcheck・actionlint・`claude plugin validate` などは `.github/workflows/lint.yml`、bats は `.github/workflows/test.yml`）。ただし、`README.md`・`docs/`・Issue と PR のテンプレート（`.github/ISSUE_TEMPLATE/`・`.github/pull_request_template.md`）だけを変えた PR では、重いジョブ（lint・test）を飛ばします。ワークフローは動いて、必須のチェック（`lint-result`・`test-result`）は成功になるので、これまでどおりマージできます。

マージキューに入れた PR では、`merge_group` のイベントで lint・test がもう一度動き、その `lint-result`・`test-result` でマージできるかが決まります。このときのドキュメントだけの変更かの判定（`.github/scripts/docs-only.sh`）は、PR の base との差ではなく、キューの一時的なブランチの元のコミット（`merge_group.base_sha`。main か、先に並んだ PR を重ねたコミット）との差で行います。PR が複数のコミットでも、その PR の変更全体で判定するためです。

```bash
# tests/lib は外部のライブラリ（git submodule）なので対象にしない
find plugins tests .github/scripts -path tests/lib -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print0 | xargs -0 shellcheck -x
shellcheck -s bash tests/*.bats
actionlint                         # 入っていなければ docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate --strict .                     # マーケットプレイス
claude plugin validate --strict plugins/dev-workflow  # プラグイン本体（. だけではスキルなどは検査されない）
```

CI の test ジョブは、`tests/*.bats` を所要時間が偏らないように複数のシャード（ubuntu は3つ、macOS は4つ）に分けて並列に動かします（分け方は `.github/scripts/shard-bats.sh`、ファイルごとの所要時間の目安は `.github/scripts/bats-weights.tsv`）。必須のチェック `test-result` は、全シャードが成功したときだけ成功になります（1つでも失敗・取り消しなら失敗です。ドキュメントだけの変更で test を飛ばしたときは、これまでどおり成功です）。手元では分けずに `bats tests/` で全部を動かして構いません。新しい `.bats` は、表に無くても必ずどれかのシャードに入ります。偏りが目立つようになったら、表を測り直します。

bats は `--jobs` で並列に実行できます（GNU parallel が要ります）。テストは git や jq の起動を待つ時間が長いので、コア数の2倍くらいにすると速くなります。各テストは自分の一時ディレクトリで動くので、並列にしても結果は変わりません。

```bash
bats --jobs "$(( $(getconf _NPROCESSORS_ONLN) * 2 ))" tests/
```

shellcheck は版によって出す指摘が違うので、CI と同じ版（`.github/workflows/lint.yml` の `SHELLCHECK_VERSION`、今は 0.11.0）を使います。CI の版を上げるときは、ここに書いた版（この段落と、下の Docker のイメージのタグ）もそろえます。手元に同じ版が無ければ、Docker で実行できます。

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:v0.11.0 sh -c '
  find plugins tests .github/scripts -path tests/lib -prune -o -type f \( -name "*.sh" -o -name "*.bash" \) -print0 | xargs -0 -r shellcheck -x &&
  shellcheck -s bash tests/*.bats
'
```

### Docker の bash 3.2 でテストする

macOS 以外でも、Docker の `bash:3.2` イメージで macOS 標準の bash 3.2 で動くことを確かめられます。リポジトリ・ワークツリーのどこで実行しても動きます。

```bash
root=$(plugins/dev-workflow/scripts/main-root.sh | jq -r .main_root)   # 元のリポジトリ（サブモジュールや bare 配置でも求まる）
top=$(git rev-parse --show-toplevel)                       # 今いるリポジトリまたはワークツリー
gitdir=$(CDPATH='' cd "$(git rev-parse --git-common-dir)" && pwd)    # git のデータ（サブモジュールでは上のリポジトリの .git/modules の中）
docker run --rm -v "$root:$root" -v "$top:$top" -v "$gitdir:$gitdir" -w "$top" bash:3.2 sh -c '
  apk add --no-cache jq git bats bash parallel >/dev/null &&
  git config --global --add safe.directory "*" &&
  export PATH=/bin:/usr/bin:$PATH &&
  TEST_BASH=/usr/local/bin/bash bats --jobs "$(( $(getconf _NPROCESSORS_ONLN) * 2 ))" tests/
'
```

- bats 本体は新しい bash（apk で入れる `/bin/bash`）で動かし、対象のスクリプトだけ bash 3.2（イメージの `/usr/local/bin/bash`）で動かします。イメージでは `/usr/local/bin` が PATH の先にあるので、`PATH` を並べ替えないと bats 本体も bash 3.2 で動き、日本語のテスト名を扱えずに失敗します。
- コンテナの中はファイルの持ち主が違うので、`safe.directory` を設定しないと git がリポジトリを使えません。
- ワークツリーの `.git` はファイルで、元のリポジトリの `.git/worktrees/` を指しています。ワークツリーだけをマウントすると `fatal: not a git repository` になるので、上のように元のリポジトリ全体とワークツリー、git のデータ（サブモジュールでは `.git/modules` の中で、元のリポジトリの外にあることがあります）を、どれも同じパスでマウントします（ワークツリーがリポジトリの外にあっても動きます）。ワークツリーでは、先に `git submodule update --init` も実行しておきます。

### スキルの振る舞いを eval で確かめる

bats のテストは、スクリプトの出力と、SKILL.md に手順が書いてあるかを確かめますが、Claude がその手順どおりに動くかは確かめません。そこで、[`claude plugin eval`](https://code.claude.com/docs/en/plugin-evals) で Claude に実際に依頼を実行させて、振る舞いを採点するケースを `plugins/dev-workflow/evals/` に置いています。確認を取る場面など、スキルの手順を変えたときは、関係するケースを手元で実行して確かめます。上の「テストとチェック」とは違い、PR を出す前に必ず通すものではありません。

ケースは、承認の前に GitHub に書き込まないか（task-create・pr-create）、何も変えないか（task-next）、fix の作業で同じ原因の箇所も直すか（タスクの進め方）、task-auto が、有効にしていなければ何もしないか・止まる条件で Issue にコメントして保留の列に移して止まるか・レビューで範囲外とした指摘を起票してから PR を作るか・既にある下書きの PR に push するときに、ready にせず、人に ready にするよう伝えるか、gh-pr-check が、スレッドが無く、レビュー本文に diff の外の指摘がある PR で、指摘を見落とさずに伝えるか（gh-pr-check）を確かめます。どのケースも、作業用の git リポジトリを準備のスクリプト（各ケースの `fixture.sh`）で作り、GitHub には触れません。`gh` は偽物（`tests/eval/bin/gh`）に置き換え、準備のスクリプトが置いた表で答えます。表では、読むだけの呼び出しを `fake_gh_read` で宣言します（よく使うものは、準備の最後に呼ぶ `fake_gh_defaults` が既定で宣言します）。宣言していない呼び出しは、すべて GitHub への書き込みとして記録され、「書き込まなかった」を確かめる grader で落ちます。宣言した読むだけの行に当たっても、`gh api` の引数に書き込みのしるし（GET 以外のメソッド、`-f`・`-F` などの本文、GraphQL の `mutation`）があれば、書き込みとして記録します（`plugins/dev-workflow/evals/lib/scaffold.bash`・`tests/eval/bin/fake-gh.sh`）。

```bash
tests/eval/run.sh --model sonnet                                        # 全部のケースを、プラグインあり・なしで3回ずつ
tests/eval/run.sh --model sonnet --tag task-create --runs 1 --ablation none  # 1つの場面を1回だけ（ケースを直している間）
```

- `tests/eval/run.sh` は、偽の gh を PATH の先頭に足し、準備のスクリプト（`--scaffold`）と Bash・Edit・Write の使用を許して、`claude plugin eval` を実行します。ほかのオプションはそのまま渡します（`claude plugin eval --help`）。
- 実行のたびに本物のモデルを呼ぶので、使っているプランの使用量（API キーなら料金）を消費します。全部のケースを既定のとおり動かすと、ケースの数 × 3回 × 2（プラグインあり・なし）だけ Claude を動かします。sonnet では1回あたり $0.1〜0.2 ほど（一覧の価格での見積もり）です。
- 結果は毎回少し揺れます。点が下がったら、出力の `Report:` のレポートで、どの grader が何を理由に落ちたかを見ます。結果は `plugins/dev-workflow/evals/results/` に出ます（git の対象外です）。
- Bash を許したケースは、Claude Code のサンドボックスの中でしか動きません。Linux では `bubblewrap` と `socat` を入れておきます（入っていないと、実行を断られます）。Ubuntu 24.04 以降では、AppArmor の設定も要ります（[サンドボックスのドキュメント](https://code.claude.com/docs/en/sandboxing)）。
- 最初の実行では、このディレクトリを信頼するかを聞かれます。

CI でも、Actions の画面から手で起動して実行できます（`.github/workflows/eval.yml`。シークレット `CLAUDE_CODE_OAUTH_TOKEN` を使います）。プランの使用量を消費するので、PR や push では自動で動かしません。必須のチェックでもありません。結果のレポートは、実行の artifact（`eval-results`）に残ります。
