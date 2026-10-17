#!/usr/bin/env bash
# claude plugin eval のケースで使う偽の gh（同じディレクトリの gh は、このファイルへのシンボリックリンク。
# 本体は、shellcheck の対象にするため、拡張子の付いたこのファイルにしてある）。GitHub に触れずに、ケースの準備のスクリプト
# （plugins/dev-workflow/evals/lib/scaffold.bash の fake_gh_read・fake_gh_write）が作業用のディレクトリに置いた表で答える。
# tests/eval/run.sh が、このディレクトリを PATH の先頭に足す。eval のサンドボックスの中からは、PATH にあるディレクトリしか
# 見えないので、本体も gh と同じディレクトリに置く。
#
# 表と記録は、今のディレクトリから上に辿って最初に見つかる .fake-gh/ に置く（ワークツリーの中で呼ばれても、作業用のリポジトリのものを使う）
#   .fake-gh/routes  1行に1つ「<パターン>\t<応答のファイル>\t<終了コード>\t<read か write>」。パターンは bash の case のパターンで、
#                    表を引く鍵に当てる。上から最初に合うものを使う。鍵は、ふつうは引数を空白でつないだ文字列で、次の形だけそろえる
#                    - gh api graphql：「api graphql <操作名>」（操作名はクエリの query / mutation の後の名前。分からなければ空）
#                    - gh issue view・gh pr view：「<issue か pr> view <番号> <残りの引数>」（#番号・URL の指定は番号にし、先頭に並べ直す）
#   .fake-gh/calls   呼ばれるたびに、引数を空白でつないだ1行を足す（graphql は「api graphql <操作名> <変数の JSON> <-f・-F の値>」）
#   .fake-gh/writes  書き込みなら、calls と同じ1行をここにも足す（grader は、これが空かで「書き込まなかった」を確かめる）
#                    gh issue comment の行は、本文（--body-file の - かファイル）があれば、最後に「 body: <本文を1行にしたもの>」を添える
#   .fake-gh/mutations  GraphQL の書き込み（mutation）の、writes と同じ行の後ろに「 query: <クエリを1行にしたもの>」を添えた行
#                    （writes の行には操作名しか残らず、mergePullRequest などの mutation の名前を grader が見分けられないため）
#   .fake-gh/pr-body gh pr create で送られた PR の本文（--body-file・-F・--body・-b。最後の呼び出しのもので上書きする）。
#                    引数の記録には本文のファイルのパスしか残らないので、grader が PR の本文を採点できるように残す
# 応答のファイルは .fake-gh/ からの相対パス。終了コードが 0 でなければ、応答を標準エラーに出して、その終了コードで終わる。
# -q / --jq があれば、応答に jq -r で当てる。合うパターンが無ければ、記録してから失敗する（足りない応答に気付けるように）。
#
# 書き込みかどうかは、表と、引数の書き込みのしるしで決める。どちらでも、誤るときは書き込み（安全な側）に倒す。
#   - 表で read と宣言した行に当たり、かつ書き込みのしるしが無い呼び出しだけを読むだけにする。それ以外（write の行に
#     当たったもの、どの行にも当たらないもの、しるしがあるもの）はすべて書き込みとして記録する
#   - 書き込みのしるしは、gh api の引数をそのまま調べるだけで、解釈しない（gh の書き方は多く、解釈すると知らない形をすり抜けさせるため）
#       REST     -X / --method が GET・HEAD 以外か、-f…・-F…・--field…・--raw-field…・--input… で始まる引数がある（gh は POST で送る）
#       GraphQL  クエリのどこかに mutation という語がある（文字列やコメントの中でも）か、クエリを読めない
#     read の行のパターンは末尾が * のことが多いので、しるしが無いと、同じ文字列で始まる書き込み（gh api user -X PATCH など）を
#     読むだけと取り違える。しるしがあれば、read の行に当たっても書き込みにする
# Claude が読むだけの呼び出しをして、表に無ければ、書き込みとして記録される。読むだけなら、ケースの表に read で足す
# （よく使うものは scaffold.bash の fake_gh_defaults が既定で足す）。
# しるしのある api の呼び出しが表に無ければ、{} で成功したように答える（書き込みの形は多く、すべてを表に書けないため。
# エラーで止まると、Claude が書き込んだと思って進んだかが、返答から読み取りにくくなる）。
set -euo pipefail

dir="$PWD"
while [ ! -f "$dir/.fake-gh/routes" ]; do
  [ "$dir" != / ] || { echo "fake gh: .fake-gh/routes が見つかりません（${PWD} から上）" >&2; exit 1; }
  dir="$(dirname "$dir")"
done
base="$dir/.fake-gh"

# 値を取るオプション（その次の引数は、位置の引数として数えない）
takes_value() {
  case "$1" in
    -R | --repo | -X | --method | -H | --header | -f | -F | --field | --raw-field | --input | -q | --jq | -t | --template \
      | -p | --preview | --hostname | --cache | --json | -b | --body | --body-file | -T | --title | -l | --label | -s | --state) return 0 ;;
  esac
  return 1
}

# --- 1. 引数を読む ---------------------------------------------------------------
# -q / --jq の式、--input のファイル、-f・-F の値（GraphQL のクエリと変数）、位置の引数、標準入力を読むか
q="" stdin_input=false input_file="" stdin_used=false stdin_read=false fields=() pos=() prev=""
body_file="" body_text="" body_set=false
for a in "$@"; do
  # gh は、値の - と @-（-F body=@- など）で標準入力を読む
  case "$a" in - | *=- | *=@-) stdin_used=true ;; esac
  if [ -n "$prev" ]; then
    # PR の本文（gh pr create の -F は --body-file。gh api の -F は本文の値なので、下の fields にも入れ、使うかは後で決める）
    case "$prev" in
      -F | --body-file) body_file="$a" ;;
      -b | --body) body_text="$a" body_set=true ;;
    esac
    case "$prev" in
      -q | --jq) q="$a" ;;
      -f | --raw-field) fields+=("f:$a") ;;
      -F | --field) fields+=("F:$a") ;;
      --input) if [ "$a" = - ]; then stdin_input=true; else input_file="$a"; fi ;;
    esac
    prev=""
    continue
  fi
  case "$a" in
    --jq=*) q="${a#--jq=}" ;;
    -f?*) fields+=("f:${a#-f}") ;;
    -F?*) fields+=("F:${a#-F}") ;;
    --raw-field=*) fields+=("f:${a#--raw-field=}") ;;
    --field=*) fields+=("F:${a#--field=}") ;;
    --input=-) stdin_input=true ;;
    --input=*) input_file="${a#--input=}" ;;
    --body-file=*) body_file="${a#--body-file=}" ;;
    --body=*) body_text="${a#--body=}" body_set=true ;;
    -) ;;
    -*) takes_value "$a" && prev="$a" ;;
    *) pos+=("$a") ;;
  esac
done
p0="${pos[0]:-}" p1="${pos[1]:-}" p2="${pos[2]:-}"

# --- 2. 表を引く鍵と、記録する行を決める ---------------------------------------------
key="$*"
line="$*"
if [ "$p0" = api ] && [ "$p1" = graphql ]; then
  # スクリプトは、クエリと変数を JSON にして --input - で渡す（dw_gql）。ファイルや -f query=… で渡されたときも読む
  body='{}'
  if $stdin_input; then
    body="$(cat)"
    stdin_read=true
  elif [ -n "$input_file" ] && [ -f "$input_file" ]; then
    body="$(cat "$input_file")"
  fi
  query="$(jq -r '.query // "" | strings' <<<"$body" 2>/dev/null || true)"
  vars="$(jq -c '.variables | objects' <<<"$body" 2>/dev/null || true)"
  extra=""
  for f in ${fields[@]+"${fields[@]}"}; do
    case "$f" in
      # -F は @ファイル を読む（gh と同じ）。-f の値はそのまま
      F:query=@*) query="$(cat "${f#F:query=@}" 2>/dev/null || true)" ;;
      ?:query=*) query="${f#?:query=}" ;;
      *) extra="${extra} ${f#?:}" ;;
    esac
  done
  op="$(printf '%s\n' "$query" | grep -oE '(query|mutation|subscription)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | head -n 1 | awk '{print $2}' || true)"
  key="api graphql ${op}"
  line="$key ${vars:-"{}"}${extra}"
elif [ "$p1" = view ] && { [ "$p0" = issue ] || [ "$p0" = pr ]; }; then
  # Issue・PR の指定（番号・#番号・URL）を番号にそろえ、先頭に並べ直して表を引く（オプションの位置や指定の仕方によらず当てるため）
  num="$(printf '%s\n' "$p2" | sed -E 's#^.*/(issues|pull)/([0-9]+).*$#\2#; s/^#//')"
  rest=() seen=false prev=""
  for a in "$@"; do
    if [ -n "$prev" ]; then rest+=("$a"); prev=""; continue; fi
    case "$a" in
      -*) rest+=("$a"); takes_value "$a" && prev="$a" ;;
      "$p0" | "$p1") ;;
      *) if ! $seen && [ "$a" = "$p2" ]; then seen=true; else rest+=("$a"); fi ;;
    esac
  done
  key="${p0} view${num:+ ${num}}${rest[0]+ ${rest[*]}}"
fi
# gh pr create の本文を残す（--body-file - なら標準入力から読む）。本文の無い呼び出しで前の本文が残らないよう、先に消す
if [ "$p0" = pr ] && [ "$p1" = create ]; then
  rm -f "$base/pr-body"
  if [ "$body_file" = - ]; then
    cat >"$base/pr-body"
    stdin_read=true
  elif [ -n "$body_file" ]; then
    cat "$body_file" >"$base/pr-body" 2>/dev/null || : >"$base/pr-body"
  elif $body_set; then
    printf '%s\n' "$body_text" >"$base/pr-body"
  fi
fi
# gh issue comment の本文（--body-file の - かファイル）を、記録の行の最後に「 body: <本文を1行にしたもの>」として添える。
# grader が、どの Issue にどんな内容のコメントをしたか（連鎖の記録の印など）を見分けられるように。行の先頭の形（issue comment <番号> …）は変えない。
# --body・-b で渡した本文は、引数が既に行に入っているので添えない
if [ "$p0" = issue ] && [ "$p1" = comment ]; then
  comment_body=""
  if [ "$body_file" = - ]; then
    comment_body="$(cat)"
    stdin_read=true
  elif [ -n "$body_file" ]; then
    comment_body="$(cat "$body_file" 2>/dev/null || true)"
  fi
  if [ -n "$comment_body" ]; then line="${line} body: $(printf '%s' "$comment_body" | tr '\n' ' ')"; fi
fi
# ほかの送られた本文は使わないが、書き手が詰まらないよう、標準入力を読み捨てる（--input - や --body-file - など）
if { $stdin_input || $stdin_used; } && ! $stdin_read; then cat >/dev/null; fi

# 書き込みのしるし（上の説明）
marked=false
if [ "$p0" = api ]; then
  if [ "$p1" = graphql ]; then
    if [ -z "$query" ] || printf '%s\n' "$query" | grep -q 'mutation'; then marked=true; fi
  else
    prev=""
    for a in "$@"; do
      method=""
      case "$prev" in -X | --method) method="$a" ;; esac
      case "$a" in
        -X?*) method="${a#-X}" ;;
        --method=*) method="${a#--method=}" ;;
        -f* | -F* | --field* | --raw-field* | --input*) marked=true ;;
      esac
      case "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" in "" | GET | HEAD) ;; *) marked=true ;; esac
      prev="$a"
    done
  fi
fi

# --- 3. 表を引いて、記録して答える -----------------------------------------------------
kind=write file="" code=1
while IFS="$(printf '\t')" read -r pat f c k; do
  [ -n "$pat" ] || continue
  # shellcheck disable=SC2254 # パターンとして当てるため、クォートしない
  case "$key" in
    $pat) file="$f" code="${c:-0}" kind="${k:-write}"; break ;;
  esac
done <"$base/routes"

if $marked; then kind="write"; fi
# GraphQL の書き込み（mutation）は、writes の行に操作名しか残らず、何をするか分からないので、クエリを1行にして .fake-gh/mutations に
# 「<writes と同じ行> query: <クエリ>」として残す（grader が mutation の名前を見分けられるように。writes の行の形は変えない）
if $marked && [ "$p0" = api ] && [ "$p1" = graphql ] && [ -n "$query" ]; then
  echo "${line} query: $(printf '%s' "$query" | tr '\n' ' ' | tr -s ' ')" >>"$base/mutations"
fi
echo "$line" >>"$base/calls"
[ "$kind" = read ] || echo "$line" >>"$base/writes"

if [ -z "$file" ] && $marked; then
  echo '{}'
  exit 0
fi
if [ -z "$file" ]; then
  echo "fake gh: 応答が用意されていない呼び出しです: gh ${key}" >&2
  exit 1
fi
if [ "$code" != 0 ]; then
  cat "$base/$file" >&2
  exit "$code"
fi
if [ -n "$q" ]; then jq -r "$q" "$base/$file"; else cat "$base/$file"; fi
