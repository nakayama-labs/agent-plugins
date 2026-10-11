# shellcheck shell=bash
# branch-name・status-set・task-start・cleanup・pr-create・issue-cancel・issue-branches のテストで使う偽の gh。load fake_gh で読み込み、setup_fake_gh を呼ぶ。
#
# - gh repo view                    me/demo を返す
# - gh issue view N --json ...      $FIX/issue-N.json を返す（-q があれば適用する）。引数を「issue-view N ...」として $CALLS に記録する
#                                    --json body だけを読むときは、$FIX/issue-N-body.json があればそれを返す
#                                    （確かめた後、読み直すまでの間に本文が変わったことを試す）
# - gh issue edit N ...             引数を「edit N ...」として $CALLS に記録する。--body-file - なら標準入力を $TMP/issue-edit-body に写す
# - gh issue comment N --body-file -  「issue-comment N」を $CALLS に記録し、標準入力を $TMP/issue-comment-body に写す
# - gh issue close N ...            引数を「issue-close N ...」として $CALLS に記録する
# - gh pr list ...                  $FIX/pr-list.json（無ければ []。$FIX/pr-list.raw があれば、その中身をそのまま）を返し、引数を「pr-list ...」として $CALLS に記録する
# - gh pr view <URL か番号> ...     $FIX/pr-<番号>.json を返す（番号は URL の最後の部分）。「pr-view <番号>」を $CALLS に記録する
# - gh pr create ...                引数を「pr-create ...」として $CALLS に記録し、--body-file の中身を $TMP/pr-body に写して、
#                                   https://github.com/me/demo/pull/42 を返す
# - gh pr comment N --body-file -   「pr-comment N」を $CALLS に記録し、標準入力を $TMP/pr-comment-body に写す
# - gh pr close N                   「pr-close N」を $CALLS に記録する
# - gh pr ready N                   「pr-ready N」を $CALLS に記録する
# - gh --version                    gh version $FAKE_GH_VERSION（既定: 2.96.0）を返す
# - gh api user                     login: me を返す
# - gh api --paginate repos/.../issues/N/sub_issues?...
#                                   「api-sub-issues <パス（? より前）>」を $CALLS に記録し、$FIX/sub-issues-N.json（無ければ []）を返す
# - gh api --paginate repos/.../rules/branches/<ブランチ>?...
#                                   「api-rules <パス>」を $CALLS に記録し、ブランチに効いているルールとして $FIX/rules/<ブランチ>.json、
#                                   無ければ $FIX/rules.json、それも無ければ [] を返す。<ブランチ> は、パスの URL エンコードを戻した
#                                   ブランチ名そのままで、/ はディレクトリの区切りになる（release/v1 なら $FIX/rules/release/v1.json）
# - gh api graphql（MergeQueueForBranch）  「api-merge-queue <ブランチ>」を $CALLS に記録し、$FIX/queue/<ブランチ>（/ はディレクトリの区切り）が
#                                   あればそのブランチにマージキューがある（古いブランチ保護のキューも含む）として返す。無ければ無い
# - gh api repos/.../issues/N/parent  「api-parent N」を $CALLS に記録し、$FIX/parent-N.json を返す（無ければ HTTP 404 で失敗する）
# - gh api repos/.../activity?...   「api-activity <パス>」を $CALLS に記録し、$FIX/activity.json（無ければ []）を返す
# - gh api repos/...                「api-get <パス>」を $CALLS に記録する。$FIX/remote-ref があれば {} を、無ければ HTTP 404 で失敗する
# - gh api -X DELETE <パス>          「api-delete <パス>」を $CALLS に記録する
# - gh api graphql                  操作名ごとに $FIX/<操作名>.json（変数 number があり $FIX/<操作名>-issue-<number>.json があればそれ）を返し、「<操作名> <変数>」を $CALLS に記録する
# - gh project ・Project の REST     fake_gh_project.bash が受け持つ（ProjectView・ProjectFields・AddItem・SetField など）
# FAKE_GH_STDERR を指定すると、どの呼び出しでも、その文字列を標準エラーに出す（成功する呼び出しでも）。
# FAKE_FAIL に指定した操作名（issue-view・edit・issue-comment・issue-close・pr-list・pr-view・pr-create・pr-comment・pr-close・api-get・api-delete・api-sub-issues・api-rules・api-merge-queue・api-parent・api-activity を含む）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。

setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$FAKE_GH_PROJECT"
fake_gh_project "$@"
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
# FAKE_GH_STDERR があれば、成功しても標準エラーに出す（gh のお知らせ・警告の代わり。JSON と混ぜずに読むかを試す）
[ -z "${FAKE_GH_STDERR:-}" ] || echo "$FAKE_GH_STDERR" >&2
case "$1 $2" in
  "repo view") echo '{"nameWithOwner": "me/demo", "url": "https://github.com/me/demo"}' | jq -r "$q" ;;
  "--version "*) echo "gh version ${FAKE_GH_VERSION:-2.96.0} (2026-07-02)" ;;
  "issue view")
    echo "issue-view $3 ${*:4}" >>"$CALLS"
    fail issue-view
    [ -f "$FIX/issue-$3.json" ] || { echo "GraphQL: Could not resolve to an issue (NOT_FOUND)" >&2; exit 1; }
    if [ "${*:4}" = "--json body" ] && [ -f "$FIX/issue-$3-body.json" ]; then
      jq -r "$q" "$FIX/issue-$3-body.json"
    else
      jq -r "$q" "$FIX/issue-$3.json"
    fi
    ;;
  "issue edit")
    shift 2
    echo "edit $*" >>"$CALLS"
    fail edit
    case " $* " in *" --body-file - "*) cat >"$(dirname "$FIX")/issue-edit-body" ;; esac
    ;;
  "issue comment")
    echo "issue-comment $3" >>"$CALLS"
    fail issue-comment
    cat >"$(dirname "$FIX")/issue-comment-body"
    ;;
  "issue close")
    shift 2
    echo "issue-close $*" >>"$CALLS"
    fail issue-close
    ;;
  "pr comment")
    echo "pr-comment $3" >>"$CALLS"
    fail pr-comment
    cat >"$(dirname "$FIX")/pr-comment-body"
    ;;
  "pr close")
    echo "pr-close $3" >>"$CALLS"
    fail pr-close
    ;;
  "pr ready")
    echo "pr-ready $3" >>"$CALLS"
    fail pr-ready
    ;;
  "api -X")
    echo "api-delete $4" >>"$CALLS"
    fail api-delete
    ;;
  "api --paginate")
    case "$3" in
      repos/*/issues/*/sub_issues*)
        path="${3%%\?*}"
        echo "api-sub-issues $path" >>"$CALLS"
        fail api-sub-issues
        n="${path%/sub_issues}"
        n="${n##*/}"
        if [ -f "$FIX/sub-issues-$n.json" ]; then cat "$FIX/sub-issues-$n.json"; else echo '[]'; fi
        ;;
      repos/*/rules/branches/*)
        echo "api-rules $3" >>"$CALLS"
        fail api-rules
        rb="${3#*/rules/branches/}"
        # %XX をバイト列として戻す（printf の %b の \xXX）。1文字ずつ戻すと、UTF-8 の多バイトの名前が化ける
        rb="${rb%%\?*}"
        rb="$(printf '%b' "${rb//%/\\x}")"
        if [ -f "$FIX/rules/$rb.json" ]; then cat "$FIX/rules/$rb.json"
        elif [ -f "$FIX/rules.json" ]; then cat "$FIX/rules.json"
        else echo '[]'; fi
        ;;
    esac
    ;;
  "api repos/"*/issues/*/parent)
    n="${2%/parent}"
    n="${n##*/}"
    echo "api-parent $n" >>"$CALLS"
    fail api-parent
    [ -f "$FIX/parent-$n.json" ] || { echo "gh: No parent issue found (HTTP 404)" >&2; exit 1; }
    cat "$FIX/parent-$n.json"
    ;;
  "api repos/"*/activity\?*)
    echo "api-activity $2" >>"$CALLS"
    fail api-activity
    if [ -f "$FIX/activity.json" ]; then cat "$FIX/activity.json"; else echo '[]'; fi
    ;;
  "api repos/"*)
    echo "api-get $2" >>"$CALLS"
    fail api-get
    [ -f "$FIX/remote-ref" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    echo '{}'
    ;;
  "pr list")
    shift 2
    echo "pr-list $*" >>"$CALLS"
    fail pr-list
    # $FIX/pr-list.raw があれば、そのまま返す（JSON でない応答を exit 0 で返す gh の役）
    if [ -f "$FIX/pr-list.raw" ]; then cat "$FIX/pr-list.raw"
    elif [ -f "$FIX/pr-list.json" ]; then jq -r "$q" "$FIX/pr-list.json"; else echo '[]' | jq -r "$q"; fi
    ;;
  "pr view")
    n="${3##*/}"
    echo "pr-view $n" >>"$CALLS"
    fail pr-view
    [ -f "$FIX/pr-$n.json" ] || { echo "GraphQL: Could not resolve to a PullRequest (NOT_FOUND)" >&2; exit 1; }
    jq -r "$q" "$FIX/pr-$n.json"
    ;;
  "pr create")
    shift 2
    echo "pr-create $*" >>"$CALLS"
    fail pr-create
    while [ $# -gt 0 ]; do
      if [ "$1" = --body-file ]; then cp "$2" "$(dirname "$FIX")/pr-body"; fi
      shift
    done
    echo https://github.com/me/demo/pull/42
    ;;
  "api user") echo '{"login": "me"}' | jq -r "$q" ;;
  "api graphql")
    # マージキューの有無（common.sh の dw_merge_queue_for_branch）は、標準入力でなく -f branch=<ブランチ> で読む
    case "$*" in *"query MergeQueueForBranch"*)
      branch=""
      for a in "$@"; do case "$a" in branch=*) branch="${a#branch=}" ;; esac; done
      echo "api-merge-queue $branch" >>"$CALLS"
      fail api-merge-queue
      if [ -f "$FIX/queue/$branch" ]; then echo '{"data": {"repository": {"mergeQueue": {"id": "MQ_1"}}}}'
      else echo '{"data": {"repository": {"mergeQueue": null}}}'; fi
      exit 0
      ;;
    esac
    body="$(cat)"
    op="$(jq -r .query <<<"$body" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2)"
    echo "$op $(jq -c .variables <<<"$body")" >>"$CALLS"
    fail "$op"
    # 変数の number（Issue の番号）ごとの応答 <操作名>-issue-<番号>.json があれば、それを返す（親の Issue の列を試す）
    num="$(jq -r '.variables.number // empty' <<<"$body")"
    if [ -n "$num" ] && [ -f "$FIX/$op-issue-$num.json" ]; then cat "$FIX/$op-issue-$num.json"
    elif [ -f "$FIX/$op.json" ]; then cat "$FIX/$op.json"; else echo '{"data": {}}'; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  echo '{"project": {"owner": "me", "number": 4}}' >"$REPO/.claude/dev-workflow/config.json"
  fake_issue 17 '["feat"]'
  echo '{"id": "P4", "number": 4, "url": "u", "owner": {"login": "me", "type": "User"}}' >"$FIX/ProjectView.json"
  # REST の項目の一覧。id は数値、node_id が gh project で使う id
  jq -n '[{id: 1, node_id: "F1", name: "Status", data_type: "single_select", options: [
    {id: "O1", name: {raw: "Todo"}}, {id: "O2", name: {raw: "In Progress"}}, {id: "O3", name: {raw: "Done"}}]}]' \
    >"$FIX/ProjectFields.json"
  issue_item Todo
  echo '{"id": "IT9"}' >"$FIX/AddItem.json"
}

# 使い方: fake_issue <番号> <ラベルの配列> [状態（既定 OPEN）] [割り当てられた login の配列]
fake_issue() {
  jq -n --argjson n "$1" --argjson l "$2" --arg s "${3:-OPEN}" --argjson a "${4:-[]}" \
    '{number: $n, url: "https://github.com/me/demo/issues/\($n)", title: "作業 \($n)", state: $s, labels: ($l | map({name: .})), assignees: ($a | map({login: .}))}' \
    >"$FIX/issue-$1.json"
}

# fake_issue で作った Issue の本文を置き換える。使い方: fake_issue_body <番号> <本文>
fake_issue_body() {
  # 長い本文も試せるよう、本文は引数ではなくファイルで jq に渡す（引数1つの長さには上限がある）
  printf '%s' "$2" | jq -Rs . >"$TMP/body.json" \
    && jq --slurpfile b "$TMP/body.json" '. + {body: $b[0]}' "$FIX/issue-$1.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-$1.json"
}

# Project P4 での Issue の項目と今の列。使い方: issue_item <列名 | none（列が空） | absent（Project に無い）>
issue_item() {
  jq -n --arg s "$1" '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/17", projectItems: {nodes: (
    if $s == "absent" then [] else [{id: "IT1", project: {id: "P4"},
      fieldValueByName: (if $s == "none" then null else {name: $s} end)}] end)}}}}}' >"$FIX/IssueItem.json"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: args <操作名> [何回目か] → 記録した変数
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }

# 標準エラーの警告の後ろに出る JSON だけを取り出す
# macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
json_of() { printf '%s\n' "$1" | LC_ALL=C sed -n '/^{/,$p'; }

# Issue 17 を閉じる PR（closedByPullRequestsReferences）を決め、PR ごとの中身を作る（issue-branches・auto-check のテストで使う）。
# PR のリポジトリを none にすると、参照に repository を入れない（gh が返さないとき）。PR の URL は me/demo のものにする
# 使い方: link_prs [<番号>:<状態>:<ブランチ>[:<PR のリポジトリ>[:<フォークか>]]]...
link_prs() {
  local refs='[]' spec n state branch pr_repo fork
  for spec in "$@"; do
    IFS=: read -r n state branch pr_repo fork <<<"$spec"
    pr_repo="${pr_repo:-me/demo}"
    refs="$(jq -c --argjson n "$n" --arg r "$pr_repo" \
      '. + [{number: $n, url: "https://github.com/\(if $r == "none" then "me/demo" else $r end)/pull/\($n)"}
        + (if $r == "none" then {} else {repository: {name: ($r | split("/")[1]), owner: {login: ($r | split("/")[0])}}} end)]' <<<"$refs")"
    jq -n --argjson n "$n" --arg s "$state" --arg b "$branch" --arg r "$pr_repo" --argjson f "${fork:-false}" \
      '{number: $n, url: "https://github.com/\(if $r == "none" then "me/demo" else $r end)/pull/\($n)", state: $s, headRefName: $b, isCrossRepository: $f}' >"$FIX/pr-$n.json"
  done
  jq --argjson refs "$refs" '. + {closedByPullRequestsReferences: $refs}' "$FIX/issue-17.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-17.json"
}
