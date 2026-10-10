# shellcheck shell=bash
# 各スクリプトから source する共通処理。
# macOS 標準の bash 3.2 でも動くよう、連想配列・mapfile・${var,,} などは使わない。

DW_SCRIPTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DW_PLUGIN_ROOT="$(CDPATH='' cd "$DW_SCRIPTS_DIR/.." && pwd)"
export DW_SCRIPTS_DIR DW_PLUGIN_ROOT

# エラーを1行で標準エラーに出して終了する。
# 使い方: dw_die <メッセージ> [終了コード]
dw_die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

dw_warn() {
  printf 'warn: %s\n' "$1" >&2
}

# 長くなりうる文を `jq -R`・`jq -R -s` で読むと、1行が約 4096 バイトを超えるとき、その区切りにかかった BMP の外の文字（絵文字など）が壊れる
# （jq の既知の不具合）。--rawfile なら壊れないので、標準入力の文を jq に渡すときは、`jq -R` を使わずに、dw_jq_text を使う。
# 標準入力の全体を、jq の変数 $dw_in（文字列）にして、jq を1回だけ起動する（jq -n --rawfile dw_in に引数を足す）。
# 入力の文字列を、`.` ではなく `$dw_in` で読む。標準入力は /dev/stdin を jq に直接読ませる（一時ファイルもプロセス置換も使わないので、読めなかったときは jq が失敗する）。
# jq のプログラムは引数で渡す（標準入力から読む形ではない）
# 使い方: dw_jq_text -r --arg b "$x" '$dw_in | split("\n") | .[0]' <<<"$text"
dw_jq_text() {
  jq -n --rawfile dw_in /dev/stdin "$@"
}

# 標準入力の各行を、JSON の文字列の配列にして1行で出力する（`jq -R . | jq -sc .` と同じ。空行も1つと数える。
# 最後の改行の後ろの空の行は数えない）。dw_jq_text を通すので、絵文字が壊れない
# 使い方: arr="$(printf '%s\n' "$a" "$b" | dw_json_lines)"
dw_json_lines() {
  # shellcheck disable=SC2016 # jq の変数（$dw_in）を bash に展開させない
  dw_jq_text -c '$dw_in | split("\n") | if .[-1] == "" then .[:-1] else . end'
}

# 標準入力の各行から、空行を除いた JSON の配列を1行で出力する。第1引数の jq のフィルター（配列を受け取る。既定は .）を通した結果を出す。
# 第2引数以降は jq の引数（--argjson など）。行を読んで空行を除く処理は、ここにそろえる（各所に split("\n") を書かない）
# 使い方: arr="$(git ... | dw_json_lines_nonempty)"
#         arr="$(printf '%s\n' "$a" | dw_json_lines_nonempty '. + $e | unique' --argjson e "$extra")"
dw_json_lines_nonempty() {
  local filter="${1:-.}"
  [ $# -eq 0 ] || shift
  # shellcheck disable=SC2016 # jq の変数（$dw_in）を bash に展開させない
  dw_jq_text -c "$@" '$dw_in | split("\n") | map(select(. != "")) | '"$filter"
}

# 必要なコマンドが無ければ終了する。
dw_require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || dw_die "$cmd が見つかりません" 127
  done
}

# Issue や PR の番号の引数（12 か #12）を、数字だけの番号にして出力する。先頭の 0 はそろえる（017 と 17 は同じ番号）。
# # だけ・## で始まる値・数字でない値・0（#0 は無い）は、使い方の誤り（64）で終了する。
# $(...) の中で呼ぶと、set -e のスクリプトはそのまま止まる。
# 使い方: n="$(dw_number <オプション名> <値> <番号の種類（Issue・PR）>)"
dw_number() {
  local v="$2"
  case "$v" in "#"?*) v="${v#\#}" ;; esac
  case "$v" in
    "" | *[!0-9]*) dw_die "$1 には ${3} の番号を指定してください: $2" 64 ;;
  esac
  # 桁あふれしないよう、算術式ではなく文字列で先頭の 0 を外す
  v="${v#"${v%%[!0]*}"}"
  [ -n "$v" ] || dw_die "$1 には ${3} の番号を指定してください: $2" 64
  printf '%s\n' "$v"
}

# Issue の番号の引数を受け取る（dw_number）。使い方: issue="$(dw_issue_number <オプション名> <値>)"
dw_issue_number() { dw_number "$1" "$2" Issue; }

# Issue を読んで、種類を終了コードで返す（止まらない）。gh issue view は PR の番号でも成功するので、URL で PR を見分ける。
#   0: Issue（指定した項目と url の JSON を出力する）  2: PR  3: 無い  1: 読めない（gh のエラーを標準エラーに出す）
# 使い方: json="$(dw_try_read_issue <番号> <JSON の項目（カンマ区切り。url は自動で足す）>)" || rc=$?
dw_try_read_issue() {
  local json err
  err="$(mktemp)"
  if ! json="$(gh issue view "$1" --json "url,$2" 2>"$err")"; then
    json="$(cat "$err")"
    rm -f "$err"
    case "$json" in
      *"Could not resolve to"* | *NOT_FOUND*) return 3 ;;
    esac
    printf '%s\n' "$json" >&2
    return 1
  fi
  rm -f "$err"
  case "$(jq -r .url <<<"$json")" in
    */pull/*) return 2 ;;
  esac
  printf '%s\n' "$json"
}

# Issue を読んで、指定した項目と url の JSON を出力する（dw_try_read_issue）。PR の番号・無い番号なら終了コード 2、
# ほかの失敗（通信・認証など）は 1 で止まる。$(...) の中で呼ぶと、set -e のスクリプトはそのまま止まる。
# 使い方: json="$(dw_read_issue <番号> <JSON の項目（カンマ区切り。url は自動で足す）> [見つからないときの名前（既定: Issue）])"
dw_read_issue() {
  local json err rc=0 name="${3:-Issue}"
  err="$(mktemp)"
  json="$(dw_try_read_issue "$1" "$2" 2>"$err")" || rc=$?
  case "$rc" in
    0) rm -f "$err"; printf '%s\n' "$json" ;;
    2)
      rm -f "$err"
      # どの値が PR の番号だったかを示す（既定の Issue のときは、番号だけで分かる）
      if [ "$name" = Issue ]; then dw_die "#${1} は PR です。Issue の番号を指定してください" 2; fi
      dw_die "${name} #${1} は PR です。Issue の番号を指定してください" 2
      ;;
    3)
      rm -f "$err"
      dw_die "${name} #${1} が $(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'このリポジトリ') にありません" 2
      ;;
    *)
      json="$(cat "$err")"
      rm -f "$err"
      dw_die "${name} #${1} を読めません: $json"
      ;;
  esac
}

# Issue の作業のブランチを探し、「名前<TAB>手元にあるか<TAB>origin にあるか<TAB>確かか」（どれも true か false）を
# 1行ずつ出力する。2つの段階に分ける（片付けで消してよいブランチと、作業があるかもしれないブランチは別のものなので）。
#   - 確か（true）：branch.pattern に合い（type は labels.types のどれか）、番号（先頭の 0 はそろえる）が一致するもの。
#     片付けや取りやめの対象にするのは、これだけ。設定で branch.pattern の形を変えても、その形で判定する
#   - 候補（false）：確かではないが、名前に「/<番号>-」を含むか「<番号>-」で始まるもの（wip/17-try・feat/17-Fix_Login のほか、
#     backup/2024-01-15 のような関係の無いものもありうる）。見落とさないために見せるだけで、使う側が自動で消したり、
#     Issue の作業と決めつけたりしない
# PR からは探さない（Closes #17, #18 の PR やリリース用の PR のように、別の Issue のブランチまで拾うため）。
# origin を読めなければ止まる（「origin に無い」と区別できないまま出すと、使う側が片付けを誤るため）。
# branch.pattern などの設定に誤り（正規表現として正しくない・文字列でない・labels.types が正しくないなど）があれば、メッセージを出して終了コード 2 で止まる（dw_check_branch_pattern）。
# 使い方: dw_issue_branches <メインのワークツリー> <Issue の番号（dw_issue_number でそろえたもの）> <設定の JSON>
dw_issue_branches() {
  local names refs msg
  msg="$(dw_check_branch_pattern "$3")" || dw_die "$msg" 2
  # refname:short はタグと同じ名前のブランチを heads/<名前> と出すので、lstrip=2 で refs/heads/ だけを外す
  names="$(git -C "$1" for-each-ref --format='%(refname:lstrip=2)' refs/heads/ | awk -v k=L 'NF { print k "\t" $0 }')"
  refs="$(git -C "$1" ls-remote --heads origin 2>/dev/null)" \
    || dw_die "origin のブランチを読めませんでした（通信や認証を確かめてください）"
  # 名前の一覧は引数ではなく標準入力で渡し（ブランチが多いと、引数の長さの上限を超えるため）、1回の jq で判定する。
  # 並べ方は jq の文字の順（ロケールに左右されない。重複を消すときに、別の名前を同じとみなさない）
  # shellcheck disable=SC2016 # jq の変数を bash に展開させない
  printf '%s\n%s\n' "$names" "$(sed -n 's|^[0-9a-f]*[[:space:]]*refs/heads/||p' <<<"$refs" | awk -v k=R 'NF { print k "\t" $0 }')" \
    | dw_jq_text -r --argjson c "$3" --arg n "$2" "$DW_JQ_BRANCH_RE"'
      ($c | branch_re) as $re | ("(^|/)0*" + $n + "-") as $broad
      | ($dw_in | split("\n")) | map(select(. != "") | split("\t")) | group_by(.[1])
      | map({name: .[0][1], l: any(.[]; .[0] == "L"), r: any(.[]; .[0] == "R")})
      | map(. + {confirmed: (((((try (.name | capture($re)) catch null) // {}).issue // "") | sub("^0+"; "")) == $n)})
      | map(select(.confirmed or (.name | test($broad))))
      | .[] | "\(.name)\t\(.l)\t\(.r)\t\(.confirmed)"'
}

# Issue の作業のブランチと、Issue を閉じる PR（開いているものとマージ済みのもの）を、JSON の {branches, candidates, open_prs, merged_prs} で出力する
# （issue-branches.sh・task-start.sh --no-worktree・auto-check.sh が使う。何も変えない）。
#   branches    確かなブランチ（dw_issue_branches）。[{name, local, remote, worktree（無ければ null）}]。
#               マージ済みかは見ない（マージの確かめは、厳密に確かめる cleanup.sh に任せる）
#   candidates  名前が似ているだけのブランチ（from: name）と、Issue を閉じる PR（開いている・マージ済み。今のリポジトリのもの）の
#               ブランチのうち、手元か origin に残っているもの（from: pr）。[{name, local, remote, worktree, from, pr}]
#   open_prs    Issue を閉じる PR のうち開いているもの（フォークや別のリポジトリの PR も含む）。[{number, url, branch,
#               cross（フォークか別のリポジトリの PR なら true。branch は、今のリポジトリのブランチとは限らない）}]
#   merged_prs  Issue を閉じる PR のうちマージ済みの、今のリポジトリのもの。[{number, url, branch}]
# origin・PR を読めなければ止まる。branch.pattern などの設定に誤り（正規表現として正しくない・文字列でない・labels.types が正しくないなど）があれば、終了コード 2 で止まる（dw_issue_branches）。
# 使い方: dw_issue_work <メインのワークツリー> <Issue の番号> <設定の JSON> <Issue の JSON（closedByPullRequestsReferences を含む）>
dw_issue_work() {
  local found branches='[]' candidates='[]' open_prs='[]' merged_prs='[]' cross b is_local is_remote confirmed wt nwo="" url pr_repo pr head
  # $(...) の中で呼ばれると set -e は効かないので、止まったときは明示的に抜ける
  found="$(dw_issue_branches "$1" "$2" "$3")" || exit $?
  while IFS="$(printf '\t')" read -r b is_local is_remote confirmed; do
    [ -n "$b" ] || continue
    wt=""
    if [ "$is_local" = true ]; then wt="$(dw_live_worktree_of "$1" "$b")"; fi
    if [ "$confirmed" = true ]; then
      branches="$(jq -c --arg b "$b" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" \
        '. + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end)}]' <<<"$branches")"
    else
      candidates="$(jq -c --arg b "$b" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" \
        '. + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end), from: "name", pr: null}]' <<<"$candidates")"
    fi
  done <<<"$found"
  # Issue を閉じる PR（closedByPullRequestsReferences は状態を返さないので、PR ごとに読む）。
  # 開いているものは open_prs に、今のリポジトリの PR のブランチは、まだ出していなければ候補に足す。
  # リポジトリの名前は、Issue を閉じる PR があるときだけ読む
  if jq -e '(.closedByPullRequestsReferences // []) | length > 0' <<<"$4" >/dev/null; then
    nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || dw_die "リポジトリの名前を読めませんでした"
  fi
  while IFS="$(printf '\t')" read -r url pr_repo; do
    [ -n "$url" ] || continue
    pr="$(gh pr view "$url" --json number,url,state,headRefName,isCrossRepository)" || dw_die "PR ${url} を読めませんでした"
    # 別のリポジトリの PR かは、参照の repository で見る。参照に repository が無ければ（gh が返さないとき）、
    # 今のリポジトリの PR とみなし、フォークかだけで決める（無いことを別のリポジトリとみなすと、どの PR もフォーク扱いになる）
    cross="$(jq -r --arg r "$pr_repo" --arg nwo "$nwo" "$DW_JQ_SAME_REPO"'(($r != "" and (same_repo($r; $nwo) | not)) or (.isCrossRepository // false))' <<<"$pr")"
    open_prs="$(jq -c --argjson p "$pr" --argjson x "$cross" \
      'if $p.state == "OPEN" then . + [{number: $p.number, url: $p.url, branch: $p.headRefName, cross: $x}] else . end' <<<"$open_prs")"
    merged_prs="$(jq -c --argjson p "$pr" --argjson x "$cross" \
      'if $p.state == "MERGED" and ($x | not) then . + [{number: $p.number, url: $p.url, branch: $p.headRefName}] else . end' <<<"$merged_prs")"
    head="$(jq -r 'select((.state == "OPEN" or .state == "MERGED") and (.isCrossRepository | not)) | .headRefName' <<<"$pr")"
    { [ -n "$head" ] && dw_same_repo "$pr_repo" "$nwo"; } || continue
    if jq -e --arg h "$head" 'any(.[]; .name == $h)' <<<"$branches" >/dev/null \
      || jq -e --arg h "$head" 'any(.[]; .name == $h)' <<<"$candidates" >/dev/null; then
      continue
    fi
    is_local=false
    if git -C "$1" show-ref --verify --quiet "refs/heads/$head"; then is_local=true; fi
    is_remote=false
    if dw_remote_has_branch "$1" "$head"; then is_remote=true; fi
    # 手元にも origin にも無いブランチ（マージして片付け終えたものなど）は、片付けるものが無いので候補に出さない
    [ "$is_local" = true ] || [ "$is_remote" = true ] || continue
    wt=""
    if [ "$is_local" = true ]; then wt="$(dw_live_worktree_of "$1" "$head")"; fi
    candidates="$(jq -c --arg b "$head" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" --argjson n "$(jq .number <<<"$pr")" \
      '. + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end), from: "pr", pr: $n}]' <<<"$candidates")"
  done < <(jq -r '.closedByPullRequestsReferences // [] | .[]
    | [.url, (if .repository then "\(.repository.owner.login)/\(.repository.name)" else "" end)] | @tsv' <<<"$4")
  # ブランチの一覧は、名前の似たブランチが多いと長くなるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
  printf '%s\n' "$branches" "$candidates" "$open_prs" "$merged_prs" \
    | jq -s '{branches: .[0], candidates: .[1], open_prs: .[2], merged_prs: .[3]}'
}

# ブランチを使っているワークツリーの場所。ディレクトリが無い（手で消して記録だけが残った）ものは、無いものとして空を返す。
# 使い方: dw_live_worktree_of <メインのワークツリー> <ブランチ>
dw_live_worktree_of() {
  local p
  p="$(dw_worktree_of "$1" "$2")"
  if [ -n "$p" ] && [ -d "$p" ]; then printf '%s\n' "$p"; fi
}

# ブランチ名を、/ で区切った部分ごとに URL に符号化して出力する。git の参照の API（git/ref/heads/<ブランチ>）のパスに入れるときに使う
# （# や ? があると、そこでパスが切れて別のブランチを指すため。/ はパスの区切りとして残す）。
# ブランチの保護など、名前全体を1つの部分として受ける API には、名前全体を @uri で符号化する（/ も %2F にする）。
# 使い方: dw_uri_path <ブランチ>
dw_uri_path() { jq -rn --arg b "$1" '$b | split("/") | map(@uri) | join("/")'; }

# ブランチを使っているワークツリーの場所（無ければ空）。
# 使い方: dw_worktree_of <メインのワークツリー> <ブランチ>
dw_worktree_of() {
  git -C "$1" worktree list --porcelain \
    | awk -v b="refs/heads/$2" '/^worktree /{p=substr($0, 10)} $0 == "branch " b {print p}'
}

# origin にブランチがあるか。あれば 0、無ければ 1 を返す。読めなければ（通信や認証の失敗）止まる。
# 読めないのを「無い」と見ると、push 済みの作業を無視して作り直したり、片付けを誤ったりするため。
# ls-remote の終了コードは、ブランチが無いとき 2、通信などの失敗のときはそれ以外。
# 使い方: if dw_remote_has_branch <リポジトリ> <ブランチ>; then ...
dw_remote_has_branch() {
  local rc=0
  git -C "$1" ls-remote --exit-code --heads origin "refs/heads/$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) return 1 ;;
    *) dw_die "origin のブランチを読めませんでした（通信や認証を確かめてください）" ;;
  esac
}

# 作業中のリポジトリ（ワークツリー）のルート。
dw_repo_root() {
  if [ -n "${WORKFLOW_REPO_ROOT:-}" ]; then
    printf '%s\n' "$WORKFLOW_REPO_ROOT"
  else
    git rev-parse --show-toplevel 2>/dev/null
  fi
}

# <基準のディレクトリ（絶対パス）> からの相対パス（絶対パスでもよい）のディレクトリを、実体の絶対パスにして出力する。
# 無ければ失敗する。--path-format=absolute は git 2.31 以降にしか無いので、git が返す相対パスは、これで絶対パスにする。
# 相対パスのまま cd すると、CDPATH が設定されているときに cd がパスを出力するので、絶対パスにしてから cd する
# 使い方: dw_abs_dir <基準のディレクトリ> <パス>
dw_abs_dir() {
  local p="$2"
  case "$p" in
    /*) ;;
    *) p="$1/$p" ;;
  esac
  (cd "$p" 2>/dev/null && pwd -P)
}

# git rev-parse --git-dir --git-common-dir --show-toplevel の出力を、<基準のディレクトリ>（rev-parse を実行した場所）から
# 実体の絶対パスにして、git のディレクトリ・リポジトリ（--git-common-dir。ワークツリーなら元のリポジトリ）・作業ツリーの一番上を、
# 1行ずつ出力する（作業ツリーが無い bare リポジトリや .git の中では、3行目は空）。読めなければ失敗する。
# rev-parse を git -C で起動する dw_repo_paths と、オプションや環境変数を付けて起動する guard-git の、どちらも使う
# 使い方: dw_parse_repo_paths <基準のディレクトリ> <rev-parse の出力>
dw_parse_repo_paths() {
  local gd c top
  { IFS= read -r gd; IFS= read -r c; IFS= read -r top; } <<<"$2" || true
  [ -n "${gd:-}" ] && [ -n "${c:-}" ] || return 1
  gd="$(dw_abs_dir "$1" "$gd")" && c="$(dw_abs_dir "$1" "$c")" || return 1
  printf '%s\n%s\n%s\n' "$gd" "$c" "${top:-}"
}

# <ディレクトリ> で git が見つけるリポジトリの、git のディレクトリ・リポジトリ・作業ツリーの一番上を出力する（dw_parse_repo_paths）。
# git は1回だけ起動する。リポジトリが無ければ失敗する。
# 環境に GIT_DIR などが export されていると、git -C はそのディレクトリのリポジトリを探さずにそれを使うので、外して起動する
# （ルートの候補が本当にそのリポジトリのものかを確かめるのに使うため）
# 使い方: dw_repo_paths <ディレクトリ>
dw_repo_paths() {
  dw_parse_repo_paths "$1" "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
    git -C "$1" rev-parse --git-dir --git-common-dir --show-toplevel 2>/dev/null || true)"
}

# <ディレクトリ> の git のディレクトリが <git のディレクトリ>（実体の絶対パス）なら、その作業ツリーの一番上を出力する。違えば失敗する。
# git の内部の配置から考えたルートの候補が、本当にそのリポジトリ（ワークツリーなら、そのワークツリー）のものかを確かめるのに使う。
# リポジトリ（--git-common-dir）ではなく git のディレクトリで比べるのは、同じリポジトリの別のワークツリーと見分けるため
# （メインのワークツリーの git のディレクトリは、リポジトリと同じ）。
# 3つ目の引数に bare を渡すと、作業ツリーが無くても（bare リポジトリ＋ワークツリーの配置の、.git ファイルを置いたディレクトリなど）、
# そのディレクトリを出力する
# 使い方: dw_root_if_repo <ディレクトリ（空なら失敗）> <git のディレクトリ> [bare]
dw_root_if_repo() {
  local gd c top
  [ -n "$1" ] || return 1
  { IFS= read -r gd; IFS= read -r c; IFS= read -r top; } <<<"$(dw_repo_paths "$1" || true)" || true
  [ -n "${gd:-}" ] && [ "$gd" = "$2" ] || return 1
  if [ -n "${top:-}" ]; then
    printf '%s\n' "$top"
  elif [ "${3:-}" = bare ]; then
    dw_abs_dir / "$1"
  else
    return 1
  fi
}

# <git のディレクトリ>（ワークツリーの .git/worktrees/<名前>）が記録している、そのワークツリーの一番上を出力する。
# git はワークツリーの .git ファイルの場所を gitdir ファイルに書いているので、それを dw_root_if_repo で確かめる。分からなければ失敗する
# 使い方: dw_worktree_root <git のディレクトリ>
dw_worktree_root() {
  local f
  [ -f "$1/gitdir" ] || return 1
  f="$(cat "$1/gitdir")"
  dw_root_if_repo "$(dw_abs_dir "$1" "$(dirname "$f")" || true)" "$1"
}

# <リポジトリ>（--git-common-dir の実体の絶対パス）のメインのワークツリーのルートを出力する。分からなければ失敗する。
# 候補は、リポジトリの親（普通のリポジトリの <ルート>/.git、bare リポジトリ＋ワークツリーの <ルート>/.bare）と
# core.worktree（サブモジュールの <上のリポジトリ>/.git/modules/<名前>）で、どちらも dw_root_if_repo で確かめる。
# --separate-git-dir で作ったリポジトリや bare のミラーは、git がメインのワークツリーを記録していないので分からない。
# bare を渡すと、作業ツリーが無い候補も返す（dw_root_if_repo）
# 使い方: dw_repo_main_root <リポジトリ> [bare]
dw_repo_main_root() {
  local wt
  dw_root_if_repo "$(dirname "$1")" "$1" "${2:-}" && return 0
  wt="$(git --git-dir="$1" config core.worktree 2>/dev/null || true)"
  [ -n "$wt" ] && dw_root_if_repo "$(dw_abs_dir "$1" "$wt" || true)" "$1" "${2:-}"
}

# メインのワークツリーのルート。コミットしないファイル（*.local.json）の置き場所で、task-start・cleanup がワークツリーを作り・消す場所。
# <リポジトリのルート> がワークツリー（git worktree add で作ったもの）でなければ、そのルートがメインのワークツリー。
# ワークツリーなら dw_repo_main_root で求め（bare リポジトリ＋ワークツリーの配置では、.git ファイルを置いたディレクトリ）、
# 分からなければ失敗する（推測した別の場所で操作しないため）
# 使い方: dw_main_root <リポジトリのルート>
dw_main_root() {
  local gd c top
  { IFS= read -r gd; IFS= read -r c; IFS= read -r top; } <<<"$(dw_repo_paths "$1" || true)" || true
  [ -n "${c:-}" ] || return 1
  if [ "$gd" = "$c" ] && [ -n "${top:-}" ]; then
    printf '%s\n' "$top"
    return 0
  fi
  # 作業ツリーが無い場所（bare リポジトリ＋ワークツリーの配置の、.git ファイルを置いたディレクトリなど）も、リポジトリから求める
  dw_repo_main_root "$c" bare
}

# パスの実体（シンボリックリンクを解いた絶対パス）を出力する。まだ無いパスは、あるところまでを解いて、残りをそのまま付ける
# （ディレクトリがまだ無くても、ユーザーの層と同じ場所かを比べられるように）
# 使い方: dw_physical_path <パス>
dw_physical_path() {
  local p="$1" rest="" base d
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ] && [ "$p" != / ]; do
    base="${p##*/}"
    rest="/$base$rest"
    p="${p%/*}"
    [ -n "$p" ] || p=/
  done
  d="$(cd -P "$p" 2>/dev/null && pwd -P)" || d="$p"
  [ "$d" != / ] || [ -z "$rest" ] || d=""
  printf '%s%s\n' "$d" "$rest"
}

# リポジトリのチームの設定の置き場所（<ルート>/.claude/dev-workflow）を出力する。
# ホームをリポジトリにしている（dotfiles を ~/.git などで管理している）と、この場所がユーザーの層の置き場所
# （dw_user_dir。~/.claude/dev-workflow）と同じになる。ユーザーの層のファイルをチームの設定として読み書きしないよう、
# その場合は、メインのワークツリーがその場所のリンクされたワークツリーでも、何も出力しない（シンボリックリンクやまだ無いディレクトリも、実体で比べる）。
# 使い方: dw_team_dir <リポジトリのルート>
dw_team_dir() {
  local d user main
  [ -n "${1:-}" ] || return 0
  d="$1/.claude/dev-workflow"
  user="$(dw_physical_path "$(dw_user_dir)")"
  [ "$(dw_physical_path "$d")" != "$user" ] || return 0
  # ホームのリポジトリのワークツリー（.git がファイル）には、コミットされたユーザーの層のファイルの写しがあるが、
  # チームの設定ではないので、メインのワークツリーがホームのリポジトリなら出力しない。
  # 普通のリポジトリ（.git がディレクトリ）では git を起動しない（フックが毎回呼ぶため）
  if [ -f "$1/.git" ]; then
    main="$(dw_main_root "$1" || true)"
    [ -z "$main" ] || [ "$main" = "$1" ] || [ "$(dw_physical_path "$main/.claude/dev-workflow")" != "$user" ] || return 0
  fi
  printf '%s\n' "$d"
}

# ホームのリポジトリ（チームの設定の置き場所がユーザーの層と同じ場所になるリポジトリ）なら成功する。
# 使い方: dw_is_home_repo <リポジトリのルート（空ならリポジトリの外で、失敗する）>
dw_is_home_repo() {
  [ -n "${1:-}" ] && [ -z "$(dw_team_dir "$1")" ]
}

# ホームのリポジトリなら、チームの設定を書く操作を止める（終了コード 2）。ユーザーの層のファイルに書くと、
# 導入したリポジトリのすべてに効いてしまうため。
# 使い方: dw_refuse_home_repo <リポジトリのルート>
dw_refuse_home_repo() {
  if dw_is_home_repo "${1:-}"; then
    dw_die "ホームのリポジトリ（${1}）には導入できません。チームの設定の置き場所 .claude/dev-workflow が、ユーザーの層（$(dw_user_dir)）と同じ場所になるためです。導入するリポジトリの中で実行してください" 2
  fi
}

# このプラグインを導入したリポジトリ（チームの設定 .claude/dev-workflow/config.json があるリポジトリ）なら成功する。
# プラグインが効く範囲を、Claude Code で有効にした範囲（ユーザー単位なら全リポジトリ）ではなく、導入したリポジトリに限るため、
# 導入していないリポジトリでは、フックは何もせず、ユーザーの層（~/.claude/dev-workflow/）も読まない（設計書 §1）。
# ワークツリーに無くても、メインのワークツリー（dw_main_root）にあれば導入したとみなす（初期設定をまだコミットしていないときや、
# 初期設定より前に作ったブランチのワークツリーで、守りが外れないようにする）。
# ホームのリポジトリ（dw_team_dir が空）と、そのワークツリー（メインのワークツリーがホームのリポジトリ）は、ユーザーの層のファイルが
# チームの設定に見えるだけなので、導入したとみなさない
# 使い方: dw_is_set_up <リポジトリのルート（空なら導入していない）>
dw_is_set_up() {
  local main d
  [ -n "${1:-}" ] || return 1
  main="$(dw_main_root "$1" || true)"
  # メインのワークツリーがホームのリポジトリなら、そのワークツリーにも、コミットされたユーザーの層のファイルの写しが
  # あるが（ユーザーの層とは別の場所）、チームの設定ではないので、導入したとみなさない
  ! dw_is_home_repo "$main" || return 1
  d="$(dw_team_dir "$1")"
  [ -z "$d" ] || [ ! -f "$d/config.json" ] || return 0
  [ -n "$main" ] || return 1
  d="$(dw_team_dir "$main")"
  [ -n "$d" ] && [ -f "$d/config.json" ]
}

# ユーザーごとの設定の置き場所。
dw_user_dir() {
  printf '%s\n' "${WORKFLOW_USER_DIR:-$HOME/.claude/dev-workflow}"
}

# 導入したリポジトリ（dw_is_set_up）なら、ユーザーごとの設定の置き場所（dw_user_dir）を出力する。導入していなければ何も出さない。
# ユーザーの層を読むスクリプトは、どれもこれで置き場所を決める（導入したかで読むかを変える判定を1か所にする）
# 使い方: dw_user_dir_for <リポジトリのルート（空ならリポジトリの外）>
dw_user_dir_for() {
  dw_is_set_up "${1:-}" || return 0
  dw_user_dir
}

# ユーザーごとのレビューの観点の置き場所。
dw_user_review_dir() {
  printf '%s\n' "$(dw_user_dir)/review"
}

# 導入したリポジトリ（dw_is_set_up）なら、ユーザーごとのレビューの観点の置き場所（dw_user_review_dir）を出力する。
# 導入していなければ何も出さない（dw_user_dir_for と同じ判定）
# 使い方: dw_user_review_dir_for <リポジトリのルート（空ならリポジトリの外）>
dw_user_review_dir_for() {
  [ -z "$(dw_user_dir_for "${1:-}")" ] || dw_user_review_dir
}

# gh の最低限のバージョン。gh issue でサブ Issue（--json parent・subIssues・subIssuesSummary）を扱えるのが 2.94.0 から。issue-cancel.sh の gh issue close --duplicate-of（2.88.0 から）もこれで足りる。source した側で使う
# shellcheck disable=SC2034
DW_GH_MIN_VERSION=2.94.0

# 今の gh のバージョン（例: 2.96.0）。分からなければ空。
# 1行目だけを読むのに head を使わない（head が先に終わると、gh が SIGPIPE で終わり、pipefail で全体が失敗するため。sed は最後まで読む）
dw_gh_version() {
  gh --version 2>/dev/null | LC_ALL=C sed -n '1s/^gh version \([0-9][0-9.]*\).*/\1/p'
}

# バージョン <a> が <b> 以上なら成功する。数字を . で区切って、前から順に比べる
# 使い方: dw_version_ge <a> <b>
dw_version_ge() {
  local a="$1" b="$2" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}" y="${b%%.*}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
  return 0
}

# gh が <バージョン> より古ければ、更新を促して終了する。
# 使い方: dw_require_gh_version <バージョン> <要る理由>
dw_require_gh_version() {
  local now
  now="$(dw_gh_version)"
  [ -n "$now" ] && dw_version_ge "$now" "$1" && return 0
  dw_die "${2}には gh ${1} 以上が要ります（今は ${now:-不明}）。gh を更新してください（https://cli.github.com/）" 2
}

# 設定ファイルが JSON のオブジェクト1つだけでできているか確かめる。違えば終了する。
dw_check_json() {
  dw_is_json_object "$1" || dw_die "JSON のオブジェクトとして読めません: $1" 2
}

# 読んだもの（jq -s で配列にしたもの）が JSON のオブジェクト1つなら、そのオブジェクトにし、違えば（空・複数の値・
# オブジェクトでない値）エラーにする jq のフィルター。設定のファイルを読むところは、どれもこの決め方を使う
# shellcheck disable=SC2034 # source した側（guard-git.sh）でも使う
DW_JQ_ONE_OBJECT='if length == 1 and (.[0] | type) == "object" then .[0] else error("JSON のオブジェクトではありません") end'

# ファイルが、JSON のオブジェクト1つなら 0 を返す（DW_JQ_ONE_OBJECT）。
# 使い方: dw_is_json_object <ファイル>
dw_is_json_object() {
  jq -se "$DW_JQ_ONE_OBJECT" "$1" >/dev/null 2>&1
}

# jq の失敗の理由（catch で受け取ったもの）が、正規表現として正しくないことによるものなら true にする jq の定義。
# jq 1.6 は「… is not a valid regex: …」、1.7 以降は「Regex failure: …」と出す
# shellcheck disable=SC2016
DW_JQ_REGEX_FAILURE='def regex_failure: tostring | test("Regex failure|is not a valid regex");'

# 設定（入力）の <キー>（. で区切る）を読み、{v: 値} にする jq の定義。上のキーがオブジェクトでないなどで読めなければ、
# 読めないキーを名指しする {e: メッセージ} にする（dw_config_regex_test・DW_JQ_BRANCH_RE）。無いキーは {v: null}
# shellcheck disable=SC2016
DW_JQ_CONFIG_READ='def config_read($k): try {v: getpath($k | split("."))}
  catch {e: "\($k) を読めません（\(tostring | gsub("\n"; " "))）。設定を直してください"};'

# 文字列を、設定の正規表現（<キー>。例：commit.pattern）に当てる。合えば 0、合わなければ 1 を返す。
# 設定の値が読めない（上のキーがオブジェクトでない）・文字列でない・正規表現として正しくないときは、合わないのと区別できるよう、設定の誤りと分かる1行を出して
# 終了コード 2 で止まる（jq の test は正しくない正規表現で失敗し、合わないのと区別できないため）
# 使い方: dw_config_regex_test <設定の JSON> <キー（. で区切る）> <文字列>
dw_config_regex_test() {
  local out
  # shellcheck disable=SC2016 # jq の変数を bash に展開させない
  out="$(jq -r --arg k "$2" --arg s "$3" "$DW_JQ_REGEX_FAILURE$DW_JQ_CONFIG_READ"'
    config_read($k)
    | if has("e") then "!" + .e
      else .v as $p | if ($p | type) != "string" then "!\($k)（\($p | tojson)）が文字列ではありません。設定を直してください"
      else try (if ($s | test($p)) then "+" else "-" end)
        catch (if regex_failure then "!\($k)（\($p | tojson)）が正規表現として正しくありません。設定を直してください"
          else "!\($k) を検査できません（\(tostring | gsub("\n"; " "))）。設定を直してください" end) end end' <<<"$1")" \
    || dw_die "${2} を検査できませんでした（jq が失敗しました）" 2
  case "$out" in
    '!'*) dw_die "${out#!}" 2 ;;
    +) return 0 ;;
    *) return 1 ;;
  esac
}

# 設定（入力）の branch.pattern を、type と Issue の番号を取り出す正規表現にする jq の定義（dw_parse_branch・dw_issue_branches・
# branch-name.sh）。設定されていない（無い・null）の branch.pattern は null（どの名前にも合わない）、labels.types は
# 空の配列とみなす（false などほかの値は、設定されていないとはみなさない）。type は正規表現の記号を含んでいても、
# 文字どおりに照合する（branch_literal）。
#   branch_error_by($strict)  設定（入力）を検査し、誤りがあれば設定の誤りと分かる1行のメッセージを、無ければ null を返す。
#                  キーを読めない（上のキーがオブジェクトでない）ときは、読めないキーを名指しする（config_read）。
#                  文字列でない branch.pattern、文字列の配列でない labels.types、正規表現としての誤りを、それぞれの原因で
#                  報告する。$strict が false（--check・dw_parse_branch・dw_issue_branches）なら、設定されていない
#                  branch.pattern・labels.types は、組み立てられないだけで誤りではないので通す。true（ブランチ名を作る
#                  branch-name.sh）なら、ブランチ名を作れないので「設定されていません」と報告する。
#                  正規表現の誤りでない jq の失敗（test の catch から投げ直したものなど）は、受け皿の
#                  「branch.pattern・labels.types の設定を検査できません（理由）」で報告する
#   branch_config($strict)  入力（設定の JSON の文字列。dw_jq_text の $dw_in で渡す）を {c: 設定} にする。JSON として読めなければ、
#                  {e: メッセージ}。読めても branch_error_by($strict) が誤りを返せば {e: メッセージ}。jq の起動 1 回で、
#                  JSON の読み取り・検査・解析までできるようにする
# jq の変数（$t など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
DW_JQ_BRANCH_RE="$DW_JQ_REGEX_FAILURE$DW_JQ_CONFIG_READ"'def branch_literal: gsub("(?<c>[][\\\\^$.|?*+(){}])"; "\\\(.c)");
def branch_pattern_not_string: "branch.pattern（\(tojson)）が文字列ではありません。設定を直してください";
def branch_types_not_strings: "labels.types（\(tojson)）が文字列の配列ではありません。設定を直してください";
def branch_re: if (.branch.pattern | type) != "string" then null
  else (.labels.types | if . == null then [] else . end) as $t | .branch.pattern
    | gsub("\\{type\\}"; "(?<type>" + ($t | map(branch_literal) | join("|")) + ")")
    | gsub("\\{issue_number\\}"; "(?<issue>[0-9]+)")
    | gsub("\\{slug\\}"; "[a-z0-9]+(?:-[a-z0-9]+)*")
    | "^" + . + "$" end;
def branch_error_by($strict): try (
    config_read("branch.pattern") as $pr | config_read("labels.types") as $tr
    | if $pr.e then $pr.e elif $tr.e then $tr.e
      else $pr.v as $p | $tr.v as $t
      | if $p == null and $strict then "branch.pattern が設定されていません。設定を直してください"
        elif $p != null and ($p | type) != "string" then $p | branch_pattern_not_string
        elif $t == null and $strict then "labels.types が設定されていません。設定を直してください"
        elif $t != null and (($t | type) != "array" or any($t[]; type != "string")) then $t | branch_types_not_strings
        elif $p == null then null
        else branch_re as $re
          | try ("" | test($re) | null)
            catch (if regex_failure then
                "branch.pattern（\($p | tojson)）が正規表現として正しくありません。設定を直してください"
              else error end)
        end end)
  catch "branch.pattern・labels.types の設定を検査できません（\(tostring | gsub("\n"; " "))）。設定を直してください";
def branch_config($strict): (try {c: fromjson}
    catch {e: "設定を JSON として読めません（\(tostring | gsub("\n"; " "))）。設定を直してください"})
  | if has("e") then . else (.c | branch_error_by($strict)) as $e | if $e then {e: $e} else . end end;'

# 設定の branch.pattern と labels.types を検査する（DW_JQ_BRANCH_RE の branch_error_by(false)）。誤りがあれば、設定の誤りと
# 分かる1行を出力して 1 を返す（jq の test は正しくない正規表現で失敗し、ブランチ名が合わないのと区別できないため、先に確かめる）
# 設定されていない（無い・null）branch.pattern・labels.types は、組み立てられないだけで誤りではないので通す
# 使い方: dw_check_branch_pattern <設定の JSON>
dw_check_branch_pattern() {
  local msg
  # shellcheck disable=SC2016 # jq の変数（$dw_in）を bash に展開させない
  msg="$(dw_jq_text -r "$DW_JQ_BRANCH_RE"'$dw_in | branch_config(false) | .e // empty' <<<"$1")" \
    || msg="branch.pattern・labels.types の設定を検査できませんでした（jq が失敗しました）"
  [ -z "$msg" ] || { printf '%s\n' "$msg"; return 1; }
}

# ブランチ名を branch.pattern に当て、type と Issue の番号を「<type>|<番号>」で出力する（無いものは空）
# 区切りを空白にすると、read が先頭の空白を外して、type が空のときに番号を type と取り違える
# 設定の検査（dw_check_branch_pattern と同じ）と解析は、1回の jq で行う。設定に誤りがあれば、
# メッセージを出して終了コード 2 で止まる。
# 使い方: dw_parse_branch <設定の JSON> <ブランチ名>
dw_parse_branch() {
  local out
  # 誤りは「!」を、解析の結果は「=」を先頭に付けて出し、取り違えないようにする
  # shellcheck disable=SC2016 # jq の変数（$b・$re）を bash に展開させない
  out="$(dw_jq_text -r --arg b "$2" "$DW_JQ_BRANCH_RE"'
    $dw_in | branch_config(false)
    | if has("e") then "!" + .e
      else .c | branch_re as $re
        | (try ($b | capture($re)) catch null) // {}
        | "=\(.type // "")|\(.issue // "")" end' <<<"$1")" \
    || dw_die "branch.pattern・labels.types の設定を検査できませんでした（jq が失敗しました）" 2
  case "$out" in
    '!'*) dw_die "${out#!}" 2 ;;
  esac
  printf '%s\n' "${out#=}"
}

# GitHub の GraphQL API を呼び、応答の JSON を出力する。GraphQL は、gh のサブコマンドにも REST にも手段が無いときだけ使う。
# 速さのためではなく、読みやすさ・保守のしやすさ・テストのしやすさと、node id を引き回さないため（設計書 §10）。
# テストの偽 gh が応答を切り替えられるよう、クエリには必ず操作名を付ける（query Foo(...)）。
# 使い方: dw_gql <クエリ> [変数の JSON]
dw_gql() {
  jq -n --arg q "$1" --argjson v "${2:-"{}"}" '{query: $q, variables: $v}' \
    | gh api graphql --input -
}

# gh の標準エラーのうち、gh のお知らせ（新しい版がある、など。成功しても失敗しても出ることがある）の行を除き、
# 空でない最後の行を出力する。gh の失敗の理由を1行にするのに使う（dw_gh_run）。
# 使い方: dw_gh_error_line <標準エラーを受けたファイル>
dw_gh_error_line() {
  grep -v -E '^(A new release of gh is available|To upgrade, run:|https://github\.com/cli/cli/releases)' "$1" 2>/dev/null \
    | grep -v -E '^[[:space:]]*$' | tail -n 1 || true
}

# gh を実行し、標準出力と標準エラーを分けて受ける。成功すれば標準出力をそのまま出す（gh が標準エラーに出すお知らせは、
# JSON と混ぜないよう捨てる）。失敗すれば、理由を1行にして標準エラーに出し、gh の終了コードを返す。理由は、標準出力の
# GraphQL の errors[].message を優先し（gh api graphql は失敗しても応答の本文を標準出力に出す）、無ければ標準エラーの
# お知らせ以外の最後の行（dw_gh_error_line）。標準入力は gh にそのまま渡す（gh api graphql --input - など）。
# マージキューの状態を読む処理（dw_merge_queue_state・dw_pushed_since・pr-merge-status.sh）で使う。
# 使い方: out="$(dw_gh_run <gh の引数>...)" || ...
dw_gh_run() {
  local out err rc=0 reason
  err="$(mktemp)"
  out="$(gh "$@" 2>"$err")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  reason="$(jq -r '[.errors[]?.message // empty] | join("; ")' <<<"$out" 2>/dev/null || true)"
  [ -n "$reason" ] || reason="$(dw_gh_error_line "$err")"
  rm -f "$err"
  [ -n "$reason" ] || reason="gh が失敗しました（終了コード ${rc}）"
  printf '%s\n' "$reason" | tr '\n' ' ' | sed 's/ *$//' >&2
  printf '\n' >&2
  return "$rc"
}

# gh のコマンド（関数でもよい）を実行して出力する。対象が無い（GraphQL の NOT_FOUND、REST の 404・410）ときは
# 失敗にせず null を出力する。呼ぶ側は「見つからない」を null で判断でき、
# スコープ不足・認証・通信など他の失敗は理由を伝えて止まる。
# 使い方: dw_gh_find <コマンド> [引数]...
dw_gh_find() {
  local out err
  err="$(mktemp)"
  if out="$("$@" 2>"$err")"; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  out="$(cat "$err")"
  rm -f "$err"
  case "$out" in
    *NOT_FOUND* | *"Could not resolve to"* | *"HTTP 404"* | *"HTTP 410"*) echo null ;;
    *) dw_die "GitHub の API に失敗しました: $out" ;;
  esac
}

# リポジトリ（OWNER/NAME）が同じかを、大文字小文字を区別せずに比べる。GitHub はリポジトリ名の大文字小文字を区別せず、
# API の repository_url と gh repo view の nameWithOwner で綴りが違うことがあるため、リポジトリを比べる処理（dw_issue_parents・dw_issue_work・dw_project_item・issue-cancel.sh の子孫の判定・next-tasks.sh）で使う。
# jq の中では、プログラムの先頭に "$DW_JQ_SAME_REPO" を足して same_repo(<a>; <b>) を使う。bash では dw_same_repo <a> <b>。
# shellcheck disable=SC2016,SC2034 # $a・$b は jq の変数で、bash に展開させない。source した側（issue-cancel.sh）で使う
DW_JQ_SAME_REPO='def same_repo($a; $b): (($a // "") | ascii_downcase) == (($b // "") | ascii_downcase);'
dw_same_repo() { [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]; }

# GitHub のログイン名を、大文字小文字と末尾の [bot] を除いて比べられる形にする。GitHub App のログインは、gh pr view（GraphQL）では
# app、gh api（REST）では app[bot] と綴りが違い、設定にはどちらで書かれることもあるため。pr-feedback.sh・pr-watch.sh・
# repair-run-count.sh で、比べる両側に使う。jq の中では、プログラムの先頭に "$DW_JQ_LOGIN_NORM" を足して <ログイン> | norm を使う。
# shellcheck disable=SC2034 # source した側で使う
DW_JQ_LOGIN_NORM='def norm: ascii_downcase | sub("\\[bot\\]$"; "");'

# Issue の親を、近い順に（親、親の親、…）たどって、JSON の配列を出力する。要素は {number, title, state, state_reason}。
# 親が無ければ []。別のリポジトリの親に当たったら、そこで打ち切る（その親も、さらに上の親も含めない。設計書 §4：親子は同じリポジトリだけ扱う）。
# GitHub の親子は8層までなので、念のため層の数で打ち切る。
# 使い方: dw_issue_parents <OWNER/NAME> <Issue の番号>
dw_issue_parents() {
  local repo="$1" cur="$2" out='[]' p i=0
  while [ "$i" -lt 8 ]; do
    # 関数は if の中から呼ばれると set -e が効かないので、失敗は明示して返す
    p="$(dw_gh_find gh api "repos/$repo/issues/$cur/parent")" || return 1
    [ "$p" != null ] || break
    dw_same_repo "$(jq -r '.repository_url | sub("^.*?/repos/"; "")' <<<"$p")" "$repo" || break
    # 親の JSON は本文を含んで長くなりうるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
    out="$(printf '%s\n' "$out" "$p" | jq -sc '.[0] + [.[1] | {number, title, state, state_reason: (.state_reason // null)}]')" || return 1
    cur="$(jq -r .number <<<"$p")"
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# Issue のサブ Issue（子）を全ページ読んで、JSON の配列を出力する。読めなければメッセージを出して終了する。
# 子は GitHub の画面で別のリポジトリの Issue も紐付けられるので、パスは Issue の API の url（.../repos/OWNER/NAME/issues/N）の形で渡す。
# 使い方: dw_sub_issues <repos/OWNER/NAME/issues/N>
dw_sub_issues() {
  gh api --paginate "$1/sub_issues?per_page=100" | jq -sc 'add // []' \
    || dw_die "#${1##*/} のサブ Issue を読めませんでした"
}

# Issue の url と、Project の項目（id・project.id・今の Status の列）を GraphQL で読み、
# {url, projectItems: {nodes: [...]}} を出力する。Issue が無ければ null（gh の GraphQL にも REST にも、Issue から Project の項目を引く手段が無い。設計書 §10）。
# 使い方: dw_issue_items <OWNER/NAME> <Issue の番号>
dw_issue_items() {
  # GraphQL の変数（$owner など）を bash に展開させないため、クエリはシングルクォートで書く
  # shellcheck disable=SC2016
  dw_gh_find dw_gql 'query IssueItem($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { url
    projectItems(first: 50) { nodes { id project { id }
      fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } }
}' "$(jq -nc --arg r "$1" --argjson n "$2" '{owner: ($r | split("/")[0]), name: ($r | split("/")[1]), number: $n}')" \
    | jq -c '.data.repository.issue // null'
}

# リポジトリの既定のブランチ（<ブランチ> を指定すればそのブランチ）にあるファイルを取り出して <出力先> に書く。
# 無ければ（404）1 を返す。それ以外の失敗は、違う内容で進めないよう終了する。
# 使い方: dw_fetch_repo_file <OWNER/NAME> <パス> <出力先> [ブランチ]
dw_fetch_repo_file() {
  local err query=""
  if [ -n "${4:-}" ]; then
    query="?ref=$(jq -rn --arg b "$4" '$b | @uri')"
  fi
  if err="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$2$query" 2>&1 >"$3")"; then
    return 0
  fi
  case "$err" in
    *"HTTP 404"*) return 1 ;;
    *) dw_die "${1} の ${2} を読めません: $err" ;;
  esac
}

# 値が、git のブランチ名として使える値なら 0 を返す（設計書 §10。設定の base_branch と、task-start.sh の --branch で使う）。
# ダッシュで始まる値（-foo）は、git fetch origin <base_branch> などでオプションとして扱われ、失敗すべきところで先へ
# 進んでしまうので、使う側ごとに -- を付けるのではなく、読む時点で拒否する。git check-ref-format --branch は
# @{-1} などを今のリポジトリで展開してしまうので、refs/heads/ を付けて書式だけを検査し、ダッシュは別に拒否する。
# HEAD と @ は書式には合うが、git が今の位置として扱う（git fetch origin HEAD は相手の既定のブランチを取る）ので拒否する。
# + で始まる値も書式には合うが、git fetch が refspec の強制更新の印と読む（+develop は develop を取る）ので拒否する。
# 使い方: dw_valid_branch_name <ブランチ名>
dw_valid_branch_name() {
  case "$1" in
    -* | +* | HEAD | @) return 1 ;;
  esac
  git check-ref-format "refs/heads/$1" 2>/dev/null
}

# 設定の base_branch が、git のブランチ名として使える値なら 0 を返す（dw_valid_branch_name）
# 使い方: dw_valid_base_branch <base_branch>
dw_valid_base_branch() { dw_valid_branch_name "$1"; }

# 設定（JSON のオブジェクト）の base_branch を出力する。文字列でない値や、git のブランチ名として使えない値
# （dw_valid_base_branch）なら、終了コード 2 で終了する。base_branch を使うスクリプトは、設定から直接読まずに、
# これで読む（設計書 §10）。config.sh は検査しないので、base_branch を使わない項目は、値が不正でも読める。
# 使い方: dw_base_branch <設定の JSON>
dw_base_branch() {
  local b
  # コマンド置換は末尾の改行を消し、"develop\n" が develop として検査を通るので、末尾に印（.）を付けて受けて外す
  b="$(jq -r '.base_branch | if type == "string" then . + "." else error end' <<<"$1" 2>/dev/null)" \
    || dw_die "設定の base_branch が文字列ではありません" 2
  b="${b%.}"
  dw_valid_base_branch "$b" || dw_die "設定の base_branch が git のブランチ名として使えません: ${b}" 2
  printf '%s\n' "$b"
}

# --- PR のマージ先（#284） -------------------------------------------------------
# PR のマージ先は、設定の base_branch と違うことがある（例：release/v1 に向いた PR）。ブランチの開いた PR のマージ先を
# 決める処理は、どれも dw_pr_pick と dw_merge_target を使い、次の1つの規則に従う（正本はここ。設計書 §10 にも書く）。
#   - 開いた PR が無い：設定の base_branch をマージ先にする（fallback ではない）
#   - PR の baseRefName が無いか空（gh が返さない）：マージ先は分からないので、設定の base_branch にする（fallback ではない。#178）
#   - PR のマージ先をそのまま使えない：fallback に理由を出す
#       invalid_name  git のブランチ名として使えない（dw_valid_branch_name。-x・+x・HEAD・制御文字など）。マージ先は base_branch
#       multiple_prs  fork でない開いた PR が複数あり、マージ先が違う。マージ先は最初の PR のもの（gh の並び順なので確かでない）
#       fetch_failed  origin/<PR のマージ先> を取得できず、手元にも無い（dw_merge_target だけ）。マージ先は base_branch
#   - fallback があるとき、変更を加える処理（branch-status.sh → branch-update の取り込み、pr-create.sh の push）は、
#     dw_pr_pick_strict で終了コード 2 で止まる（取り違えたマージ先を取り込んだり、それで先行を確かめたりしない）。
#     マージ先を取得できないときも、dw_fetch_target_strict で同じく終了コード 2 で止まる（fetch_failed に当たる）。
#     gh で PR を読めない（gh が失敗した・JSON でない応答）ときも、PR が別のマージ先に向いているかが分からないので止まる
#     （gh が無いときだけは、PR が無いものとして base_branch を使う）。
#     pr-create.sh の --dry-run も、本番と同じく止まる（dry-run は本番で何が起きるかを先に見せるためのものなので）。読むだけの処理
#     （review-perspectives.sh、merge-target.sh を使う pr-create の手順2・task-auto の確認）は、警告して出したマージ先で続け、
#     スキルは fallback が null でなければその旨を伝える
# fork でない開いた PR が複数あってもマージ先が同じなら、そのマージ先を使う（どれを選んでも同じなので fallback ではない。
# マージ先が無いか空の PR は、base_branch に向いているとみなして比べる）。

# gh pr list --head <ブランチ> の応答（JSON の配列）から、このブランチの開いた PR とマージ先を選ぶ。--head はブランチ名だけで
# 探すので、fork の同じ名前のブランチからの PR（isCrossRepository が true）は除き、残りの最初の PR を選ぶ。
# 4行を出力する：1行目 マージ先、2行目 fallback の理由（上の規則。無ければ空）、3行目 PR が示したマージ先を JSON の文字列に
# したもの（メッセージ用。制御文字も印字できる形になる。PR が無ければ null）、4行目 選んだ PR（応答のオブジェクトのまま
# 1行の JSON。無ければ null）。応答は1回だけ jq で読み、行には制御文字を出さない。
# 応答を JSON の配列として読めなければ（gh が JSON でない出力を返したなど）1 を返す。呼ぶ側は gh が失敗したときと同じに扱う。
# 使い方: dw_pr_pick <gh pr list の応答（--json に baseRefName・isCrossRepository を含める）> <既定の base_branch>
dw_pr_pick() {
  local out base="" reason="" shown="" pr=""
  # 1行目は、制御文字を含む値なら空にして2行目に invalid_name の印を出す（行や here-string の中で制御文字を扱わないため）
  out="$(jq -r --arg d "$2" 'if type == "array" then . else error end
    | map(select(type == "object" and (.isCrossRepository | not))) as $prs
    | ($prs | first // null) as $p
    | ($p.baseRefName // "" | if type == "string" then . else "" end) as $b
    | ($b | explode | any(. < 32 or . == 127)) as $ctrl
    | (if $ctrl then "" else $b end),
      (if $ctrl then "invalid_name"
       elif ([$prs[] | .baseRefName // "" | if type == "string" and . != "" then . else $d end] | unique | length) > 1
       then "multiple_prs" else "" end),
      (if $p == null then "null" else ($b | tojson) end),
      ($p | tojson)' <<<"$1" 2>/dev/null)" || return 1
  { IFS= read -r base; IFS= read -r reason; IFS= read -r shown; IFS= read -r pr; } <<<"$out" || true
  [ -n "$pr" ] || return 1
  if [ "$reason" = invalid_name ] || { [ -n "$base" ] && ! dw_valid_branch_name "$base"; }; then
    reason=invalid_name base="$2"
  elif [ -z "$base" ]; then
    base="$2"
  fi
  printf '%s\n%s\n%s\n%s\n' "$base" "$reason" "$shown" "$pr"
}

# fallback の理由を、1文（句点なし）にする。使い方: dw_pr_fallback_msg <理由> <PR が示したマージ先（JSON の文字列）>
dw_pr_fallback_msg() {
  case "$1" in
    invalid_name) printf '%s\n' "PR のマージ先（${2}）は git のブランチ名として使えません" ;;
    multiple_prs) printf '%s\n' "このブランチに、マージ先の違う開いた PR が複数あります（最初の PR のマージ先は ${2}）" ;;
    fetch_failed) printf '%s\n' "PR のマージ先（${2}）を origin から取得できず、手元にもありません" ;;
    *) printf '%s\n' "PR のマージ先を使えません（${1}）" ;;
  esac
}

# 変更を加える処理（branch-status.sh・pr-create.sh）の、PR とマージ先の選び方。dw_pr_pick で選び、fallback があれば
# 「<理由>。<止めるときの文>」で終了コード 2 で止まる。選べたら、マージ先を DW_PICK_BASE に、PR（無ければ null）を DW_PICK_PR に
# 入れる（止まれるよう、コマンド置換の中では呼ばない）。応答を JSON として読めなければ 1 を返す（呼ぶ側が扱う）
# 使い方: dw_pr_pick_strict <gh pr list の応答> <既定の base_branch> <止めるときの文>
dw_pr_pick_strict() {
  local picked reason shown
  picked="$(dw_pr_pick "$1" "$2")" || return 1
  # shellcheck disable=SC2034 # DW_PICK_BASE・DW_PICK_PR は、呼んだスクリプトが読む
  { IFS= read -r DW_PICK_BASE; IFS= read -r reason; IFS= read -r shown; IFS= read -r DW_PICK_PR; } <<<"$picked"
  [ -z "$reason" ] || dw_die "$(dw_pr_fallback_msg "$reason" "$shown")。${3}" 2
}

# origin/<ブランチ> が手元にあれば 0 を返す（取得はしない）。使い方: dw_remote_ref_exists <リポジトリのルート> <ブランチ>
dw_remote_ref_exists() { git -C "$1" rev-parse -q --verify "refs/remotes/origin/$2^{commit}" >/dev/null; }

# origin/<ブランチ> を取得する。取得できて手元にあれば 0、取得できなくても手元にあれば 1、手元に無ければ 2 を返す
# 使い方: dw_fetch_target <リポジトリのルート> <ブランチ>
dw_fetch_target() {
  local fetched=false
  git -C "$1" fetch -q origin -- "$2" 2>/dev/null && fetched=true
  dw_remote_ref_exists "$1" "$2" || return 2
  $fetched || return 1
}

# 変更を加える処理の、マージ先の取得。取得できない（手元の古い ref で確かめない）か手元に無ければ、終了コード 2 で止まる
# 使い方: dw_fetch_target_strict <リポジトリのルート> <ブランチ>
dw_fetch_target_strict() {
  dw_fetch_target "$1" "$2" || dw_die "origin/${2} を取得できませんでした（マージ先を確かめられないので止めます）" 2
}

# 今のブランチのマージ先を決め、origin から取得して、JSON を出力する（merge-target.sh の本体。読むだけの処理が使う）。
# 規則は上の「PR のマージ先」のとおり。fallback があれば警告して続ける。origin/<マージ先> を取得できなければ、手元にあれば
# 警告してそれを使い（fetched が false）、PR のマージ先が手元にも無ければ fetch_failed として base_branch に戻す。
# base_branch も取得できず手元にも無ければ、終了コード 2 で止まる。gh が失敗するか応答を読めなければ pr_unreadable として
# base_branch を使う。gh が無ければ PR は無いものとする。
# 出力: {branch, base_branch, target, ref, from, pr, fallback, fetched}（merge-target.sh --help）
# 使い方: dw_merge_target <リポジトリのルート> <設定の base_branch> <今のブランチ（detached HEAD なら空）>
dw_merge_target() {
  local root="$1" base_branch="$2" branch="$3" target="$2" from="base_branch" pr=null reason="" shown=null prs picked rc fetched=true
  if [ -n "$branch" ] && command -v gh >/dev/null 2>&1; then
    if prs="$(gh pr list --head "$branch" --state open --json number,url,baseRefName,isCrossRepository 2>/dev/null)" \
      && picked="$(dw_pr_pick "$prs" "$base_branch")"; then
      { IFS= read -r target; IFS= read -r reason; IFS= read -r shown; IFS= read -r pr; } <<<"$picked"
      if [ "$pr" != null ]; then
        pr="$(jq -c '{number, url}' <<<"$pr")"
        # from は、PR の baseRefName をそのまま使ったときだけ pr（base_branch と同じ値でも）。使えない値・無いか空なら base_branch
        [ "$reason" = invalid_name ] || [ "$shown" = '""' ] || from="pr"
      fi
    else
      reason=pr_unreadable
    fi
  fi
  rc=0
  dw_fetch_target "$root" "$target" || rc=$?
  if [ "$rc" = 2 ] && [ "$from" = pr ] && [ "$target" != "$base_branch" ]; then
    # 前の理由（multiple_prs）の警告は、fetch_failed で上書きする前に出しておく（fallback の値は fetch_failed にする）
    [ -z "$reason" ] || dw_warn "$(dw_pr_fallback_msg "$reason" "$shown")"
    reason=fetch_failed shown="$(jq -n --arg t "$target" '$t')" target="$base_branch" from="base_branch" rc=0
    dw_fetch_target "$root" "$target" || rc=$?
  fi
  [ "$rc" != 2 ] || dw_die "マージ先が見つかりません: origin/${target}（git fetch origin ${target} で取得してください）" 2
  if [ "$rc" = 1 ]; then
    fetched=false
    dw_warn "origin/${target} を最新にできませんでした。手元の origin/${target} で判断します"
  fi
  [ -z "$reason" ] || dw_warn "$(dw_pr_fallback_msg "$reason" "$shown")。マージ先を origin/${target} として判断します"
  jq -n --arg branch "$branch" --arg base_branch "$base_branch" --arg target "$target" --arg from "$from" \
    --argjson pr "$pr" --arg fallback "$reason" --argjson fetched "$fetched" \
    '{branch: (if $branch == "" then null else $branch end), base_branch: $base_branch, target: $target,
      ref: "origin/\($target)", from: $from, pr: $pr, fallback: (if $fallback == "" then null else $fallback end), fetched: $fetched}'
}

# チームの設定から項目を1つ選び、{"<キー>": <値>} の形（1行）で出力する。設定のファイルが無いか、項目が無い（null）なら
# プラグインの既定を使う（// と違い、false は値として保つ）。ファイルを JSON のオブジェクト1つとして読めなければ
# （DW_JQ_ONE_OBJECT。空のファイルを含む）1 を返す。jq は1回だけ動かす（フックからも呼ぶため）。
# 使い方: dw_team_pick <チームの設定のファイル（空なら無い）> <キー>
dw_team_pick() {
  # shellcheck disable=SC2016 # jq の変数（$k・$d）を bash に展開させない
  local pick='{($k): (if .[$k] == null then $d[0][$k] else .[$k] end)}'
  if [ -n "$1" ] && [ -f "$1" ]; then
    jq -sc --arg k "$2" --slurpfile d "$DW_PLUGIN_ROOT/defaults/workflow.json" "$DW_JQ_ONE_OBJECT | $pick" "$1" 2>/dev/null \
      || return 1
  else
    jq -nc --arg k "$2" --slurpfile d "$DW_PLUGIN_ROOT/defaults/workflow.json" "{} | $pick"
  fi
}

# チームの設定の base_branch を、dw_team_config と同じ決め方（dw_team_pick）で読み、dw_base_branch と同じく検査して
# 出力する。チームの設定を JSON のオブジェクトとして読めない（空のファイルを含む）か、使えない値なら、終了コード 2 で
# 終了する。
# 使い方: dw_team_base_branch <チームの設定のファイル（空なら無い）> [エラーで示すファイルの名前（既定はパス）]
dw_team_base_branch() {
  local c
  c="$(dw_team_pick "$1" base_branch)" || dw_die "${2:-$1} を JSON のオブジェクトとして読めません" 2
  dw_base_branch "$c"
}

# チームの設定の項目（トップレベルのキー）を出力する。ルールセットのようにリポジトリ全体で共有するものに使い、
# 個人の層（config.local.json・~/.claude/dev-workflow）は使わず、チームの設定とプラグインの既定だけで決める
# （dw_team_pick）。JSON のオブジェクトとして読めなければ（空のファイルを含む）1 を返す。
# 使い方: dw_team_config <チームの設定のファイル（空なら無い）> <キー>
dw_team_config() {
  local c
  c="$(dw_team_pick "$1" "$2")" || return 1
  jq -r --arg k "$2" '.[$k]' <<<"$c"
}

# 必須のチェックを求めるルール（rules/branches の required_status_checks のうち、名前が1つ以上あるもの）を選ぶ jq の定義。
# 名前が1つも無いルールは何も求めていないので数えない。source した側で、jq のフィルターの先頭に付けて使う
# shellcheck disable=SC2034
DW_JQ_CHECK_RULES='def check_rules: [.[] | select(.type == "required_status_checks"
  and ((.parameters.required_status_checks // []) | length > 0))];'

# ブランチに効いているルールセットのルール（組織のルールセットも含む）を出力する。--paginate のページごとの配列が
# 並ぶので、使う側で jq -s の add でまとめる。読めなければ非0を返す（どう扱うかは呼び出し側で決める）。
# 使い方: dw_branch_rules <owner/repo（{owner}/{repo} でもよい）> <ブランチ>
dw_branch_rules() {
  gh api --paginate "repos/$1/rules/branches/$(jq -rn --arg b "$2" '$b | @uri')?per_page=100" 2>/dev/null
}

# ブランチへのマージがマージキューを通すか（ブランチに効いているルールに merge_queue があるか）を判定する jq の定義。
# 入力は、rules/branches のページをまとめた1つの配列。source した側で、jq のフィルターの先頭に付けて使う
# shellcheck disable=SC2034
DW_JQ_MERGE_QUEUE='def merge_queue: any(.[]; .type == "merge_queue");'

# ブランチへのマージがマージキューを通すかを、true か false で出力する。組織のルールセットも含めて、ブランチに効いている
# ルール（dw_branch_rules）で決める（doctor.sh と同じ読み方）。読めなければ非0を返す（どう扱うかは呼び出し側で決める）。
# 使い方: dw_merge_queue_enabled <owner/repo（{owner}/{repo} でもよい）> <ブランチ>
dw_merge_queue_enabled() {
  local rules
  rules="$(dw_branch_rules "$1" "$2")" || return 1
  # --paginate はページごとに配列を出力するので、1つにまとめる
  jq -s "$DW_JQ_MERGE_QUEUE"' add // [] | merge_queue' <<<"$rules" 2>/dev/null
}

# PR のブランチに、<時刻> より後の push（push・force_push）があるかを、true か false で出力する。マージキューから
# 外れたままか（キューに入れた後に push して、まだ入れ直していないか）を見分けるのに使う（dw_merge_queue_state。ADR 000323）。
# GitHub には PR のコミットを push した時刻が無く（Commit.pushedDate は廃止。コミットの時刻は手元でコミットした時刻）、
# リポジトリの activity（REST）がブランチへの push の時刻を返すので、それで見る。新しい順に返るので、最初のページだけ見ればよい。
# gh は dw_gh_run で呼ぶ（標準エラーを分けて受け、失敗の理由を1行にする）。
# 読めなければ、理由を1行で標準エラーに出して非0を返す（どう扱うかは呼び出し側で決める）。
# 使い方: dw_pushed_since <PR の URL> <PR のブランチ> <時刻（ISO 8601）>
dw_pushed_since() {
  local repo out
  repo="$(jq -rn --arg u "$1" '$u | capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/pull/").r // empty' 2>/dev/null || true)"
  [ -n "$repo" ] || { echo "PR の URL からリポジトリが分かりません: $1" >&2; return 1; }
  out="$(dw_gh_run api "repos/$repo/activity?ref=$(jq -rn --arg r "refs/heads/$2" '$r | @uri')&per_page=100")" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || { echo "activity の応答を読めません: ${out:0:200}" | tr '\n' ' ' >&2; printf '\n' >&2; return 1; }
  jq --arg t "$3" 'any(.[]; (.activity_type == "push" or .activity_type == "force_push") and ((.timestamp // "") > $t))' <<<"$out"
}

# キューに入れたイベント（AddedToMergeQueueEvent）の後、mergeQueueEntry が出るのを待つ時間（分）。入れた直後は、
# mergeQueueEntry が出るまでに少し時間がかかるので、その間はキューの中とみなす。この時間を過ぎても出ないのは、
# 外れたイベントの欠けなど、キューの中ではない状態なので、並んでいないとみなす（いつまでも待ち続けないため）
DW_QUEUE_ADDED_GRACE_MINUTES=10

# ファイルに受けた warn（「warn: 」で始まる行。dw_warn）のうち、まだ出していない種類のものだけを標準エラーに出す。
# 種類は「warn: 」の後の、最初の「: 」より前の文で見分ける（後ろの gh のエラーの文などは、呼ぶたびに変わりうるため）。
# 出した種類は <覚えるファイル> に足す。同じ確かめ方を繰り返す処理（pr-merge-status.sh の --wait）で、同じ warn を1回だけにする
# 使い方: dw_warn_once <warn を受けたファイル> <出した種類を覚えるファイル>
dw_warn_once() {
  local line body key
  while IFS= read -r line; do
    case "$line" in warn:\ *) ;; *) continue ;; esac
    body="${line#warn: }"
    key="${body%%: *}"
    grep -qxF -- "$key" "$2" 2>/dev/null && continue
    printf '%s\n' "$line" >&2
    printf '%s\n' "$key" >>"$2"
  done <"$1"
}

# 環境変数 DW_QUEUE_NOW（テスト用の今の時刻。UNIX 秒）が数字かを確かめる。数字でなければ、1行のエラーで止まる（終了コード 64）。
# dw_merge_queue_state を使うスクリプトが、始めに呼ぶ
dw_check_queue_now() {
  [ -z "${DW_QUEUE_NOW:-}" ] || [[ "$DW_QUEUE_NOW" =~ ^[0-9]+$ ]] || dw_die "DW_QUEUE_NOW は UNIX 秒（0 以上の整数）にしてください: $DW_QUEUE_NOW" 64
}

# PR のマージキューの状態を読んで、判定した結果を JSON で出力する（pr-merge-status.sh・branch-status.sh が共通に使う。ADR 000323）。
# キューが有効か（isMergeQueueEnabled）、キューに並んでいるか（mergeQueueEntry）とキューの出入りのイベント（タイムラインの
# AddedToMergeQueueEvent・RemovedFromMergeQueueEvent）は、gh pr view にも REST にも無いので GraphQL で読む（設計書 §10）。
# PR は URL で引く。isMergeQueueEnabled は、ルールセットでも古いブランチ保護でもキューが有効なら true になる
# （REST の rules/branches はルールセットだけを返す）。衝突で外れた PR はすぐに mergeQueueEntry が null になり、
# CI の実行も作られないので、外れたことは最後のイベントで見る。
#
# 出力: {enabled, state, position, queued, removed, before_commit}
#   enabled        PR のマージ先でキューが有効か（isMergeQueueEnabled）。false なら、queued は false、removed は null で、
#                  push は読まない
#   state・position  キューに並んでいるときの状態（QUEUED・AWAITING_CHECKS・MERGEABLE・UNMERGEABLE・LOCKED）と順番。並んでいなければ null
#   queued         キューの中か。mergeQueueEntry があるか、最後のイベントが入れたもの（入れた直後で、まだ mergeQueueEntry に
#                  出ていない。DW_QUEUE_ADDED_GRACE_MINUTES 分まで）か、最後が merged の理由で外れたもの（マージの直前で、
#                  PR の state がまだ MERGED でない）なら true
#   removed        キューから外れたまま（{reason, at, push_unknown}）。最後が merged 以外の理由で外れたイベントで、最後にキューに
#                  入れた時刻（入れたイベントが読めなければ外れた時刻）より後に PR のブランチへの push が無いとき。キューに
#                  並んでいる間の push もそれ自体で PR をキューから外すので、外れた時刻ではなく入れた時刻と比べる。push があれば、
#                  直してまだ入れ直していないので null（キューに入っていない）。push_unknown は、push したかを確かめられなかったか
#                  （フォークからの PR は push がこのリポジトリの activity に無いので読まない。activity を読めなければ warn を出す。
#                  入れたイベントが読めず、外れた時刻と比べたときは、並んでいる間の push が見えないので、push が見つからなくても
#                  true）。
#                  確かめられなければ、外れたままとみなす（キューの状態は捨てない）
#   before_commit  removed のときの、外れたイベントのコミット（キューの一時的なブランチのコミット。そのキューの CI の実行の
#                  headSha）。CI を動かす前に外れた（衝突など）ときや、removed でなければ null
# gh は dw_gh_run で呼ぶ（標準エラーを分けて受け、失敗の理由を1行にする）。読めなければ、理由を1行で標準エラーに出して
# 非0を返す（どう扱うかは呼び出し側で決める）。warn（dw_warn。「warn: <種類の文>: <変わる値>」の形）も標準エラーに出るので、
# 呼び出し側は、成功したときの標準エラーを warn として出し、失敗したときの標準エラーの最後の行を理由として使う。
# 入れたイベントの後、DW_QUEUE_ADDED_GRACE_MINUTES 分を過ぎても並びに出ていなければ、キューに入っていないとみなし、warn を出す。
# テストのため、環境変数 DW_QUEUE_NOW（UNIX 秒）で今の時刻を差し替えられる（pr-watch.sh の PR_WATCH_NOW と同じ形。
# 数字でなければ、理由を出して終了コード 64 を返す。スクリプトは始めに dw_check_queue_now で確かめる）
# 使い方: dw_merge_queue_state <PR の URL> <PR のブランチ> <フォークか（true・false）>
dw_merge_queue_state() {
  local res q pushed err
  if [ -n "${DW_QUEUE_NOW:-}" ] && ! [[ "$DW_QUEUE_NOW" =~ ^[0-9]+$ ]]; then
    echo "DW_QUEUE_NOW は UNIX 秒（0 以上の整数）にしてください: $DW_QUEUE_NOW" >&2
    return 64
  fi
  # shellcheck disable=SC2016 # GraphQL の変数（$url）を bash に展開させないため、シングルクォートで書く
  res="$(jq -n --arg u "$1" '{query: "query PrQueue($url: URI!) {
      resource(url: $url) {
        ... on PullRequest {
          isMergeQueueEnabled
          mergeQueueEntry { state position }
          timelineItems(itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT], last: 2) {
            nodes {
              __typename
              ... on AddedToMergeQueueEvent { createdAt }
              ... on RemovedFromMergeQueueEvent { reason createdAt beforeCommit { oid } }
            }
          }
        }
      }
    }", variables: {url: $u}}' | dw_gh_run api graphql --input -)" || return 1
  q="$(jq -c --argjson now "${DW_QUEUE_NOW:-$(date -u +%s)}" --argjson grace "$DW_QUEUE_ADDED_GRACE_MINUTES" '
    .data.resource | select(type == "object" and has("mergeQueueEntry"))
    | (.isMergeQueueEnabled == true) as $enabled
    | (.timelineItems.nodes // []) as $n | ($n | last) as $ev
    | ([$n[] | select(.__typename == "AddedToMergeQueueEvent")] | last) as $added
    | ($ev.__typename == "RemovedFromMergeQueueEvent") as $was_removed
    | ($ev.__typename == "AddedToMergeQueueEvent" and .mergeQueueEntry == null) as $added_no_entry
    | ($added_no_entry
       and (($now - (($ev.createdAt // "1970-01-01T00:00:00Z") | fromdateiso8601)) < ($grace * 60))) as $just_added
    | ($enabled and (.mergeQueueEntry != null or $just_added or ($was_removed and $ev.reason == "merged"))) as $queued
    | ($enabled and ($queued | not) and $was_removed) as $removed
    | {enabled: $enabled, state: .mergeQueueEntry.state, position: .mergeQueueEntry.position,
       queued: $queued,
       removed: (if $removed then {reason: $ev.reason, at: $ev.createdAt, push_unknown: false} else null end),
       before_commit: (if $removed then $ev.beforeCommit.oid else null end),
       since: (if $added != null then $added.createdAt else $ev.createdAt end),
       since_is_added: ($added != null),
       stale_added: ($enabled and $added_no_entry and ($just_added | not))}' <<<"$res" 2>/dev/null)" || q=""
  if [ -z "$q" ]; then
    # 成功しても errors を返すことがあるので、あればその本文を、無ければ応答の先頭を、1行で理由にする
    err="$(jq -r '[.errors[]?.message // empty] | join("; ")' <<<"$res" 2>/dev/null || true)"
    [ -n "$err" ] || err="マージキューの状態の応答を読めません: ${res:0:200}"
    printf '%s' "$err" | tr '\n' ' ' >&2
    printf '\n' >&2
    return 1
  fi
  if [ "$(jq -r .stale_added <<<"$q")" = true ]; then
    # 入れたイベントの後、待つ時間を過ぎても並びに出ていない。外れたイベントの欠けなどで、外れた理由は分からない
    dw_warn "マージキューに入れたイベントの後、${DW_QUEUE_ADDED_GRACE_MINUTES} 分を過ぎても並びに出ていないので、キューに入っていないとみなします（外れた理由は分かりません）: $(jq -r .since <<<"$q")"
  fi
  if [ "$(jq -r '.removed != null' <<<"$q")" = true ]; then
    if [ "$3" = true ]; then
      # フォークのブランチへの push は、このリポジトリの activity に無いので読まない
      q="$(jq -c '.removed.push_unknown = true' <<<"$q")"
    else
      err="$(mktemp)"
      if pushed="$(dw_pushed_since "$1" "$2" "$(jq -r .since <<<"$q")" 2>"$err")"; then
        if [ "$pushed" = true ]; then
          q="$(jq -c '.removed = null | .before_commit = null' <<<"$q")"
        elif [ "$(jq -r .since_is_added <<<"$q")" != true ]; then
          # 入れたイベントが読めず、外れた時刻と比べた。並んでいる間の push（外れた時刻より前）は見えないので、
          # push が見つからなくても、push したかは確かめられなかったものとする
          q="$(jq -c '.removed.push_unknown = true' <<<"$q")"
        fi
      else
        q="$(jq -c '.removed.push_unknown = true' <<<"$q")"
        dw_warn "PR のブランチへの push を読めないので、マージキューから外れたままとみなします: $(tail -n 1 "$err")"
      fi
      rm -f "$err"
    fi
  fi
  jq -c 'del(.since, .since_is_added, .stale_added)' <<<"$q"
}

# 古いブランチ保護（ルールセットでない）が求める必須のチェックの名前の一覧（JSON の配列）を出力する。
# rules/branches には出ないので、ブランチの情報（branches/<ブランチ> の protection）から読む。
# 読めなければ（保護が無い・権限が無いなど）[] を出力する。
# 使い方: dw_classic_required_checks <owner/repo（{owner}/{repo} でもよい）> <ブランチ>
dw_classic_required_checks() {
  local info
  info="$(gh api "repos/$1/branches/$(jq -rn --arg b "$2" '$b | @uri')" 2>/dev/null)" \
    && jq -c '[.protection.required_status_checks.contexts[]?]' <<<"$info" 2>/dev/null \
    || echo '[]'
}

# ブランチに効いている必須のチェックの名前の一覧（JSON の配列）を出力する。ルールセットのルール（rules/branches の
# 出力。--paginate のページを並べたものでもよい）と、古いブランチ保護の名前（dw_classic_required_checks）を合わせる。
# ルールセットの ID を渡すと、そのルールセットのルールは数えない（置き換える前の一覧を除くとき）。
# 使い方: dw_required_checks <ルールの JSON> <古いブランチ保護の名前の JSON> [<除くルールセットの ID>]
dw_required_checks() {
  jq -sc --argjson classic "$2" --arg id "${3:-}" "$DW_JQ_CHECK_RULES"'
    add // [] | check_rules
    | [(.[] | select($id == "" or ((.ruleset_id // "" | tostring) != $id))
        | .parameters.required_status_checks[].context), $classic[]] | unique' <<<"$1"
}

# Story Point に使える値（フィボナッチ数）。設定では変えられない。
# 21 と 34 は受け付けるが、見積もりの精度が低いので分割を勧める。34 より大きい作業は分割する。source した側で使う
# shellcheck disable=SC2034
DW_STORY_POINTS='[1, 2, 3, 5, 8, 13, 21, 34]'
# shellcheck disable=SC2034
DW_STORY_POINT_SPLIT=21

# 親子の Issue（サブ Issue）の目安の深さ。上限（設定の sub_issues.max_depth。既定 3）までは作れるが、
# これより深い Issue を作るときは警告する（一番上の Issue が 1 層目）。source した側で使う
# shellcheck disable=SC2034
DW_SUB_ISSUE_DEPTH_GUIDE=2

# 設定（config.sh の出力）から sub_issues.max_depth を読み、1・2・3 のどれかなら出力する。それ以外なら終了コード 2 で止まる。
# "2" のような文字列は認めないよう、JSON の形のまま比べる。
# 使い方: max_depth="$(dw_max_depth "$config")"
dw_max_depth() {
  local v
  v="$(jq -c '.sub_issues.max_depth' <<<"$1")" || return 1
  case "$v" in
    1 | 2 | 3) printf '%s\n' "$v" ;;
    *) dw_die "sub_issues.max_depth は 1・2・3 のどれかにしてください: $v" 2 ;;
  esac
}

# REST の Issue（repos/<所有者/名前>/issues/<番号>）を読んで出力する。無いか PR の番号なら null。
# 使い方: json="$(dw_rest_issue <OWNER/NAME> <番号>)"
dw_rest_issue() {
  local out
  out="$(dw_gh_find gh api "repos/$1/issues/$2")" || return 1
  jq -c 'if . == null or .pull_request then null else . end' <<<"$out"
}

# 親子の深さの規則をまとめた関数。<Issue の JSON> の下に <下の層の数> の層の Issue を紐付けたとき、一番深い Issue が何層目になるか
# （一番上の Issue が 1 層目。<Issue> は 1 + 上の親の数 層目で、一番深い Issue はその <下の層の数> 層下）と、
# 上限 <max_depth> を超えるかを調べ、{depth（一番深い Issue の層。上限を超えると分かってたどるのを止めたときは null）,
# exceeds（上限を超えるか）, first（一番近い親の {number, repo}。親が無いか、たどらなかったときは null）} を出力する。
# 上へ issues/{番号}/parent をたどり、上限を超えると分かった時点で止める（API の呼び出しは max_depth - <下の層の数> 回まで）。
# <最低の回数> を渡すと、上限に関わらず、少なくともその回数はたどる（親があるかを知りたいとき 1。既定 0）。
# 親の親は別のリポジトリにあることもあるので、たどる API のパスは応答の url から作り、別のリポジトリの親もたどる。
# first の repo は repository_url から作り、無ければ url から作る。
# 使い方: dw_sub_issue_depth <Issue の JSON> <下の層の数> <max_depth> [<最低の回数>]
dw_sub_issue_depth() {
  local node="$1" levels="$2" max="$3" limit count=0 first=null out path
  limit=$((max - levels))
  [ "$limit" -ge "${4:-0}" ] || limit="${4:-0}"
  # 関数は if の中から呼ばれると set -e が効かないので、失敗は明示して返す
  path="$(jq -r '.url | sub("^.*?/repos/"; "repos/")' <<<"$node")" || return 1
  while [ "$count" -lt "$limit" ]; do
    node="$(dw_gh_find gh api "$path/parent")" || return 1
    [ "$node" != null ] || break
    count=$((count + 1))
    # 1つの応答から、次にたどるパス（1行目）と、親の {number, repo}（2行目）を、jq を1回だけ起動して作る
    out="$(jq -r '(.url | sub("^.*?/repos/"; "repos/")),
      ({number, repo: (if .repository_url then .repository_url | sub("^.*?/repos/"; "")
        else .url | sub("^.*?/repos/"; "") | sub("/issues/[0-9]+$"; "") end)} | tojson)' <<<"$node")" || return 1
    path="${out%%
*}"
    [ "$first" != null ] || first="${out#*
}"
  done
  # 上限の回数までたどった（その上にも親があるかもしれない）なら、一番深い Issue は 1 + count + levels 層より深く、
  # 上限を超える（count が max - levels に達したか、<最低の回数> で levels だけで上限に届いているため）
  jq -nc --argjson c "$count" --argjson l "$levels" --argjson m "$max" --argjson lim "$limit" --argjson f "$first" '
    if $c >= $lim then {depth: null, exceeds: true, first: $f}
    else (1 + $c + $l) as $d | {depth: $d, exceeds: ($d > $m), first: $f} end'
}

# 破壊的変更を表すラベル。type ラベルとは別に付け、PR のタイトルの type の後に ! を付ける（設計書 §5）。source した側で使う
# shellcheck disable=SC2034
DW_BREAKING_LABEL=breaking

# Issue のラベルの名前の配列から、type ラベル（設定の labels.types のどれか）を、設定の書き方で出す jq の関数 issue_types。
# GitHub と同じく、ラベルの名前は大文字と小文字を区別せずに照合する（Fix のラベルも fix として読み、Fix と fix は1つと数える）。
# 順はラベルの順。type ラベルを読むスクリプト（pr-create.sh・branch-name.sh・review-perspectives.sh・auto-check.sh）で、照合をそろえる。
# source した側で使う
# 使い方: jq --argjson t "$(jq -c .labels.types <<<"$config")" "$DW_JQ_ISSUE_TYPES"' [.labels[].name] | issue_types($t)'
# shellcheck disable=SC2016,SC2034 # jq のプログラムなので、$ は展開しない
DW_JQ_ISSUE_TYPES='
  def issue_types($t):
    reduce (.[] | ascii_downcase as $n | $t[] | select(ascii_downcase == $n)) as $x ([]; if index([$x]) then . else . + [$x] end);
'

# Markdown の本文（文字列）を読む jq の関数 md_scan を定義する。上から順に、チェックリストの項目（items。
# {line（0 からの行番号）, checked, text}）と、見出しの行番号（headings）と、GitHub に表示される行（lines。{line, text}。
# コードブロックの囲みと中の行、複数行の HTML のコメントの行を除いた、項目・見出しを含む行。行末の \r は外す）を出す。
# GitHub と同じく、コードブロック（3つ以上の ` か ~ で囲む）の中の行は、項目とも見出しともみなさない。
# 閉じるのは、開いたときと同じ文字が同じ数以上並び、後ろが空白だけの行（中の短い囲みや ```js では閉じない）。
# ` の囲みの後ろに ` がある行（```x``` のようなインラインのコード）は囲みとみなさない。
# リストの中のコードブロックも拾うため、囲みの字下げは問わない。
# 複数行の HTML のコメント（行頭の <!-- から --> まで。囲みと同じく字下げは問わない）の中の行も、GitHub に表示されないので項目とみなさない。
# GitHub と同じく、行の途中の <!--（インラインのコードや項目の補足）はコメントの始まりとみなさない
# （gh api markdown で確かめた。段落や項目の中の <!-- は、閉じる --> が後の行にあっても、文字としてそのまま表示され、間の行も表示される）。
# コメントを閉じる行の --> の後ろの文字は、GitHub に表示されるので、lines の行にする。ただし HTML ブロックの続きとして
# そのまま表示される（Markdown としては読まれない）ので、項目にも見出しにもしない。その後ろに閉じない <!-- があれば、GitHub は
# 文書の最後までを隠すので、以降の行は読まない。
# --> の後ろの文字は、ほかの本文の行と同じく、前後の空白を外さずに残す（lines の行は \r だけを外す）。
# 項目の文は、前後の空白を外す。source した側で使う
# 使い方: jq "$DW_JQ_MD_SCAN"' .body | md_scan | .items'
# shellcheck disable=SC2016,SC2034 # jq のプログラムなので、$ は展開しない
DW_JQ_MD_SCAN='
  def md_scan:
    def item: "^\\s*(?:[-*+]|[0-9]+[.)])\\s+\\[(?<c>[ xX])\\](?:\\s+(?<t>.*))?$";
    reduce (split("\n") | to_entries[]) as $e ({fence: null, comment: false, items: [], headings: [], lines: []};
      ($e.value | sub("\r$"; "")) as $l | .fence as $f
      | if .comment == "eof" then .
        elif .comment then
          (if $l | test("-->") then
            ($l | sub("^.*?-->"; "")) as $tail
            | .comment = ($tail | test("<!--(?!.*-->)") | if . then "eof" else false end)
            | if $tail != "" then .lines += [{line: $e.key, text: $tail}] else . end
          else . end)
        elif $f != null then
          (if $l | test("^\\s*" + $f + "+\\s*$") then .fence = null else . end)
        elif $l | test("^\\s*(`{3,}[^`]*|~{3,}.*)$") then .fence = ($l | capture("^\\s*(?<f>`{3,}|~{3,})").f)
        elif $l | test("^\\s*<!--(?!.*-->)") then .comment = true
        else
          .lines += [{line: $e.key, text: $l}]
          | if $l | test(item) then
              ($l | capture(item)) as $m
              | .items += [{line: $e.key, checked: ($m.c != " "), text: ($m.t // "" | sub("\\s+$"; ""))}]
            elif $l | test("^ {0,3}#{1,6}(\\s|$)") then .headings += [$e.key]
            else . end
        end)
    | {items, headings, lines};
'

# Issue の本文の節（「## <見出し>」の行から、次の「## 」の行の前まで）を読む jq の関数。依存を読む next-tasks.sh と、
# 依存を書く issue-depend.sh とで、節の見つけ方をそろえる（食い違うと、書いた依存が読まれない）。
# 見出しは「## 」（## と空白）で始まる行だけで、見出しの文字は前後の空白と行末の \r を無視して比べる。同じ見出しの節が
# 複数あれば、全部を読む。コードブロックの中の「## 」の行も見出しとみなす（md_scan のように除くと、閉じていないコードブロックの後の
# 節が見えなくなり、issue-depend.sh が実行のたびに節を足してしまう。読むのも書くのもこの決まりなので、食い違わない）。
# HTML のコメントの中の「## 」の行も同じく見出しとみなし、その中の #N も読む（既知の制限）。入力は .body を持つ Issue。source した側で使う
#   body_lines：本文を行の配列にする（\r は残す）
#   section_ranges_of($l; $h)：行の配列 $l の、見出しが $h の節ごとに、{head（見出しの行番号）, end（節の次の行番号）}。
#     中身は head+1 から end-1 まで。本文を何度も分けないよう、分けた行の配列を受け取る
#   section($h)：見出しが $h の節の中身の行（\r は外す）
#   deps：「依存」の節にある #N の番号（重複は除く）
# 使い方: jq "$DW_JQ_ISSUE_SECTIONS"' deps'
# shellcheck disable=SC2016,SC2034 # jq のプログラムなので、$ は展開しない
DW_JQ_ISSUE_SECTIONS='
  def body_lines: (.body // "") | split("\n");
  def section_ranges_of($l; $h):
    [range(0; $l | length) | select($l[.] | test("^## "))] as $hs
    | [range(0; $hs | length) as $i
        | select($l[$hs[$i]] | gsub("\r"; "") | test("^## [ \t]*" + $h + "[ \t]*$"))
        | {head: $hs[$i], end: ($hs[$i + 1] // ($l | length))}];
  def section($h): body_lines as $l | [section_ranges_of($l; $h)[] as $r | $l[$r.head + 1:$r.end][] | gsub("\r"; "")];
  def deps: [section("依存")[] | scan("#([0-9]+)") | .[0] | tonumber] | unique;
'

# 本文を分けた行の配列（split("\n")。行末の \r は残す）に行を足す jq の関数。改行は本文に合わせる（どれかの行が \r で終われば
# \r\n）。行ごとに合わせると、CRLF の本文の改行の無い最後の行の後に足したとき、LF が混ざる。pr-create.sh と issue-depend.sh で使う
#   crlf：本文が \r\n なら "\r"、でなければ ""
#   insert_after($k; $new)：$k 番目の行の後に、$new（行末の無い文字列の配列）を足す。$k が CRLF の本文の改行の無い最後の行なら、
#     その行に改行を付け、足した最後の行を改行の無い行にする（本文の最後に改行を足さない）
# 使い方: jq "$DW_JQ_LINES"' .body | split("\n") | insert_after(0; ["x"]) | join("\n")'
# shellcheck disable=SC2016,SC2034 # jq のプログラムなので、$ は展開しない
DW_JQ_LINES='
  def crlf: if any(.[]; endswith("\r")) then "\r" else "" end;
  def insert_after($k; $new): crlf as $cr
    | ($k == length - 1 and $cr != "" and (.[$k] | endswith("\r") | not)) as $last
    | (if $last then .[$k] += $cr else . end)
    | .[:$k + 1] + ($new | map(. + $cr) | if $last and length > 0 then .[-1] |= rtrimstr("\r") else . end) + .[$k + 1:];
'

# 同じリポジトリの Issue を REST で読み、JSON を出力する。REST の issues は PR も返すので、PR の番号と無い番号（404・410）は、
# 何も出力しない。認証・通信などほかの失敗は、dw_gh_find が理由を伝えて止まる
# 使い方: json="$(dw_issue_json <OWNER/NAME> <番号>)"; [ -n "$json" ] || <無いときの処理>
dw_issue_json() {
  dw_gh_find gh api "repos/$1/issues/$2" | jq -c 'if . == null or .pull_request then empty else . end'
}

# dw_issue_json の Issue の「数値の id 状態（open か closed）」を出力する（無ければ何も出力しない）。依存関係（blocked by）の
# 登録には、node id ではなく数値の id を使う。issue-create.sh と issue-depend.sh で使う
# 使い方: ref="$(dw_issue_ref <OWNER/NAME> <番号>)"; [ -n "$ref" ] || <無いときの処理>
dw_issue_ref() {
  local json
  # $(...) の中では set -e が効かないので、読めなかったとき（dw_gh_find が止まったとき）の終了コードを、自分で返す
  json="$(dw_issue_json "$1" "$2")" || return
  [ -z "$json" ] || jq -r '"\(.id) \(.state)"' <<<"$json"
}

# Issue <番号> の依存関係（blocked by）に、数値の id <依存する Issue の id> を登録する。失敗したら 0 以外を返す（gh の理由は標準エラー）
# 使い方: dw_add_blocked_by <OWNER/NAME> <番号> <依存する Issue の id> || <失敗したときの処理>
dw_add_blocked_by() {
  gh api -X POST "repos/$1/issues/$2/dependencies/blocked_by" -F issue_id="$3" >/dev/null
}

# awk のプログラムの先頭に足し、行末の CR と、ファイルの先頭の BOM（Windows のエディタが付ける）を外す。
# 改行が \r\n のファイルや BOM 付きのファイルでも、front matter の区切りの --- などを見分けるため。
# 読んだ行を書き戻す処理では使わない（外した CR と BOM が書き戻されなくなるため）。source した側で使う
# 使い方: awk "$DW_AWK_STRIP_CR_BOM"' <プログラム>' <ファイル>...
# shellcheck disable=SC2034
DW_AWK_STRIP_CR_BOM='{ sub(/\r$/, "") } FNR == 1 { sub(/^\357\273\277/, "") }'

# YAML の1行を読む awk の関数 strip（コメントを消す）・unquote（値を囲む引用符を外し、エスケープを元の文字に戻す）・
# trim（前後の空白を外す）。awk のプログラムの先頭に足して使う。ワークフローを読む merge-group-check.sh と、ADR の
# front matter を読む adr-list.sh で、値の読み方を揃えるため。source した側で使う
# 使い方: awk "$DW_AWK_YAML"' { v = unquote(strip($0)) }' <ファイル>
# shellcheck disable=SC2016,SC2034 # awk のプログラムなので、$ は展開しない
DW_AWK_YAML='
    # コメント（行頭か空白の後の #）を消す。引用符の中の #（name: "Build #1" など）は残す。
    # 引用符は、値の始まり（空白・[・, の後）に来たものだけを数える（Bob\047s のような語の中のものは除く）。
    # 引用符の中のエスケープ（単一引用符の中の \047\047、二重引用符の中の \ の次の文字）は、引用符の終わりとみなさない
    function strip(s,   i, c, q, prev) {
      sub(/\r$/, "", s)
      q = ""; prev = " "
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "") {
          if (c == "#" && (prev == " " || prev == "\t")) return substr(s, 1, i - 1)
          if ((c == "\"" || c == "\047") && (prev == " " || prev == "\t" || prev == "[" || prev == ",")) q = c
        } else if (q == "\"" && c == "\\") {
          i++
        } else if (c == q) {
          if (q == "\047" && substr(s, i + 1, 1) == "\047") i++
          else q = ""
        }
        prev = c
      }
      return s
    }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/) {
        s = substr(s, 2, length(s) - 2)
        # \" と \\ を元の文字に戻す。\001 は \\ をいったん置いておく印
        gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\001/, "\\", s)
      } else if (s ~ /^\047.*\047$/) {
        s = substr(s, 2, length(s) - 2)
        gsub(/\047\047/, "\047", s)
      }
      return s
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
'

# 設定の adr.dir（ADR の置き場所）を読み、末尾の / を外して出力する。リポジトリのルートからの相対パスでなければ
# （空・/ で始まる・.. を含む）終了コード 2 で止まる。ADR を作る側と探す側で、置き場所の扱いを食い違わせないため。
# $(...) の中で呼ぶと、set -e のスクリプトはそのまま止まる。
# 使い方: dir="$(dw_adr_dir <config.sh の出力の JSON>)"
dw_adr_dir() {
  local d
  d="$(jq -r '[.adr.dir?][0] // ""' <<<"$1")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
  d="${d%/}"
  case "$d" in
    "" | /* | .. | ../* | */.. | */../*) dw_die "adr.dir はリポジトリのルートからの相対パスにしてください（/ で始めない・.. を使わない）: ${d}" 2 ;;
  esac
  printf '%s\n' "$d"
}

# 値が null か、一覧（JSON の文字列の配列）のどれかの文字列かを確かめる。どちらも JSON で渡す（例: '["a", "b"]' "a"）。
# 当たれば 0、当たらなければ 1 を返す。一覧が1つの配列でない（文字列で部分一致させない・複数の値を続けない）とき、
# 値が読めない JSON のときも 1。一覧は common.sh の定数だけを渡す（定数の正しさは tests/common.bats で確かめる）
# 使い方: dw_json_enum_ok <一覧の JSON> <値の JSON>
dw_json_enum_ok() {
  jq -s -e --argjson v "$2" 'length == 1 and (.[0] | type == "array" and ($v == null or (($v | type) == "string" and index($v) != null)))' <<<"$1" >/dev/null 2>&1 || return 1
}

# 一覧（JSON の文字列の配列）を「a・b・c」の形で出力する（エラーのメッセージ用）
# 使い方: dw_json_enum_names <一覧の JSON>
dw_json_enum_names() {
  jq -r 'join("・")' <<<"$1"
}

# レビューのサブエージェントに指定できるモデル（設定の review.model。Agent ツールの model が受け付ける別名）。
# 設定が null ならサブエージェントはセッションと同じモデルで動く（設計書 §7）。source した側で使う
# shellcheck disable=SC2034
DW_REVIEW_MODELS='["opus", "sonnet", "haiku", "fable"]'

# review スキルが組み込みの /code-review に渡せる effort の段階（設定の review.code_review_effort）。
# 設定が null なら段階を渡さず、/code-review が最後に打った段階かセッションの effort を使う（設計書 §7）。source した側で使う
# shellcheck disable=SC2034
DW_CODE_REVIEW_EFFORTS='["low", "medium", "high", "xhigh", "max"]'

# リポジトリの個人の上書き（config.local.json）のパスを出力する。今のワークツリーに無ければ、メインのワークツリーのもの。
# config.sh が読む場所と、setup-models.sh が書く場所を、ここで1つに決める
# 使い方: dw_local_config_file <リポジトリのルート>
dw_local_config_file() {
  local d f main
  d="$(dw_team_dir "$1")"
  # ホームのリポジトリでは、ユーザーの層の config.local.json を個人の上書きにしない（何も出力しない）
  [ -n "$d" ] || return 0
  f="$d/config.local.json"
  if [ ! -f "$f" ]; then
    # ワークツリーで作業中なら、メインのワークツリーに置いた個人の設定を使う
    main="$(dw_main_root "$1" || true)"
    if [ -n "$main" ]; then
      d="$(dw_team_dir "$main")"
      [ -z "$d" ] || f="$d/config.local.json"
    fi
  fi
  printf '%s\n' "$f"
}

# 保留の列（status.hold）が、ほかの役割の列と同じ名前なら止まる。同じ列だと、保留の Issue が Todo や着手中にも数えられ、
# 保留にした意味が無くなる
# 使い方: dw_check_hold_column <合わせた設定の JSON>
dw_check_hold_column() {
  local same
  same="$(jq -r '.status as $s | ($s.hold // "") as $h | select($h != "")
    | [$s | to_entries[] | select(.key != "hold" and .value == $h) | .key] | first // empty' <<<"$1")"
  [ -z "$same" ] \
    || dw_die "保留の列（status.hold）は、ほかの役割（status.${same}）と別の列名にしてください: $(jq -r .status.hold <<<"$1")" 2
}

# 設定ファイルに jq の式を当てて書き直す。ファイルが無ければ {} から作り、JSON のオブジェクトとして読めなければ止まる。
# 一時ファイルに書いてから置き換え、jq が失敗したら一時ファイルを消して止まる（書きかけのファイルを残さない）
# 使い方: dw_write_config <設定ファイル> <jq の引数（--arg などと式）...>
dw_write_config() {
  local f="$1" body='{}'
  shift
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    dw_check_json "$f"
    body="$(cat "$f")"
  fi
  if ! jq "$@" <<<"$body" >"$f.tmp"; then
    rm -f "$f.tmp"
    dw_die "${f} を書き直せませんでした" 2
  fi
  mv "$f.tmp" "$f"
}

# 個人の上書き（dw_local_config_file のファイル）がコミットされてしまわないかを、次のどれかで出力する。
#   ignored      git に無視されていて、コミットもされていない
#   not_ignored  git に無視されていない（.gitignore に足す必要がある）
#   tracked      既にコミットしてある（.gitignore に書いても追跡は外れないので、git rm --cached で外す必要がある）
# 「.gitignore に当たるか」だけでは、コミット済みのファイルを見分けられないので、追跡しているかを先に確かめる
# 使い方: dw_local_config_state <リポジトリのルート>
dw_local_config_state() {
  local f wt
  f="$(dw_local_config_file "$1")"
  # 個人の上書きが無い（ホームのリポジトリ）ので、コミットされる心配も無い
  if [ -z "$f" ]; then echo ignored; return 0; fi
  wt="${f%/.claude/dev-workflow/config.local.json}"
  if git -C "$wt" ls-files --error-unmatch -- .claude/dev-workflow/config.local.json >/dev/null 2>&1; then
    echo tracked
  elif git -C "$wt" check-ignore -q .claude/dev-workflow/config.local.json 2>/dev/null; then
    echo ignored
  else
    echo not_ignored
  fi
}

# dw_local_config_state の not_ignored・tracked のときに、利用者にする案内を出力する（ignored なら何も出さない）
# 使い方: dw_local_config_hint <状態>
dw_local_config_hint() {
  case "$1" in
    not_ignored) echo "個人の設定（.claude/dev-workflow/config.local.json）が git に無視されていません。.gitignore に足してください" ;;
    tracked) echo "個人の設定（.claude/dev-workflow/config.local.json）がコミットされています。git rm --cached .claude/dev-workflow/config.local.json で追跡を外し、.gitignore に足してください" ;;
  esac
}

# 設定ファイルが review.model を決めていれば（null も「使わないと決めた」として）、その値の JSON を出力する。
# 決めていなければ（ファイルもキーも無い）何も出さずに 1 を返す。JSON のオブジェクトとして読めなければ止まる
# 使い方: dw_review_model_of <設定ファイル>
dw_review_model_of() {
  [ -f "$1" ] || return 1
  dw_check_json "$1"
  jq -e '(.review | type) == "object" and (.review | has("model"))' "$1" >/dev/null || return 1
  jq -c .review.model "$1"
}

# review.model を決めている層（user・team・local）を、優先度の低い順に1行ずつ「<層>\t<ファイル>\t<値の JSON>」で出力する。
# ユーザーの層（~/.claude/dev-workflow/config.json）は、config.sh と同じく、導入したリポジトリ（dw_is_set_up）の中でだけ読む（設計書 §1）。
# どれかの層のファイルが JSON のオブジェクトとして読めなければ、書く層でなくても止まる。
# 使い方: dw_review_model_layers <リポジトリのルート>
dw_review_model_layers() {
  local pairs pair name f v user_dir team_dir
  pairs=()
  user_dir="$(dw_user_dir_for "$1")"
  [ -z "$user_dir" ] || pairs+=("user:$user_dir/config.json")
  team_dir="$(dw_team_dir "$1")"
  # ホームのリポジトリには、チームの層も個人の層も無い（dw_team_dir）
  [ -z "$team_dir" ] || pairs+=("team:$team_dir/config.json" "local:$(dw_local_config_file "$1")")
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    name="${pair%%:*}" f="${pair#*:}"
    [ -f "$f" ] || continue
    # 壊れたファイルで止めるため、$(...) の外で確かめる（中で止めても、そのサブシェルが終わるだけになる）
    dw_check_json "$f"
    v="$(dw_review_model_of "$f")" || continue
    printf '%s\t%s\t%s\n' "$name" "$f" "$v"
  done
}

# GitHub がテンプレートを探す場所。source した側で使う。
# 大文字小文字は区別せず、拡張子は .md・.txt・なしを認める。書き方は dw_find_nocase を参照
# PR テンプレート（1ファイル）と、複数の PR テンプレートを置くディレクトリ（?template= で選ぶ形式）
# shellcheck disable=SC2034
DW_PR_TEMPLATE_FILES=".github/pull_request_template docs/pull_request_template pull_request_template"
# shellcheck disable=SC2034
DW_PR_TEMPLATE_DIRS=".github/pull_request_template/ docs/pull_request_template/ pull_request_template/"
# Issue テンプレートのディレクトリと、古い形式の1ファイル
# shellcheck disable=SC2034
DW_ISSUE_TEMPLATES=".github/issue_template/ .github/issue_template docs/issue_template issue_template"

# <ルート> からの相対パスの候補を、大文字小文字を区別せずに順に探し、見つかった実際のパスを出力する
# （GitHub のテンプレートの探し方に合わせる）。候補の書き方:
#   末尾が /         そのディレクトリだけに当てはまる（例: .github/issue_template/）
#   拡張子が無い     同じ名前で、拡張子が .md・.txt・なしのファイルに当てはまる（例: docs/pull_request_template →
#                    docs/PULL_REQUEST_TEMPLATE.md、docs/pull_request_template.txt）
#   拡張子がある     その名前のファイルだけに当てはまる
# 候補を空白区切りの一覧から分割して渡せるよう、* などのワイルドカードは使わない。
# 使い方: dw_find_nocase <ルート> <候補>...
dw_find_nocase() {
  local root="$1" f dir base want entry name lower
  shift
  for f in "$@"; do
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    want="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    [ -d "$root/$dir" ] || continue
    for entry in "$root/$dir"/* "$root/$dir"/.[!.]*; do
      [ -e "$entry" ] || continue
      # ディレクトリの候補はディレクトリだけ、ファイルの候補はファイルだけに当てはめる
      case "$f" in
        */) [ -d "$entry" ] || continue ;;
        *) [ ! -d "$entry" ] || continue ;;
      esac
      name="$(basename "$entry")"
      lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      # 拡張子の有無は、ディレクトリ部分（.github など）ではなく候補の名前で見る
      case "$f" in
        */) [ "$lower" = "$want" ] || continue ;;
        *)
          case "$base" in
            *.*) [ "$lower" = "$want" ] || continue ;;
            # GitHub が例に挙げる .md・.txt と、拡張子なしだけを認める（.md~ などのバックアップは除く）
            *) [ "$lower" = "$want" ] || [ "$lower" = "$want.md" ] || [ "$lower" = "$want.txt" ] || continue ;;
          esac
          ;;
      esac
      if [ "$dir" = . ]; then printf '%s\n' "$name"; else printf '%s\n' "$dir/$name"; fi
      return 0
    done
  done
  return 1
}

# --- GitHub Project（v2） -------------------------------------------------------
# gh project と REST で操作する。REST の Project の API は所有者の種類（users / orgs）でパスが分かれる。

# 所有者の種類（User / Organization）から、REST と URL に使う所有者のパス（users/<所有者> か orgs/<所有者>）を出力する。
# 使い方: dw_owner_path <所有者の種類> <所有者>
dw_owner_path() {
  case "$1" in
    Organization) printf 'orgs/%s\n' "$2" ;;
    *) printf 'users/%s\n' "$2" ;;
  esac
}

# Project の id（node id）・番号・URL・REST のパス（restPath。users/<所有者>/projectsV2/<番号> など）と
# 項目（Status の選択肢を含む）を出力する。無ければ案内して止まる。
# 項目は {id（node id）, databaseId（REST の数値の id）, name, dataType（REST の data_type。number・single_select など）,
# options: [{id, name}]} の配列。
# gh project field-list は数値の項目と文字列の項目を区別しないので、項目は REST で読む。
# 使い方: dw_project_fields <所有者> <番号>
dw_project_fields() {
  local project path fields
  project="$(dw_gh_find gh project view "$2" --owner "$1" --format json)" || return 1
  # 無い Project は gh がエラー（Could not resolve to a ProjectV2）を返すので、dw_gh_find で null に揃えてから案内する
  [ "$project" != null ] || dw_die "Project が見つかりません: ${1}/${2}（setup-project.sh で設定してください）"
  path="$(dw_owner_path "$(jq -r .owner.type <<<"$project")" "$1")"
  fields="$(gh api --paginate "$path/projectsV2/$2/fields?per_page=100" | jq -sc 'add // []')" || return 1
  jq -c --argjson f "$fields" --arg p "$path/projectsV2/$2" '{id, number, url, restPath: $p,
    fields: ($f | map({id: .node_id, databaseId: .id, name, dataType: .data_type,
      options: ((.options // []) | map({id, name: (.name.raw // .name)}))}))}' <<<"$project"
}

# Issue などを Project に追加し、項目の id（node id）を出力する。既に入っていれば既存の項目が返る。
# Project の自動追加と同時に走ると、片方が「Content already exists」で失敗する。再試行すれば既存の項目が返るので、
# その失敗のときだけ、待って最大3回まで試す（待つ秒数は DW_RETRY_SLEEP、既定 1）。
# それでも「Content already exists」で失敗したときは、項目が既にあるので、項目の一覧（REST）から探して、その id を使う。
# 見つからないとき、ほかのエラーのときは、エラーを出して止まる。
# 使い方: dw_project_add_item <所有者> <番号> <Issue の URL>
dw_project_add_item() {
  local out errfile tries=0 existing
  errfile="$(mktemp)"
  while :; do
    if out="$(gh project item-add "$2" --owner "$1" --url "$3" --format json 2>"$errfile")"; then
      rm -f "$errfile"
      jq -er '.id' <<<"$out"
      return
    fi
    tries=$((tries + 1))
    if grep -q 'Content already exists' "$errfile"; then
      if [ "$tries" -lt 3 ]; then
        sleep "${DW_RETRY_SLEEP:-1}"
        continue
      fi
      if existing="$(dw_project_find_item "$1" "$2" "$3")" && [ -n "$existing" ]; then
        rm -f "$errfile"
        printf '%s\n' "$existing"
        return
      fi
    fi
    cat "$errfile" >&2
    rm -f "$errfile"
    return 1
  done
}

# Project の項目のうち、リポジトリの Issue <番号> の項目（REST の項目。node_id が gh project で使う id）を出力する。無ければ null。
# Issue から項目を引く REST は無いので、項目の一覧をリポジトリで絞り、ページを辿って、リポジトリと番号で探す
# （番号で絞る検索は無く、文字列での検索は本文などにも当たるため）。値を読む項目の databaseId を渡すと、その値も fields に入る。
# 使い方: dw_project_item <Project の REST のパス（restPath）> <所有者/名前> <Issue の番号> [<値を読む項目の databaseId>]
dw_project_item() {
  local args
  args=(-f q="repo:$2 is:issue" -f per_page=100)
  [ -z "${4:-}" ] || args+=(-f fields="$4")
  gh api --paginate "$1/items" -X GET "${args[@]}" \
    | jq -sc --arg r "$2" --argjson n "$3" "$DW_JQ_SAME_REPO"'
        [add // [] | .[] | select(.content.number == $n and same_repo((.content.repository_url // "") | sub("^.*?/repos/"; ""); $r))][0]'
}

# Project の項目から、<Issue の URL> の項目の id（node id）を探して出力する。無ければ何も出さずに失敗する。
# 使い方: dw_project_find_item <所有者> <番号> <Issue の URL>
dw_project_find_item() {
  local project path repo n id
  # URL は https://<ホスト>/<所有者>/<名前>/issues/<番号>
  repo="$(sed -nE 's#^https://[^/]+/([^/]+/[^/]+)/issues/[0-9]+$#\1#p' <<<"$3")"
  n="${3##*/}"
  [ -n "$repo" ] || return 1
  project="$(gh project view "$2" --owner "$1" --format json 2>/dev/null)" || return 1
  path="$(dw_owner_path "$(jq -r .owner.type <<<"$project")" "$1")/projectsV2/$2"
  id="$(dw_project_item "$path" "$repo" "$n" 2>/dev/null | jq -r '.node_id // empty')" || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# 項目の値を設定する。値は gh project item-edit のオプションで渡す（--single-select-option-id <id> や --number <数>。
# 空欄にするなら --clear だけ）。
# 使い方: dw_project_set_field <Project の id> <項目の id> <フィールドの id> <オプション> [値]
dw_project_set_field() {
  gh project item-edit --project-id "$1" --id "$2" --field-id "$3" "${@:4}" >/dev/null
}
