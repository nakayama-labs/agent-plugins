#!/usr/bin/env bats
# スクリプトの共通処理（lib/common.sh）の関数を、直接呼んで確かめる。

load test_helper

# common.sh を読み込んで、関数を1つ呼ぶ。使い方: run_common <関数> [引数]...
run_common() {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1"; shift; "$@"' _ "$SCRIPTS/lib/common.sh" "$@"
}

@test "dw_remote_has_branch は、origin にあれば 0、無ければ 1 を返し、読めなければ止まる" {
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  run_common dw_remote_has_branch "$REPO" main
  assert_success
  run_common dw_remote_has_branch "$REPO" feat/17-x
  assert_failure 1
  assert_output ""
  git remote set-url origin "$TMP/no-such.git"
  run_common dw_remote_has_branch "$REPO" main
  assert_failure 1
  assert_output "error: origin のブランチを読めませんでした（通信や認証を確かめてください）"
}

@test "dw_issue_number は #・先頭の 0 をそろえ、# だけ・## で始まる値・数字でない値・0 を拒否する" {
  for v in 17 '#17' 017 '#0017'; do
    run_common dw_issue_number --issue "$v"
    assert_success
    assert_output 17
  done
  for v in '#' '##17' abc 0 000 ''; do
    run_common dw_issue_number --issue "$v"
    assert_failure 64
    assert_output "error: --issue には Issue の番号を指定してください: ${v}"
  done
  # 算術式にすると桁があふれる長さでも、文字列のまま 0 を外す
  run_common dw_issue_number --issue 00018446744073709551616
  assert_success
  assert_output 18446744073709551616
}

@test "dw_worktree_of は、ブランチを使っているワークツリーの場所を返す（無ければ空）" {
  git worktree add -q -b feat/17-x "$TMP/wt"
  run_common dw_worktree_of "$REPO" feat/17-x
  assert_success
  assert_output "$TMP/wt"
  run_common dw_worktree_of "$REPO" feat/1-x
  assert_success
  assert_output ""
}

@test "dw_read_issue は、Issue なら JSON を出し、PR の番号・無い番号なら終了コード 2 で止まる" {
  load fake_gh
  setup_fake_gh
  run_common dw_read_issue 17 title
  assert_success
  assert_equal "$(jq -r .title <<<"$output")" "作業 17"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_read_issue 21 number
  assert_failure 2
  assert_output "error: #21 は PR です。Issue の番号を指定してください"
  run_common dw_read_issue 99 number "重複の元の Issue"
  assert_failure 2
  assert_output "error: 重複の元の Issue #99 が me/demo にありません"
  FAKE_FAIL=issue-view FAKE_FAIL_MSG="HTTP 401: Bad credentials" run_common dw_read_issue 17 number
  assert_failure 1
  assert_output "error: Issue #17 を読めません: HTTP 401: Bad credentials"
}

@test "dw_read_issue は、PR の番号で止まるとき、見つからないときと同じく、どの値かを名前で示す" {
  load fake_gh
  setup_fake_gh
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_read_issue 21 number "重複の元の Issue"
  assert_failure 2
  assert_output "error: 重複の元の Issue #21 は PR です。Issue の番号を指定してください"
}

@test "dw_try_read_issue は止まらずに、Issue なら JSON を出して 0、PR なら 2、無ければ 3、読めなければ 1 を返す" {
  load fake_gh
  setup_fake_gh
  run_common dw_try_read_issue 17 title
  assert_success
  assert_equal "$(jq -r .title <<<"$output")" "作業 17"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_try_read_issue 21 number
  assert_failure 2
  assert_output ""
  run_common dw_try_read_issue 99 number
  assert_failure 3
  FAKE_FAIL=issue-view FAKE_FAIL_MSG="HTTP 401: Bad credentials" run_common dw_try_read_issue 17 number
  assert_failure 1
  assert_output "HTTP 401: Bad credentials"
}

@test "dw_uri_path は、ブランチ名を / で区切った部分ごとに符号化する（git の参照の API のパスに入れるため）" {
  run_common dw_uri_path 'feature/login#2'
  assert_success
  assert_output 'feature/login%232'
  run_common dw_uri_path 'feat/17-x'
  assert_output 'feat/17-x'
}

@test "dw_main_root は、普通のリポジトリとそのワークツリーで、メインのワークツリーを返す" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  run_common dw_main_root "$REPO"
  assert_success
  assert_output "$REPO"
  run_common dw_main_root "$TMP/wt"
  assert_success
  assert_output "$REPO"
}

@test "dw_main_root は、サブモジュールとそのワークツリーで、サブモジュールの作業ツリーを返す（.git/modules を返さない）" {
  make_submodule
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  run_common dw_main_root "$TMP/super/sm"
  assert_success
  assert_output "$TMP/super/sm"
  run_common dw_main_root "$TMP/smwt"
  assert_success
  assert_output "$TMP/super/sm"
}

@test "dw_main_root は、--separate-git-dir のリポジトリでは、メインのワークツリーそのものなら返し、ワークツリーからは分からないので失敗する" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  git -C "$TMP/sep" commit -q --allow-empty -m init
  git -C "$TMP/sep" worktree add -q "$TMP/sepwt" -b feat/1-x
  run_common dw_main_root "$TMP/sep"
  assert_success
  assert_output "$TMP/sep"
  # リポジトリの親（$TMP）を返さない
  run_common dw_main_root "$TMP/sepwt"
  assert_failure
  assert_output ""
}

@test "dw_repo_main_root は、リポジトリから、確かめたメインのワークツリーを返す（bare リポジトリは分からない）" {
  run_common dw_repo_main_root "$REPO/.git"
  assert_success
  assert_output "$REPO"
  make_submodule
  run_common dw_repo_main_root "$TMP/super/.git/modules/sm"
  assert_success
  assert_output "$TMP/super/sm"
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  run_common dw_repo_main_root "$TMP/mirror.git"
  assert_failure
}

@test "dw_is_set_up は、サブモジュールのワークツリーでは、サブモジュールのメインのワークツリーのチームの設定を見る" {
  make_submodule
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  run_common dw_is_set_up "$TMP/smwt"
  assert_failure
  mark_set_up "$TMP/super/sm"
  run_common dw_is_set_up "$TMP/smwt"
  assert_success
  # 上のリポジトリ（super）は導入していない
  run_common dw_is_set_up "$TMP/super"
  assert_failure
}

@test "dw_main_root は、bare リポジトリ＋ワークツリーの配置で、.git ファイルを置いたディレクトリを返す" {
  git clone -q --bare "$REPO" "$TMP/proj/.bare"
  echo 'gitdir: ./.bare' >"$TMP/proj/.git"
  git -C "$TMP/proj" worktree add -q "$TMP/proj/main" main
  git -C "$TMP/proj" worktree add -q "$TMP/proj/feat" -b feat/1-x
  run_common dw_main_root "$TMP/proj/main"
  assert_success
  assert_output "$TMP/proj"
  run_common dw_main_root "$TMP/proj/feat"
  assert_success
  assert_output "$TMP/proj"
}

@test "dw_main_root は、作業ツリーの無い、bare リポジトリ＋ワークツリーの配置のルートでも、そのルートを返す（#233）" {
  git clone -q --bare "$REPO" "$TMP/proj/.bare"
  echo 'gitdir: ./.bare' >"$TMP/proj/.git"
  run_common dw_main_root "$TMP/proj"
  assert_success
  assert_output "$TMP/proj"
  # メインのワークツリーを記録していない bare のミラーは、分からない
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  run_common dw_main_root "$TMP/mirror.git"
  assert_failure
}

@test "dw_main_root・dw_is_set_up は、CDPATH を export していても動く" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  mark_set_up
  export CDPATH=.
  run_common dw_main_root "$TMP/wt"
  assert_success
  assert_output "$REPO"
  run_common dw_is_set_up "$TMP/wt"
  assert_success
}

@test "dw_repo_paths・dw_main_root は、環境に別のリポジトリの GIT_DIR などが export されていても、指定したディレクトリを調べる" {
  git init -q -b main "$TMP/other"
  git worktree add -q "$TMP/wt" -b feat/1-x
  export GIT_DIR="$TMP/other/.git" GIT_WORK_TREE="$TMP/other" GIT_COMMON_DIR="$TMP/other/.git"
  run_common dw_main_root "$TMP/wt"
  assert_success
  assert_output "$REPO"
  run_common dw_repo_paths "$REPO"
  assert_success
  assert_line --index 0 "$REPO/.git"
  assert_line --index 2 "$REPO"
}

@test "dw_base_branch は、git のブランチ名として使える base_branch を出力する" {
  run_common dw_base_branch '{"base_branch": "release/v1"}'
  assert_success
  assert_output "release/v1"
}

@test "dw_base_branch は、ダッシュで始まる base_branch を拒否する（git のオプションとして扱わせない）" {
  for b in -v -foo --all; do
    run_common dw_base_branch "$(jq -nc --arg b "$b" '{base_branch: $b}')"
    assert_failure 2
    assert_output "error: 設定の base_branch が git のブランチ名として使えません: ${b}"
  done
}

@test "dw_base_branch は、書式に合わない値と、git が今の位置として扱う HEAD・@ を拒否する" {
  for b in "" "a..b" "a b" "x@{-1}" "@{-1}" "refs/" "a.lock" HEAD @; do
    run_common dw_base_branch "$(jq -nc --arg b "$b" '{base_branch: $b}')"
    assert_failure 2
    assert_output --partial "設定の base_branch が git のブランチ名として使えません"
  done
}

@test "dw_base_branch は、git fetch が refspec の強制更新の印と読む + で始まる値を拒否する" {
  run_common dw_base_branch '{"base_branch": "+develop"}'
  assert_failure 2
  assert_output "error: 設定の base_branch が git のブランチ名として使えません: +develop"
}

@test "dw_base_branch は、末尾に改行のある値を拒否する（改行を消してから検査しない）" {
  for b in $'develop\n' $'develop\n\n'; do
    run_common dw_base_branch "$(jq -nc --arg b "$b" '{base_branch: $b}')"
    assert_failure 2
    assert_output --partial "設定の base_branch が git のブランチ名として使えません"
  done
}

@test "dw_base_branch は、文字列でない base_branch を拒否する" {
  for v in null 1 true '["main"]'; do
    run_common dw_base_branch "{\"base_branch\": $v}"
    assert_failure 2
    assert_output "error: 設定の base_branch が文字列ではありません"
  done
}

@test "dw_team_base_branch は、チームの設定の base_branch を検査し、無ければプラグインの既定を使う" {
  run_common dw_team_base_branch ""
  assert_success
  assert_output main
  echo '{"base_branch": null}' >"$TMP/team.json"
  run_common dw_team_base_branch "$TMP/team.json"
  assert_output main
  echo '{"base_branch": "develop"}' >"$TMP/team.json"
  run_common dw_team_base_branch "$TMP/team.json"
  assert_output develop

  for v in 1 true '"-foo"'; do
    echo "{\"base_branch\": $v}" >"$TMP/team.json"
    run_common dw_team_base_branch "$TMP/team.json"
    assert_failure 2
  done
  # JSON のオブジェクトとして読めなければ（空のファイルも）、渡した名前で示して止まる
  for c in '{broken' '' '[]'; do
    printf '%s' "$c" >"$TMP/team.json"
    run_common dw_team_base_branch "$TMP/team.json" "チームの設定"
    assert_failure 2
    assert_output "error: チームの設定 を JSON のオブジェクトとして読めません"
  done
}

@test "dw_team_config も、チームの設定を JSON のオブジェクトとして読めなければ（空のファイルも）1 を返す" {
  echo '{"require_status_checks": false}' >"$TMP/team.json"
  run_common dw_team_config "$TMP/team.json" require_status_checks
  assert_success
  assert_output false
  for c in '{broken' '' '[]'; do
    printf '%s' "$c" >"$TMP/team.json"
    run_common dw_team_config "$TMP/team.json" require_status_checks
    assert_failure 1
    assert_output ""
  done
}

@test "base_branch は、dw_base_branch・dw_team_base_branch を通さずに設定から読まない" {
  # guard-git.sh は止まらずに使えない値を外すので、自分で dw_valid_base_branch で検査する（tests/guard-git.bats）
  # --exclude は busybox の grep に無いので、見つけた行から外す。シェルのコメントの行（# の後が空白か行末）は読んでいないので外す
  found="$(grep -rnE '\.base_branch|dw_team_config .*base_branch' "$SCRIPTS" "$SCRIPTS/../hooks" \
    | grep -v -e '/lib/common\.sh:' -e '/guard-git\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#([[:space:]]|$)' || true)"
  assert_equal "$found" ""
}

@test "dw_gh_version は、gh --version が1行目の後にたくさん出しても、パイプを途中で閉じて失敗しない（set -e・pipefail でも）" {
  mkdir -p "$TMP/bin"
  # 1行目の後に、パイプの容量（64 KiB）を大きく超える出力を続ける。読む側が1行で読むのをやめると、gh は SIGPIPE で終わる
  printf '#!/bin/sh\necho "gh version 2.96.0 (2026-07-02)"\nyes https://github.com/cli/cli/releases | head -n 100000\n' >"$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  PATH="$TMP/bin:$PATH" run "${TEST_BASH:-bash}" -c 'set -euo pipefail; . "$1"; v="$(dw_gh_version)"; echo "v=$v"' _ "$SCRIPTS/lib/common.sh"
  assert_success
  assert_output "v=2.96.0"
}

@test "dw_team_dir は、ユーザーの層と同じ場所なら空で、違えばチームの設定の置き場所を出す（シンボリックリンクや、まだ無いディレクトリも実体で比べる）" {
  # shellcheck disable=SC2016 # $1・$2 は bash -c の中で展開する
  team_dir() { "${TEST_BASH:-bash}" -c '. "$1"; dw_team_dir "$2"' _ "$SCRIPTS/lib/common.sh" "$1"; }
  # 違う場所
  assert_equal "$(team_dir "$REPO")" "$REPO/.claude/dev-workflow"
  # 同じ場所
  export WORKFLOW_USER_DIR="$REPO/.claude/dev-workflow"
  assert_equal "$(team_dir "$REPO")" ""
  # ディレクトリがまだ無くても同じ場所
  rm -rf "$REPO/.claude"
  assert_equal "$(team_dir "$REPO")" ""
  # ユーザーの層が、シンボリックリンクを通した同じ場所
  mkdir -p "$TMP/real/.claude/dev-workflow"
  ln -s "$TMP/real" "$TMP/link"
  export WORKFLOW_USER_DIR="$TMP/link/.claude/dev-workflow"
  assert_equal "$(team_dir "$TMP/real")" ""
  # チームの設定のほうがシンボリックリンク
  export WORKFLOW_USER_DIR="$TMP/real/.claude/dev-workflow"
  rm -rf "$REPO/.claude"
  mkdir -p "$REPO/.claude"
  ln -s "$TMP/real/.claude/dev-workflow" "$REPO/.claude/dev-workflow"
  assert_equal "$(team_dir "$REPO")" ""
}

@test "ホームのリポジトリは、ユーザーの層のファイルがあっても導入したとみなさない（dw_is_set_up）" {
  # shellcheck disable=SC2016 # $1・$2 は bash -c の中で展開する
  is_set_up() { "${TEST_BASH:-bash}" -c '. "$1"; dw_is_set_up "$2"' _ "$SCRIPTS/lib/common.sh" "$1"; }
  mark_set_up
  run is_set_up "$REPO"
  assert_success
  make_home_repo
  run is_set_up "$REPO"
  assert_failure
  # ワークツリーも、メインのワークツリーがホームのリポジトリなら導入したとみなさない
  git worktree add -q "$TMP/wt" -b feature
  run is_set_up "$TMP/wt"
  assert_failure
}

@test "ホームのリポジトリのワークツリーは、ユーザーの層のファイルをコミットしてあっても、導入したとみなさない（dw_is_set_up）" {
  # shellcheck disable=SC2016 # $1・$2 は bash -c の中で展開する
  wt_is_set_up() { "${TEST_BASH:-bash}" -c '. "$1"; dw_is_set_up "$2"' _ "$SCRIPTS/lib/common.sh" "$1"; }
  make_home_repo
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  git add -f .claude/dev-workflow/config.json
  git commit -q -m "user layer"
  git worktree add -q "$TMP/wt" -b feature
  # ワークツリーには、コミットされたファイルの写しがある（ユーザーの層とは別の場所）
  [ -f "$TMP/wt/.claude/dev-workflow/config.json" ]
  run wt_is_set_up "$TMP/wt"
  assert_failure
  run wt_is_set_up "$REPO"
  assert_failure
}

@test "dw_team_dir は、メインのワークツリーがホームのリポジトリなら、リンクされたワークツリーでも何も出さない" {
  # shellcheck disable=SC2016 # $1・$2 は bash -c の中で展開する
  wt_team_dir() { "${TEST_BASH:-bash}" -c '. "$1"; dw_team_dir "$2"' _ "$SCRIPTS/lib/common.sh" "$1"; }
  git worktree add -q "$TMP/wt" -b feature
  # ホームのリポジトリでなければ、ワークツリーでも出す
  run wt_team_dir "$TMP/wt"
  assert_output "$TMP/wt/.claude/dev-workflow"
  make_home_repo
  run wt_team_dir "$TMP/wt"
  assert_output ""
  run wt_team_dir "$REPO"
  assert_output ""
}

@test "dw_team_dir は、引数が無くても set -u で落ちず、何も出さない" {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c 'set -eu; . "$1"; dw_team_dir; echo ok' _ "$SCRIPTS/lib/common.sh"
  assert_success
  assert_output ok
}

@test "dw_pr_pick は、fork を除いた最初の PR とマージ先を出し、使えないマージ先と、マージ先の違う複数の PR は fallback の理由で知らせ、JSON でなければ 1 を返す（#284）" {
  # 応答 → 4行（マージ先・fallback の理由・PR が示したマージ先（JSON）・選んだ PR）
  pick() {
    run_common dw_pr_pick "$1" main
    assert_success
    assert_equal "$output" "$(printf '%s\n%s\n%s\n%s' "$2" "$3" "$4" "$5")"
  }
  # PR が無い
  pick '[]' main '' null null
  # 同じリポジトリの PR
  pick '[{"number": 5, "baseRefName": "release/v1", "isCrossRepository": false}]' release/v1 '' '"release/v1"' '{"number":5,"baseRefName":"release/v1","isCrossRepository":false}'
  # fork の PR は除き、同じリポジトリの PR を選ぶ
  pick '[{"number": 9, "baseRefName": "fork/x", "isCrossRepository": true}, {"number": 5, "baseRefName": "release/v1", "isCrossRepository": false}]' release/v1 '' '"release/v1"' '{"number":5,"baseRefName":"release/v1","isCrossRepository":false}'
  # fork の PR だけ
  pick '[{"number": 9, "baseRefName": "release/v1", "isCrossRepository": true}]' main '' null null
  # マージ先が無いか空（gh が返さない）なら、base_branch にする（fallback ではない）
  pick '[{"number": 5, "isCrossRepository": false}]' main '' '""' '{"number":5,"isCrossRepository":false}'
  pick '[{"number": 5, "baseRefName": "", "isCrossRepository": false}]' main '' '""' '{"number":5,"baseRefName":"","isCrossRepository":false}'
  # 日本語のブランチ名は使える
  pick '[{"number": 5, "baseRefName": "feat/日本語", "isCrossRepository": false}]' feat/日本語 '' '"feat/日本語"' '{"number":5,"baseRefName":"feat/日本語","isCrossRepository":false}'
  # 同じマージ先の PR が複数あっても、マージ先は1つに決まる
  pick '[{"number": 5, "baseRefName": "release/v1"}, {"number": 6, "baseRefName": "release/v1"}]' release/v1 '' '"release/v1"' '{"number":5,"baseRefName":"release/v1"}'
  # マージ先が無いか空の PR は base_branch に向いているとみなして比べる（main の PR と並んでも multiple_prs にしない）
  pick '[{"number": 5, "baseRefName": ""}, {"number": 6, "baseRefName": "main"}]' main '' '""' '{"number":5,"baseRefName":""}'
  pick '[{"number": 5}, {"number": 6, "baseRefName": "main"}]' main '' '""' '{"number":5}'
  pick '[{"number": 5, "baseRefName": ""}, {"number": 6, "baseRefName": "release/v1"}]' main multiple_prs '""' '{"number":5,"baseRefName":""}'
  # マージ先の違う PR が複数あれば multiple_prs（マージ先は最初の PR のもの）
  pick '[{"number": 5, "baseRefName": "release/v1"}, {"number": 6, "baseRefName": "main"}]' release/v1 multiple_prs '"release/v1"' '{"number":5,"baseRefName":"release/v1"}'
  # git のブランチ名として使えない値は invalid_name で、マージ先は base_branch
  for b in -x +x HEAD @ 'a..b' 'a b'; do
    pick "$(jq -nc --arg b "$b" '[{number: 5, baseRefName: $b}]')" main invalid_name "$(jq -n --arg b "$b" '$b')" "$(jq -nc --arg b "$b" '{number: 5, baseRefName: $b}')"
  done
  # 制御文字（改行・\u0001 など）を含む値も invalid_name。行には制御文字を出さない（bash 3.2 の here-string と read でも落ちない）
  pick '[{"number": 5, "baseRefName": "a\nb"}]' main invalid_name '"a\nb"' '{"number":5,"baseRefName":"a\nb"}'
  pick '[{"number": 5, "baseRefName": "a\u0001b"}]' main invalid_name '"a\u0001b"' '{"number":5,"baseRefName":"a\u0001b"}'
  pick '[{"number": 5, "baseRefName": "\u0001"}]' main invalid_name '"\u0001"' '{"number":5,"baseRefName":"\u0001"}'
  # JSON の配列として読めない応答
  for r in 'not json' '' '{}' '"x"'; do
    run_common dw_pr_pick "$r" main
    assert_failure 1
    assert_output ""
  done
}

@test "dw_json_enum_ok は、null か一覧のどれかの文字列なら 0、それ以外（読めない JSON を含む）は 1 を返す" {
  list='["low", "high"]'
  for v in null '"low"' '"high"'; do
    run_common dw_json_enum_ok "$list" "$v"
    assert_success
  done
  for v in '"Low"' '"medium"' '""' 1 true '["low"]' '{"v": "low"}' 'low' ''; do
    run_common dw_json_enum_ok "$list" "$v"
    assert_failure 1
    assert_output ""
  done
}

@test "dw_json_enum_names は、一覧を「・」でつないで出す" {
  run_common dw_json_enum_names '["low", "medium", "high"]'
  assert_success
  assert_output "low・medium・high"
}

@test "dw_json_enum_ok は、一覧が1つの配列でなければ（文字列・複数の値・オブジェクト・読めない JSON）当てない" {
  # 一覧が文字列だと、jq の index が部分文字列で当たってしまう（"slow" の中の "low"）
  for list in '"slow"' '1 ["low"]' '["low"] ["high"]' '{"low": 1}' '[low' ''; do
    run_common dw_json_enum_ok "$list" '"low"'
    assert_failure 1
    assert_output ""
  done
}

@test "設定の値の一覧の定数（DW_REVIEW_MODELS・DW_CODE_REVIEW_EFFORTS）は、空でない文字列の配列" {
  for name in DW_REVIEW_MODELS DW_CODE_REVIEW_EFFORTS; do
    # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
    run "${TEST_BASH:-bash}" -c '. "$1"; printf "%s" "${!2}"' _ "$SCRIPTS/lib/common.sh" "$name"
    assert_success
    jq -s -e 'length == 1 and (.[0] | type == "array" and length > 0 and all(.[]; type == "string" and . != ""))' <<<"$output" >/dev/null \
      || fail "${name} が空でない文字列の配列ではありません: ${output}"
  done
}

# 所有者が repos のリポジトリ（API の URL が .../repos/repos/<名前>）を読む偽の gh を置く。
# gh api repos/<所有者>/<名前>/issues/<番号>/parent は $TMP/fix/parent-<番号>.json を返し（無ければ 404。FAKE_FAIL_PARENT があれば 500）、
# 「GetParent <番号>」を $TMP/fix/calls に記録する。
# gh api --paginate <パス>/items ... は $TMP/fix/items.json を返す
fake_gh_repos_owner() {
  mkdir -p "$TMP/bin" "$TMP/fix"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*/parent)
    n="${2%/parent}"
    n="${n##*/}"
    echo "GetParent $n" >>"$FIX/calls"
    [ -z "${FAKE_FAIL_PARENT:-}" ] || { echo 'gh: Server Error (HTTP 500)' >&2; exit 1; }
    [ -f "$FIX/parent-$n.json" ] || { echo 'gh: No parent issue found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/parent-$n.json"
    ;;
  "api --paginate") cat "$FIX/items.json" ;;
  *) echo "gh: unexpected $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" FIX="$TMP/fix"
}

@test "dw_issue_parents・dw_sub_issue_depth・dw_project_item は、所有者の名前が repos でもリポジトリを正しく読む" {
  fake_gh_repos_owner
  for n in 10 5; do
    jq -n --argjson n "$n" '{number: $n, title: "親 \($n)", state: "open", url: "https://api.github.com/repos/repos/demo/issues/\($n)",
      repository_url: "https://api.github.com/repos/repos/demo"}' >"$FIX/parent-$((n == 10 ? 17 : 10)).json"
  done
  run_common dw_issue_parents repos/demo 17
  assert_success
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[10,5]'
  run_common dw_sub_issue_depth '{"url": "https://api.github.com/repos/repos/demo/issues/17"}' 1 3
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":{"number":10,"repo":"repos/demo"}}'
  jq -n '[{node_id: "IT12", content: {number: 12, repository_url: "https://api.github.com/repos/repos/demo"}}]' >"$FIX/items.json"
  run_common dw_project_item users/me/projectsV2/4 repos/demo 12
  assert_success
  assert_equal "$(jq -r .node_id <<<"$output")" IT12
}

@test "dw_sub_issue_depth は、下に付ける層を含めた深さを数え、上限を超えると分かったらたどるのを止めて depth を null にする" {
  fake_gh_repos_owner
  for c in 17:10 10:5 5:2; do
    jq -n --argjson n "${c#*:}" '{number: $n, url: "https://api.github.com/repos/me/demo/issues/\($n)",
      repository_url: "https://api.github.com/repos/me/demo"}' >"$FIX/parent-${c%%:*}.json"
  done
  issue='{"url": "https://api.github.com/repos/me/demo/issues/17"}'
  calls() { grep -c '^GetParent ' "$FIX/calls" || true; }
  # 17 の上に親が 3 個。上限 3・下に 1 層なら、親を 2 個数えたところで超えると分かる
  : >"$FIX/calls"
  run_common dw_sub_issue_depth "$issue" 1 3
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":{"number":10,"repo":"me/demo"}}'
  assert_equal "$(calls)" 2
  # 下の層だけで上限に届けば、たどらない。<最低の回数> を渡せば、その回数はたどる
  : >"$FIX/calls"
  run_common dw_sub_issue_depth "$issue" 3 3
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":null}'
  assert_equal "$(calls)" 0
  run_common dw_sub_issue_depth "$issue" 3 3 1
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":{"number":10,"repo":"me/demo"}}'
  assert_equal "$(calls)" 1
  # 連鎖を 17 → 10 → 5（5 には親が無い）にしても、上限 3・下に 1 層では、親を 2 個数えた時点で超えると分かるので、
  # 5 の上は読まずに打ち切り、depth は null にする
  : >"$FIX/calls"
  rm "$FIX/parent-5.json"
  run_common dw_sub_issue_depth "$issue" 1 3
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":{"number":10,"repo":"me/demo"}}'
  assert_equal "$(calls)" 2
  # 連鎖を 17 → 10（10 には親が無い）にすると、上限の手前で親が尽きるので、depth は数えた値（10 が 1 層目、17 が 2 層目、下が 3 層目）
  rm "$FIX/parent-10.json"
  run_common dw_sub_issue_depth "$issue" 1 3
  assert_success
  assert_equal "$output" '{"depth":3,"exceeds":false,"first":{"number":10,"repo":"me/demo"}}'
  rm "$FIX/parent-17.json"
  run_common dw_sub_issue_depth "$issue" 2 3
  assert_success
  assert_equal "$output" '{"depth":3,"exceeds":false,"first":null}'
  run_common dw_sub_issue_depth "$issue" 1 1
  assert_success
  assert_equal "$output" '{"depth":null,"exceeds":true,"first":null}'
}

@test "dw_sub_issue_depth の親の repo は、repository_url があればそこから作り、無ければ url から作る" {
  fake_gh_repos_owner
  # url と repository_url を食い違わせて、どちらから作ったかを見分ける
  jq -n '{number: 10, url: "https://api.github.com/repos/me/demo/issues/10", repository_url: "https://api.github.com/repos/Me/Demo"}' >"$FIX/parent-17.json"
  run_common dw_sub_issue_depth '{"url": "https://api.github.com/repos/me/demo/issues/17"}' 1 3
  assert_success
  assert_equal "$(jq -c .first <<<"$output")" '{"number":10,"repo":"Me/Demo"}'
  jq -n '{number: 10, url: "https://api.github.com/repos/me/demo/issues/10"}' >"$FIX/parent-17.json"
  run_common dw_sub_issue_depth '{"url": "https://api.github.com/repos/me/demo/issues/17"}' 1 3
  assert_success
  assert_equal "$(jq -c .first <<<"$output")" '{"number":10,"repo":"me/demo"}'
}

@test "dw_sub_issue_depth は、親を読めなければ（404 以外）失敗する" {
  fake_gh_repos_owner
  FAKE_FAIL_PARENT=1 run_common dw_sub_issue_depth '{"url": "https://api.github.com/repos/me/demo/issues/17"}' 1 3
  assert_failure
  assert_output --partial "GitHub の API に失敗しました"
}

# dw_gh_run のための偽の gh。標準出力に $FAKE_OUT、標準エラーに $FAKE_ERR を出し、終了コード $FAKE_RC で終わる
fake_gh_run() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_OUT:-}" ] || printf '%s\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

@test "dw_gh_run は、成功すれば標準出力だけを出し（gh のお知らせを混ぜない）、失敗すれば理由を1行で標準エラーに出す（#323）" {
  fake_gh_run
  notice=$'A new release of gh is available: 2.0.0 → 2.1.0\nTo upgrade, run: gh upgrade\nhttps://github.com/cli/cli/releases/tag/v2.1.0'
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  out="$(FAKE_OUT='{"a": 1}' FAKE_ERR="$notice" "${TEST_BASH:-bash}" -c '. "$1"; dw_gh_run api x' _ "$SCRIPTS/lib/common.sh" 2>"$TMP/err")"
  assert_equal "$out" '{"a": 1}'
  # GraphQL の errors があれば、その本文を理由にする（複数なら「; 」でつなぐ）
  FAKE_OUT='{"errors": [{"message": "a"}, {"message": "b\nc"}]}' FAKE_ERR='gh: failed' FAKE_RC=1 run_common dw_gh_run api graphql
  assert_failure 1
  assert_output 'a; b c'
  # 無ければ、お知らせを除いた標準エラーの最後の行
  FAKE_ERR=$'gh: HTTP 502\n\n'"$notice" FAKE_RC=1 run_common dw_gh_run api x
  assert_failure 1
  assert_output 'gh: HTTP 502'
  # 何も無ければ、終了コードを添えた1行
  FAKE_RC=4 run_common dw_gh_run api x
  assert_failure 4
  assert_output 'gh が失敗しました（終了コード 4）'
}

@test "dw_warn_once は、warn の種類（最初の「: 」より前の文）ごとに1回だけ出す（後ろの文が変わっても。#323）" {
  printf '%s\n' 'warn: 読めません: gh: HTTP 502' 'warn: 別の種類' 'ほかの行' >"$TMP/w1"
  printf '%s\n' 'warn: 読めません: gh: HTTP 503' 'warn: 別の種類' 'warn: 新しい種類: x' >"$TMP/w2"
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1"; dw_warn_once "$2" "$4"; dw_warn_once "$3" "$4"' _ "$SCRIPTS/lib/common.sh" "$TMP/w1" "$TMP/w2" "$TMP/seen"
  assert_success
  assert_output $'warn: 読めません: gh: HTTP 502\nwarn: 別の種類\nwarn: 新しい種類: x'
}

# 1行が約 4096 バイトを超え、その区切りに絵文字がかかる入力を、標準入力の jq -R・-R -s で読むと、絵文字が壊れる（jq の不具合）。
# 文を jq に渡すには、dw_jq_text・dw_json_lines・dw_json_lines_nonempty（--rawfile 経由）を使う
@test "dw_json_lines_nonempty は、空行を除いた行の配列にし、フィルターと jq の引数を受け取り、4096 バイトの区切りに絵文字がかかっても壊さない" {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  nonempty() { run "${TEST_BASH:-bash}" -c '. "$1"; shift; printf "$1" | { shift; dw_json_lines_nonempty "$@"; }' _ "$SCRIPTS/lib/common.sh" "$@"; }
  nonempty 'a\n\nb\n'
  assert_output '["a","b"]'
  nonempty ''
  assert_output '[]'
  nonempty 'b\na\nb\n' 'unique'
  assert_output '["a","b"]'
  # shellcheck disable=SC2016 # jq の変数は bash に展開させない
  nonempty 'a\n' '. + $e | map(select(. != "")) | unique' --argjson e '["z",""]'
  assert_output '["a","z"]'
  for pad in 4092 4093 4094; do
    text="$(head -c "$pad" /dev/zero | tr '\0' a)😀tail"
    # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
    run "${TEST_BASH:-bash}" -c '. "$1"; printf "%s\n\n%s\n" "$2" "$2" | dw_json_lines_nonempty' _ "$SCRIPTS/lib/common.sh" "$text"
    assert_success
    assert_equal "$(jq -c --arg t "$text" '. == [$t, $t]' <<<"$output")" true
  done
}

@test "dw_json_lines は、jq -R . | jq -sc . と同じ行の配列にする（最後の改行の後ろの空は数えず、空行は数える）" {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run_lines() { run "${TEST_BASH:-bash}" -c '. "$1"; printf "$2" | dw_json_lines' _ "$SCRIPTS/lib/common.sh" "$1"; }
  run_lines ''
  assert_output '[]'
  run_lines 'a'
  assert_output '["a"]'
  run_lines 'a\n'
  assert_output '["a"]'
  run_lines 'a\n\nb\n'
  assert_output '["a","","b"]'
  run_lines '\n'
  assert_output '[""]'
  text="$(head -c 4094 /dev/zero | tr '\0' a)😀"
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1"; printf "%s\n%s\n" "$2" "$2" | dw_json_lines' _ "$SCRIPTS/lib/common.sh" "$text"
  assert_success
  assert_equal "$(jq -c --arg t "$text" '. == [$t, $t]' <<<"$output")" true
}

# 標準入力のスクリプトから、jq に -R（-Rs・-sR・--raw-input など）を渡している行を出す。
# 行末の \ で続く行は1行につなぎ、コメントの行（# で始まる行）は除く。jq の語ごとに、後ろの引数を1文字ずつ読み、
# 引用符の中の文字列と $(...) の中は「x」に置き換えて（引数の中身に惑わされない）、引用符の外の | ; & ) < > まで（コマンドの終わり）を、
# フラグを探す対象にする。引数に $(...) や引用符を挟んでも拾う。$(...) の中の jq は、その中で別に探す。
# macOS の awk は、日本語の入った行を文字として読もうとして失敗する（towc: multibyte conversion failure）ので、バイト列として読ませる
raw_jq_hits() {
  LC_ALL=C awk '
    function flag(rest,   i, c, q, depth, flat, n, d) {
      flat = ""; q = ""; depth = 0
      n = length(rest)
      for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        if (depth > 0) {
          if (c == "(") depth++
          else if (c == ")") depth--
          continue
        }
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (q == "\"") {
          if (c == "\\") { i++; continue }
          if (c == "\"") { q = ""; continue }
          if (c == "$" && substr(rest, i + 1, 1) == "(") { depth = 1; i++; continue }
          continue
        }
        if (c == "\047" || c == "\"") { q = c; flat = flat "x"; continue }
        if (c == "$" && substr(rest, i + 1, 1) == "(") { depth = 1; i++; flat = flat "x"; continue }
        if (c ~ /[|;&)<>]/) break
        flat = flat c
      }
      return (flat ~ /(^| )-[A-Za-z]*R[A-Za-z]*( |$)/ || flat ~ /(^| )--raw-input( |$)/)
    }
    function scan(line,   pos, rest, prev, found) {
      found = 0
      rest = line
      pos = 0
      while (match(rest, /jq( |$)/)) {
        prev = (RSTART + pos > 1) ? substr(line, RSTART + pos - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_.\/-]/ && flag(substr(rest, RSTART + 2))) found = 1
        pos += RSTART + 1
        rest = substr(rest, RSTART + 2)
      }
      return found
    }
    { if (sub(/\\$/, "")) { buf = buf $0; next } line = buf $0; buf = "" }
    line !~ /^[[:space:]]*#/ && scan(line) { print line }
  '
}

@test "raw_jq_hits は、jq -R の書き方（引数を挟む・\$(...) や引用符を挟む・継続行にある）を拾い、コメントや jq でないコマンドは拾わない" {
  hit() { assert_equal "$(printf '%s\n' "$1" | raw_jq_hits)" "$1"; }
  hit "x=\$(printf a | jq -R -s .)"
  hit "jq -Rs ."
  hit "jq -sR ."
  hit "jq --raw-input ."
  hit "jq -r --arg x \"\$y\" -R '.'"
  hit "jq --arg a b -Rs '.'"
  hit "jq -c --argjson e \"\$extra\" -R -s 'split(1)'"
  hit "jq --arg x \"\$(foo)\" -Rs ."
  hit "jq --argjson c \"\$(jq -c .a <<<\"\$x\")\" -R ."
  hit "out=\"\$(foo | jq -r --arg b '|;)' -R .)\""
  hit "jq -r --arg x \$(foo) -Rs . <<<\"\$y\""
  hit "echo \"\$(jq -Rs . <f)\" && jq . g"
  assert_equal "$(printf '%s\n' $'jq -r \\' $'  -R "$p"' | raw_jq_hits)" $'jq -r   -R "$p"'
  assert_equal "$(printf '%s\n' $'jq -r --arg a b \\' $'  --arg c d \\' $'  -Rs "$p"' | raw_jq_hits | grep -c -- -Rs)" 1
  # shellcheck disable=SC2016 # 引数は、検査する行の文字列で、展開しない
  assert_equal "$(printf '%s\n' '# jq -R は使わない' '  # jq -Rs' 'jq -r .a' 'sort -R' 'jq .a | sort -R' 'jq --arg r "x" .a' 'ls -R | jq .' 'jq -r --arg x "$(foo -R)" .a' "jq -r '-R' .a" 'myjq -R .' 'jq -n --rawfile s /dev/stdin "$s"' | raw_jq_hits)" ""
}

@test "scripts/ と hooks/ に、標準入力の jq -R・-R -s（--raw-input）が残っていない（絵文字が壊れるため。dw_jq_text を使う）" {
  hits=""
  while IFS= read -r f; do
    h="$(raw_jq_hits <"$f")"
    [ -z "$h" ] || hits="${hits}${f}: ${h}"$'\n'
  done < <(find "$SCRIPTS" "$SCRIPTS/../hooks" -type f -name '*.sh')
  assert_equal "$hits" ""
}

# md_scan を直接呼ぶ。使い方: md_scan_of <Markdown の本文> <jq のフィルター>
md_scan_of() {
  # shellcheck disable=SC2016 # DW_JQ_MD_SCAN と $b は jq のプログラムなので、bash に展開させない
  run "${TEST_BASH:-bash}" -c '. "$1"; jq -nc --arg b "$2" "$DW_JQ_MD_SCAN"'"'"'$b | md_scan | '"'"'"$3"' _ "$SCRIPTS/lib/common.sh" "$1" "$2"
}

@test "md_scan：複数行のコメントを閉じる行の --> の後ろの文字は、本文の行として lines に残す（項目や見出しにはしない）" {
  md_scan_of $'<!-- 例:\n- [ ] 隠れる\n--> 後ろの文字\n- [ ] 見える' '[.lines[] | [.line, .text]], [.items[].text], .headings'
  assert_success
  assert_output $'[[2," 後ろの文字"],[3,"- [ ] 見える"]]\n["見える"]\n[]'
  # GitHub では、--> の後ろは HTML ブロックの続きとして表示され、Markdown としては読まれない（gh api markdown で確かめた）
  md_scan_of $'<!-- a\n--> - [ ] x\n- [ ] y' '[.items[].text], [.lines[].text]'
  assert_output $'["y"]\n[" - [ ] x","- [ ] y"]'
  md_scan_of $'<!-- a\n--> # h\n- [ ] y' '.headings, [.lines[].text]'
  assert_output $'[]\n[" # h","- [ ] y"]'
}

@test "md_scan：コメントを閉じる行の --> だけの行（後ろが空）は、lines に残さない" {
  md_scan_of $'<!-- a\n-->\n- [ ] y' '[.lines[] | [.line, .text]]'
  assert_output '[[2,"- [ ] y"]]'
}

@test "md_scan：コメントを閉じる行の --> の後ろに閉じない <!-- があれば、GitHub と同じく文書の最後まで隠す" {
  # gh api markdown で確かめた：閉じない <!-- は、後ろの --> があっても、文書の最後までを隠す
  md_scan_of $'<!-- a\n--> x <!-- b\n-->\n- [ ] y' '[.lines[] | [.line, .text]], [.items[].text]'
  assert_output $'[[1," x <!-- b"]]\n[]'
  # 後ろでコメントが閉じていれば、続きは読む
  md_scan_of $'<!-- a\n--> x <!-- b -->\n- [ ] y' '[.items[].text]'
  assert_output '["y"]'
}

@test "md_scan：行の途中で始まる複数行のコメントは、コメントとみなさない（GitHub は <!-- を文字として表示し、間の行も表示する）" {
  # gh api markdown で確かめた：段落や項目の中の <!-- は、閉じる --> が後の行にあっても、そのまま表示され、間の項目も項目になる
  md_scan_of $'text <!-- start\n- [ ] 見える\nend -->\n- [ ] b' '[.items[] | [.line, .text]], [.lines[].text]'
  assert_output $'[[1,"見える"],[3,"b"]]\n["text <!-- start","- [ ] 見える","end -->","- [ ] b"]'
  md_scan_of $'- [ ] foo <!-- note\n- [ ] bar\n-->' '[.items[].text]'
  assert_output '["foo <!-- note","bar"]'
}
