#!/usr/bin/env bash
# PR がマージされた後の後片付け。マージを確かめてから、ワークツリーとローカルのブランチを削除し、
# マージ先のブランチ（base_branch）を最新にする。
# --abandon では、マージせずにやめた作業を片付ける（マージを確かめず、base_branch も更新しない）。
# 何度実行しても同じ結果になる（既に無いワークツリー・ブランチは飛ばす）。
#
# 使い方: cleanup.sh [--branch NAME] [--remove-ignored] [--abandon] [--dry-run]
#   --branch NAME     片付けるブランチ。省略すると今のブランチ
#   --remove-ignored  git が無視するファイル（.env など）があっても、ワークツリーごと削除する
#   --abandon         やめた（マージしない）作業を捨てる。1 と 4 を飛ばし、2 で止まる代わりに、失うもの
#                     （base_branch に無いコミット・未コミットの変更・git が無視するファイル・サブモジュールの
#                     リモートに無いコミットか stash）を lost に出して削除する。--dry-run で先に lost を確かめる
#   --dry-run         変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. そのブランチの PR がマージされたかを確かめる。PR に入っていないコミットがあれば止まる
#      （スカッシュマージでは git branch -d が使えないので、PR の最後のコミットと比べる）
#   2. ワークツリーを削除する。未コミットの変更（サブモジュールの中も含む）や、
#      サブモジュールにリモートに無いコミット・stash があれば止まる。
#      git が無視するファイル（サブモジュールの中も含む）があれば、--remove-ignored が無い限り止まる。
#      メインのワークツリーでそのブランチを使っていたら、削除せずに base_branch に切り替える
#      （--abandon でも、メインのワークツリーに未コミットの変更があれば止まる。捨てずに残すため）
#   3. ローカルのブランチを削除する（git branch -D）
#   4. base_branch を最新にする（git pull --ff-only に当たる。fetch --prune の後、早送りだけで取り込む）
#   5. PR が閉じる Issue（Closes #N）が閉じたかを調べて issues（number・repo・state）に出す（--abandon では調べない）。
#      Issue のリポジトリ（owner/repo）は repo に出す（参照に無ければ null）。
#      調べられなくても片付けは止めず、その Issue の state を null にして警告する
#
# 削除するワークツリーの中から実行すると、実行後にその場所が無くなる。メインのワークツリー（main_root）で実行する。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

branch="" dry_run=false remove_ignored=false abandon=false
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      need_value "$@"
      branch="$2"
      shift 2
      ;;
    --remove-ignored) remove_ignored=true; shift ;;
    --abandon) abandon=true; remove_ignored=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# bare リポジトリ＋ワークツリーの配置の、.git ファイルを置いたディレクトリ（メインのワークツリー）には作業ツリーが無い。
# ここで実行してもよいが、今のブランチは分からない（--branch が要る）。
# 作業ツリーの有無は、dw_repo_root の成功ではなく git で確かめる（WORKFLOW_REPO_ROOT があると、作業ツリーが無くても成功するため）
has_toplevel=true
repo_root="$(dw_repo_root || true)"
if [ -n "$repo_root" ] && git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  main_root="$(dw_main_root "$repo_root")" || dw_die "メインのワークツリーが分かりません"
else
  has_toplevel=false
  main_root="$(dw_main_root "${repo_root:-$PWD}")" || dw_die "リポジトリの外か、メインのワークツリーが分からない配置（--separate-git-dir のワークツリーなど）です" 64
  repo_root="$main_root"
fi
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(dw_base_branch "$config")"

if [ -z "$branch" ]; then
  # 作業ツリーが無い場所の HEAD は、今のブランチではない
  ! $has_toplevel || branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
  [ -n "$branch" ] || dw_die "ブランチの上にいません。--branch で指定してください" 64
fi
[ "$branch" != "$base" ] || dw_die "${base} は片付けられません。--branch で作業用のブランチを指定してください" 64

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# ブランチを使っているワークツリーの場所（無ければ空）
worktree_of() { dw_worktree_of "$main_root" "$1"; }

# 失うものの一覧（--abandon）。使い方: lose <種類> <1行に1つの一覧>
# 一覧は長くなりうる（数千件のコミットなど）ので、jq には引数ではなく標準入力で渡す
lost='{"commits": [], "uncommitted": [], "ignored": [], "submodules": []}'
lose() {
  local v
  # shellcheck disable=SC2119 # 引数（フィルター）は省く
  v="$(printf '%s' "$2" | dw_json_lines_nonempty)"
  lost="$(printf '%s\n%s\n' "$lost" "$v" | jq -s -c --arg k "$1" '.[1] as $v | .[0] | .[$k] += $v')"
}

has_branch=false
git -C "$main_root" show-ref --verify --quiet "refs/heads/$branch" && has_branch=true

# --- 1. マージの確認 ------------------------------------------------------------
pr=null
if $abandon; then
  # マージしないので、base_branch（手元と origin）に無いコミットはすべて失う
  if $has_branch; then
    excludes=""
    for ref in "refs/heads/$base" "refs/remotes/origin/$base"; do
      git -C "$main_root" show-ref --verify --quiet "$ref" && excludes="$excludes $ref"
    done
    # 署名を表示する設定（log.showSignature）でも、gpg の行が混ざらないようにする。引数の中のコマンド置換では、
    # git が失敗しても止まらず、失うコミットが無いと伝えたまま削除してしまうので、先に変数に取って確かめる
    # shellcheck disable=SC2086 # 除く ref を1つずつの引数に分ける（ref に空白は無い）
    commits="$(git -C "$main_root" log --no-show-signature --format='%h %s' "refs/heads/$branch" --not $excludes)" \
      || dw_die "${branch} の失うコミットを調べられませんでした"
    lose commits "$commits"
  fi
else
  # --head はブランチ名だけで探すので、フォークの同じ名前のブランチからの PR を除く（ほかの --head の呼び出しと同じ）
  prs="$(gh pr list --head "$branch" --state all --json number,url,state,mergedAt,headRefOid,baseRefName,closingIssuesReferences,isCrossRepository \
    | jq -c 'map(select(.isCrossRepository | not))')" \
    || dw_die "${branch} の PR を取得できませんでした"
  pr="$(jq -c 'map(select(.state == "MERGED")) | sort_by(.mergedAt) | last // empty' <<<"$prs")"
  if [ -z "$pr" ]; then
    open="$(jq -r 'map(select(.state == "OPEN")) | .[0].number // empty' <<<"$prs")"
    [ -z "$open" ] || dw_die "PR #${open} はまだマージされていません" 2
    dw_die "${branch} のマージされた PR がありません" 2
  fi
  pr_number="$(jq -r .number <<<"$pr")"
  head_oid="$(jq -r .headRefOid <<<"$pr")"

  if $has_branch; then
    tip="$(git -C "$main_root" rev-parse "refs/heads/$branch")"
    if [ "$tip" != "$head_oid" ]; then
      # PR の最後のコミットが手元に無ければ、GitHub が残している refs/pull/<番号>/head から取る
      git -C "$main_root" cat-file -e "${head_oid}^{commit}" 2>/dev/null \
        || git -C "$main_root" fetch -q origin "refs/pull/$pr_number/head" 2>/dev/null \
        || dw_die "PR #${pr_number} の最後のコミット ${head_oid} を取得できません"
      git -C "$main_root" merge-base --is-ancestor "$tip" "$head_oid" \
        || dw_die "${branch} に PR #${pr_number} に入っていないコミットがあります（push していない作業が無いか確かめてください）" 2
    fi
  fi
fi

# --- 2. ワークツリー ------------------------------------------------------------
path="$(worktree_of "$branch")"
worktree_removed=false switched=false
# ディレクトリを手で消すと、git の記録だけが残る。記録を片付ける
if [ -n "$path" ] && [ ! -d "$path" ]; then
  note "消えたワークツリー $path の記録を片付ける（git worktree prune）"
  $dry_run || git -C "$main_root" worktree prune
  path=""
fi
if [ -n "$path" ]; then
  # サブモジュールの中の変更も見る（submodule.<name>.ignore などの設定で隠されないよう none を指定する）。
  # status.showUntrackedFiles=no の設定で追跡していないファイルが隠されないよう -unormal も指定する
  changes="$(git -C "$path" status --porcelain -unormal --ignore-submodules=none)"
  if [ -n "$changes" ]; then
    # メインのワークツリーは削除せずに切り替えるだけなので、--abandon でも変更を捨てずに止まる
    if ! $abandon || [ "$path" = "$main_root" ]; then
      dw_die "$path に未コミットの変更があります。コミットするか片付けてから実行してください" 2
    fi
    lose uncommitted "$(LC_ALL=C cut -c4- <<<"$changes")"
  fi
  if [ "$path" = "$main_root" ]; then
    switched=true
    note "メインのワークツリーを ${branch} から ${base} に切り替える"
    $dry_run || git -C "$main_root" switch -q "$base" || dw_die "${base} に切り替えられませんでした"
  else
    # サブモジュールの git のデータはワークツリーと一緒に消えるので、リモートに無いコミット（HEAD とローカルのブランチ）や
    # stash が残っていれば止まる。リモートのブランチかタグ（タグは手元のものとリモートのものを区別できない）から届かない
    # コミットは、SHA で取ってきた push 済みのものでも手元では見分けられないので、安全のために止まる。
    # git log が失敗したら、push していないコミットが無いとはみなさず、foreach を失敗させる
    # shellcheck disable=SC2016 # 各サブモジュールの中で展開させる
    unpushed="$(git -C "$path" submodule --quiet foreach --recursive '
      local_only="$(git log -1 --no-show-signature --format=%h HEAD --branches --not --remotes --tags)" || exit 1
      if [ -n "$local_only" ] || git rev-parse -q --verify refs/stash >/dev/null; then
        echo "$displaypath"
      fi')" || dw_die "$path のサブモジュールを確かめられませんでした"
    if $abandon; then
      lose submodules "$unpushed"
    else
      [ -z "$unpushed" ] \
        || dw_die "$path のサブモジュール（${unpushed//$'\n'/, }）に、リモートに無いコミットか stash があります。push するか片付けてから実行してください" 2
    fi
    # git が無視するファイル（.env やローカルの設定など）は status に出ないが、ワークツリーと一緒に消える。
    # 消してよいと言われたとき（--remove-ignored）だけ続ける。--abandon では一覧を lost に出す
    if ! $remove_ignored || $abandon; then
      # shellcheck disable=SC2016 # 各サブモジュールの中で展開させる
      ignored="$( {
        git -C "$path" status --porcelain -unormal --ignored --ignore-submodules=all
        git -C "$path" submodule --quiet foreach --recursive \
          'git status --porcelain -unormal --ignored --ignore-submodules=all | sed "s|^!! |!! $displaypath/|"'
      } | sed -n 's/^!! //p')" || dw_die "$path の git が無視するファイルを確かめられませんでした"
      if $abandon; then
        lose ignored "$ignored"
      elif [ -n "$ignored" ]; then
        list="$(awk 'NR <= 5 { printf "%s%s", (NR > 1 ? ", " : ""), $0 }' <<<"$ignored")"
        count="$(grep -c '' <<<"$ignored")"
        [ "$count" -le 5 ] || list="${list} ほか $((count - 5)) 件"
        dw_die "$path に git が無視するファイル（${list}）があります。消してよければ --remove-ignored を付けて実行してください" 2
      fi
    fi
    worktree_removed=true
    note "ワークツリー $path を削除する"
    # サブモジュールを初期化したワークツリーは --force が無いと削除できない。変更が無いことは上で確かめた
    $dry_run || git -C "$main_root" worktree remove --force "$path" || dw_die "ワークツリー $path を削除できませんでした"
  fi
fi

# --- 3. ブランチ ----------------------------------------------------------------
branch_deleted=false
if $has_branch; then
  branch_deleted=true
  note "ローカルのブランチ ${branch} を削除する"
  $dry_run || git -C "$main_root" branch -q -D "$branch" >/dev/null || dw_die "ブランチ ${branch} を削除できませんでした"
fi

# --- 4. base_branch を最新にする -------------------------------------------------
# --abandon では何も取り込まれていないので、base_branch は変えない
from="$(git -C "$main_root" rev-parse -q --verify "refs/heads/$base" || true)"
base_path="$(worktree_of "$base")"
# 切り替えた後はメインのワークツリーが base_branch を使う（dry-run では切り替えていない）
$switched && base_path="$main_root"
if $abandon; then
  :
elif [ -n "$base_path" ]; then
  note "${base_path} の ${base} に origin/${base} を早送りで取り込む（git pull --ff-only）"
else
  note "${base} を origin/${base} まで早送りする"
fi
to="$from"
if ! $dry_run && ! $abandon; then
  git -C "$main_root" fetch -q --prune origin || dw_die "origin を取得できませんでした"
  if [ -n "$base_path" ]; then
    git -C "$base_path" merge -q --ff-only "origin/$base" \
      || dw_die "${base} を早送りで最新にできません（${base} に origin に無いコミットがあるか、未コミットの変更とぶつかります）"
  else
    git -C "$main_root" fetch -q origin "$base:$base" \
      || dw_die "${base} を早送りで最新にできません（${base} に origin に無いコミットがあります）"
  fi
  to="$(git -C "$main_root" rev-parse "refs/heads/$base")"
fi

# --- 5. Issue の状態 -------------------------------------------------------------
# PR の本文の Closes #N でマージ時に GitHub が閉じる。閉じたかを伝えるだけなので、調べられなくても止めない
issues='[]'
if ! $abandon; then
  # 別のリポジトリの Issue（Closes owner/repo#N）も参照に入るので、その Issue のリポジトリで調べる（無ければ今のリポジトリ）
  while read -r n repo; do
    [ -n "$n" ] || continue
    if state="$(gh issue view "$n" ${repo:+--repo "$repo"} --json state -q .state 2>/dev/null)" && [ -n "$state" ]; then
      issues="$(jq -c --argjson n "$n" --arg r "$repo" --arg s "$state" '. + [{number: $n, repo: (if $r == "" then null else $r end), state: $s}]' <<<"$issues")"
    else
      dw_warn "Issue ${repo:+${repo}}#${n} の状態を取得できませんでした"
      issues="$(jq -c --argjson n "$n" --arg r "$repo" '. + [{number: $n, repo: (if $r == "" then null else $r end), state: null}]' <<<"$issues")"
    fi
  done < <(jq -r '.closingIssuesReferences // [] | .[] | "\(.number) \(if .repository then "\(.repository.owner.login)/\(.repository.name)" else "" end)"' <<<"$pr")
fi

# lost は長くなりうるので、引数ではなく標準入力で渡す
jq --arg branch "$branch" --arg path "$path" --arg main "$main_root" --arg base "$base" \
  --argjson pr "$pr" --argjson wr "$worktree_removed" --argjson sw "$switched" --argjson bd "$branch_deleted" \
  --arg from "$from" --arg to "$to" --argjson dry "$dry_run" --argjson actions "$actions" \
  --argjson abandon "$abandon" --argjson issues "$issues" '. as $lost | {
    branch: $branch,
    dry_run: $dry,
    abandon: $abandon,
    pr: (if $pr == null then null else {number: $pr.number, url: $pr.url, merged_at: $pr.mergedAt} end),
    worktree: (if $path == "" then null else $path end),
    main_root: $main,
    removed: {worktree: $wr, branch: $bd},
    switched: $sw,
    base: {name: $base, from: (if $from == "" then null else $from end), to: (if $to == "" then null else $to end)},
    issues: $issues,
    lost: (if $abandon then $lost else null end),
    actions: $actions
  }' <<<"$lost"
