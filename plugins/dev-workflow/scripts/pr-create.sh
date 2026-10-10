#!/usr/bin/env bash
# 今のブランチを push し、Issue に紐付けた PR を作る。
# 何度実行しても同じ結果になる（そのブランチの開いた PR が既にあれば、push と（--check・--add-task があれば）Issue のチェックと項目の追加だけを行い、
# その PR のタイトル・本文・ラベル・Project の列は変えない）。
#
# 使い方: pr-create.sh --issue N --body-file PATH [--title TEXT] [--check TEXT]... [--add-task TEXT]... [--draft | --no-draft] [--dry-run]
#   --issue N         紐付ける Issue の番号（#N でもよい）
#   --body-file PATH  PR の本文のファイル。- なら標準入力
#   --title TEXT      PR のタイトル。省略すると <Issue の type ラベル>: <Issue のタイトル>
#                     （Issue に breaking ラベルがあれば <type>!: <Issue のタイトル>）
#   --check TEXT      Issue の本文のチェックリストの、文が TEXT（出力の tasks の text）の項目にチェックを付ける。
#                     繰り返し指定できる。既にチェックがある項目は変えない。番号ではなく文で指すので、
#                     確かめた後に項目が増減しても、別の項目には付かない（その文の項目がちょうど1つでなければ止まる）
#   --add-task TEXT   Issue の本文の最初の項目がある節の最後に、チェックの無い項目「- [ ] TEXT」を足す（前後の空白は外す）。繰り返し指定できる。
#                     文が TEXT の項目が既にあれば足さない（もう一度実行しても重ならない）。ADR の作成の提案を断ったことを、
#                     取り消し線の項目（~~…~~）として残すのに使う
#   --draft           設定の pr.draft にかかわらず、PR を下書きにする（人が、この PR だけ下書きにしたいときに使う。task-auto は付けない）
#   --no-draft        設定の pr.draft が true でも、PR を下書きにしない（task-auto が、自動で作った PR をレビューできる状態で出すのに使う）。
#                     --draft と同時には指定できない
#                     --draft・--no-draft とも、既にある PR では下書きかどうかを変えない（出力の draft は、その PR の今の状態）
#   --dry-run         push も PR の作成も Issue のチェックと項目の追加もせず、行う予定の操作と PR のタイトル・本文、
#                     Issue のチェックリストの項目（tasks）・チェックを付ける項目（checked）・足す項目（added）を出力する。
#                     dry-run ではマージ先を取得（git fetch）せず、手元の origin/<マージ先> で、マージ先に無いコミットがあるかを
#                     確かめる（取得していない手元の ref で数えた値で、本番は取得し直して確かめる）。手元に無ければ確かめるのを
#                     飛ばし、警告して出力の ahead を null にする。既にある PR のマージ先を使えないときは、本番と同じく止まる
#                     （dry-run は本番で何が起きるかを先に見せるため）
#
# 行うこと:
#   1. タイトルを設定の pr.title_pattern で検証する。type は Issue の type ラベルと同じにする。
#      Issue に breaking ラベルがあれば、type の後に ! が無いタイトルは止める
#   2. Issue に breaking ラベルがあれば、本文に BREAKING CHANGE: <移行のしかた> の行が無いと止める。
#      PR が既にあるときは、その PR のタイトルに ! が無い、または本文に BREAKING CHANGE が無いと、push の前に止める。
#      本文に <pr.close_keyword> #N（既定: Closes #N）が無ければ末尾に足す。
#      テンプレートの番号が空のままの行（Closes #）は消す
#   3. origin に push する（-u で追跡させる）。未コミットの変更や、PR にするコミット（PR のマージ先（下の pr_base）に無いコミット）が無ければ止まる。
#      既にある PR のマージ先を使えない（ブランチ名として使えない・マージ先の違う開いた PR が複数ある）か、マージ先を取得できなければ、
#      push せずに終了コード 2 で止まる（規則は lib/common.sh の「PR のマージ先」）
#   4. base_branch に向けた PR を作り、Issue のラベルを引き継ぐ。pr.draft が true か --draft を付けたら下書きにする（--no-draft なら、pr.draft にかかわらず下書きにしない）
#   5. PR を新しく作ったときだけ、status.pr_opened が設定されていれば Issue をその列に移す（status-set.sh）。
#      既にある PR では移さない（手で先の列に移した Issue を戻さないため）
#   6. --check・--add-task があれば、Issue の本文を読み直し、指定した文の項目だけにチェックを付け、項目を足す
#      （既にある PR のときも行う）。ほかの行は変えない。コードブロックと、行頭（字下げは問わない）の <!-- から --> までの
#      HTML のコメントの中の行は、項目とみなさない。足す項目は、最初の項目がある節（次の見出しの手前まで）の最後の
#      空でない行の後に、最初の項目と同じ字下げで置く（改行が \r\n なら \r\n で書く）。その行がリストの項目でなければ
#      （項目の続きの行・HTML の塊・区切り線など）、空行を挟む。項目が無ければ本文の最後に置く
#
# 出力の pr_base は PR のマージ先。既にある PR を使うならその PR のマージ先（設定の base_branch と違うことがある）、
# 新しく作るなら作る PR のマージ先（base_branch）。設定の base_branch は base に出す。
# 出力の merge_queue は、pr_base へのマージがマージキューを通すか（true・false。ブランチに効いているルールを
# 読めなければ null）。PR を出した後の案内（キューに入れるか、マージ先が進んだら取り込むか）を切り替えるのに使う
# 出力の ahead は、origin/<pr_base> より先のコミットの数（dry-run で手元に origin/<pr_base> が無く、確かめていなければ null）
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

issue="" body_file="" title="" dry_run=false draft_opt=false no_draft_opt=false checks='[]' adds='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --body-file | --title | --check | --add-task)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --body-file) body_file="$2" ;;
        --title) title="$2" ;;
        --check) checks="$(jq -c --arg t "$2" '. + [$t] | unique' <<<"$checks")" ;;
        --add-task)
          case "$2" in *$'\n'* | *$'\r'*) dw_die "--add-task の文に改行は使えません" 64 ;; esac
          # 項目の文（md_scan の text）は前後の空白を外して読むので、足す文も外しておく（同じ文の項目があるかを比べられるように）。
          # 足す順は指定した順にし、同じ文は1つにする
          adds="$(jq -c --arg t "$2" '($t | sub("^\\s+"; "") | sub("\\s+$"; "")) as $t
            | if $t == "" then error("empty") elif index([$t]) then . else . + [$t] end' <<<"$adds" 2>/dev/null)" \
            || dw_die "--add-task の文が空です" 64
          ;;
      esac
      shift 2
      ;;
    --draft) draft_opt=true; shift ;;
    --no-draft) no_draft_opt=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
! { $draft_opt && $no_draft_opt; } || dw_die "--draft と --no-draft は同時に指定できません" 64
[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
[ -n "$body_file" ] || dw_die "--body-file は必須です" 64
if [ "$body_file" = - ]; then
  body="$(cat)"
else
  [ -f "$body_file" ] || dw_die "本文のファイルがありません: $body_file" 64
  body="$(cat "$body_file")"
fi

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(dw_base_branch "$config")"

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# --- ブランチと変更の確認 -------------------------------------------------------
branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
[ -n "$branch" ] || dw_die "ブランチの上にいません（detached HEAD）" 2
[ "$branch" != "$base" ] || dw_die "${base} からは PR を作りません。作業用のブランチで実行してください（task-start）" 2
# 条件の中のコマンド置換では、git が失敗しても止まらず、変更が無いとみなしてしまうので、先に変数に取って確かめる
changes="$(git -C "$repo_root" status --porcelain --untracked-files=no)" \
  || dw_die "未コミットの変更を調べられませんでした（git が失敗しました）"
[ -z "$changes" ] || dw_die "未コミットの変更があります。コミットしてから実行してください（commit）" 2

# --- Issue ----------------------------------------------------------------------
# PR の番号なら止まる（dw_read_issue）
issue_json="$(dw_read_issue "$issue" number,title,state,labels,body)"
labels="$(jq -c '[.labels[].name]' <<<"$issue_json")"
types="$(jq -c --argjson t "$(jq -c '.labels.types' <<<"$config")" "$DW_JQ_ISSUE_TYPES"' issue_types($t)' <<<"$labels")"
[ "$(jq length <<<"$types")" = 1 ] \
  || dw_die "Issue #${issue} の type ラベルを1つにしてください（今は $(jq -r 'if length == 0 then "なし" else join(", ") end' <<<"$types")）" 2
type="$(jq -r '.[0]' <<<"$types")"
# GitHub と同じく、ラベルの名前は大文字と小文字を区別せずに照合する
breaking="$(jq --arg b "$DW_BREAKING_LABEL" 'any(.[]; ascii_downcase == $b)' <<<"$labels")"

# スカッシュのコミットの type に ! が無いと、release-please などが破壊的変更とみなさない
has_bang() { jq -e --arg s "$1" '$s | test("^[^:]*!:")' <<<null >/dev/null; }
# スカッシュマージでは PR の本文がコミットの本文になるので、移行のしかたを本文に残す
# 本文は大きいことがあるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
has_breaking_note() { printf '%s' "$1" | dw_jq_text -e '$dw_in | test("(^|\n)BREAKING[ -]CHANGE: *\\S")' >/dev/null; }

# --- Issue のチェックリスト -----------------------------------------------------
# 本文を md_scan（lib/common.sh）で読み、チェックリストの項目（items。上から順に {line（0 からの行番号）, checked, text}）と
# 見出しの行番号（headings）を出す。2つ目の引数で、そこから取り出す部分を指定できる（jq の起動を増やさないため）
# 使い方: scan_of <Issue の JSON> [jq のフィルター（既定 .）]
scan_of() { jq -c "$DW_JQ_MD_SCAN"' .body // "" | md_scan | '"${2:-.}" <<<"$1"; }
tasks="$(scan_of "$issue_json" .items)"
# 項目（tasks・now_scan）は Issue の本文から読むので長くなりうる。引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
# 文が1つの項目にだけ当たらない --check の文を出す（無い・複数ある）
# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
unmatched_jq='map(. as $s | select([$t[] | select(.text == $s)] | length != 1))'
unmatched="$(printf '%s\n' "$checks" "$tasks" | jq -sc '.[1] as $t | .[0] | '"$unmatched_jq")"
[ "$unmatched" = '[]' ] \
  || dw_die "--check の文の項目が Issue #${issue} のチェックリストに1つだけではありません（無いか、同じ文が複数あります）: $(jq -r 'join(" / ")' <<<"$unmatched")" 64
# まだチェックの無い項目だけに付ける
to_check="$(printf '%s\n' "$checks" "$tasks" | jq -sc '.[1] as $t | .[0] | map(. as $s | select(any($t[]; .text == $s and (.checked | not))))')"
# 文が同じ項目がまだ無いものだけを足す
# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
missing_jq='map(. as $s | select(any($t[]; .text == $s) | not))'
to_add="$(printf '%s\n' "$adds" "$tasks" | jq -sc '.[1] as $t | .[0] | '"$missing_jq")"

# --- 既にある PR ----------------------------------------------------------------
# --head はブランチ名だけで探すので、fork の同じ名前のブランチからの PR を除く
# PR のマージ先（pr_base）。新しく作る PR は base_branch に向ける。既にある PR はマージ先を変えていることがあるので、
# その PR のマージ先にする。PR の選び方と、マージ先を使えないとき（fallback）の規則は lib/common.sh の「PR のマージ先」が正本。
# push の前の確認（マージ先に無いコミットがあるか）も、PR を出した後の案内も、このマージ先で行う（変更を加える）ので、ここは
# 止める側：PR のマージ先を使えない（ブランチ名として使えない、マージ先の違う PR が複数ある）なら、終了コード 2 で止まる
prs="$(gh pr list --head "$branch" --state open --json number,url,title,body,isCrossRepository,isDraft,baseRefName)" \
  || dw_die "${branch} の PR を取得できませんでした"
# --dry-run も、本番と同じく止まる（dry-run は本番で何が起きるかを先に見せるためのもの）
dw_pr_pick_strict "$prs" "$base" "PR のマージ先を決められないので、push しません（PR のマージ先を確かめてください）" \
  || dw_die "${branch} の PR を取得できませんでした（gh の応答を JSON として読めません）"
pr_base="$DW_PICK_BASE" existing="$DW_PICK_PR"
# 以下は、既にある PR を配列（無ければ空）として読む
existing="$(jq -c 'if . == null then [] else [.] end' <<<"$existing")"
pr_number="$(jq -r '.[0].number // empty' <<<"$existing")"
pr_url="$(jq -r '.[0].url // empty' <<<"$existing")"
# 既にある PR のタイトルと本文は変えないので、PR を出した後に breaking ラベルを付けたときは、
# ! と BREAKING CHANGE の無いままマージされないよう、push の前に止める
if [ -n "$pr_number" ] && $breaking; then
  has_bang "$(jq -r '.[0].title' <<<"$existing")" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なのに、既にある PR #${pr_number} のタイトルの type の後に ! がありません（gh pr edit ${pr_number} --title で直してから実行してください）" 2
  has_breaking_note "$(jq -r '.[0].body' <<<"$existing")" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なのに、既にある PR #${pr_number} の本文に「BREAKING CHANGE: <移行のしかた>」がありません（gh pr edit ${pr_number} --body-file で直してから実行してください）" 2
fi

# --- 1. タイトル ----------------------------------------------------------------
[ -n "$title" ] || title="${type}$($breaking && echo '!'): $(jq -r .title <<<"$issue_json")"
case "$title" in
  *$'\n'*) dw_die "タイトルは1行にしてください" 64 ;;
esac
# pr.title_pattern が読めない・文字列でない・正規表現として正しくないときは、設定の誤りとして止まる（dw_config_regex_test）
dw_config_regex_test "$config" pr.title_pattern "$title" \
  || dw_die "タイトルが規約に合いません（<type>: <Issue のタイトル>）: $title" 2
# type ラベル・ブランチ名・PR のタイトルは同じ type で1対1に対応させる（設計書 §5）
title_type="$(jq -rn --arg s "$title" '$s | capture("^(?<t>[a-z]+)").t // ""')"
[ "$title_type" = "$type" ] \
  || dw_die "タイトルの type（${title_type}）が Issue #${issue} の type ラベル（${type}）と違います" 2
if [ -z "$pr_number" ] && $breaking; then
  has_bang "$title" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なので、タイトルの type の後に ! を付けてください（${type}!: …）: $title" 2
fi

# --- 2. 本文 --------------------------------------------------------------------
if [ -z "$pr_number" ] && $breaking; then
  has_breaking_note "$body" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なので、本文の最後に「BREAKING CHANGE: <移行のしかた>」を書いてください" 64
fi
keyword="$(jq -r '.pr.close_keyword' <<<"$config")"
# 本文は大きいことがあるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
body="$(printf '%s' "$body" | dw_jq_text -r --arg k "$keyword" --arg n "$issue" '
  # テンプレートの番号が空のままの行（Closes #）を消し、末尾の空行を落とす
  ($dw_in | split("\n") | map(select(test("^\\s*" + $k + "\\s+#\\s*$"; "i") | not)) | join("\n")
    | sub("\\s+$"; "")) as $body
  | if $body | test("\\b" + $k + "\\s+#" + $n + "\\b"; "i") then $body
    elif $body == "" then "\($k) #\($n)"
    else "\($body)\n\n\($k) #\($n)" end')"
[ "$body" != "$keyword #$issue" ] || dw_die "本文が空です（概要・変更点・確認方法を書いてください）" 64
# 本文は一時ファイルに1回だけ書き、PR を作るときの --body-file と、最後の出力の --rawfile の両方で使う
body_tmp="$(mktemp)"
trap 'rm -f "$body_tmp"' EXIT
printf '%s' "$body" >"$body_tmp"

# --- 3. push --------------------------------------------------------------------
# マージ先を取得してから、マージ先に無いコミットがあるかを確かめる。dry-run では、周りのスクリプト（task-start.sh など）と
# 同じく fetch せず（手元の remote-tracking ref もネットワークも触らない）、手元の origin/<マージ先> で確かめる。手元に無ければ
# （既にある PR のマージ先を一度も取得していないなど）、止めずに確かめるのを飛ばし、警告と出力（ahead が null）で伝える。
# 本番の実行では必ず取得して確かめる（取得できなければ終了コード 2 で止まる）。dry-run の値は取得していない手元の ref で
# 数えたものなので、本番で取得し直すと変わることがある（本番は push の前に確かめ直して止まるので、誤って push はしない）
ahead=null
if ! $dry_run; then
  dw_fetch_target_strict "$repo_root" "$pr_base"
fi
if dw_remote_ref_exists "$repo_root" "$pr_base"; then
  ahead="$(git -C "$repo_root" rev-list --count "refs/remotes/origin/$pr_base..HEAD")"
  [ "$ahead" -gt 0 ] || dw_die "origin/${pr_base} に無いコミットがありません。PR にする変更をコミットしてください" 2
  if $dry_run; then
    note "${branch} を origin に push する（手元の origin/${pr_base}（取得していない）より ${ahead} 個先のコミット。本番は取得し直して確かめる）"
  else
    note "${branch} を origin に push する（origin/${pr_base} より ${ahead} 個先のコミット）"
  fi
else
  dw_warn "手元に origin/${pr_base} が無いので、dry-run では origin/${pr_base} に無いコミットがあるかを確かめていません（本番の実行で取得して確かめます）"
  note "${branch} を origin に push する（origin/${pr_base} が手元に無いので、先行するコミットはまだ確かめていない。push の前に取得して確かめる）"
fi

if ! $dry_run; then
  # 出力は JSON だけにするため、git の出力は標準エラーに回す
  git -C "$repo_root" push -q -u origin "$branch" >&2 \
    || dw_die "${branch} を push できませんでした（origin/${branch} に手元に無いコミットがあれば、取り込んでからやり直してください）"
fi

# --- 4. PR ----------------------------------------------------------------------
draft="$(jq -r '.pr.draft // false' <<<"$config")"
! $draft_opt || draft=true
! $no_draft_opt || draft=false
created=false
if [ -n "$pr_number" ]; then
  note "既にある PR #${pr_number} を使う（作り直さず、タイトル・本文・ラベル・列・下書きかどうかは変えない）"
  # 下書きかどうかは変えないので、出力にはその PR の今の状態を出す（--draft・--no-draft を付けても、取り違えないように）
  draft="$(jq -r '.[0].isDraft // false' <<<"$existing")"
else
  created=true
  note "${base} に向けた PR「${title}」を作る$($draft && echo '（下書き）')"
  [ "$(jq length <<<"$labels")" = 0 ] || note "PR にラベル $(jq -r 'join(", ")' <<<"$labels") を付ける"
  if ! $dry_run; then
    pr_args=(--base "$base" --head "$branch" --title "$title" --body-file "$body_tmp")
    $draft && pr_args+=(--draft)
    while IFS= read -r l; do
      [ -n "$l" ] && pr_args+=(--label "$l")
    done <<<"$(jq -r '.[]' <<<"$labels")"
    pr_url="$(gh pr create "${pr_args[@]}" | tail -n 1)" || dw_die "${branch} は push しましたが、PR を作れませんでした"
    pr_number="${pr_url##*/}"
  fi
fi

# --- 5. pr_opened の列に移す ----------------------------------------------------
if ! $created || [ -z "$(jq -r '.status.pr_opened // empty' <<<"$config")" ]; then
  status='{"skipped": true, "actions": []}'
elif [ -z "$(jq -r '.project.number // empty' <<<"$config")" ]; then
  dw_warn "project.number が未設定なので、Project の列は移しません（setup-project.sh --write-config で設定できます）"
  status='{"skipped": true, "actions": []}'
else
  status_args=(--issue "$issue" --to pr_opened)
  $dry_run && status_args+=(--dry-run)
  if ! status="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" "${status_args[@]}")"; then
    $dry_run && dw_die "Issue #${issue} を列に移す予定を作れませんでした"
    # 次に実行しても PR は既にあるので列は移さない。移し方を伝える
    dw_die "PR #${pr_number} は作りましたが、Issue #${issue} の列を移せませんでした（status-set.sh --issue ${issue} --to pr_opened で移せます）"
  fi
fi
while IFS= read -r a; do
  [ -n "$a" ] && note "$a"
done <<<"$(jq -r '.actions[]?' <<<"$status")"

# --- 6. Issue のチェックリストにチェックを付け、項目を足す ----------------------
# 項目（to_check・to_add）は --check・--add-task の数だけ長くなるので、引数ではなく標準入力で jq に渡す
# （引数1つの長さには上限がある）。項目を並べた知らせも、note（引数で渡す）を通さずに jq の中で作る
actions="$(printf '%s\n' "$actions" "$to_check" "$to_add" | jq -sc --arg i "$issue" '
  .[0]
  + (if (.[1] | length) > 0 then ["Issue #\($i) のチェックリストの項目「\(.[1] | join("」「"))」にチェックを付ける"] else [] end)
  + (if (.[2] | length) > 0 then ["Issue #\($i) のチェックリストに項目「\(.[2] | join("」「"))」を足す"] else [] end)')"
if ! $dry_run && [ "$(printf '%s\n' "$to_check" "$to_add" | jq -s 'add | length')" -gt 0 ]; then
  # 確かめた後に本文が変わっていてもよいよう、読み直した本文で、文が同じ項目を探して付ける
  # $( ) は末尾の改行を落とすので、本文は JSON のまま扱う
  now_json="$(gh issue view "$issue" --json body)" \
    || dw_die "PR #${pr_number} はできていますが、Issue #${issue} を読めず、チェックリストを変えられませんでした（もう一度実行すれば変えます）"
  # 項目と見出しは、読み直した本文を1回だけ読んで使う
  # jq の起動を増やさないよう、項目（.items）と見出し（.headings）は、それぞれの jq の中で取り出す
  now_scan="$(scan_of "$now_json")"
  [ "$(printf '%s\n' "$to_check" "$now_scan" | jq -sc '.[1].items as $t | .[0] | '"$unmatched_jq")" = '[]' ] \
    || dw_die "PR #${pr_number} はできていますが、Issue #${issue} の本文のチェックリストが途中で変わり、指定した文の項目が1つだけではなくなったので、チェックを付けませんでした（項目を確かめ直してから、もう一度実行してください）" 2
  # 読み直す間に足された項目は、もう足さない
  now_add="$(printf '%s\n' "$to_add" "$now_scan" | jq -sc '.[1].items as $t | .[0] | '"$missing_jq")"
  # 出力の added は、実際に足した項目にする
  to_add="$now_add"
  # 指定した行の行頭のチェックボックスだけを [x] にし、項目の文の中の [ ] や、ほかの行（改行の \r を含む）はそのまま残す。
  # 足す項目は、最初の項目がある節（次の見出しの手前まで。コードブロックの中の見出しの形の行は見出しとみなさない）の
  # 最後の空でない行の後に、最初の項目と同じ字下げで置く。改行は本文に合わせる（DW_JQ_LINES。CRLF の本文の改行の無い最後の行の
  # 後に足しても、LF を混ぜない）
  printf '%s\n' "$now_json" "$now_scan" "$to_check" "$now_add" | jq -sj "$DW_JQ_LINES"'
    .[1] as $scan | .[2] as $c | .[3] as $a | .[0]
    | $scan.items as $t | $scan.headings as $headings
    | ($t | map(select(.text as $s | $c | index($s))) | map(.line)) as $lines
    | .body // "" | split("\n")
    | to_entries
    | map(if .key as $k | $lines | index($k)
        then .value | sub("^(?<p>\\s*(?:[-*+]|[0-9]+[.)])\\s+)\\[ \\]"; "\(.p)[x]")
        else .value end)
    | if ($a | length) == 0 then .
      elif ($t | length) == 0 then
        # 項目が無ければ本文の最後に置く（最後の改行は残す。本文が空なら項目だけにする）
        if . == [""] then $a | map("- [ ] " + .)
        else insert_after(if length > 1 and .[-1] == "" then length - 2 else length - 1 end; $a | map("- [ ] " + .)) end
      else
        . as $l
        | ($t[0].line) as $f
        | ([$headings[] | select(. > $f)] | first // ($l | length)) as $end
        | ([range($f; $end) | select($l[.] | sub("\r$"; "") | test("\\S"))] | last) as $last
        | ($l[$f] | capture("^(?<i>\\s*)").i) as $indent
        # 直前の行がリストの項目なら、そのまま続ける。それ以外（項目の続きの行・HTML の塊・区切り線など）なら空行を挟む。
        # 字下げした行は、項目の続きか HTML の塊かを行の形では見分けられないので、塊に入って表示されなくなるより、
        # 間の空いたリストになるほうを選ぶ。区切り線（* * * など）は項目とみなさない
        | ($l[$last] | sub("\r$"; "")) as $prev
        | (if ($prev | test("^ {0,3}([-*_])[ \\t]*(?:\\1[ \\t]*){2,}$") | not)
              and ($prev | test("^\\s*(?:[-*+]|[0-9]+[.)])(?:\\s|$)"))
           then [] else [""] end) as $gap
        | $l | insert_after($last; $gap + ($a | map($indent + "- [ ] " + .)))
      end
    | join("\n")' \
    | gh issue edit "$issue" --body-file - >/dev/null \
    || dw_die "PR #${pr_number} はできていますが、Issue #${issue} のチェックリストを変えられませんでした（もう一度実行すれば変えます）"
fi

# --- マージキュー ----------------------------------------------------------------
# PR を出した後の案内を切り替えるため、PR のマージ先（pr_base）へのマージがキューを通すかを読む（doctor.sh と同じく、
# 組織のルールセットも含めてブランチに効いているルールで見る）。読むだけなので dry-run でも読む。読めなければ null にし、止めない
merge_queue="$(dw_merge_queue_enabled '{owner}/{repo}' "$pr_base")" || merge_queue=null

# 本文、Issue のチェックリストの項目（tasks）、指定した項目（to_check・to_add）と、それを並べた知らせを含む actions は
# 大きいことがあるので、引数では渡さない（引数1つの長さには上限がある）。本文は一時ファイル（body_tmp）から --rawfile で、
# ほかは標準入力の JSON で渡す（標準入力の -R では、4096 バイトを超える1行の BMP の外の文字が読み込みの区切りで割れることがある）
printf '%s\n' "$tasks" "$to_check" "$to_add" "$actions" | jq -s --rawfile body "$body_tmp" --argjson i "$issue" --arg branch "$branch" --arg base "$base" --arg pr_base "$pr_base" --arg title "$title" \
  --argjson labels "$labels" --argjson breaking "$breaking" --argjson draft "$draft" --argjson created "$created" \
  --arg number "$pr_number" --arg url "$pr_url" --argjson status "$status" \
  --argjson dry "$dry_run" --argjson merge_queue "$merge_queue" --argjson ahead "$ahead" '.[0] as $tasks | .[1] as $checked | .[2] as $added | .[3] as $actions | {
    issue: $i,
    dry_run: $dry,
    branch: $branch,
    # 設定の base_branch
    base: $base,
    # PR のマージ先（既にある PR ならそのマージ先、新しく作るなら base）
    pr_base: $pr_base,
    # origin/<pr_base> より先のコミットの数。dry-run で手元に origin/<pr_base> が無く、確かめていなければ null
    ahead: $ahead,
    # 既にある PR には反映しないので、作るときだけ出す
    title: (if $created then $title else null end),
    body: (if $created then $body else null end),
    labels: (if $created then $labels else null end),
    breaking: $breaking,
    draft: $draft,
    created: $created,
    pr: (if $number == "" then null else {number: ($number | tonumber), url: $url} end),
    status: {from: ($status.from // null), to: ($status.to // null), skipped: ($status.skipped // false)},
    # Issue の本文のチェックリストの項目と、この実行でチェックを付ける項目の文
    tasks: ($tasks | map(del(.line))),
    checked: $checked,
    # この実行で足す項目の文（文が同じ項目が既にあるものは除く。実行したときは、読み直した本文に実際に足したもの）
    added: $added,
    # PR のマージ先（pr_base）へのマージがマージキューを通すか（読めなければ null）
    merge_queue: $merge_queue,
    actions: $actions
  }'
