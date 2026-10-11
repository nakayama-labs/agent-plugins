#!/usr/bin/env bats
# main を守るフック（hooks/guard-git.sh）。
# bats はテストごとにサブシェルで動くので、変数（HOME など）の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

# フックは導入したリポジトリでだけ動くので、テストのリポジトリを導入したことにする
setup() {
  test_helper_setup
  mark_set_up
}

# フックの入力（JSON）を作って渡す。cwd は既定で今のディレクトリ
# 使い方: run_hook <コマンド> [cwd]
run_hook() {
  jq -n --arg c "$1" --arg d "${2:-$PWD}" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/guard-git.sh" <"$TMP/input.json"
}

# 通すコマンド
allowed() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（${status}）: $c / $output"
  done
}

# 止めるコマンド。使い方: denied <理由の一部> <コマンド>...
denied() {
  local msg="$1" c
  shift
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 2 ] || fail "止めなかった（${status}）: $c"
    assert_output --partial "$msg"
  done
}

# ブランチ名を警告するコマンド。コマンドは止めず、使用者と Claude の両方に警告を伝える
# 使い方: warned <名前> <コマンド>...
warned() {
  local name="$1" c
  shift
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（${status}）: $c / $output"
    # 1コマンドごとの jq の起動を減らすため、検査は1回の jq にまとめる（JSON でない出力も、ここで失敗する）
    jq -e --arg n "ブランチ名 ${name} は規約に合いません" '
      .hookSpecificOutput.hookEventName == "PreToolUse"
      and .hookSpecificOutput.permissionDecision == null
      and .systemMessage == .hookSpecificOutput.additionalContext
      and (.systemMessage | contains($n))
    ' <<<"$output" >/dev/null || fail "警告が期待どおりでない（JSON、hookEventName、permissionDecision なし、systemMessage と additionalContext の一致、名前）: $c / $output"
  done
}

# 何も出さずに通すコマンド
silent() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（${status}）: $c / $output"
    [ -z "$output" ] || fail "何か出した: $c / $output"
  done
}

@test "hooks.json は Bash の前にフックを呼び、呼ぶスクリプトがある" {
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$HOOKS/hooks.json"
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS/hooks.json"
  # ${CLAUDE_PLUGIN_ROOT} は Claude Code が置き換える文字なので、そのまま比べる
  # shellcheck disable=SC2016
  assert_output 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-git.sh"'
  [ -f "$HOOKS/guard-git.sh" ]
}

@test "git を使わないコマンドは通す" {
  allowed "ls -la" "echo hello" ""
}

@test "main の上での commit を止める" {
  denied "main の上ではコミットしません" \
    "git commit -m x" \
    "git add a && git commit -m x" \
    "FOO=1 git commit --amend" \
    "git -c user.name=t commit -m x" \
    "git commit -m x 2>&1 | tail -1"
}

@test "作業用のブランチの上の commit は通す" {
  git checkout -q -b feat/21-x
  allowed "git commit -m x" "git commit -m 'fix: main'"
}

@test "main の上でも commit 以外の git の操作は通す" {
  allowed "git status" "git log --oneline -3" "git pull --ff-only" "git fetch origin" "git switch -c feat/21-x"
}

@test "cd や -C で移った先のブランチで判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "cd $TMP/wt && git commit -m x" "git -C $TMP/wt commit -m x" "cd ../repo/../../${TMP##*/}/wt; git push"
  cd "$TMP/wt"
  denied "main の上ではコミットしません" "cd $REPO && git commit -m x" "git -C $REPO commit -m x" "git -C ../repo commit -m x"
}

@test "base_branch の設定に従う" {
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  allowed "git commit -m x" "git push origin HEAD:main"
  git checkout -q -b develop
  denied "develop の上ではコミットしません" "git commit -m x"
  denied "develop へは push しません" "git push"
}

@test "個人の層の base_branch が使えない値なら、チームの設定の base_branch を守る（main に変えない）" {
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  echo '{"base_branch": "-foo"}' >.claude/dev-workflow/config.local.json
  git checkout -q -b develop
  denied "develop の上ではコミットしません" "git commit -m x"
  denied "develop へは push しません" "git push"
}

@test "末尾に改行のある base_branch は、改行を消して使わず、使えない値として扱う" {
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  printf '%s\n' '{"base_branch": "release\n"}' >.claude/dev-workflow/config.local.json
  git checkout -q -b develop
  denied "develop の上ではコミットしません" "git commit -m x"
  # ユーザーの層の値も同じ（ルートが分からず、チームの設定が値を決めていないとき）
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mkdir -p "$TMP/sep/.claude/dev-workflow"
  echo '{}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  printf '%s\n' '{"base_branch": "release\n"}' >"$WORKFLOW_USER_DIR/config.json"
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
}

@test "チームの設定の base_branch も使えない値なら、止まらずに main を守る" {
  echo '{"base_branch": "-foo"}' >.claude/dev-workflow/config.json
  denied "main の上ではコミットしません" "git commit -m x"
  denied "main へは push しません" "git push"
  warned foo "git switch -c foo"
}

@test "HEAD にコミットしたチームの設定の base_branch が使えない値なら、main を守る" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mark_set_up "$TMP/sep"
  echo '{"base_branch": "-foo"}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  # チームの設定に値があれば、使えなくてもユーザーの層の値には進まない（develop ではなく main を守る）
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  # false も値として扱う（「値が無い」とみなさない）
  echo '{"base_branch": false}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" commit -q -am false
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  # 壊れていても、ユーザーの層の値には進まない（ルートが分かるときと同じく main を守る）
  for c in '{broken' '[]' ''; do
    printf '%s' "$c" >"$TMP/sep/.claude/dev-workflow/config.json"
    git -C "$TMP/sep" commit -q -am "broken: $c"
    denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  done
  # 値が無いときだけ、ユーザーの層の値を守る
  echo '{}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" commit -q -am none
  silent "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  # ユーザーの層も、JSON のオブジェクト1つとして読めなければ使わない（複数の値が並んでいても読まない）
  echo '{"base_branch": "develop"}{}' >"$WORKFLOW_USER_DIR/config.json"
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
}

@test "チームの設定の base_branch が使えなければ、個人の層が上書きしていても、その値ではなく main を守る" {
  echo '{"base_branch": "-foo"}' >.claude/dev-workflow/config.json
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.local.json
  denied "main の上ではコミットしません" "git commit -m x"
}

@test "main への push を止める" {
  denied "main へは push しません" \
    "git push" \
    "git push origin" \
    "git push -u origin HEAD" \
    "git push origin main" \
    "git push origin feat/21-x:main" \
    "git push origin HEAD:refs/heads/main" \
    "git push origin --delete main"
  git checkout -q -b feat/21-x
  denied "main へは push しません" "git push origin main" "git push origin HEAD:main" "git push origin -- main"
}

@test "作業用のブランチの push は通す" {
  git checkout -q -b feat/21-x
  allowed "git push" "git push -u origin HEAD" "git push origin feat/21-x" "git push -o ci.skip origin feat/21-x" \
    "git push --force-with-lease" "git push --force-with-lease=feat/21-x origin HEAD" "git push --force-if-includes --force-with-lease"
}

@test "main の上でも、別のブランチを明示した push は通す" {
  allowed "git push origin feat/21-x" "git push origin --delete feat/21-x"
}

@test "強制 push を止める（--force-with-lease は通す）" {
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "git push --force" \
    "git push -f" \
    "git push -uf origin HEAD" \
    "git push origin +feat/21-x" \
    "git push origin +HEAD:feat/21-x" \
    "git push --force-with-lease --force" \
    "git push --mirror"
}

@test "git push の値を取るオプションの値（次の語）を、リモートや refspec と読まない" {
  # main の上で refspec を書かない push。値（check）をリモートと読むと、origin を refspec と読んで通してしまう
  denied "main へは push しません" "git push --recurse-submodules check origin" "git push --recurse-submodules check"
  git checkout -q -b feat/21-x
  denied "main へは push しません" \
    "git push --recurse-submodules check origin main" \
    "git push --recurse-submodules=check origin main" \
    "git push --repo origin origin main" \
    "git push --receive-pack git-receive-pack origin main" \
    "git push --exec git-receive-pack origin main" \
    "git push --push-option x origin main"
  allowed "git push --recurse-submodules check origin feat/21-x"
}

@test "git push の長いオプションを略して書いても、git と同じに読む" {
  git checkout -q -b feat/21-x
  # --mirr・--m は --mirror、--recu は --recurse-submodules（値を取る）
  denied "強制 push" "git push --mirr" "git push --m origin"
  denied "main へは push しません" "git push --recu check origin main" "git push --rep origin origin main" \
    "git push --e git-receive-pack origin main"
  git checkout -q main
  denied "main へは push しません" "git push --recu check origin"
  git checkout -q feat/21-x
  # --force-w は --force-with-lease
  allowed "git push --force-w" "git push --force-with origin feat/21-x"
}

@test "git の値を取るグローバルオプション（--attr-source・--shallow-file）の値を、サブコマンドと読まない" {
  git checkout -q -b feat/21-x
  denied "強制 push" "git --attr-source HEAD push -f" "git --shallow-file x push -f"
}

@test "引用符・ヒアドキュメント・コメントの中の文字は、コマンドとみなさない" {
  git checkout -q -b feat/21-x
  allowed \
    "echo 'git push --force'" \
    "echo \"a; git push -f\"" \
    "git commit -m 'docs: git push -f を止める'" \
    "ls # git push -f" \
    "$(printf 'git commit -F - <<EOF\nfix: x\ngit push --force\nEOF\ngit push')" \
    "$(printf "git commit -m \"\$(cat <<'EOF'\nfix: don't (git push -f)\nEOF\n)\" && git push -u origin HEAD")"
}

@test "if・for・{ }・! の中のコマンドも調べる" {
  denied "強制 push" "if true; then git push --force; fi" "{ git push --force; }" "! git push -f" \
    "while false; do :; done && until true; do git push -f; done"
  denied "main の上ではコミットしません" "for b in a; do git commit -m x; done" "if false; then :; else git commit -m x; fi"
}

@test "( ) の中の cd は、括弧の外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "(cd $TMP/wt && git status); git commit -m x" "(cd $TMP/wt) && git commit -m x"
  allowed "(cd $TMP/wt && git commit -m x)" "cd $TMP/wt && (git status) && git commit -m x"
}

@test "パイプラインの各コマンドと、& でバックグラウンドで動かす並びの cd・pushd・popd は、外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "cd ../wt | true; git commit -m x" "cd $TMP/wt & git commit -m x" \
    "pushd $TMP/wt | cat; git commit -m x" "true | cd $TMP/wt; git commit -m x" "cd $TMP/wt && true & git commit -m x" \
    "cd $TMP/wt |& cat; git commit -m x" "pushd $TMP/wt && popd | cat && popd; git commit -m x"
  allowed "cd $TMP/wt && git commit -m x | cat" "cd $TMP/wt; true & git commit -m x" "pushd $TMP/wt && popd | cat && git commit -m x" \
    "cd $TMP/wt && true | true; git commit -m x" "true | true; cd $TMP/wt && git commit -m x"
  # || はパイプではない（a || b | c の | は b と c のパイプライン）
  allowed "cd $TMP/wt || true; git commit -m x" "cd $TMP/wt || true | cat; git commit -m x"
  denied "main の上ではコミットしません" "cd $TMP/wt | true || true; git commit -m x"
  # 語のあるコマンドで終わった並びの後の改行では、新しい並びを始める（& で戻す先は、その並びの始まり）
  allowed "$(printf 'cd %s && true\ntrue & git commit -m x' "$TMP/wt")"
  # & を含むリダイレクト（&>）、&& の後の改行、case の ;& は、バックグラウンドやパイプではない
  allowed "cd $TMP/wt &> /dev/null && git commit -m x" "$(printf 'cd %s &&\ngit commit -m x' "$TMP/wt")" \
    "case x in x) cd $TMP/wt ;& y) : ;; esac; git commit -m x"
}

@test "パイプラインや & の中の複合コマンド（{ }・ループ・if）は、全体を1つのコマンドとして扱う" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "{ cd $TMP/wt; } & git commit -m x" "{ cd $TMP/wt; } | cat; git commit -m x" \
    "while true; do cd $TMP/wt; break; done | cat; git commit -m x" "if true; then cd $TMP/wt; fi | cat; git commit -m x"
  # { } の中の ; でコマンドごとに戻すと、{ } の中の cd の後の commit を、cd の前の場所で判断してしまう
  denied "main の上ではコミットしません" "cd $TMP/wt; true | { cd $REPO; git commit -m x; }" \
    "cd $TMP/wt; true | { cd $REPO; git commit -m x; } && :"
  allowed "true | { cd $TMP/wt; git commit -m x; }" "true | (cd $TMP/wt; git commit -m x)" \
    "{ cd $TMP/wt; } && git commit -m x" "if true; then cd $TMP/wt; fi; git commit -m x"
}

@test "case のパターンの | ( ) はパイプやサブシェルではなく、パターンの語はコマンドとして調べない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  export HOME="$TMP/wt"
  denied "main の上ではコミットしません" "cd $TMP/wt; case x in a|x) cd $REPO && git commit -m x;; esac" \
    "cd $TMP/wt; case x in a|x) cd $REPO;; esac; git commit -m x" "case x in a) :;; cd) :;; esac; git commit -m x" \
    "cd $TMP/wt; case x in (a|x) cd $REPO;; esac; git commit -m x"
  # 1行の空の case は、すぐに閉じる（その後のコマンドを、パターンと読まない）
  denied "main の上ではコミットしません" "case x in esac; git commit -m x" "$(printf 'case x in esac\ngit commit -m x')"
  # time case も case として入れ子を数える（( ) の中のパターンの ) で、括弧を閉じない）
  denied "main の上ではコミットしません" "( time case x in x) cd $TMP/wt;; esac ); git commit -m x"
  allowed "time case x in x) cd $TMP/wt;; esac; git commit -m x"
}

@test "function f { } の { } も、複合コマンドとして入れ子を数える。time -p の後の { } も数える" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "{ function f { :; }; cd $TMP/wt; } | cat; git commit -m x" \
    "time -p { cd $TMP/wt; } | cat; git commit -m x" "time -- { cd $TMP/wt; } | cat; git commit -m x" \
    "time -p -- { cd $TMP/wt; } | cat; git commit -m x"
}

@test "関数の定義の名前はコマンドとして調べず、本体はその場で動いた複合コマンドとして読む" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  # cd() { … } の cd は移動ではない。定義した関数を呼べば、本体の cd が動く
  denied "main の上ではコミットしません" "cd() { :; }; git commit -m x" "cd $TMP/wt; f() { cd $REPO; }; f; git commit -m x"
  allowed "f() { cd $TMP/wt; }; f; git commit -m x"
  # 本体の中の git も調べる（function f { … } の1行の書き方も）。x=() は空の配列の代入で、関数の定義ではない
  denied "強制 push" "f() { git push -f; }" "function f { git push -f; }"
  allowed "x=(); { cd $TMP/wt; }; git commit -m x"
}

@test "語の無いコマンド（(( ))）の後でも、パイプラインと並びの区切りを正しく読む" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  # (( )) で終わるパイプラインの後の cd を戻さない。&& (( )) の後の改行では、新しい並びを始める
  denied "main の上ではコミットしません" "cd $TMP/wt; true | ((1)); cd $REPO && git commit -m x" \
    "$(printf 'cd %s; cd %s && ((1))\ntrue & git commit -m x' "$TMP/wt" "$REPO")"
}

@test "case のパターンの ) は括弧を閉じない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "(case x in a) :;; esac; cd $TMP/wt); git commit -m x" \
    "(case x in (a) :;; b) (cd /tmp);; esac; cd $TMP/wt); git commit -m x"
  allowed "(case x in a) :;; esac; cd $TMP/wt && git commit -m x)"
}

@test "算術式の << はヒアドキュメントとみなさない" {
  git checkout -q -b feat/21-x
  # $((...)) はフックに渡す文字として書く
  # shellcheck disable=SC2016
  denied "強制 push" "$(printf 'x=$((1<<2))\ngit push --force')" "$(printf '(( x = 1 << 2 ))\ngit push --force')" \
    "$(printf '((x = (1 + 2) << 3))\ngit push --force')"
}

@test "(( で始まる入れ子のサブシェルは、算術式とみなさずに調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "((git push -f) || true)" "((cd /tmp && ls) && git push -f)"
}

@test "長いコマンドでも速く終わる" {
  git checkout -q -b feat/21-x
  msg="$(head -c 50000 /dev/zero | tr '\0' a | fold -w 76)"
  words="$(printf 'w%d ' $(seq 1 10000))"
  # 壁時計の10秒は、bats を並列に実行すると CPU の取り合いで延びて落ちた（#125）。
  # 解析そのものの重さを見るために、フックを動かす間の CPU 時間（ユーザー + システム。子プロセスを含む）で測る。
  # CPU を使わない待ちや停止は見えないので、壁時計にも大きめの上限を置く
  local TIMEFORMAT='%U %S' c
  : >"$TMP/cpu"
  SECONDS=0
  for c in "git commit -m \"$msg\"; git push -f" "echo $words; git push -f" \
    "$(printf 'git commit -F - <<EOF\n%s\nEOF\ngit push -f' "$msg")"; do
    { time run_hook "$c"; } 2>>"$TMP/cpu"
    [ "$status" -eq 2 ] || fail "止めなかった（${status}）: ${c:0:80}"
    assert_output --partial "強制 push"
  done
  local cpu
  cpu="$(awk '{ t += $1 + $2 } END { printf "%.1f", t }' "$TMP/cpu")"
  awk -v t="$cpu" 'BEGIN { exit !(t < 10) }' || fail "CPU 時間で ${cpu} 秒かかった"
  [ "$SECONDS" -lt 120 ] || fail "壁時計で ${SECONDS} 秒かかった"
}

@test "ヒアドキュメントの後ろのコマンドは調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "$(printf 'git commit -F - <<EOF\nfix: x\nEOF\ngit push -f')"
}

@test "対象のリポジトリが分からないときは、コミットと push 先を書かない push を止め、対象の書き直し方を案内する" {
  # 導入していない設定でも、ディレクトリが分からない cd の後も、リポジトリの外も、今のブランチを読めない
  denied "対象のリポジトリが分からない" \
    "cd - && git commit -m x" "cd \$SOMEWHERE && git commit -m x" "cd $TMP && git commit -m x" \
    "cd - && git push" "cd \$SOMEWHERE && git push origin" "cd $TMP && git push"
  denied "git -C <絶対パス>" "cd - && git commit -m x"
  # HEAD・@ への push も、今のブランチを読めないので止める。HEAD:feat/x のように先の名前を書けば判断できる
  denied "対象のリポジトリが分からない" "cd - && git push origin HEAD" "cd - && git push origin @"
  allowed "cd - && git push origin HEAD:feat/x"
  # ":" は matching refspec（同じ名前のブランチをすべて push する）なので、対象が分からなくても止める
  denied "matching refspec" "cd - && git push origin :"
  denied "main へは push しません" "cd - && git push origin HEAD:main"
  # push 先を書いた push は、書かれた先で判断できる
  allowed "cd - && git push origin feat/1-x"
  denied "main へは push しません" "cd - && git push origin main"
  # 対象を書き直せば、そのリポジトリで判断する
  git checkout -q -b feat/1-x
  allowed "cd - && git -C $REPO commit -m x" "cd - && git -C $REPO push" "cd - && git -C $REPO push origin HEAD"
}

@test "同じコマンドの中で git init で作るリポジトリは、導入していないので、cd・-C で移った後のコミットを止めない" {
  silent "git init proj && cd proj && git commit -m x" "git init -q -b main proj; cd proj; git commit -m x" \
    "git init $TMP/new && cd $TMP/new && git commit -m x" \
    "git init proj && git -C proj commit -m x" "git init proj && cd proj/ && git push -f origin main" \
    "git -C $TMP init --template=x new && cd $TMP/new && git commit -m x" "git init proj && cd proj && mkdir a && cd a/.. && git commit -m x"
  # 既にあるディレクトリでも、リポジトリのルートでなければ、git init は新しいリポジトリを作る
  mkdir sub
  silent "git init sub && cd sub && git commit -m x" "cd sub && git init && git commit -m x"
  # 既にあるリポジトリのルートでの git init は、作り直すだけなので、そのリポジトリで判断する
  denied "main の上ではコミットしません" "git init && git commit -m x" "git init . && git commit -m x" "git init $REPO && cd $REPO && git commit -m x"
  # git init で作った場所と関係のない場所は、今までどおり判断する
  denied "main の上ではコミットしません" "git init proj && git commit -m x" "git init proj && cd proj && cd $REPO && git commit -m x"
}

@test "既にあるリポジトリの配下での git init は、成功した前提の && の並びでだけ新しいリポジトリとみなす" {
  mkdir sub
  silent "git init sub && cd sub && git commit -m x" "cd sub && git init && git commit -m x"
  # init が失敗しても動く後ろは、親のリポジトリで判断する
  denied "main の上ではコミットしません" "cd sub && git init; git commit -m x" \
    "git init sub; git -C sub commit -m x" "git init sub && cd sub; git commit -m x" \
    "cd sub && git init || git commit -m x" "$(printf 'cd sub && git init\ngit commit -m x')" \
    "cd sub && git init & git commit -m x"
  denied "強制 push" "cd sub && git init; git push --force origin main"
  # リポジトリの外の既にあるディレクトリは、親のリポジトリを使うことがない
  mkdir "$TMP/outside"
  silent "git init $TMP/outside; git -C $TMP/outside commit -m x"
}

@test "git init した場所の配下や、--git-dir・GIT_DIR で別のリポジトリを指した git は、新しいリポジトリとみなさない" {
  # 外側に git init しても、内側の既にあるリポジトリ（main の上）の git は、そのリポジトリを使う
  denied "main の上ではコミットしません" "git init .. && git commit -m x" "git init $TMP && git commit -m x" \
    "git init $TMP && cd $TMP/repo && git commit -m x"
  denied "強制 push" "git init .. && git push --force origin main"
  denied "main へは push しません" "git init $TMP && git push"
  # まだ無い場所の配下は、作る場所と同じではないので、分からないものとする
  denied "対象のリポジトリが分からない" "git init proj && cd proj/sub && git commit -m x"
  # 作った場所でも、--git-dir・GIT_DIR で別のリポジトリを指せば、そのリポジトリを使う（作る前なので、場所が分からない）
  denied "コミットは止めます" "git init $TMP/n && git -C $TMP/n --git-dir=$REPO/.git commit -m x" \
    "git init $TMP/n && cd $TMP/n && GIT_DIR=$REPO/.git git commit -m x"
}

@test "同じコマンドの中で git clone するリポジトリは、まだ無くて調べられないので、cd・-C で移った後のコミットを止める" {
  denied "git clone" "git clone $REPO d && cd d && git commit -m x" "git clone https://example.com/me/demo.git && cd demo && git commit -m x" \
    "git clone -b main --depth 1 git@example.com:me/demo && cd demo && git commit -m x" "git clone $REPO d && git -C d push" \
    "git clone --bare $REPO && cd repo.git && git commit -m x" "git clone -- $REPO d/ && cd d && git commit -m x"
  # push 先を書いた push は、書かれた先で判断する
  allowed "git clone $REPO d && cd d && git push origin feat/1-x"
  denied "main へは push しません" "git clone $REPO d && cd d && git push origin main"
}

@test "mkdir だけで git init の無いディレクトリへの cd の後は、どのリポジトリに入るか分からないので、コミットを止める" {
  denied "対象のリポジトリが分からない" "mkdir d && cd d && git commit -m x" "mkdir -p a/b && cd a/b && git commit -m x" \
    "git init proj && cd proj2 && git commit -m x"
  # 移った先がまだ無いことを、理由で伝える
  denied "はまだ無く" "mkdir d && cd d && git commit -m x"
  # まだ無いディレクトリへの cd が失敗しても動く後ろ（; ・ || ・改行）では、cd は移らなかったかもしれない
  # （cd /x/nope; git init は、今のリポジトリを作り直す）ので、git init の後でも分からないものとする
  denied "対象のリポジトリが分からない" "cd $TMP/nope; git init; git commit -m x" "mkdir d && cd d; git init && git commit -m x" \
    "cd $TMP/nope || git init && git commit -m x" "$(printf 'cd %s\ngit init && git commit -m x' "$TMP/nope")"
}

@test "まだ無いディレクトリへの cd の後ろで覚えた作る場所は、cd が失敗しても動く後ろでは使わない" {
  # cd が失敗すると、&& でつないだ git init は動かず、; などの後ろの git commit は今のリポジトリ（main）で動く
  # （cd が成功したかは分からないので、今の場所は分からないものとして止める）
  denied "コミット" "cd $TMP/nope && git init; git commit -m x" \
    "$(printf 'cd %s && git init\ngit commit -m x' "$TMP/nope")" \
    "if cd $TMP/nope && git init; then :; fi; git commit -m x" "cd $TMP/nope && git init || true; git commit -m x" \
    "cd $TMP/nope && git init & git commit -m x"
  # 移った先にとどまる書き方も、cd が失敗したかもしれないので分からないものとする
  denied "対象のリポジトリが分からない" "cd $TMP/nope && git init; cd $TMP/nope; git commit -m x"
  # 前提の無いところで覚えた作る場所は、境目を越えても使う
  silent "git init proj; cd proj; git commit -m x" "mkdir d && cd d && git init && git commit -m x" \
    "git init proj && cd proj && git init sub; cd sub; git commit -m x"
}

@test "! の付いた cd がまだ無いディレクトリを指すときは、失敗しても後ろが動くので、今の場所を分からないものとする" {
  git checkout -q -b feat/1-x
  # cd nope が失敗すると、cd .. は REPO の外へ移るので、nope/..（REPO）とは言えない
  denied "対象のリポジトリが分からない" "! cd nope && cd .. && git commit -m x" "! pushd nope && cd .. && git commit -m x"
  allowed "! cd $TMP && cd repo && git commit -m x"
}

@test "まだ無いディレクトリへの cd の後も、&& でつないだ後ろでは、文字の上のパスで追い続ける" {
  git checkout -q -b feat/1-x
  # cd .. で既にある場所へ戻れば、そのリポジトリで判断する
  allowed "mkdir build && cd build && cd .. && git commit -m x" "mkdir -p a/b && cd a/b && cd ../.. && git commit -m x"
  # git init が作る場所へ、途中のディレクトリを通って移っても、新しいリポジトリとみなす
  silent "git init a/b && cd a && cd b && git commit -m x" "mkdir -p $TMP/z && cd $TMP/z && git init && git commit -m x" \
    "mkdir d && cd d && git init && git commit -m x" "git init proj; cd proj; git commit -m x"
  denied "main へは push しません" "mkdir build && cd build && cd .. && git push origin main"
}

@test "対象のリポジトリが分からないときも、コミット・push 以外は止めない" {
  allowed "cd - && git switch -c feat/x" "cd - && git checkout -b feat/x" "cd - && git branch feat/x"
}

# 今のブランチで、追跡しているファイル f を変えて stash を作る。使い方: make_stash [メッセージ]
make_stash() {
  [ -f f ] || { echo a >f && git add f && git commit -q -m f; }
  echo "$RANDOM" >>f
  if [ $# -gt 0 ]; then git stash push -q -m "$1"; else git stash -q; fi
}

@test "別のブランチで作った stash の取り出し・破棄（pop・apply・drop・branch）を止める" {
  make_stash
  git checkout -q -b feat/1-x
  denied "別のブランチ（main）で作られた stash" "git stash pop" "git stash apply" "git stash drop" "git stash pop 0" \
    "git stash pop --index stash@{0}" "git stash apply -q 'stash@{0}'" "git stash drop -q stash@{0}" \
    "git stash branch feat/2-y" "git stash branch feat/2-y stash@{0}" "git stash pop -- 0"
  # 今のブランチで作った stash は取り出せる。番号で、別のブランチの stash を指せば止める
  make_stash "fix: x"
  allowed "git stash pop" "git stash apply stash@{0}" "git stash drop 0" "git stash branch feat/2-y"
  denied "別のブランチ（main）で作られた stash" "git stash pop 1" "git stash apply stash@{1}" "git stash branch feat/2-y 1"
  # 理由は1行で伝える
  run_hook "git stash pop 1"
  [ "${#lines[@]}" -eq 1 ]
}

@test "stash は全ワークツリーで共有されるので、別のワークツリーで作った stash も、ブランチが違えば止める" {
  make_stash
  git worktree add -q -b feat/1-x "$TMP/wt"
  denied "別のブランチ（main）で作られた stash" "cd $TMP/wt && git stash pop" "git -C $TMP/wt stash apply"
  allowed "git stash pop"
}

@test "detached HEAD で作った stash は、detached HEAD のまま取り出せ、ブランチで作った stash は止める" {
  make_stash
  git checkout -q --detach
  denied "別のブランチ（main）で作られた stash" "git stash pop"
  make_stash
  allowed "git stash pop" "git stash apply stash@{0}"
  denied "別のブランチ（main）で作られた stash" "git stash pop 1"
  # 別のコミットの detached HEAD（別のワークツリーの作業など）で作った stash は、同じ (no branch) でも止める
  git commit -q --allow-empty -m y
  git checkout -q --detach
  denied "別の detached HEAD" "git stash pop" "git stash drop 0"
  # 同じコミットの detached HEAD に戻れば取り出せる
  git checkout -q HEAD~1
  allowed "git stash pop"
  # detached HEAD で作った stash を、ブランチの上で取り出すときも止める
  git checkout -q main
  denied "別のブランチ（(no branch)）で作られた stash" "git stash pop"
}

@test "git stash clear は、どのブランチの上でも止める" {
  denied "git stash clear" "git stash clear"
  git checkout -q -b feat/1-x
  denied "git stash clear" "git stash clear"
}

@test "stash を作る・見るだけの操作と、無い stash の取り出しは止めない" {
  allowed "git stash pop" "git stash apply stash@{3}"
  make_stash
  git checkout -q -b feat/1-x
  allowed "git stash" "git stash push -m x" "git stash list" "git stash show -p" "git stash show stash@{0}" "git stash pop stash@{5}"
}

@test "導入していないリポジトリでは stash を止めない。対象が分からないときの取り出しは止める" {
  make_stash
  git checkout -q -b feat/1-x
  denied "対象のリポジトリが分からない" "cd - && git stash pop"
  rm .claude/dev-workflow/config.json
  silent "git stash pop" "git stash clear"
}

@test "規約に合わない名前でブランチを作るコマンドは、止めずに警告する" {
  warned foo \
    "git switch -c foo" \
    "git switch -C foo main" \
    "git switch --create foo" \
    "git switch --create=foo" \
    "git switch -qcfoo" \
    "git switch --orphan foo" \
    "git checkout -b foo" \
    "git checkout -qB foo origin/main" \
    "git checkout --orphan=foo" \
    "git branch foo" \
    "git branch -f foo main" \
    "git branch --track foo origin/main" \
    "git worktree add -b foo ../wt" \
    "git worktree add ../foo" \
    "git worktree add -f --lock ../x/foo/" \
    "git worktree add -f -B foo ../wt main" \
    "git -C $REPO switch -c foo" \
    "git fetch && git switch -c foo"
  run_hook "git switch -c foo"
  assert_output --partial "branch.pattern（{type}/{issue_number}-{slug}）の形になっていません"
  assert_output --partial "task-start"
  warned Feat/1-x "git switch -c Feat/1-x"
}

@test "commit-ish を書かない git worktree add <パス> は、パスの最後の名前のブランチを作るので警告する。作らないときは出さない" {
  warned bad_name "git worktree add ../bad_name" "git worktree add --orphan ../bad_name"
  run_hook "git worktree add ../bad_name"
  assert_output --partial "ブランチ名 bad_name は規約に合いません"
  silent "git worktree add --detach ../bad_name" "git worktree add -d ../bad_name" \
    "git worktree add ../bad_name main" "git worktree add .."
  warned 21-x "git worktree add ../feat/21-x"
}

@test "リモートのブランチの名前が一部しか一致しない（team/bad_name）ときは、既にあるブランチとして扱わず警告する" {
  git update-ref refs/remotes/origin/team/bad_name HEAD
  warned bad_name "git switch -c bad_name" "git worktree add ../bad_name"
}

@test "リモートにだけあるブランチへの switch・checkout や、-t の追跡ブランチは、これまでどおり確かめない" {
  git update-ref refs/remotes/origin/bad_name HEAD
  silent "git switch bad_name" "git checkout bad_name" "git checkout -t origin/bad_name" "git switch --track origin/bad_name" \
    "git worktree add ../bad_name"
}

@test "ブランチを作るオプションを略して書いても、git と同じに読んで警告する" {
  warned foo "git switch --cre foo" "git switch --force-c foo" "git switch --orph=foo" "git checkout --orph foo" \
    "git branch --forc foo main" "git branch --tr foo origin/main"
  # switch の --force（--discard-changes）は値を取らないので、次の語を作るブランチと読まない
  silent "git switch --force foo"
}

@test "1つのコマンドで複数のブランチを作れば、まとめて警告する" {
  run_hook "git branch foo && git branch feat/1-ok && git branch bar"
  assert_success
  assert_output --partial "ブランチ名 foo は規約に合いません"
  assert_output --partial "ブランチ名 bar は規約に合いません"
  refute_output --partial "feat/1-ok"
}

@test "規約に合う名前や、ブランチを作らない git のコマンドでは何も出さない" {
  silent \
    "git switch -c feat/21-add-login" \
    "git checkout -b fix/3-typo" \
    "git branch docs/4-readme main" \
    "git worktree add -b feat/5-x ../wt" \
    "git status" \
    "git branch" \
    "git branch -a" \
    "git branch -vv" \
    "git branch -d foo" \
    "git branch -D foo" \
    "git branch -m foo" \
    "git branch --list 'f*'" \
    "git branch -u origin/foo foo" \
    "git switch foo" \
    "git switch -" \
    "git checkout foo" \
    "git checkout -- foo" \
    "git checkout -p foo" \
    "git worktree add ../wt foo" \
    "git worktree list" \
    "echo git branch foo"
  # 展開前の変数の名前は確かめない
  # shellcheck disable=SC2016
  silent 'git switch -c "$name"' 'git branch $(echo foo)'
}

@test "ブランチ名は、操作する先のリポジトリの設定で確かめる" {
  git init -q -b main "$TMP/other"
  mkdir -p "$TMP/other/.claude/dev-workflow"
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}}' >"$TMP/other/.claude/dev-workflow/config.json"
  silent "git -C $TMP/other switch -c feat-1/x" "cd $TMP/other && git branch feat-1/x"
  warned feat/1-x "git -C $TMP/other switch -c feat/1-x"
  warned feat-1/x "git switch -c feat-1/x"
}

@test "設定を読めないときや、リポジトリの外では何も出さない" {
  echo '{' >.claude/dev-workflow/config.json
  silent "git switch -c foo"
  rm .claude/dev-workflow/config.json
  silent "cd $TMP && git switch -c foo"
}

@test "ブランチ名を警告しても、main を守る判断は変わらない" {
  denied "main の上ではコミットしません" "git branch foo && git commit -m x"
  denied "強制 push" "git switch -c foo && git push -f"
}

@test "base_branch や、手元・リモートに既にあるブランチの名前は確かめない" {
  git branch wip
  git update-ref refs/remotes/origin/dependabot/npm/foo HEAD
  silent \
    "git switch -C main origin/main" \
    "git checkout -B main origin/main" \
    "git branch -f main origin/main" \
    "git branch -f wip main" \
    "git switch -c dependabot/npm/foo origin/dependabot/npm/foo" \
    "git worktree add -b dependabot/npm/foo ../wt origin/dependabot/npm/foo"
  # 名前の一部だけが同じリモートのブランチでは、確かめる
  warned npm/foo "git switch -c npm/foo"
}

@test "git branch のまとめた短いオプションや --color の後ろの名前も確かめる" {
  warned bad "git branch -ft bad origin/main" "git branch -qf bad" "git branch --no-color bad" "git branch --color=always bad"
  silent "git branch -fd bad" "git branch -tm bad"
}

@test "git branch の名前の後ろに、作らないオプションがあれば確かめない" {
  silent "git branch bar -d" "git branch bar -D" "git branch 'f*' --list" "git branch bar -m baz" "git branch bar --contains main"
  warned bar "git branch bar main -f" "git branch bar -- main"
}

@test "導入していないリポジトリでは、main の上の commit・強制 push も、ブランチ名も止めない" {
  rm .claude/dev-workflow/config.json
  # ユーザーの層の設定も読まない（base_branch を develop にしても、develop の上の commit を止めない）
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  silent "git commit -m x" "git push origin main" "git push --force" "git switch -c foo"
  git switch -q -c develop
  silent "git commit -m x"
}

@test "操作する先のリポジトリが導入したものかで判断する" {
  git init -q -b main "$TMP/other"
  silent "git -C $TMP/other commit -m x" "cd $TMP/other && git push --force"
  denied "main の上ではコミットしません" "cd $TMP/other && cd $REPO && git commit -m x"
  mark_set_up "$TMP/other"
  denied "main の上ではコミットしません" "git -C $TMP/other commit -m x"
}

@test "ワークツリーにチームの設定が無くても、メインのワークツリーにあれば守る" {
  # 初期設定をコミットする前に作ったワークツリーには、チームの設定が無い
  git worktree add -q "$TMP/wt" -b feat/1-x
  [ ! -f "$TMP/wt/.claude/dev-workflow/config.json" ]
  denied "強制 push" "cd $TMP/wt && git push --force"
  denied "main へは push しません" "cd $TMP/wt && git push origin feat/1-x:main"
}

@test "操作する先のディレクトリが分からないときは、今までどおり調べる" {
  rm .claude/dev-workflow/config.json
  denied "強制 push" "cd - && git push --force"
}

@test "--git-dir・--work-tree・GIT_DIR などで指したリポジトリや .git の中でも、その対象が導入したリポジトリかで判断する" {
  git init -q -b main "$TMP/other"
  # 導入したリポジトリ（REPO）を、導入していないディレクトリ（other）などから指す
  denied "強制 push" \
    "cd $TMP/other && git --git-dir=$REPO/.git push --force" \
    "cd $TMP/other && git --git-dir $REPO/.git --work-tree $REPO push --force" \
    "cd $TMP/other && GIT_DIR=$REPO/.git git push --force" \
    "cd $TMP/other && env GIT_DIR=$REPO/.git git push --force" \
    "cd $TMP && GIT_DIR=repo/.git GIT_WORK_TREE=repo git push --force" \
    "cd $REPO/.git && git push --force" \
    "cd $REPO/.git/refs && git push --force"
  denied "main へは push しません" "cd $TMP/other && GIT_DIR=$REPO/.git git push origin main"
  denied "main の上ではコミットしません" "cd $TMP/other && git --git-dir=$REPO/.git --work-tree=$REPO commit -m x"
  # 導入していないリポジトリ（other）を、導入したリポジトリ（REPO）の中から指す
  silent \
    "git --git-dir=$TMP/other/.git push --force" \
    "GIT_DIR=$TMP/other/.git git push --force" \
    "cd $TMP/other/.git && git push --force" \
    "git --git-dir=$TMP/other/.git commit -m x"
}

@test "base_branch とブランチ名の規約は、今のディレクトリではなく、操作の対象のリポジトリの設定から読む" {
  git init -q -b develop "$TMP/dev"
  mark_set_up "$TMP/dev"
  echo '{"base_branch": "develop"}' >"$TMP/dev/.claude/dev-workflow/config.json"
  git -C "$TMP/dev" commit -q --allow-empty -m init
  # 今のディレクトリ（REPO）の base_branch は main
  denied "develop へは push しません" \
    "GIT_DIR=$TMP/dev/.git GIT_WORK_TREE=$TMP/dev git push origin develop" \
    "git --git-dir $TMP/dev/.git --work-tree $TMP/dev push origin develop" \
    "git --git-dir=$TMP/dev/.git push origin develop"
  denied "develop の上ではコミットしません" "cd $TMP && GIT_DIR=dev/.git GIT_WORK_TREE=dev git commit -m x"
  silent "git --git-dir=$TMP/dev/.git push origin main"
  # 導入したリポジトリを、リポジトリの外から --git-dir で指しても、その規約でブランチ名を確かめる
  warned foo "cd $TMP && git --git-dir=$REPO/.git switch -c foo"
}

@test "ユーザーの層の base_branch は、導入していないリポジトリを --git-dir・GIT_DIR で指したときにも効かない" {
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  git init -q -b develop "$TMP/other"
  git -C "$TMP/other" commit -q --allow-empty -m init
  # 今のディレクトリ（REPO）は導入したリポジトリなので、ここではユーザーの層を読む
  silent "git --git-dir=$TMP/other/.git commit -m x" "GIT_DIR=$TMP/other/.git git push origin develop"
}

@test "--separate-git-dir のリポジトリは、作業ツリーからはそのチームの設定で、外から指したときは HEAD にコミットしたチームの設定で判断する" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mark_set_up "$TMP/sep"
  denied "main の上ではコミットしません" \
    "cd $TMP/sep && git commit -m x" \
    "cd $TMP/sep && GIT_WORK_TREE=. git commit -m x" \
    "cd $TMP/sep && git --work-tree=. commit -m x"
  # 外から git のディレクトリだけで指すと、作業ツリーは分からない（git がメインのワークツリーを記録していない）
  silent "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
}

@test "サブモジュールは、サブモジュールのチームの設定で判断する（そのワークツリーや、外から指したときも）" {
  make_submodule
  git -C "$TMP/super/sm" switch -q main
  mark_set_up "$TMP/super/sm"
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  denied "main の上ではコミットしません" \
    "cd $TMP/super/sm && git commit -m x" \
    "cd $TMP && GIT_DIR=super/.git/modules/sm git commit -m x"
  # サブモジュールのワークツリーにチームの設定が無くても、メインのワークツリー（super/sm）にあれば守る
  denied "強制 push" "cd $TMP/smwt && git push --force"
  # 上のリポジトリ（super）は導入していない
  silent "cd $TMP/super && git push --force"
}

@test "bare リポジトリは、HEAD にチームの設定がコミットされているかで判断する（関係のないミラーの移行は止めない）" {
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  silent \
    "cd $TMP/mirror.git && git push --mirror ../elsewhere.git" \
    "git -C $TMP/mirror.git push --force" \
    "GIT_DIR=$TMP/mirror.git git push --mirror ../elsewhere.git"
  # 導入したリポジトリ（チームの設定をコミットしたもの）のミラーは守る
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --mirror "$REPO" "$TMP/mirror2.git"
  denied "強制 push" "cd $TMP/mirror2.git && git push --mirror ../elsewhere.git"
}
@test "CDPATH を export していても、--git-dir・.git の中・ワークツリーで、対象のリポジトリを求められる" {
  git init -q -b main "$TMP/other"
  git worktree add -q "$TMP/wt" -b feat/1-x
  export CDPATH=.
  denied "強制 push" \
    "cd $TMP/other && git --git-dir=$REPO/.git push --force" \
    "cd $REPO/.git && git push --force" \
    "cd $TMP/wt && git push --force"
  silent "git --git-dir=$TMP/other/.git push --force"
}

@test "--git-dir・GIT_DIR の値の先頭の ~・\$HOME を展開して、対象のリポジトリを求める" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  # 導入していないリポジトリは止めない
  # shellcheck disable=SC2016
  silent 'GIT_DIR=~/other/.git git push --force' 'git --git-dir=$HOME/other/.git push --force' 'git --git-dir ${HOME}/other/.git push --force'
  # 導入したリポジトリは守る
  # shellcheck disable=SC2016
  denied "強制 push" 'cd ~/other && GIT_DIR=~/repo/.git git push --force' 'cd ~/other && git --git-dir=$HOME/repo/.git push --force'
}

@test "ワークツリーの git のディレクトリを GIT_DIR で指したときは、今のディレクトリのワークツリーではなく、指したワークツリーの設定で判断する" {
  git worktree add -q "$TMP/wt" -b develop
  mkdir -p "$TMP/wt/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/wt/.claude/dev-workflow/config.json"
  git -C "$TMP/wt" add .claude/dev-workflow/config.json
  git -C "$TMP/wt" commit -q -m setup
  # 今のディレクトリ（REPO）の base_branch は main。対象（wt）は develop の上で、base_branch は develop
  denied "develop の上ではコミットしません" "GIT_DIR=$REPO/.git/worktrees/wt git commit -m x"
}

@test "ワークツリーの git のディレクトリを指したとき、そのワークツリーにチームの設定が無くても、メインのワークツリーにあれば守る" {
  # 初期設定より前に作ったブランチのワークツリー（チームの設定がコミットされていない）
  git worktree add -q "$TMP/wt" -b old
  denied "強制 push" "GIT_DIR=$REPO/.git/worktrees/wt git push --force" "git --git-dir=$TMP/wt/.git push --force"
}

@test "GIT_WORK_TREE で同じリポジトリの別のワークツリーを指しても、そのワークツリーの設定では判断しない" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  mkdir -p "$TMP/wt/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/wt/.claude/dev-workflow/config.json"
  # git のディレクトリ（HEAD）は REPO（main の上）のもの。base_branch も REPO の設定（main）で判断する
  denied "main の上ではコミットしません" "GIT_WORK_TREE=$TMP/wt git commit -m x"
}

@test "--opt=値 の ~ はシェルが展開しないので展開せず、cd・git -C の先の \$HOME は展開する" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  # git には ~/other/.git がそのまま渡り、リポジトリが見つからないので、守りを外さないよう調べる
  denied "強制 push" "git --git-dir=~/other/.git push --force"
  # 導入していないリポジトリを、cd・git -C の $HOME で指せば止めない
  # shellcheck disable=SC2016
  silent 'cd $HOME/other && git push --force' 'git -C ${HOME}/other push --force'
}

@test "--work-tree・GIT_WORK_TREE の値の ~・\$HOME も展開し、値が \$HOME だけでも展開する" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mark_set_up "$TMP/sep"
  # 作業ツリーを展開して求められれば、そのルートの規約でブランチ名を確かめる
  # shellcheck disable=SC2016
  warned foo 'cd ~/other && git --git-dir $HOME/sep.git --work-tree ~/sep switch -c foo' \
    'cd ~/other && GIT_DIR=$HOME/sep.git GIT_WORK_TREE=${HOME}/sep git switch -c foo'
  # 値が $HOME だけの作業ツリー（dotfiles の bare リポジトリの使い方）
  git init -q --bare "$TMP/dot.git"
  # shellcheck disable=SC2016
  silent 'git --git-dir=$HOME/dot.git --work-tree=$HOME push --force'
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --bare "$REPO" "$TMP/dot2.git"
  # shellcheck disable=SC2016
  denied "強制 push" 'git --git-dir=$HOME/dot2.git --work-tree=$HOME push --force'
}

@test "ルートが分からない対象は、HEAD にコミットしたチームの設定、ユーザーの層の順に base_branch を読み、ブランチ名は確かめない" {
  git init -q -b develop --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mkdir -p "$TMP/sep/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  echo '{"base_branch": "release"}' >"$WORKFLOW_USER_DIR/config.json"
  # チームの設定（develop）がユーザーの層（release）より優先される
  denied "develop の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  silent "cd $TMP && git --git-dir=$TMP/sep.git push origin main" "cd $TMP && git --git-dir=$TMP/sep.git switch -c foo"
  # チームの設定が base_branch を決めていなければ、ユーザーの層の値を使う
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  denied "release へは push しません" "cd $TMP/mirror.git && git push origin release"
}

@test "対象のリポジトリが見つからないときは、守りを外さないよう調べる" {
  mkdir "$TMP/plain"
  denied "強制 push" "cd $TMP/plain && git push --force" "cd $TMP/plain && GIT_DIR=$TMP/nowhere git push --force"
}

@test "積んだ場所が無い popd は場所を移さない（その後でも、main への commit を止める）" {
  denied "main の上ではコミットしません" "popd; git commit -m x" "popd && git commit -m x"
  denied "強制 push" "popd; git push -f"
}

@test "pushd で積んだ場所を追い、popd で戻った先で判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" \
    "pushd ../wt && git push && popd && git commit -m x" \
    "pushd $TMP/wt; popd; git commit -m x" \
    "pushd $TMP/wt && pushd $TMP && popd && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd -n && git commit -m x"
  allowed "pushd ../wt && pushd $REPO && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd +0 && git commit -m x" \
    "pushd $TMP/wt && dirs -c && popd; git commit -m x" "pushd $TMP/wt && dirs -l -c +0 && popd; git commit -m x"
  # dirs は、まとめ書き（-cl）・ほかのオプション・-- の後ろの語があると失敗して、スタックを変えない
  denied "main の上ではコミットしません" "pushd $TMP/wt && dirs -- -c; popd; git commit -m x" \
    "pushd $TMP/wt && dirs -x -c; popd; git commit -m x" "pushd $TMP/wt && dirs -cl; popd; git commit -m x" \
    "pushd $TMP/wt && dirs +1x -c; popd; git commit -m x"
  # 番号の頭には、符号を1つ付けられる（dirs・pushd・popd で同じ）
  allowed "pushd $TMP/wt && dirs +-0 -c && popd; git commit -m x" "pushd $TMP/wt && pushd +-0 && git commit -m x"
  denied "main の上ではコミットしません" "pushd $TMP/wt && popd -+1; git commit -m x" "pushd $TMP/wt && pushd ++1 && git commit -m x"
}

@test "( ) の中で積んだ・戻した場所は、括弧の外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" \
    "pushd $TMP/wt && (popd && git commit -m x)" \
    "(pushd $TMP/wt); popd; git commit -m x" \
    "pushd $TMP/wt && (popd; pushd $TMP/wt) && popd && git commit -m x"
  allowed "pushd $TMP/wt && (popd) && git commit -m x" "cd $TMP/wt && (pushd $REPO) && popd; git commit -m x"
}

@test "引数の無い pushd・pushd -n・pushd +N/-N・popd +N/-N を、シェルと同じに扱う" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  # 引数の無い pushd は、積んだ場所が無ければ失敗し、あれば上の2つを入れ替える（$HOME へは移らない）
  denied "main の上ではコミットしません" "pushd; git commit -m x" "pushd $TMP/wt && pushd && git commit -m x" \
    "pushd -n $TMP/wt && git commit -m x" "pushd -n ../wt && popd -n && popd; git commit -m x"
  allowed "pushd -n $TMP/wt && pushd && git commit -m x" "pushd -n ../wt && popd && git commit -m x"
  # pushd -n で積んだ相対パスは、移るときの場所から解決する（シェルと同じ）
  allowed "pushd -n wt && cd .. && popd && git commit -m x"
  # +N は左から、-N は右から数えた場所を先頭に回して移る（dirs -v の順。0 は今の場所）
  denied "main の上ではコミットしません" "pushd $TMP/wt && pushd +1 && git commit -m x" \
    "pushd $TMP/wt && pushd -0 && git commit -m x" "pushd $TMP/wt && pushd $TMP && pushd -0 && git commit -m x"
  allowed "pushd $TMP/wt && pushd $TMP && pushd +1 && git commit -m x" "pushd $TMP/wt && pushd +1 && pushd -0 && git commit -m x"
  # 範囲の外の番号は失敗し、移らない
  denied "main の上ではコミットしません" "pushd +1; git commit -m x" "pushd $TMP/wt && pushd +2; pushd +1; git commit -m x"
  # popd +N は、その場所を取り除くだけで、+0（今の場所）でなければ移らない
  allowed "pushd $TMP/wt && popd +1 && git commit -m x" "pushd $TMP/wt && pushd $TMP && popd -0 && popd && git commit -m x"
  denied "main の上ではコミットしません" "pushd $TMP/wt && popd -1 && git commit -m x"
  # 引数の無い pushd -n は何もしない
  denied "main の上ではコミットしません" "pushd $TMP/wt && pushd -n && popd && git commit -m x"
  # pushd -n +N は、今の場所を残したまま、積んだ場所だけを回す
  denied "main の上ではコミットしません" "pushd -n $TMP/wt && pushd -n $TMP && pushd -n +1 && git commit -m x"
  allowed "pushd -n $TMP/wt && pushd -n $TMP && pushd -n +1 && popd && git commit -m x"
}

@test "前に付くだけのコマンド（command・exec・time・nohup・env）を飛ばして、git を調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "command git push -f" "exec git push -f" "time git push -f" "nohup git push -f" "env git push -f" \
    "env FOO=1 git push -f" "FOO=1 nohup git push -f"
}

@test "前に付くコマンドのオプション（timeout・nice・time -p・env・command・exec）を飛ばして、git を調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "timeout 60 git push -f" "timeout -s KILL 60 git push -f" "timeout --signal=KILL -k5 --foreground 60 git push -f" \
    "timeout --sig KILL 60 git push -f" "timeout -- 60 git push -f" \
    "nice git push -f" "nice -n 5 git push -f" "nice -n5 git push -f" "nice -5 git push -f" "nice --adjustment=5 git push -f" \
    "time -p git push -f" \
    "env -u FOO git push -f" "env -i git push -f" "env - git push -f" "env -iu FOO git push -f" "env --unset=FOO git push -f" \
    "env --unset FOO git push -f" "env -0 -v git push -f" "env -S 'git push -f'" "env -S '-u FOO' git push -f" \
    "command -p git push -f" "exec -a x git push -f" "exec -cl git push -f" \
    "timeout 60 nice -n 5 env -u FOO FOO=1 git push -f" "nohup -- git push -f" "command -- git push -f"
  # command -v・-V は、コマンドを実行しない
  allowed "command -v git push -f" "command -pV git push -f"
}

@test "前に付くコマンド（sudo・stdbuf・setsid・ionice・chrt・taskset・flock）を、そのオプションと位置引数とともに飛ばして、git を調べる" {
  denied "main へは push しません" "sudo git push origin main" "sudo -u root -g wheel git push origin main" \
    "sudo -E -H -n -- git push origin main" "sudo --user=root git push origin main" "sudo -C 3 git push origin main" \
    "sudo FOO=1 git push origin main"
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "stdbuf -oL git push -f" "stdbuf -i0 -o L -e 0 git push -f" "stdbuf --output=L --error 0 git push -f" \
    "setsid git push -f" "setsid -w -f git push -f" "setsid --wait git push -f" \
    "ionice -c3 git push -f" "ionice -c 2 -n 7 -t git push -f" "ionice --class=idle git push -f" \
    "chrt 10 git push -f" "chrt -r 10 git push -f" "chrt -b 0 git push -f" "chrt -T 100 -D 200 -d 0 git push -f" \
    "taskset 0x1 git push -f" "taskset -c 0,1 git push -f" "taskset -a 3 git push -f" \
    "flock /tmp/x.lock git push -f" "flock -w 5 -x /tmp/x.lock git push -f" "flock -E 3 -n /tmp/x.lock git push -f" \
    "sudo stdbuf -oL setsid ionice -c3 nice -n 5 git push -f"
  # コマンドを実行しない使い方（sudo -l・-v・-K・-V・-e、ionice -p、chrt -p・-m、taskset -p、flock -u）は、git を調べない
  allowed "sudo -l git push -f" "sudo -v" "sudo -K" "sudo -V" "sudo -e git" "ionice -p 1 git" "chrt -p 1 git" "chrt -m" \
    "taskset -p 1 git" "taskset -cp 0 1 git" "flock -u 3"
}

@test "sudo -i・-R は別の場所で動き、sudo の前の GIT_DIR などは効くか決められないので、git を実行する場所を分からないものとする" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  cd "$TMP/wt"
  denied "対象のリポジトリが分からない" "sudo -i git commit -m x" "sudo -iu root git commit -m x" "sudo --login git commit -m x" \
    "sudo -D $TMP/wt -i git commit -m x" "sudo -R / git commit -m x"
  # 絶対パスの git -C なら、場所が分かる
  allowed "sudo -i git -C $TMP/wt commit -m x"
  # sudo の前の GIT_DIR は、env_reset で消えるかもしれず、env_keep・-E で残るかもしれない
  git init -q -b main "$TMP/other"
  denied "対象のリポジトリが分からない" "GIT_DIR=$TMP/other/.git sudo git commit -m x" "GIT_WORK_TREE=$TMP/other sudo -E git commit -m x"
  # sudo の後ろに書いた代入は、そのコマンドに渡る（導入していない other を指すので、何もしない）
  silent "sudo GIT_DIR=$TMP/other/.git git commit -m x"
}

@test "sudo の前の GIT_DIR などがあるときの git init・git clone は、作る場所が分からないので覚えない" {
  git init -q -b main "$TMP/other"
  denied "対象のリポジトリが分からない" "GIT_DIR=$TMP/other/.git sudo git init $TMP/n && cd $TMP/n && git commit -m x"
}

@test "sudo -D <dir> で移った先で、そのコマンドの git を判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "sudo -D $TMP/wt git commit -m x" "sudo -D ../wt git commit -m x" "sudo --chdir=$TMP/wt git commit -m x" \
    "sudo -D$TMP/wt git commit -m x"
  # sudo -D は、そのコマンドだけに効く
  denied "main の上ではコミットしません" "sudo -D $TMP/wt true; git commit -m x" "cd $TMP/wt && sudo -D $REPO git commit -m x"
}

@test "env -S の値は、env と同じく引用符とエスケープを解いて分ける" {
  git checkout -q -b feat/21-x
  denied "main へは push しません" "env -S \"git push origin 'main'\"" "env -S 'git push origin \"main\"'" \
    "env -S 'git push origin ma\\in'" "env -S 'git push \"origin\" \"feat/21-x:main\"'"
  # '…' の中では \\ と \' だけを解く（GNU env と同じ）。'a\'' と main は別の語
  local c
  c="$(cat <<'EOF'
env -S "git push origin 'a\\'' main"
EOF
)"
  denied "main へは push しません" "$c"
  # '…' の中の \\ は \（env が受け取る値は git push origin 'a\\' main。'a\\' と main は別の語）
  c="$(cat <<'EOF'
env -S "git push origin 'a\\\\' main"
EOF
)"
  denied "main へは push しません" "$c"
  # "…" の外の \_ は区切り、中では空白
  denied "強制 push" "env -S 'git\\_push\\_-f'"
  allowed "env -S 'git push origin \"x\\_main\"'"
}

@test "env -i・env -・env -u で消した GIT_DIR などは、対象を求めるときに使わない" {
  git init -q -b main "$TMP/other"
  # 導入していないリポジトリ（other）を指した GIT_DIR を消すので、今のディレクトリ（main の上）で判断する
  denied "main の上ではコミットしません" "GIT_DIR=$TMP/other/.git env -i git commit -m x" \
    "GIT_DIR=$TMP/other/.git env - git commit -m x" "GIT_DIR=$TMP/other/.git env -u GIT_DIR git commit -m x" \
    "GIT_DIR=$TMP/other/.git env --unset=GIT_DIR git commit -m x" "GIT_DIR=$TMP/other/.git env --ignore-env git commit -m x"
  # exec -c も、環境変数をすべて消してから実行する
  denied "main の上ではコミットしません" "GIT_DIR=$TMP/other/.git exec -c git commit -m x" "GIT_DIR=$TMP/other/.git exec -cl git commit -m x"
  # 消した後の代入と、ほかの変数を消すときは、GIT_DIR が効く
  silent "env -i GIT_DIR=$TMP/other/.git git commit -m x" "GIT_DIR=$TMP/other/.git env -u FOO git commit -m x"
}

@test "env -C の値をくっつけて書いたとき（-C~/x・--chdir=~/x）は、シェルと同じく ~ を展開しない" {
  export HOME="$TMP/home"
  # 文字どおりの ~/repo（$TMP/sub/~ → $TMP）は main の上のリポジトリ、展開した ~/repo は作業用のブランチのワークツリー
  mkdir -p "$TMP/sub"
  ln -s "$TMP" "$TMP/sub/~"
  git worktree add -q -b feat/21-x "$TMP/home/repo"
  denied "main の上ではコミットしません" "cd $TMP/sub && env -C~/repo git commit -m x" "cd $TMP/sub && env --chdir=~/repo git commit -m x"
  allowed "cd $TMP/sub && env -C ~/repo git commit -m x" "cd $TMP/sub && env --chdir ~/repo git commit -m x"
}

@test "env -C <dir> で移った先で、そのコマンドの git を判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "env -C $TMP/wt git commit -m x" "env -C ../wt git commit -m x" "env --chdir=$TMP/wt git commit -m x" \
    "env --chd ../wt nice git commit -m x" "env -iC../wt git commit -m x" "env -C $TMP env -C wt git commit -m x"
  # env -C は、そのコマンドだけに効く
  denied "main の上ではコミットしません" "env -C $TMP/wt true; git commit -m x" "cd $TMP/wt && env -C $REPO git commit -m x"
}

@test "外部のコマンドとして実行する cd・pushd・popd は、場所を移さない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "env cd $TMP/wt; git commit -m x" "nohup pushd $TMP/wt; git commit -m x" \
    "timeout 5 cd $TMP/wt; git commit -m x"
  # builtin・command・time は、シェルの組み込みの cd を実行する
  allowed "command cd $TMP/wt && git commit -m x" "time cd $TMP/wt && git commit -m x" "builtin cd $TMP/wt && git commit -m x"
  # builtin・cd・nohup に不正なオプションがあると、シェルは失敗して、移らない・実行しない
  denied "main の上ではコミットしません" "builtin -x cd $TMP/wt; git commit -m x" "cd -x $TMP/wt; git commit -m x"
  allowed "cd -P $TMP/wt && git commit -m x" "cd -L -P $TMP/wt && git commit -m x" "nohup --help git commit -m x"
  # cd -e は bash 4.3 から（bash 4.3 以降に合わせて、移るものとして扱う）。-@ は拡張属性に対応したシステムだけなので、失敗として扱う
  allowed "cd -e $TMP/wt && git commit -m x"
  denied "main の上ではコミットしません" "cd -@ $TMP/wt; git commit -m x"
  denied "main の上ではコミットしません" "cd $TMP/wt && builtin cd $REPO && git commit -m x" \
    "cd $TMP/wt && builtin -- cd $REPO && git commit -m x"
  # sudo・stdbuf・setsid などの後ろの cd も、外部のコマンドとして実行するので、場所を移さない
  denied "main の上ではコミットしません" "sudo cd $TMP/wt; git commit -m x" "stdbuf -oL cd $TMP/wt; git commit -m x" \
    "setsid cd $TMP/wt; git commit -m x" "ionice -c3 cd $TMP/wt; git commit -m x" "chrt 0 cd $TMP/wt; git commit -m x" \
    "taskset 1 cd $TMP/wt; git commit -m x" "flock /tmp/x.lock cd $TMP/wt; git commit -m x"
}

@test "cd \"\" は移らない（引数の無い cd だけが \$HOME へ移る）" {
  # $HOME を作業用のブランチのワークツリーにして、$HOME へ移ったと読めば通してしまうようにする
  git worktree add -q -b feat/21-x "$TMP/wt"
  export HOME="$TMP/wt"
  denied "main の上ではコミットしません" "cd \"\"; git commit -m x" "cd ''; git commit -m x"
  # pushd "" は失敗し、pushd -n "" で積んだ場所へ戻っても移らない
  denied "main の上ではコミットしません" "pushd \"\"; git commit -m x" "pushd -n \"\" && popd && git commit -m x"
  allowed "cd; git commit -m x" "cd && git commit -m x"
}

@test "cd -- の後ろは、- で始まっても行き先として読む" {
  # $HOME は作業用のブランチのワークツリー、-r は main の上のリポジトリ（REPO）
  git worktree add -q -b feat/21-x "$TMP/wt"
  export HOME="$TMP/wt"
  ln -s "$REPO" "$TMP/-r"
  denied "main の上ではコミットしません" "cd $TMP && cd -- -r && git commit -m x" "cd $TMP && cd -L -- -r && git commit -m x"
}

@test "push の引数が : のとき（matching refspec）は、同じ名前のブランチをすべて push するので、どのブランチの上でも止める" {
  git checkout -q -b feat/1-x
  denied "matching refspec" "git push origin :"
  git checkout -q main
  denied "matching refspec" "git push origin :"
}

@test "ホームのリポジトリ（ユーザーの層と同じ場所にチームの設定が見える）は導入したとみなさず、守らない" {
  export HOME="$TMP/home"
  export WORKFLOW_USER_DIR="$HOME/.claude/dev-workflow"
  mkdir -p "$WORKFLOW_USER_DIR"
  echo '{}' >"$WORKFLOW_USER_DIR/config.json"
  # ~/.git で dotfiles を管理している
  git init -q -b main "$HOME"
  git -C "$HOME" add .claude/dev-workflow/config.json
  git -C "$HOME" commit -q -m dotfiles
  mkdir -p "$HOME/sub"
  silent "cd $HOME/sub && git push --force" "cd $HOME && git commit -m x"
  # bare の dotfiles を --work-tree=\$HOME で指す
  git clone -q --bare "$HOME" "$TMP/cfg.git"
  silent "git --git-dir=$TMP/cfg.git --work-tree=$HOME push --force" "git --git-dir=$TMP/cfg.git --work-tree $HOME commit -m x" "GIT_DIR=$TMP/cfg.git GIT_WORK_TREE=$HOME git push --force"
}

@test "ホームのリポジトリを相対の --work-tree で指しても（git -C や CDPATH があっても）、導入したとみなさない" {
  export HOME="$TMP/home"
  export WORKFLOW_USER_DIR="$HOME/.claude/dev-workflow"
  mkdir -p "$WORKFLOW_USER_DIR"
  echo '{}' >"$WORKFLOW_USER_DIR/config.json"
  git init -q -b main "$HOME"
  git -C "$HOME" add .claude/dev-workflow/config.json
  git -C "$HOME" commit -q -m dotfiles
  git clone -q --bare "$HOME" "$TMP/cfg.git"
  silent "cd $HOME && git --git-dir=$TMP/cfg.git --work-tree=. push --force" \
    "git -C $HOME --git-dir=$TMP/cfg.git --work-tree=. push --force" \
    "cd $TMP && git --git-dir=$TMP/cfg.git --work-tree=home push --force"
  export CDPATH="$TMP"
  silent "cd $TMP && git --git-dir=$TMP/cfg.git --work-tree=home push --force"
}

@test "ホームのリポジトリを、展開前の \$HOME・\${HOME}・GIT_WORK_TREE=~ で指しても、導入したとみなさない" {
  export HOME="$TMP/home"
  export WORKFLOW_USER_DIR="$HOME/.claude/dev-workflow"
  mkdir -p "$WORKFLOW_USER_DIR"
  echo '{}' >"$WORKFLOW_USER_DIR/config.json"
  git init -q -b main "$HOME"
  git -C "$HOME" add .claude/dev-workflow/config.json
  git -C "$HOME" commit -q -m dotfiles
  git clone -q --bare "$HOME" "$HOME/.dotfiles"
  # shellcheck disable=SC2016
  silent 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m x' \
    'git --git-dir=${HOME}/.dotfiles --work-tree ${HOME} push --force' \
    'git --git-dir ~/.dotfiles --work-tree ~ push --force' \
    'GIT_DIR=~/.dotfiles GIT_WORK_TREE=~ git push --force'
}

# 設定の誤りがあるときの警告（ブランチ名が規約に合うかは確かめられない）。フックは止めない
config_warned() {
  local c
  for c in "$@"; do
    run_hook "git switch -c feat/17-x"
    [ "$status" -eq 0 ] || fail "止めてしまった（${status}）: $c / $output"
    jq -e '
      .hookSpecificOutput.hookEventName == "PreToolUse"
      and .hookSpecificOutput.permissionDecision == null
      and .systemMessage == .hookSpecificOutput.additionalContext
      and (.systemMessage | contains("設定の誤り"))
    ' <<<"$output" >/dev/null || fail "設定の誤りの警告が出ていない: $c / $output"
  done
}

@test "ブランチを作るとき、branch.pattern・labels.types の誤りは、フックを止めずに設定の誤りとして警告する" {
  local c
  for c in '{"branch":{"pattern":"^(feat"}}' \
    '{"branch":{"pattern":5}}' \
    '{"branch":{"pattern":["x"]}}' \
    '{"labels":{"types":"feat"}}' \
    '{"labels":{"types":["feat", 1]}}' \
    '{"labels":{"types":false}}' \
    '{"branch":"x"}'; do
    printf '%s\n' "$c" >.claude/dev-workflow/config.local.json
    config_warned "$c"
  done
  printf '%s\n' '{"branch":{"pattern":"^(feat"}}' >.claude/dev-workflow/config.local.json
  run_hook "git switch -c feat/17-x"
  assert_output --partial "正規表現として正しくありません"
  # 名前の形の問題（大文字）があっても、設定の誤りを警告する
  run_hook "git switch -c Feat/17-X"
  assert_success
  assert_output --partial "設定の誤り"
}

@test "設定を読めないとき（config.sh の失敗）は、今までどおり何も伝えずに通す" {
  echo '[1]' >.claude/dev-workflow/config.local.json
  silent "git switch -c feat/17-x"
}
