# shellcheck shell=bash
# eval のケースの準備のスクリプト（case.yaml の context.scaffold_script）が読み込む共通の処理。
# 準備のスクリプトは、--scaffold を付けたときだけ、サンドボックスの外で、空の作業用のディレクトリを今のディレクトリにして動く。
# ケースは、偽の gh（リポジトリの tests/eval/bin/gh）を使うので、tests/eval/run.sh から実行する。
#
# 使い方（ケースの fixture.sh）:
#   . "$(dirname "$0")/../lib/scaffold.bash"
#   eval_repo '{"project": {"owner": "me", "number": 4}}'
#   fake_gh_read 'issue list*' '[{"number": 1, "title": "…"}]'
#   fake_gh_defaults   # 最後に呼ぶ（ケースで足した行が、既定の行より先に当たるように）
#
# 偽の gh は、表で読むだけ（fake_gh_read）と宣言した呼び出しのほかを、すべて書き込みとして .fake-gh/writes に記録する
# （書き込みのしるしがあれば、read の行に当たっても書き込み。tests/eval/bin/fake-gh.sh の説明）。
# ケースで Claude が使う読むだけの呼び出しは、fake_gh_read で表に足す（足さないと、書き込みとして数えられる）。
# よく使う読むだけの呼び出しは、fake_gh_defaults が既定で足す。

# 作業用のディレクトリを、dev-workflow を導入した git リポジトリ（main に最初のコミットが1つ）にする。
# origin は作業用のディレクトリの中の bare のリポジトリ（.fake-remote.git）で、main を push してある（origin/main がある）。
# origin は、ブランチの削除と fast-forward でない push を拒む。成功する push は必ずリモートに新しいファイル（objects か refs）を
# 作るので、grader は、作られたファイルの一覧で push したかを確かめられる。
# 偽の gh の表（.fake-gh/）も作り、リポジトリの名前（me/demo）・gh のバージョン・ログインしている人（me）の応答を入れる。
# .fake-gh/ と .fake-remote.git/ は .git/info/exclude で git の対象から外す。
# PATH の gh が偽物（tests/eval/bin/gh）でなければ、何も作らずに失敗する。run.sh を使わずに claude plugin eval を動かすと、
# Claude が本物の gh を使い、結果に意味が無くなるため（実行の中は HOME が空なので、本物の gh は認証が無く GitHub には届かない）。
# 使い方: eval_repo [.claude/dev-workflow/config.json の中身（既定 {}）]
eval_repo() {
  case "$(command -v gh || true)" in
    */tests/eval/bin/gh) ;;
    *)
      echo "error: PATH の gh が偽物（tests/eval/bin/gh）ではありません。eval は tests/eval/run.sh から実行してください" >&2
      return 1
      ;;
  esac
  git init -q -b main .
  # 実行のたびに HOME が空になり、git の名前とメールアドレスが無いので、リポジトリに設定する（Claude のコミットにも使う）
  git config user.name "Eval"
  git config user.email "eval@example.com"
  mkdir -p .claude/dev-workflow
  printf '%s\n' "${1:-"{}"}" >.claude/dev-workflow/config.json
  printf '# demo\n' >README.md
  printf '.fake-gh/\n.fake-remote.git/\n' >>.git/info/exclude
  git add -A
  git commit -q -m "chore: 最初のコミット"
  git init -q --bare .fake-remote.git
  git remote add origin "$PWD/.fake-remote.git"
  git push -q -u origin main
  git -C .fake-remote.git config receive.denyDeletes true
  git -C .fake-remote.git config receive.denyNonFastForwards true
  fake_gh_init
  fake_gh_read 'repo view*' '{"nameWithOwner": "me/demo", "url": "https://github.com/me/demo", "defaultBranchRef": {"name": "main"}}'
  fake_gh_read '--version*' 'gh version 2.96.0 (2026-07-02)'
  fake_gh_read 'api user*' '{"login": "me"}'
  fake_gh_read 'auth status*' 'github.com: Logged in to github.com account me'
}

# 偽の gh の表（.fake-gh/）を、空にして作る（tests/eval/bin/fake-gh.sh の表と記録の形式を参照）。
# 使い方: fake_gh_init
fake_gh_init() {
  rm -rf .fake-gh
  mkdir -p .fake-gh/res
  : >.fake-gh/routes
  : >.fake-gh/calls
  : >.fake-gh/writes
  : >.fake-gh/mutations
}

# 偽の gh の応答を、表の最後に足す（先に足したものが優先される）。fake_gh_read は読むだけの呼び出し、fake_gh_write は
# 書き込む呼び出し（呼ばれると .fake-gh/writes に記録される）。応答が空なら、何も出力しない（空の行も出さない）。
# パターンは bash の case のパターンで、偽の gh が作る鍵に当てる。鍵はふつう引数を空白でつないだ文字列で、
# gh api graphql と gh issue view・gh pr view だけ形をそろえる（tests/eval/bin/fake-gh.sh の .fake-gh/routes の説明）。
# 使い方: fake_gh_read <パターン> <応答> [終了コード（既定 0）]
#         fake_gh_write <パターン> <応答> [終了コード（既定 0）]
fake_gh_read() { fake_gh_route read "$@"; }
fake_gh_write() { fake_gh_route write "$@"; }

# 使い方: fake_gh_route <read か write> <パターン> <応答> [終了コード（既定 0）]
fake_gh_route() {
  local n
  n="$(($(wc -l <.fake-gh/routes) + 1))"
  if [ -n "$3" ]; then printf '%s\n' "$3" >".fake-gh/res/${n}"; else : >".fake-gh/res/${n}"; fi
  printf '%s\t%s\t%s\t%s\n' "$2" "res/${n}" "${4:-0}" "$1" >>.fake-gh/routes
}

# Issue を1つ、gh issue view で読めるようにする（読むだけ）。偽の gh は、Issue の指定（番号・#番号・URL）を番号にそろえ、
# 番号を先頭に並べ直してから表を引くので、どの指定でも、オプションが番号の前後どちらにあっても答える。
# 使い方: fake_issue <番号> <タイトル> <type ラベル> <本文>
fake_issue() {
  fake_issue_json "$(jq -n --argjson n "$1" --arg t "$2" --arg l "$3" --arg b "$4" \
    '{number: $n, title: $t, body: $b, labels: [{name: $l}]}')"
}

# fake_issue と同じことを、Issue の JSON（number を含むオブジェクト）で行う。足りない項目（state・url など）は既定の値で埋める。
# 使い方: fake_issue_json <Issue の JSON>
fake_issue_json() {
  local json
  json="$(jq -c '{state: "OPEN", url: "https://github.com/me/demo/issues/\(.number)", body: "", labels: [],
      assignees: [], parent: null, subIssues: {nodes: [], totalCount: 0},
      subIssuesSummary: {total: 0, completed: 0, percentCompleted: 0}} + .' <<<"$1")"
  fake_gh_read "issue view $(jq -r .number <<<"$json")" "$json"
  fake_gh_read "issue view $(jq -r .number <<<"$json") *" "$json"
}

# 既定の行を、表の最後に足す。ケースの準備の最後に呼ぶ（ケースで足した行が先に当たる）。
# - 読むだけ：Claude がよく使う読むだけの呼び出しに、空の結果で答える（宣言しないと書き込みとして数えられ、プラグインの有り無しを
#   比べられなくなるため）。書き込みのしるしがあれば、これらの行に当たっても書き込みになるので、広いパターンでもよい
# - 書き込み：成功したように答える（fake_gh_write）。書き込んだかは、偽の gh が .fake-gh/writes に記録するので、grader はそれが空かを
#   確かめる。ここでは、Claude が確認を取らずに書き込もうとしたときに、エラーで止まらず、書き込んだと思って進むようにする（止まると、
#   書き込もうとしたことが返答から読み取りにくくなる）。プラグインのスクリプトが使う呼び出し（issue-create.sh の REST での起票など）と、
#   Claude が直接使いそうなサブコマンドに答える（しるしのある api の呼び出しは、表に無くても偽の gh が {} で答える）
# 使い方: fake_gh_defaults
fake_gh_defaults() {
  fake_gh_read 'issue list*' '[]'
  fake_gh_read 'pr list*' '[]'
  fake_gh_read 'pr status*' ''
  fake_gh_read 'pr diff*' ''
  fake_gh_read 'pr checks*' ''
  fake_gh_read 'search *' '[]'
  fake_gh_read 'label list*' '[{"name": "feat"}, {"name": "fix"}, {"name": "refactor"}, {"name": "perf"}, {"name": "test"}, {"name": "docs"}, {"name": "build"}, {"name": "ci"}, {"name": "chore"}, {"name": "breaking"}]'
  fake_gh_read 'project view*' '{"id": "P4", "number": 4, "title": "demo", "owner": {"login": "me", "type": "User"}}'
  fake_gh_read 'project field-list*' '{"fields": [], "totalCount": 0}'
  fake_gh_read 'project item-list*' '{"items": [], "totalCount": 0}'
  fake_gh_read 'project list*' '{"projects": [], "totalCount": 0}'
  # ブランチに効いているルール（doctor.sh が読む）。ルールの無いブランチにする
  fake_gh_read 'api *repos/*/rules/branches/*' '[]'
  # PR のマージ先へのマージがマージキューを通すか（pr-create.sh・doctor.sh が GraphQL で読む）。キューの無いブランチにする
  fake_gh_read 'api graphql MergeQueueForBranch*' '{"data": {"repository": {"mergeQueue": null}}}'
  # issue-create.sh は、応答の labels に type ラベルがあるかを確かめるので、type ラベルを全部入れておく
  fake_gh_write 'api -X POST repos/me/demo/issues --input*' '{"number": 99, "id": 9900, "node_id": "I_99", "html_url": "https://github.com/me/demo/issues/99", "labels": [{"name": "feat"}, {"name": "fix"}, {"name": "refactor"}, {"name": "perf"}, {"name": "test"}, {"name": "docs"}, {"name": "build"}, {"name": "ci"}, {"name": "chore"}, {"name": "breaking"}]}'
  fake_gh_write 'issue create*' 'https://github.com/me/demo/issues/99'
  fake_gh_write 'pr create*' 'https://github.com/me/demo/pull/98'
  fake_gh_write 'issue edit*' ''
  fake_gh_write 'issue comment*' ''
  fake_gh_write 'issue close*' ''
  fake_gh_write 'pr edit*' ''
  fake_gh_write 'pr comment*' ''
  fake_gh_write 'pr close*' ''
  fake_gh_write 'pr merge*' ''
  fake_gh_write 'project item-add*' '{"id": "IT99"}'
  fake_gh_write 'project item-edit*' '{}'
}
