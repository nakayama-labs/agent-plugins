#!/usr/bin/env bats
# repair-push-check.sh：無人で push する前の、パスの機械的な確認（ADR 000285）。本物の git で確かめる。

load test_helper

setup() {
  test_helper_setup
  # origin（bare）を作って、main を push する
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  mkdir -p .github/workflows .claude/dev-workflow src
  echo a >src/a.txt
  echo w >.github/workflows/ci.yml
  git add -A && git commit -q -m base
  git push -q origin main
  git checkout -q -b feat/1-x
}

commit_file() { mkdir -p "$(dirname "$1")" && echo "$2" >"$1" && git add "$1" && git commit -q -m "change $1"; }
# ファイルを書かずに、index に直接パスを入れてコミットする。大文字と小文字を区別しないファイルシステム（macOS）では、
# .GitHub/x を書くと既にある .github/ に入り、git が .github/x と記録するので、綴りどおりのパスを作るのに使う
commit_index_only() {
  local blob
  blob=$(echo "$2" | git hash-object -w --stdin) && git update-index --add --cacheinfo "100644,$blob,$1" && git commit -q -m "change $1"
}

@test "通常のファイルだけなら ok" {
  commit_file src/b.txt b
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"ok":true,"forbidden":[],"compared_with":"origin/main"}'
}

@test ".github/workflows/ を変えていたら ok が false で、そのパスを返す" {
  commit_file .github/workflows/ci.yml changed
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,[".github/workflows/ci.yml"]]'
}

@test ".claude/ を新しく足していたら ok が false" {
  commit_file .claude/dev-workflow/x.json '{}'
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,[".claude/dev-workflow/x.json"]]'
}

@test "取り込んだ main が変えた .github/workflows/ は数えない（main と同じ内容のパス）" {
  # main が workflows を変え、それを取り込む
  git checkout -q main
  commit_file .github/workflows/ci.yml from-main
  git push -q origin main
  git checkout -q feat/1-x
  commit_file src/b.txt b
  git fetch -q origin
  git merge -q --no-edit origin/main
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[true,[]]'
}

@test "origin のブランチがあれば、それとの差だけを見る（push 済みの変更は数えない）" {
  commit_file .github/workflows/ci.yml pushed
  git push -q origin feat/1-x
  commit_file src/b.txt b
  git fetch -q origin
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .compared_with]' <<<"$output")" '[true,"origin/feat/1-x"]'
}

@test "origin/<base> が無いと止まる" {
  run_script repair-push-check.sh --base-branch nothing
  assert_failure 2
}

@test "--base-branch が無いと止まる" {
  run_script repair-push-check.sh
  assert_failure 64
}

@test "禁止パスから名前を変えて出したときも、元のパスを返す（名前の変更で漏れない）" {
  git mv .github/workflows/ci.yml src/ci.yml
  git commit -q -m rename
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".github/workflows/ci.yml"]]'
}

@test "パスの [ を glob にしない（main と同じ内容のパスを、別のパスの変更で禁止にしない）" {
  git push -q origin feat/1-x
  git checkout -q main
  commit_file '.claude/[a].txt' same
  git push -q origin main
  git checkout -q feat/1-x
  git fetch -q origin
  git merge -q --no-edit origin/main
  commit_file '.claude/a.txt' changed
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,[".claude/a.txt"]]'
}

@test "detached HEAD で --branch が無いと止まる。--branch があれば進む" {
  commit_file src/b.txt b
  git checkout -q --detach
  run_script repair-push-check.sh --base-branch main
  assert_failure 64
  run_script repair-push-check.sh --base-branch main --branch feat/1-x
  assert_success
  assert_equal "$(jq -r .compared_with <<<"$output")" origin/main
}

@test "--branch X：origin/X があれば origin/X、無ければ origin/<base> との差を見る" {
  commit_file src/b.txt b
  git push -q origin feat/1-x
  git fetch -q origin
  run_script repair-push-check.sh --base-branch main --branch feat/1-x
  assert_success
  assert_equal "$(jq -r .compared_with <<<"$output")" origin/feat/1-x
  run_script repair-push-check.sh --base-branch main --branch feat/none
  assert_success
  assert_equal "$(jq -r .compared_with <<<"$output")" origin/main
}

@test "値の無い --base-branch・--branch と、不明な引数は 64 で止まる" {
  run_script repair-push-check.sh --base-branch
  assert_failure 64
  run_script repair-push-check.sh --base-branch main --branch
  assert_failure 64
  run_script repair-push-check.sh --base-branch main --nope
  assert_failure 64
}

@test "workflows と .claude を同時に変えると forbidden は 2 件" {
  commit_file .github/workflows/ci.yml changed
  commit_file .claude/dev-workflow/x.json '{}'
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".claude/dev-workflow/x.json",".github/workflows/ci.yml"]]'
}

@test ".github/ 以下は workflows でなくても止める（actions・scripts・CODEOWNERS。#331）" {
  commit_file .github/scripts/x.sh '#!/bin/sh'
  commit_file .github/actions/setup/action.yml 'runs: {}'
  commit_file .github/CODEOWNERS '* @someone'
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".github/CODEOWNERS",".github/actions/setup/action.yml",".github/scripts/x.sh"]]'
}

@test "入れ子の .claude/ 以下も止める（どの階層でも。#331）" {
  commit_file packages/app/.claude/settings.json '{}'
  commit_file a/b/c/.claude/skills/x/SKILL.md x
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,["a/b/c/.claude/skills/x/SKILL.md","packages/app/.claude/settings.json"]]'
}

@test "名前が似ているだけのパスと、入れ子の .github/ は止めない" {
  commit_file src/.claudex/a.txt a
  commit_file src/x.claude/a.txt a
  commit_file docs/.github/a.txt a
  commit_file .githubx/a.txt a
  commit_file .claude.md a
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[true,[]]'
}

@test "取り込んだ main が変えた入れ子の .claude/ は数えない（main と同じ内容のパス）" {
  git checkout -q main
  commit_file sub/.claude/settings.json from-main
  git push -q origin main
  git checkout -q feat/1-x
  commit_file src/b.txt b
  git fetch -q origin
  git merge -q --no-edit origin/main
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[true,[]]'
}

@test "git diff が失敗したら、禁止パスなしと読まずに終了コード 2 で止まる（ok:true を出さない）" {
  commit_file .github/workflows/ci.yml changed
  real_git="$(command -v git)"
  mkdir -p "$TMP/shim"
  cat >"$TMP/shim/git" <<SHIM
#!/usr/bin/env bash
case "\$*" in *"diff --name-only"*) echo "fatal: simulated" >&2; exit 128 ;; esac
exec "$real_git" "\$@"
SHIM
  chmod +x "$TMP/shim/git"
  PATH="$TMP/shim:$PATH" run_script repair-push-check.sh --base-branch main
  assert_failure 2
  refute_output --partial '"ok":true'
  assert_output --partial "git diff に失敗しました"
}

@test ".github・.claude という名前そのもの（ファイル・シンボリックリンク）も止める" {
  # 名前をファイルとシンボリックリンクにするため、先にディレクトリを消して push しておく（.claude は追跡していない空のディレクトリ）
  git rm -q -r .github
  rm -rf .github .claude
  git commit -q -m "rm dirs"
  git push -q origin feat/1-x
  echo x >.github
  ln -s /tmp .claude
  mkdir -p sub && ln -s ../src sub/.claude
  git add .github .claude sub/.claude && git commit -q -m names
  git fetch -q origin
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".claude",".github","sub/.claude"]]'
}

@test ".claude という名前のサブモジュール（gitlink）も止める" {
  git init -q "$TMP/sub" && git -C "$TMP/sub" commit -q --allow-empty -m s
  git -c protocol.file.allow=always submodule -q add "$TMP/sub" pkg/.claude
  git commit -q -m submodule
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,["pkg/.claude"]]'
}

@test "大文字と小文字を区別せずに止める（.Claude/・sub/.CLAUDE/・.GitHub/）" {
  commit_index_only .Claude/settings.json '{}'
  commit_index_only sub/.CLAUDE/x x
  commit_index_only .GitHub/x x
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".Claude/settings.json",".GitHub/x","sub/.CLAUDE/x"]]'
}

@test "NTFS で同じ名前になる別名（末尾の点・空白）も止める（.claude.・.github ・sub/.claude. ./x。#356）" {
  commit_index_only '.claude./settings.json' '{}'
  commit_index_only '.github /x' x
  commit_index_only 'sub/.claude. ./x' x
  commit_index_only '.github..' x
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,[".claude./settings.json",".github /x",".github..","sub/.claude. ./x"]]'
}

@test "NTFS の 8.3 形式の短い名前（CLAUDE~1・GITHUB~1）も止める（#356）" {
  commit_index_only 'CLAUDE~1/settings.json' '{}'
  commit_index_only 'sub/claude~2/x' x
  commit_index_only 'GITHUB~1/workflows/ci.yml' x
  commit_index_only 'GITHUB~2' x
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, (.forbidden | sort)]' <<<"$output")" '[false,["CLAUDE~1/settings.json","GITHUB~1/workflows/ci.yml","GITHUB~2","sub/claude~2/x"]]'
}

@test "別名に似ているだけのパスと、入れ子の .github の別名は止めない（#356）" {
  commit_index_only 'docs/GITHUB~1/x' x
  commit_index_only 'claude~x/y' x
  commit_index_only '.claudex./y' x
  commit_index_only 'a.claude./y' x
  commit_index_only 'src/b.txt.' x
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[true,[]]'
}

@test "止めるパスの一覧の正本は --help にある（SKILL.md・設計書はここを参照する）" {
  run_script repair-push-check.sh --help
  assert_success
  assert_output --partial "止めるパス（無人で変えてはいけないパス。この一覧が正本"
  assert_output --partial ".github という名前そのもの"
  assert_output --partial "どの階層の .claude という名前そのもの"
  assert_output --partial "大文字と小文字は区別しない"
  assert_output --partial "NTFS"
  assert_output --partial "8.3"
}
