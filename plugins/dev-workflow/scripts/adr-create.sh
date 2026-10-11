#!/usr/bin/env bash
# ADR（Architecture Decision Record）のファイルを、テンプレートから1つ作り、JSON で出力する。
#
# 使い方: adr-create.sh --issue N --name TEXT --template TYPE [--date YYYY-MM-DD] [--supersedes FILE]... [--dry-run]
#        adr-create.sh --accept FILE [--date YYYY-MM-DD] [--dry-run]
#
#   --issue N          判断をした Issue の番号（#N でもよい）。ファイル名の先頭（6桁に0埋め。999999 まで）と front matter の issue になる
#   --name TEXT        短い名前（英語）。小文字にし、英数字以外は - にして 40 文字までに整える
#   --template TYPE    テンプレート（templates/adr/ の MADR 4.0.0 を日本語に訳したもの）
#                        full          全部の節・説明あり（adr-template.md）
#                        minimal       必須の節・説明あり（adr-template-minimal.md）
#                        bare          全部の節・説明なし（adr-template-bare.md）
#                        bare-minimal  必須の節・説明なし（adr-template-bare-minimal.md）
#   --date YYYY-MM-DD  front matter の date（判断をした日）。省くと今日の日付。過去の判断を後から残すときに使う
#   --supersedes FILE  この ADR が置き換える ADR（繰り返して複数書ける）。置き場所からの相対か、リポジトリのルートからの
#                      相対パス。置き換えられる側は、status の行だけを superseded by <この ADR> に書き換える
#   --accept FILE      status が proposed の ADR を採択する。FILE の front matter の status を accepted に、date を採択した日
#                      （--date、省くと今日）に書き換える。この2行のほかは書き換えない。status が proposed でなければ、何も
#                      書き換えずに終了コード 4 で止まる。置き場所からの相対か、リポジトリのルートからの相対パス。
#                      --issue・--name・--template・--supersedes とは一緒に使えない
#   --dry-run          何も作らず書き換えず、することを JSON で出力する
#
# 置き場所は設定の adr.dir（既定: docs/adr。リポジトリのルートからの相対パス）。
# ファイル名は <adr.dir>/<Issue 番号を6桁に0埋め>-<短い名前>.md。1つの Issue から、名前を変えて2つ以上作れる。
# front matter の date は --date の値（省くと今日の日付）、issue は --issue の値にする。status などは、作った後に書く。
# 同じファイル名があれば、上書きせずに終了コード 3 で止まる。置き換える ADR の status の行が読めなければ、
# 何も作らずに終了コード 4 で止まる。
#
# 採択（--accept）の出力: path（採択した ADR）・status（accepted）・date・accepted（true）・dry_run
# 出力: path（作った ADR）・template・issue・date・superseded（status を書き換えた ADR の一覧）・dry_run
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" name="" template="" date="" accept="" dry_run=false
supersedes=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --issue | --name | --template | --date | --supersedes | --accept)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --issue) issue="$2" ;;
        --name) name="$2" ;;
        --template) template="$2" ;;
        --date) date="$2" ;;
        --supersedes) supersedes+=("$2") ;;
        --accept) accept="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# --date は YYYY-MM-DD の形で、暦にある日（2月30日などは不可）だけを受け付ける
if [ -n "$date" ]; then
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) dw_die "--date は YYYY-MM-DD の形にしてください: $date" 64 ;;
  esac
  # 先頭の 0 を8進数として読まないよう、10# を付ける
  y=$((10#${date%%-*})) m=$((10#${date:5:2})) d=$((10#${date##*-}))
  case "$m" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) last=31 ;;
    4 | 6 | 9 | 11) last=30 ;;
    2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then last=29; else last=28; fi ;;
    *) last=0 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ] || dw_die "--date が暦にない日付です: $date" 64
else
  date="$(date +%F)"
fi

# 既にある ADR を書き換える awk に足す。行の前に改行を出し（out）、最後に元の末尾が改行のときだけ改行を足す（eol=1）ので、
# 末尾に改行の無い ADR に改行を足さない。使い方: awk -v eol="$(adr_eol "$p")" "$AWK_OUT"'...out(...)...'
# shellcheck disable=SC2016 # awk のプログラムなので、$ は展開しない
AWK_OUT='function out(x) { printf "%s%s", (NR > 1 ? "\n" : ""), x } END { if (eol && NR > 0) printf "\n" } '
# ファイルの末尾が改行なら 1、そうでなければ 0 を出す
adr_eol() { if [ -z "$(tail -c1 "$1")" ]; then echo 1; else echo 0; fi; }

# ADR を探す。置き場所からの相対パス、リポジトリのルートからの相対パスの順に見て、最初の通常ファイルを resolved_adr に入れる。
# 見つからなければ 1 を返す（--accept と --supersedes で、探し方を揃えるため）。repo_root と adr_dir を使う
resolve_adr() {
  local cand
  resolved_adr=""
  for cand in "$repo_root/$adr_dir/$1" "$repo_root/$1"; do
    if [ -f "$cand" ]; then
      resolved_adr="$cand"
      return 0
    fi
  done
  return 1
}

if [ -n "$accept" ]; then
  [ -z "$issue$name$template" ] && [ ${#supersedes[@]} -eq 0 ] || dw_die "--accept は --issue・--name・--template・--supersedes と一緒に使えません" 64
  repo_root="$(dw_repo_root || true)"
  [ -n "$repo_root" ] || dw_die "git のリポジトリの中ではありません" 2
  config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
  adr_dir="$(dw_adr_dir "$config")"
  resolve_adr "$accept" || dw_die "採択する ADR が見つかりません: ${accept}" 4
  p="$resolved_adr"
  # front matter が閉じていて、その中に status（値が proposed）と date の行がそれぞれあること
  awk "$DW_AWK_STRIP_CR_BOM$DW_AWK_YAML"' NR == 1 && $0 != "---" { bad = 1; exit } NR > 1 && $0 == "---" { closed = 1; exit }
    !st && /^status:/ { v = $0; sub(/^status:/, "", v); if (unquote(strip(v)) != "proposed") { bad = 1; exit } st = 1 }
    !dt && /^date:/ { dt = 1 }
    END { exit !(closed && st && dt && !bad) }' "$p" \
    || dw_die "採択する ADR の front matter が閉じていない、status が proposed でない、または status か date の行がありません: ${accept}" 4
  [ -w "$p" ] || dw_die "採択する ADR に書き込めません: ${accept}" 4
  if [ "$dry_run" = false ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/adr-create.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    # status と date の行だけを書き換える（front matter の中の最初の行）。行末の CR は、見分けるときだけ外し、書く行に残す
    awk -v d="$date" -v eol="$(adr_eol "$p")" "$AWK_OUT"'
      { l = $0; cr = sub(/\r$/, "", l) ? "\r" : "" }
      NR == 1 { fm = 1; out($0); next }
      fm && l == "---" { fm = 0 }
      fm && !sd && l ~ /^status:/ { out("status: \"accepted\"" cr); sd = 1; next }
      fm && !dd && l ~ /^date:/ { out("date: " d cr); dd = 1; next }
      { out($0) }' "$p" >"$tmp"
    cat "$tmp" >"$p" || dw_die "採択する ADR を書き換えられません: ${accept}（一部だけ書き換わっているかもしれません）" 1
  fi
  jq -n --arg p "${p#"$repo_root"/}" --arg d "$date" --argjson dr "$dry_run" \
    '{path: $p, status: "accepted", date: $d, accepted: true, dry_run: $dr}'
  exit 0
fi

[ -n "$issue" ] || dw_die "--issue は必須です" 64
# #12 の形も受け、先頭の 0 を外す（dw_issue_number。printf %06d は 08 を8進数として読んで落ちるため）
issue="$(dw_issue_number --issue "$issue")"
# ファイル名は6桁に0埋めする。dw_issue_number は文字列で 0 を外すので、数として使う前に桁数を見て桁あふれを避ける
[ "${#issue}" -le 6 ] || dw_die "--issue は6桁までにしてください: $issue" 64
[ -n "$name" ] || dw_die "--name は必須です" 64
case "$template" in
  full) tpl="adr-template.md" ;;
  minimal) tpl="adr-template-minimal.md" ;;
  bare) tpl="adr-template-bare.md" ;;
  bare-minimal) tpl="adr-template-bare-minimal.md" ;;
  "") dw_die "--template は必須です（full / minimal / bare / bare-minimal）" 64 ;;
  *) dw_die "--template は full / minimal / bare / bare-minimal のどれかにしてください: $template" 64 ;;
esac

# 小文字にし、英数字以外（日本語を含む）を - にまとめ、前後の - を除いて 40 文字までにする
name="$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40 | sed 's/-$//')"
[ -n "$name" ] || dw_die "短い名前に英数字がありません。英語で指定してください" 64

repo_root="$(dw_repo_root || true)"
[ -n "$repo_root" ] || dw_die "git のリポジトリの中ではありません" 2
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
adr_dir="$(dw_adr_dir "$config")"

base="$(printf '%06d-%s' "$issue" "$name")"
rel="$adr_dir/$base.md"
path="$repo_root/$rel"
# 壊れたシンボリックリンクも、既にあるものとして扱う
{ [ -e "$path" ] || [ -L "$path" ]; } && dw_die "同じファイル名の ADR が既にあるので上書きしません: ${rel}（--name を変えてください）" 3

# 置き換える ADR を、作る前にすべて確かめる（途中で止まって中途半端に書き換えないため）
old_paths=()
for f in ${supersedes[@]+"${supersedes[@]}"}; do
  resolve_adr "$f" || dw_die "置き換える ADR が見つかりません: ${f}" 4
  p="$resolved_adr"
  [ "$p" != "$path" ] || dw_die "自分自身は置き換えられません: ${f}" 4
  # front matter が閉じていて、その中に status の行があること
  awk "$DW_AWK_STRIP_CR_BOM"' NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { closed = 1; exit !found } /^status:/ { found = 1 } END { exit !closed }' "$p" \
    || dw_die "置き換える ADR の front matter が閉じていない、または status の行がありません: ${f}" 4
  # 書き込めないと、新しい ADR を作った後で書き換えに失敗するので、先に確かめる
  [ -w "$p" ] || dw_die "置き換える ADR に書き込めません: ${f}" 4
  old_paths+=("$p")
done

tpl_path="$DW_PLUGIN_ROOT/templates/adr/$tpl"
[ -f "$tpl_path" ] || dw_die "テンプレートがありません: ${tpl_path}" 1

superseded='[]'
for p in ${old_paths[@]+"${old_paths[@]}"}; do
  superseded="$(jq -c --arg p "${p#"$repo_root"/}" '. + [$p]' <<<"$superseded")"
done

if [ "$dry_run" = false ]; then
  mkdir -p "$repo_root/$adr_dir" 2>/dev/null || dw_die "ADR を置くディレクトリを作れません: ${adr_dir}" 1
  # front matter（先頭の --- から次の --- まで）の date と issue だけを置き換える。確かめた後に別の処理が作った
  # ファイルも上書きしないよう、noclobber で書く。行末の CR と先頭の BOM は、見分けるときだけ外し、書く行には残す
  if ! (set -C; awk -v d="$date" -v i="$issue" '
      { l = $0; cr = sub(/\r$/, "", l) ? "\r" : "" }
      NR == 1 { sub(/^\357\273\277/, "", l) }
      NR == 1 && l == "---" { fm = 1; print; next }
      fm && l == "---" { fm = 0 }
      fm && l ~ /^date:/ { print "date: " d cr; next }
      fm && l ~ /^issue:/ { print "issue: " i cr; next }
      { print }' "$tpl_path" >"$path") 2>/dev/null; then
    { [ -e "$path" ] || [ -L "$path" ]; } && dw_die "同じファイル名の ADR が既にあるので上書きしません: ${rel}" 3
    dw_die "ADR を書き込めません: ${rel}" 1
  fi
  tmp=""
  trap 'rm -f "$tmp"' EXIT
  rewritten=""
  for p in ${old_paths[@]+"${old_paths[@]}"}; do
    tmp="$(mktemp "${TMPDIR:-/tmp}/adr-create.XXXXXX")"
    # 行末の CR は、見分けるときだけ外し、書き換えた status の行にも残す（改行が \r\n の ADR の改行をそろえたままにする）
    awk -v s="superseded by $base" -v eol="$(adr_eol "$p")" "$AWK_OUT"'
      { l = $0; cr = sub(/\r$/, "", l) ? "\r" : "" }
      NR == 1 { fm = 1; out($0); next }
      fm && l == "---" { fm = 0 }
      fm && !done && l ~ /^status:/ { out("status: \"" s "\"" cr); done = 1; next }
      { out($0) }' "$p" >"$tmp"
    # 元のファイルの権限を保つため、mv ではなく中身を書き戻す。途中で失敗したときは、何が変わったかを知らせる
    cat "$tmp" >"$p" || dw_die "置き換える ADR を書き換えられません: ${p#"$repo_root"/}（一部だけ書き換わっているかもしれません。作った ADR ${rel} は残っています。すでに書き換えた ADR: ${rewritten:-なし}）" 1
    rewritten="${rewritten:+${rewritten}、}${p#"$repo_root"/}"
    rm -f "$tmp"
  done
fi

jq -n --arg p "$rel" --arg t "$template" --argjson i "$issue" --arg d "$date" --argjson s "$superseded" --argjson dr "$dry_run" \
  '{path: $p, template: $t, issue: $i, date: $d, superseded: $s, dry_run: $dr}'
