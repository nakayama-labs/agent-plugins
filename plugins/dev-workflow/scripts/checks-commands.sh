#!/usr/bin/env bash
# テストとチェックのコマンドを、設定から読む。設定が無ければ、リポジトリから決める手がかりを出す。
# branch-update（手順3）・gh-pr-check・review が、実行するコマンドを決めるのに使う。
#
# 使い方:
#   checks-commands.sh                                  設定と手がかりを出力する（何も変えない）
#   checks-commands.sh --save --scope S --command C ... 設定 checks.commands に保存する（--command は複数回）
#   checks-commands.sh --save --scope S --none          実行するものが無いと保存する（空の配列）
#
#   --scope S   書く層。local（<repo>/.claude/dev-workflow/config.local.json。自分だけ）・
#               team（<repo>/.claude/dev-workflow/config.json。コミットして共有する）
#
# 決め方（スキルが従う。出力の action で決まる）:
#   run      commands が空でない配列で、commands_changed が false。commands を、絞らずに全部順に実行する
#            （チームが決めた一覧なので、関係するものだけに絞らない）
#   confirm  commands が空でない配列で、commands_changed が true か null。PR の作者が決めた任意のコマンドになりうるので、
#            実行する前にコマンドを見せて確認を取り、確認が取れるまで実行しない（確認が取れたら run と同じく全部実行する）
#   none     commands が空の配列。実行するものが無いと決めてあること（何も実行せず、聞きもしない）
#   infer    commands が null。hints（リポジトリの手がかり）から実行するコマンドを推測する。推測できなければユーザーに聞く。
#            聞いた答えは --save で設定に保存するかも聞く（保存すれば次からは聞かない）
#
# 出力:
#   action     上の run・confirm・none・infer（commands と commands_changed から、スクリプトが決める）
#   commands   設定の checks.commands（配列か null）
#   commands_changed  リポジトリにコミットされた設定（チームの設定 .claude/dev-workflow/config.json と、git に追跡されている個人の設定）の
#              checks.commands が、今のブランチで書き換わったか。origin/HEAD（リモートの既定のブランチ）との merge-base の時点の値と比べる
#              （設定の base_branch は PR の作者が書き換えられるので使わない。追跡されていない個人の設定は自分のものなので比べない）。
#              true（書き換わった）・false（同じ。commands が null のときも false）・null（比べる基点 origin/HEAD が無いなど、比べられない。true と同じに扱う）
#   hints      リポジトリの手がかり（commands が null のときだけ調べる。configured のときは null）
#     contributing       CONTRIBUTING.md のパス（無ければ null）
#     package_scripts    package.json の scripts のうち、test・lint・check・typecheck・build・verify・ci で始まるもの（Makefile のターゲットと同じ条件）（名前 → コマンド。無ければ null）
#     makefile_targets   Makefile のターゲットのうち、同じ名前で始まるもの
#     ci_workflows       CI の設定ファイルのパス
#     project_files      ビルドやテストの手がかりになるファイル（Cargo.toml・go.mod・pyproject.toml など）のパス
#   saved      --save のときだけ。{file, scope, commands, local_hint, warning}（local_hint は個人の設定が git に無視されていないときの案内か null。
#              warning は、保存した層より優先される層が別の値を決めていて、保存した値が使われないときの知らせか null）
#
# 止まるとき: checks.commands が null でも配列でもない・文字列でない要素や空の要素がある（終了コード 2）、
#             --save の引数の誤り（64）、--save がホームのリポジトリ（.claude/dev-workflow がユーザーの層と同じ場所）で、何も書かずに止まる（2）、
#             設定を読めない・書けない（2）、--save で書き込み先の設定の checks がオブジェクトでない（2。設定は書き換えない）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

save=false scope="" none=false cmds=""
while [ $# -gt 0 ]; do
  case "$1" in
    --save) save=true ;;
    --none) none=true ;;
    --scope | --command)
      [ $# -ge 2 ] || dw_die "$1 には値が要ります" 64
      case "$1" in
        --scope) scope="$2" ;;
        --command)
          case "$2" in *[![:space:]]*) ;; *) dw_die "--command には空でないコマンドを指定してください" 64 ;; esac
          case "$2" in *$'\n'*) dw_die "--command に改行は使えません" 64 ;; esac
          cmds="${cmds}${2}"$'\n'
          ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) dw_die "不明なオプション: $1" 64 ;;
  esac
  shift
done

if ! $save; then
  { [ -z "$scope" ] && [ "$none" = false ] && [ -z "$cmds" ]; } || dw_die "--scope・--command・--none は --save と一緒に使ってください" 64
fi

repo_root="$(dw_repo_root || true)"
[ -n "$repo_root" ] || dw_die "git のリポジトリの中で実行してください" 2

if $save; then
  case "$scope" in
    local | team) ;;
    "") dw_die "--save には --scope（local・team）が要ります" 64 ;;
    *) dw_die "--scope は local・team のどちらかにしてください: ${scope}" 64 ;;
  esac
  if $none; then
    [ -z "$cmds" ] || dw_die "--none と --command は一緒に使えません" 64
  else
    [ -n "$cmds" ] || dw_die "--save には --command か --none が要ります" 64
  fi

  # ホームのリポジトリでは、ユーザーの層のファイルに書かない
  dw_refuse_home_repo "$repo_root"
  if [ "$scope" = local ]; then
    target="$(dw_local_config_file "$repo_root")"
  else
    target="$(dw_team_dir "$repo_root")/config.json"
  fi
  value="$(printf '%s' "$cmds" | dw_json_lines)"
  if [ -f "$target" ]; then
    dw_check_json "$target"
    jq -e '(.checks // {}) | type == "object"' "$target" >/dev/null \
      || dw_die "${target} の checks がオブジェクトではありません。直してから保存してください" 2
  fi
  # $v は jq の変数で、bash に展開させない
  # shellcheck disable=SC2016
  dw_write_config "$target" --argjson v "$value" '.checks = ((.checks // {}) + {commands: $v})'
  hint=""
  if [ "$scope" = local ]; then
    hint="$(dw_local_config_hint "$(dw_local_config_state "$repo_root")")"
  fi
fi

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
commands="$(jq -c '.checks.commands' <<<"$config")"
jq -e '. == null or (type == "array" and all(.[]; type == "string" and (gsub("\\s"; "") != "")))' <<<"$commands" >/dev/null \
  || dw_die "checks.commands は、空でない文字列の配列か null にしてください: ${commands}" 2

# リポジトリにコミットされた設定（チームの設定と、追跡されている個人の設定）の checks.commands が、今のブランチで書き換わったか。
# commands が null なら、設定のコマンドを実行しないので false。
# 比べる基点は、origin/HEAD（リモートの既定のブランチ）との merge-base にする。設定の base_branch は PR の作者が書き換えられる
# （自分のブランチを指すと、変更済みの設定が基点になる）ので使わない。origin/HEAD が無ければ比べられないので null
commands_changed=false
if [ "$commands" != null ]; then
  commands_changed=null
  head_ref="$(git -C "$repo_root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head_ref" ] && merge_base="$(git -C "$repo_root" merge-base HEAD "$head_ref" 2>/dev/null)"; then
    any_changed=false any_unknown=false
    for rel in .claude/dev-workflow/config.json .claude/dev-workflow/config.local.json; do
      # 個人の設定は、git に追跡されている（コミットされた）ときだけ比べる。追跡されていなければ、自分の設定なので信頼する
      if [ "$rel" = .claude/dev-workflow/config.local.json ] \
        && ! git -C "$repo_root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        continue
      fi
      now=null
      if [ -f "$repo_root/$rel" ]; then
        now="$(jq -c '.checks.commands // null' "$repo_root/$rel" 2>/dev/null)" || now=unknown
      fi
      then_value=null
      if old="$(git -C "$repo_root" show "$merge_base:$rel" 2>/dev/null)"; then
        then_value="$(jq -c '.checks.commands // null' <<<"$old" 2>/dev/null)" || then_value=unknown
      fi
      if [ "$now" = unknown ] || [ "$then_value" = unknown ]; then
        any_unknown=true
      elif [ "$now" != "$then_value" ]; then
        any_changed=true
      fi
    done
    if $any_changed; then
      commands_changed=true
    elif $any_unknown; then
      commands_changed=null
    else
      commands_changed=false
    fi
  fi
fi

if [ "$commands" = null ]; then
  action=infer
elif [ "$commands" = '[]' ]; then
  action=none
elif [ "$commands_changed" = false ]; then
  action=run
else
  action=confirm
fi

hints=null
if [ "$commands" = null ]; then
  contributing="" mk="" targets="" ci="" proj=""
  for f in CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md; do
    if [ -z "$contributing" ] && [ -f "$repo_root/$f" ]; then contributing="$f"; fi
  done
  for f in Makefile makefile GNUmakefile; do
    if [ -z "$mk" ] && [ -f "$repo_root/$f" ]; then mk="$f"; fi
  done
  if [ -n "$mk" ]; then
    targets="$(LC_ALL=C sed -En 's/^((test|lint|check|typecheck|build|verify|ci)[A-Za-z0-9_.-]*):([^=]|$).*/\1/p' "$repo_root/$mk" | sort -u)"
  fi
  # glob は呼んだディレクトリではなく、リポジトリのルートで展開する
  ci="$(CDPATH='' cd "$repo_root" && for f in .github/workflows/*.yml .github/workflows/*.yaml .gitlab-ci.yml .circleci/config.yml Jenkinsfile; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done)"
  for f in Cargo.toml go.mod pyproject.toml pytest.ini tox.ini setup.py justfile Taskfile.yml composer.json Gemfile pom.xml build.gradle build.gradle.kts mix.exs deno.json; do
    if [ -f "$repo_root/$f" ]; then proj="${proj}${f}"$'\n'; fi
  done
  scripts=null
  if [ -f "$repo_root/package.json" ]; then
    scripts="$(jq -c '((.scripts // {}) | if type == "object" then . else {} end) | with_entries(select(.key | test("^(test|lint|check|typecheck|build|verify|ci)")))' "$repo_root/package.json" 2>/dev/null)" \
      || dw_die "package.json を JSON として読めません" 2
  fi
  # shellcheck disable=SC2119 # 引数（フィルター）は省く
  lines() { printf '%s' "$1" | dw_json_lines_nonempty; }
  hints="$(jq -nc --arg c "$contributing" --argjson s "$scripts" --argjson t "$(lines "$targets")" \
    --argjson w "$(lines "$ci")" --argjson p "$(lines "$proj")" \
    '{contributing: (if $c == "" then null else $c end), package_scripts: $s, makefile_targets: $t, ci_workflows: $w, project_files: $p}')"
fi

warning="" saved_value=""
if $save; then
  saved_value="$(printf '%s' "$cmds" | dw_json_lines)"
  if $none; then saved_value='[]'; fi
  if [ "$commands" != "$saved_value" ]; then
    warning="保存した値（${scope}）より優先される層が checks.commands を決めているため、実際に使われるのは ${commands} です"
  fi
fi

if $save; then
  jq -nc --arg action "$action" --argjson commands_changed "$commands_changed" --arg warning "$warning" --argjson saved "$saved_value" --argjson commands "$commands" --argjson hints "$hints" --arg file "$target" --arg scope "$scope" --arg hint "$hint" \
    '{action: $action, commands: $commands, commands_changed: $commands_changed, hints: $hints, saved: {file: $file, scope: $scope, commands: $saved, local_hint: (if $hint == "" then null else $hint end), warning: (if $warning == "" then null else $warning end)}}'
else
  jq -nc --arg action "$action" --argjson commands_changed "$commands_changed" --argjson commands "$commands" --argjson hints "$hints" '{action: $action, commands: $commands, commands_changed: $commands_changed, hints: $hints}'
fi
