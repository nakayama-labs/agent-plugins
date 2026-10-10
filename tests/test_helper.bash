# shellcheck shell=bash
# テスト共通の準備。一時ディレクトリに git リポジトリとユーザー設定の置き場所を作る。
# TEST_BASH でスクリプトを実行する bash を指定できる（例: macOS の /bin/bash 3.2）。

SCRIPTS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts"
# 偽の gh から読み込む、GitHub Project の部分（fake_gh_project.bash を参照）
export FAKE_GH_PROJECT="$BATS_TEST_DIRNAME/fake_gh_project.bash"

# assert_success・assert_equal などを使う（git submodule で同梱。git submodule update --init で取得する）
load lib/bats-support/load
load lib/bats-assert/load

# 一時ディレクトリに git リポジトリを作って、そこに移る。独自の setup() から呼べるよう、名前を付けてある
test_helper_setup() {
  # macOS の /var は /private/var へのシンボリックリンクなので、git が返すパスと揃えるため実体にする
  TMP="$(CDPATH='' cd "$(mktemp -d)" && pwd -P)"
  REPO="$TMP/repo"
  export WORKFLOW_USER_DIR="$TMP/user"
  # CI やコンテナには git の名前とメールアドレスが無いので、テストでコミットできるよう決めておく
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$REPO/.claude/dev-workflow" "$WORKFLOW_USER_DIR"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  cd "$REPO" || return 1
}

# <リポジトリのルート>（既定は REPO）を、プラグインを導入したリポジトリにする（チームの設定を空で作る）。
# 導入していないリポジトリでは、フックは何もせず、ユーザーの層も読まない（dw_is_set_up）
# 使い方: mark_set_up [リポジトリのルート]
mark_set_up() {
  mkdir -p "${1:-$REPO}/.claude/dev-workflow"
  [ -f "${1:-$REPO}/.claude/dev-workflow/config.json" ] || echo '{}' >"${1:-$REPO}/.claude/dev-workflow/config.json"
}

# REPO をホームのリポジトリにする。ユーザーの層の置き場所（WORKFLOW_USER_DIR）を、チームの設定の置き場所
# （$REPO/.claude/dev-workflow。dotfiles を ~/.git で管理するときの ~/.claude/dev-workflow と同じ関係）にそろえる
# 使い方: make_home_repo
make_home_repo() {
  export WORKFLOW_USER_DIR="$REPO/.claude/dev-workflow"
  mkdir -p "$WORKFLOW_USER_DIR"
}

# サブモジュール（$TMP/super/sm。中身は REPO）を作る
make_submodule() {
  git init -q -b main "$TMP/super"
  git -C "$TMP/super" commit -q --allow-empty -m init
  git -C "$TMP/super" -c protocol.file.allow=always submodule add -q "$REPO" sm
}

# 署名と検証をまねる偽の gpg を、リポジトリ（既定は今のリポジトリ）で使うようにする。検証では、本物の gpg と同じく
# 「gpg:」で始まる行を出すので、log.showSignature を有効にすると、git log の出力に混ざる
# 使い方: use_fake_gpg [リポジトリ]
use_fake_gpg() {
  local repo="${1:-.}"
  cat >"$TMP/fake-gpg" <<'SH'
#!/bin/sh
case " $* " in
  *" --verify "*) echo "gpg: Signature made (fake)" >&2; exit 0 ;;
  *) cat >/dev/null; echo "[GNUPG:] SIG_CREATED " >&2
     printf '%s\n' '-----BEGIN PGP SIGNATURE-----' '' 'ZmFrZQ==' '-----END PGP SIGNATURE-----' ;;
esac
SH
  chmod +x "$TMP/fake-gpg"
  git -C "$repo" config gpg.program "$TMP/fake-gpg"
  git -C "$repo" config user.signingkey fake
}

# ブランチ <名前> の先に、件名の長いコミットを <件数> だけ fast-import で一度に作る（コミットの一覧を長くするため）。
# 作業ツリーは変えない
# 使い方: make_commits <ブランチ> <件数> [リポジトリ]
make_commits() {
  local branch="$1" n="$2" repo="${3:-.}" title parent i msg
  title="$(printf 'x%.0s' $(seq 1 100))"
  parent="$(git -C "$repo" rev-parse "refs/heads/$branch")"
  for i in $(seq 1 "$n"); do
    msg="feat: $i $title"
    printf 'commit refs/heads/%s\nmark :%d\ncommitter t <t@t> 0 +0000\ndata %d\n%s\nfrom %s\n\n' "$branch" "$i" "${#msg}" "$msg" "$parent"
    parent=":$i"
  done | git -C "$repo" fast-import --quiet --force
}

# 引数1つの長さの上限（Linux の MAX_ARG_STRLEN、128 KiB）を超える長さの文を、ファイル <パス> に書く（改行は付けない）。
# 日本語は UTF-8 で1文字3バイトなので、6万文字で 180KB ほどになる。jq には --rawfile で読ませる（引数で渡すと、テストの側で止まる）
# 2つ目の引数で、繰り返す文字を変えられる（絵文字のような BMP の外の文字も試すとき）
# 使い方: long_text <パス> [繰り返す文字（既定: あ）]
long_text() { head -c 60000 /dev/zero | tr '\0' x | sed "s/x/${2:-あ}/g" | tr -d '\n' >"$1"; }

# 引数が環境変数 FAIL_GIT の形（case のパターン。前後に空白を足した引数の並びと照らす）に当たる呼び出しだけを
# 失敗させる偽の git を $TMP/failgit に作る。PATH の先頭に足して使う（FAIL_GIT が空なら、どれも本物の git に渡す）
# パターンは変数で渡るので、引用符は文字として扱われる。空白も含めて、引用符を使わずに書く
# 使い方: make_failing_git → PATH="$TMP/failgit:$PATH" FAIL_GIT='* rev-list [!-]*' run_script ...
make_failing_git() {
  local real
  real="$(command -v git)"
  mkdir -p "$TMP/failgit"
  cat >"$TMP/failgit/git" <<SH
#!/bin/sh
if [ -n "\$FAIL_GIT" ]; then
  case " \$* " in
    \$FAIL_GIT) echo "fatal: failed (fake)" >&2; exit 128 ;;
  esac
fi
exec "$real" "\$@"
SH
  chmod +x "$TMP/failgit/git"
}

setup() {
  test_helper_setup
}

teardown() {
  rm -rf "$TMP"
}

run_script() {
  local name="$1"
  shift
  run "${TEST_BASH:-bash}" "$SCRIPTS/$name" "$@"
}

# 'ab😀' を <回数> だけ並べた文字列を出力する。1周が6バイトなので、約 4096 バイトごとの読み込みの区切りに、
# BMP の外の文字（絵文字。4バイト）がまたがる。jq -R で読むと壊れる入力を作るのに使う（約 4096 バイトより長くなる回数にする）
# 使い方: text="$(emoji_text 1500)"
emoji_text() {
  local i
  for ((i = 0; i < $1; i++)); do printf 'ab😀'; done
}
