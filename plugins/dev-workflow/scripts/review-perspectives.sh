#!/usr/bin/env bash
# レビューの観点ファイルを3つの層から集め、JSON で出力する。
# --auto（または --base と --target）を渡すと、観点ごとの実行する条件で、今の変更に当てはまらない観点を外す。
#
# 使い方:
#   review-perspectives.sh                 観点の一覧（条件で外す前）
#   review-perspectives.sh --auto          今のブランチの変更で絞り込む（review スキルはこれを使う）
#   review-perspectives.sh --base <基点> --target <マージ先> [--type <type>] [--issue <番号>]
#                                          渡した値で絞り込む（--auto が決める値を自分で渡す）
#
#   --auto    次を決めて絞り込み、決めた値を context に出す
#             - マージ先: dw_merge_target（merge-target.sh と同じ）の ref（開いた PR があればその PR のマージ先、無ければ設定の
#               base_branch。origin から取得し、できなければ警告して手元のものを使う。PR のマージ先を使えなければ（規則は lib/common.sh の
#               「PR のマージ先」）、警告して続け、理由を context.fallback に出す。どれも無ければ終了コード 2。
#               branch.pattern などの設定に誤り（正規表現として正しくない・文字列でない・labels.types が正しくないなど）が
#               あるときも、設定の誤りとして終了コード 2）
#             - 基点: git merge-base <マージ先> HEAD
#             - Issue の番号: ブランチ名（branch.pattern の {issue_number}。先頭の 0 はそろえる）。番号として使えない値（0 など）なら
#               Issue は無いものとする（警告）。gh で Issue を読み、見つからないか、番号が PR のものなら、Issue は無いものとする（警告）。
#               gh で読めなければ（認証・通信など）、番号は使い、type はブランチ名から決める（警告）
#             - type: Issue の type ラベル（labels.types のどれか1つ）。無いか1つに決まらなければ、
#               ブランチ名（branch.pattern の {type}）。どちらでも決まらなければ無し
#   --base    基点のコミット。差分のファイルは git diff <基点> で読む
#   --target  マージ先の ref（例: origin/main）。base_ahead の条件で、基点より進んでいるかを見る
#   --type    変更の type。分からなければ省く
#   --issue   作業中の Issue の番号（#N でもよい）。Issue が無ければ省く
#
# 層（下ほど優先。同じ名前の観点は上位の層のファイルが使われる）:
#   3. プラグインに同梱する共通の観点   review/*.md
#   2. ユーザーの観点                   ~/.claude/dev-workflow/review/*.md（導入したリポジトリの中でだけ使う）
#   1. リポジトリの観点                 <repo>/.claude/dev-workflow/review/*.md
#
# 観点ファイルの形式（1ファイルに1観点）:
#   ---
#   title: 一覧に出す1行の説明（必須）
#   enabled: false                （任意。下位の層にある同じ名前の観点を止める）
#   builtin: code-review          （任意。本文の代わりに、組み込みの /code-review を実行する）
#   types: [fix, perf]            （任意。変更の type がこのどれかのときだけ実行する）
#   paths: ["**/*.sh", "!docs/**"] （任意。差分のファイルがこのパターンに当たるときだけ実行する）
#   issue: required               （任意。Issue があるときだけ実行する）
#   base_ahead: required          （任意。マージ先が基点より進んでいる（ブランチを作った後に
#                                   コミットが入った）ときだけ実行する）
#   ---
#   本文：サブエージェントへのレビューの指示（何を確かめ、どう指摘するか）
#
#   - 観点の名前はファイル名（.md を除く）。小文字の英数字と - だけ
#   - enabled: false のときは本文を省いてよい。builtin を書いたときも本文を省いてよい。builtin の観点の本文に
#     「## 指摘しないこと」の節を書くと、review スキルは組み込みのコマンドの指摘をこれに照らして外す
#   - 条件（types・paths・issue・base_ahead）を書かなければ毎回実行する。複数書けば、すべてに当てはまるときだけ実行する
#   - types・paths は [a, b] の形か、1つだけの値で書く。, と引用符は値に使えない
#   - type が分からなければ、types を書いた観点は外す
#   - paths は .gitignore や GitHub Actions の paths と同じ書き方（git の pathspec の glob）で、リポジトリの
#     ルートからの相対パスに当てる。* と ? は / をまたがない。**/ は0個以上のディレクトリ、/** はその下のすべてに当たる
#     （例: "**/*.sh" はどこの .sh にも、"*.sh" はルートの .sh だけに、"docs/**" は docs の下のすべてに当たる）。
#     ! で始まるパターンは除外で、除外されないファイルが1つでも当たれば実行する
#     （例: ["!docs/**"] は docs の下だけを変えたときは実行しない）
#   - 条件は観点ファイルごとに書く。上位の層で同じ名前の観点を置くと、条件も上位の層のファイルのものになる
#
# 出力:
#   perspectives  使う観点（名前の順）。name・title・layer・path・builtin（無ければ null）・
#                 overrides（上書きした下位の層のパス）
#   skipped       条件に当てはまらないので外した観点。name・layer・path・reason（外した理由）
#   disabled      enabled: false で止めた観点。name・layer・path・overrides
#   invalid       形式の誤りで使わないファイル。path・reason・overrides（標準エラーにも warn を出す）
#                 ファイル名が正しければ、下位の層にある同じ名前の観点も使わない（止めるつもりの書き間違いで動かさない）
#   context       絞り込みに使った値（絞り込まないときは null）。base・target・ahead（マージ先が基点より
#                 進んだコミットの数）・issue（番号か null）・type（null もある）・type_from（issue・branch・given・null）・
#                 max_rounds（--auto のとき、設定 review.max_rounds の値。1以上の整数でなければ止まる。--auto でなければ null）・
#                 model（--auto のとき、設定 review.model の値。
#                 null か opus・sonnet・haiku・fable でなければ止まる。--auto でなければ null）・
#                 code_review_effort（--auto のとき、設定 review.code_review_effort の値。/code-review に渡す effort の段階。
#                 null か low・medium・high・xhigh・max でなければ止まる。--auto でなければ null）・
#                 fallback（--auto のとき、PR のマージ先をそのまま使えなかった理由（merge-target.sh の fallback）。ほかは null）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

auto=false base="" target="" type="" issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --auto) auto=true; shift ;;
    --base | --target | --type | --issue)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      case "$1" in
        --base) base="$2" ;;
        --target) target="$2" ;;
        --type) type="$2" ;;
        --issue) issue="$2" ;;
      esac
      shift 2
      ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

type_from=null
target_fallback=null
max_rounds=null
model=null
code_review_effort=null
if [ "$auto" = true ]; then
  if [ -n "$base$target$type$issue" ]; then
    dw_die "--auto と --base・--target・--type・--issue は一緒に使えません" 64
  fi
  auto_root="$(dw_repo_root)" || dw_die "git のリポジトリの中ではないので、絞り込めません" 2
  config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
  max_rounds="$(jq -c '.review.max_rounds' <<<"$config")"
  case "$max_rounds" in
    "" | null | 0 | 0[0-9]* | *[!0-9]*) dw_die "review.max_rounds は1以上の整数にしてください: ${max_rounds}" 2 ;;
  esac
  # review.model もほかの設定と同じく層を合わせた値を使う（ユーザーの層は、導入したリポジトリの中でだけ効く。設計書 §7）
  model="$(jq -c '.review.model' <<<"$config")"
  dw_json_enum_ok "$DW_REVIEW_MODELS" "$model" || dw_die "review.model は null か $(dw_json_enum_names "$DW_REVIEW_MODELS") のどれかにしてください: ${model}" 2
  code_review_effort="$(jq -c '.review.code_review_effort' <<<"$config")"
  dw_json_enum_ok "$DW_CODE_REVIEW_EFFORTS" "$code_review_effort" \
    || dw_die "review.code_review_effort は null か $(dw_json_enum_names "$DW_CODE_REVIEW_EFFORTS") のどれかにしてください: ${code_review_effort}" 2
  # マージ先は dw_merge_target が決めて取得する（merge-target.sh と同じ。読むだけなので、PR のマージ先を使えなければ
  # 警告して続ける。規則は lib/common.sh の「PR のマージ先」）。設定とブランチは、ここで読んだものを渡す
  branch="$(git symbolic-ref --short -q HEAD || true)"
  base_branch="$(dw_base_branch "$config")"
  merge_target="$(dw_merge_target "$auto_root" "$base_branch" "$branch")" || exit $?
  { IFS= read -r target; IFS= read -r target_fallback; } <<<"$(jq -r '.ref, (.fallback | tojson)' <<<"$merge_target")"
  base="$(git merge-base "$target" HEAD)" || dw_die "${target} と HEAD の基点が見つかりません" 2
  parsed="$(dw_parse_branch "$config" "$branch")" || exit $?
  IFS='|' read -r branch_type branch_issue <<<"$parsed"
  # ブランチ名の番号は、先頭の 0 をそろえる（017 は 17）。Issue の番号として使えない（0 など）ときは、止まらずに Issue は無いものとする
  issue=""
  if [ -n "$branch_issue" ] && ! issue="$(dw_issue_number --issue "$branch_issue" 2>/dev/null)"; then
    dw_warn "ブランチ名の番号 ${branch_issue} は Issue の番号として使えないので、Issue は無いものとして判断します"
    issue=""
  fi
  if [ -n "$issue" ]; then
    err="$(mktemp)"
    if ! command -v gh >/dev/null 2>&1; then
      dw_warn "gh が無いので Issue #${issue} を読めません。type はブランチ名から決めます"
    elif labels="$(dw_try_read_issue "$issue" labels 2>"$err")"; then
      type="$(jq -r --argjson t "$(jq -c .labels.types <<<"$config")" \
        "$DW_JQ_ISSUE_TYPES"' [.labels[].name] | issue_types($t) | if length == 1 then .[0] else "" end' <<<"$labels")"
      [ -z "$type" ] || type_from=issue
    else
      # PR の番号・無い番号なら Issue は無いものとし、読めなければ番号は使う（dw_try_read_issue の終了コード）
      case "$?" in
        2)
          dw_warn "#${issue} は PR なので、Issue は無いものとして判断します"
          issue=""
          ;;
        3)
          dw_warn "Issue #${issue} が見つからないので、Issue は無いものとして判断します"
          issue=""
          ;;
        *) dw_warn "Issue #${issue} を読めません（$(head -n 1 "$err")）。type はブランチ名から決めます" ;;
      esac
    fi
    rm -f "$err"
  fi
  if [ -z "$type" ] && [ -n "$branch_type" ]; then
    type="$branch_type" type_from=branch
  fi
elif [ -n "$type" ]; then
  type_from=given
fi

# 条件で絞り込むのは --auto か --base を渡したときだけ（--type・--issue が無いことを「type も Issue も無い」と読むため）
filter=false
if [ "$auto" = true ] || [ -n "$base" ] || [ -n "$target" ] || [ -n "$type" ] || [ -n "$issue" ]; then
  if [ -z "$base" ] || [ -z "$target" ]; then
    dw_die "条件で絞り込むには --base と --target の両方を渡してください" 64
  fi
  # スキルの引数の #12 も受ける（dw_issue_number）。--issue は任意
  [ -z "$issue" ] || issue="$(dw_issue_number --issue "$issue")"
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || dw_die "基点のコミットが見つかりません: ${base}" 2
  git rev-parse --verify --quiet "$target^{commit}" >/dev/null || dw_die "マージ先が見つかりません: ${target}" 2
  filter=true
fi

repo_root="$(dw_repo_root || true)"

# 先頭の --- で囲まれた部分を出力する。閉じる --- が無ければ失敗する
# 行末の CR と、先頭の BOM（Windows のエディタが付ける）は取り除く
frontmatter() {
  awk "$DW_AWK_STRIP_CR_BOM"'
    NR == 1 { if ($0 != "---") exit 1; on = 1; next }
    $0 == "---" { closed = 1; exit }
    { print }
    END { if (!closed) exit 1 }' "$1"
}

# 閉じる --- より後ろ（本文）のうち、空白でない行の数
body_lines() {
  awk "$DW_AWK_STRIP_CR_BOM"' n >= 2 && NF { c++ } $0 == "---" && n < 2 { n++ } END { print c + 0 }' "$1"
}

# frontmatter から <キー> の値を取り出す。前後の空白と、囲む引用符を外す
fm_value() {
  # 最初の値だけを読むのに head を使わない（同じキーの行が多いと、head が先に終わって sed が SIGPIPE で終わり、pipefail で止まるため）
  printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | sed -n 1p \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# frontmatter の値を一覧として読み、1行に1つ出力する。[a, b] の形と、1つだけの値を受け付ける
fm_list() {
  local v="$1"
  case "$v" in
    \[*\]) v="${v#\[}" v="${v%\]}" ;;
  esac
  printf '%s\n' "$v" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" \
    | grep -v '^$' || true
}

# 1行に1つの値を JSON の配列にする
# shellcheck disable=SC2119 # 引数（フィルター）は省く
lines_json() { dw_json_lines_nonempty; }

records='[]'
invalid='[]'

# 使い方: add_invalid <パス> <理由> [<層の名前> <観点の名前>]
# 観点の名前を渡すと、その名前の観点として並べ、下位の層にある同じ名前の観点を使わないようにする
add_invalid() {
  dw_warn "観点ファイルを使いません（$2）: $1"
  invalid="$(jq -c --arg p "$1" --arg r "$2" '. + [{path: $p, reason: $r}]' <<<"$invalid")"
  [ $# -ge 4 ] || return 0
  records="$(jq -c --arg n "$4" --arg l "$3" --arg p "$1" \
    '. + [{name: $n, title: "", enabled: false, invalid: true, layer: $l, path: $p}]' <<<"$records")"
}

# frontmatter から実行する条件を読み、{types, paths, issue, base_ahead} の JSON を出力する。
# types・paths は書かなければ null。形式が誤っていれば、理由を出力して失敗する
conditions() {
  local fm="$1" v types=null paths=null issue_req=false ahead_req=false t
  if printf '%s\n' "$fm" | grep -q '^types:'; then
    v="$(fm_list "$(fm_value "$fm" types)")"
    if [ -z "$v" ]; then echo "types に type がありません"; return 1; fi
    while IFS= read -r t; do
      printf '%s' "$t" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
        || { echo "types は type の名前（小文字の英数字と -）の一覧にしてください"; return 1; }
    done <<<"$v"
    types="$(lines_json <<<"$v")"
  fi
  if printf '%s\n' "$fm" | grep -q '^paths:'; then
    v="$(fm_list "$(fm_value "$fm" paths)")"
    if [ -z "$v" ]; then echo "paths にパターンがありません"; return 1; fi
    while IFS= read -r t; do
      case "${t#!}" in
        "" | /* | .. | ../* | */.. | */../*)
          echo "paths はリポジトリのルートからの相対パスのパターンにしてください（/ で始めない・.. を使わない）: ${t}"
          return 1
          ;;
      esac
    done <<<"$v"
    paths="$(lines_json <<<"$v")"
  fi
  case "$(fm_value "$fm" issue)" in
    "") ;;
    required) issue_req=true ;;
    *) echo "issue は required にしてください"; return 1 ;;
  esac
  case "$(fm_value "$fm" base_ahead)" in
    "") ;;
    required) ahead_req=true ;;
    *) echo "base_ahead は required にしてください"; return 1 ;;
  esac
  jq -nc --argjson t "$types" --argjson p "$paths" --argjson i "$issue_req" --argjson a "$ahead_req" \
    '{types: $t, paths: $p, issue: $i, base_ahead: $a}'
}

# 使い方: collect <層の名前> <ディレクトリ>
collect() {
  local layer="$1" dir="$2" f name fm title enabled builtin when
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    if ! printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      add_invalid "$f" "ファイル名は小文字の英数字と - だけにしてください"
      continue
    fi
    if ! fm="$(frontmatter "$f")"; then
      add_invalid "$f" "先頭に --- で囲んだ frontmatter がありません" "$layer" "$name"
      continue
    fi
    enabled="$(fm_value "$fm" enabled)"
    case "$enabled" in
      "" | true) enabled=true ;;
      false) ;;
      *) add_invalid "$f" "enabled は true か false にしてください" "$layer" "$name"; continue ;;
    esac
    title="$(fm_value "$fm" title)"
    builtin="$(fm_value "$fm" builtin)"
    case "$builtin" in
      "" | code-review) ;;
      *) add_invalid "$f" "builtin は code-review にしてください" "$layer" "$name"; continue ;;
    esac
    if ! when="$(conditions "$fm")"; then
      add_invalid "$f" "$when" "$layer" "$name"
      continue
    fi
    if [ "$enabled" = true ]; then
      if [ -z "$title" ]; then
        add_invalid "$f" "title がありません" "$layer" "$name"
        continue
      fi
      if [ -z "$builtin" ] && [ "$(body_lines "$f")" -eq 0 ]; then
        add_invalid "$f" "本文（レビューの指示）がありません" "$layer" "$name"
        continue
      fi
    fi
    records="$(jq -c --arg n "$name" --arg t "$title" --argjson e "$enabled" --arg l "$layer" --arg p "$f" \
      --arg b "$builtin" --argjson w "$when" \
      '. + [{name: $n, title: $t, enabled: $e, layer: $l, path: $p,
        builtin: (if $b == "" then null else $b end), when: $w}]' <<<"$records")"
  done
}

collect plugin "$DW_PLUGIN_ROOT/review"
# 導入していないリポジトリでは、ユーザーの層を使わない（設計書 §1）
user_review_dir="$(dw_user_review_dir_for "$repo_root")"
[ -z "$user_review_dir" ] || collect user "$user_review_dir"
# ホームのリポジトリでは、リポジトリの層がユーザーの層と同じ場所になるので、リポジトリの観点としては使わない
[ -z "$repo_root" ] || [ -z "$(dw_team_dir "$repo_root")" ] || collect repo "$(dw_team_dir "$repo_root")/review"

# 優先度の低い層から順に入れ、同じ名前は後の層で置き換える
result="$(jq -n --argjson r "$records" --argjson inv "$invalid" '
  (reduce $r[] as $x ({};
    .[$x.name] as $prev
    | .[$x.name] = ($x + {overrides: (if $prev then $prev.overrides + [$prev.path] else [] end)})))
  | [.[]] | sort_by(.name) as $all
  | ([$all[] | select(.invalid) | {key: .path, value: .overrides}] | from_entries) as $shadow
  | {
      perspectives: [$all[] | select(.enabled) | {name, title, layer, path, builtin, overrides, when}],
      disabled: [$all[] | select((.enabled | not) and (.invalid | not)) | {name, layer, path, overrides}],
      invalid: [$inv[] | . + {overrides: ($shadow[.path] // [])}]
    }')"

# 形式の誤ったファイルに隠れて使わなくなった下位の層の観点を知らせる
jq -r '.invalid[] | select(.overrides != []) | .path | split("/") | last | rtrimstr(".md")' <<<"$result" \
  | while IFS= read -r name; do
    dw_warn "形式の誤ったファイルがあるので、同じ名前の下位の層の観点も使いません: $name"
  done
# 条件に当てはまらない理由を出力する。当てはまれば何も出力しない
# 使い方: skip_reason <条件の JSON>
skip_reason() {
  local when="$1" list pat files
  local -a specs
  if [ "$(jq -r .issue <<<"$when")" = true ] && [ -z "$issue" ]; then
    echo "Issue が無い（issue: required）"
    return
  fi
  list="$(jq -r '.types // empty | .[]' <<<"$when")"
  if [ -n "$list" ]; then
    if [ -z "$type" ]; then
      echo "type が分からない（types: $(jq -r '.types | join("、")' <<<"$when")）"
      return
    fi
    if ! printf '%s\n' "$list" | grep -Fxq -- "$type"; then
      echo "type（${type}）が types（$(jq -r '.types | join("、")' <<<"$when")）のどれでもない"
      return
    fi
  fi
  list="$(jq -r '.paths // empty | .[]' <<<"$when")"
  if [ -n "$list" ]; then
    # git の pathspec の glob で当てる。top でリポジトリのルートからのパスにし、! は除外にする
    specs=()
    while IFS= read -r pat; do
      case "$pat" in
        '!'*) specs+=(":(top,exclude,glob)${pat#!}") ;;
        *) specs+=(":(top,glob)${pat}") ;;
      esac
    done <<<"$list"
    # 名前を変えたファイルは、元の名前と新しい名前の両方を差分のファイルとみなす
    files="$(git diff --name-only --no-renames "$base" -- "${specs[@]}")" \
      || dw_die "差分のファイルを paths に当てられません: $(jq -r '.paths | join("、")' <<<"$when")"
    if [ -z "$files" ]; then
      echo "差分のファイルが paths（$(jq -r '.paths | join("、")' <<<"$when")）に当たらない"
      return
    fi
  fi
  if [ "$(jq -r .base_ahead <<<"$when")" = true ] && [ "$ahead" -eq 0 ]; then
    echo "マージ先（${target}）が基点より進んでいない（base_ahead: required）"
  fi
}

skipped='[]'
context=null
if [ "$filter" = true ]; then
  ahead="$(git rev-list --count "$base..$target")" || dw_die "マージ先の進み具合を読めません: ${base}..${target}"
  # pathspec の top はリポジトリのルートからなので、どのディレクトリで実行しても同じに当たる
  kept='[]'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    reason="$(skip_reason "$(jq -c .when <<<"$p")")"
    if [ -n "$reason" ]; then
      skipped="$(jq -c --argjson p "$p" --arg r "$reason" '. + [$p | {name, layer, path, reason: $r}]' <<<"$skipped")"
    else
      kept="$(jq -c --argjson p "$p" '. + [$p]' <<<"$kept")"
    fi
  done < <(jq -c '.perspectives[]' <<<"$result")
  result="$(jq -c --argjson k "$kept" '.perspectives = $k' <<<"$result")"
  context="$(jq -nc --arg b "$base" --arg t "$target" --argjson a "$ahead" --arg i "$issue" --arg ty "$type" --argjson mr "$max_rounds" --argjson m "$model" --argjson cre "$code_review_effort" --argjson fb "$target_fallback" \
    --argjson f "$(if [ "$type_from" = null ]; then echo null; else jq -n --arg x "$type_from" '$x'; fi)" \
    '{base: $b, target: $t, ahead: $a, issue: (if $i == "" then null else ($i | tonumber) end),
      type: (if $ty == "" then null else $ty end), type_from: $f, max_rounds: $mr, model: $m, code_review_effort: $cre, fallback: $fb}')"
fi

jq --argjson s "$skipped" --argjson c "$context" \
  '{perspectives: [.perspectives[] | del(.when)], skipped: $s, disabled, invalid, context: $c}' <<<"$result"
