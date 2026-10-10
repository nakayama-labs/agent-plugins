#!/usr/bin/env bash
# 必須のチェックを出すワークフローが、マージキューの merge_group のイベントでも動くかを確かめる。何も変更しない。
# キューは必須のチェックを merge_group のイベントでもう一度動かしてからマージするので、ワークフローの on: に
# merge_group が無いと、チェックが「待ち」のまま残り、PR がマージされない。ジョブの if: で merge_group を
# 除いていると、ジョブが飛ばされて成功とみなされ、キューが CI を動かさないままマージしてしまう。
# setup-repo.sh と doctor.sh が使う（確かめる理由は、この説明を正本とする）。
#
# 使い方: merge-group-check.sh --branch NAME [--repo OWNER/NAME] [--check NAME]... [--checks-json JSON]
#   --branch NAME    ワークフローを読むブランチ（base_branch。キューはこのブランチのワークフローを動かす）
#   --repo OWNER/NAME  対象のリポジトリ（既定: 今いるリポジトリ）
#   --check NAME     必須のチェックの名前（繰り返し指定できる。--check と --checks-json のどちらにも名前が無ければ、
#                    何も読まずに空の結果を出す）
#   --checks-json JSON  必須のチェックの名前の JSON の配列（--check と合わせて使える）
#
# 確かめ方:
#   ブランチの .github/workflows/*.yml・*.yaml を GitHub の API で読む（手元の作業中のファイルではなく、
#   キューで動く GitHub 上のものを見る）。YAML のパーサーは前提にしないので、次の簡易な読み方をする。
#   - merge_group で動くか：トップレベルの on: の範囲（on: の行から次のトップレベルのキーまで）に、
#     merge_group という語があるか
#   - ジョブの if:：必須のチェックのジョブと、そのジョブが needs: でたどれるすべてのジョブの if: を読む。
#     if: で merge_group を除いたジョブは飛ばされ、飛ばされたジョブのチェックは成功とみなされるので、
#     キューは CI を動かさないままマージしてしまう。式は ${{ }} を外し、括弧の外の && で項に分けて
#     （括弧の外に || があれば式全体を1つの項として）、項ごとに次のように判定する。
#       除く：github.event_name を merge_group 以外と == で、または merge_group と != で比べる項
#       動く：github.event_name を merge_group と == で、または merge_group 以外と != で比べる項
#       分からない：上の形以外で github.event・github.head_ref・github.base_ref・github.ref・merge_group を使う項
#         （github.event.pull_request.draft == false などは、merge_group では値が無いので飛ばされる）
#       動く：それ以外の項（always()・needs.<ID>.outputs.<名前> など）
#     除く項が1つでもあればそのジョブは除かれ、無くて分からない項があれば分からないとする。
#     needs: で頼るジョブが除かれていれば、そのジョブも飛ばされるので除かれるとする。ただし、自分の if: に
#     状態の関数（always()・cancelled()・failure()）があれば、頼るジョブが飛ばされても動くので、
#     CI を動かしたかは結果の確かめ方次第になり、分からないとする。
#     見つからないジョブを needs: で頼っていれば、分からないとする。
#     再利用するワークフローの、呼ばれる側のジョブの if: は読まない（呼ぶ側のジョブだけで判定する）
#   - チェックとジョブの対応：チェックの名前を、GitHub がジョブのチェックに付ける名前（name: があればその値、
#     無ければジョブの ID）と突き合わせる。
#     matrix の「名前 (値)」は括弧の前でも、再利用するワークフローの「呼ぶ側 / 呼ばれる側」は / の前でも比べる。
#     ${{ }} の式を含む name: とは比べない（式を何にでも当たる形にすると、どこまで広く当たるかを見分けきれず、
#     関係の無いチェックに当てて、誤って not_running にしてしまうため。そのチェックは unknown になる）
#   対応するジョブのどれかが、merge_group で動くワークフローにあり、if: でも除かれていなければ、動くとみなす。
#   そうでなく、if: を判定できないジョブがあれば unknown に、どれも動かなければ not_running に入れる。
#   どのジョブとも対応しない名前（外部のアプリのチェックなど）も unknown に入れる。
#
# 出力（JSON）:
#   branch        読んだブランチ
#   workflows     読んだワークフローのファイル
#   not_running   merge_group で動かないチェック（check と workflows と reason）。reason は、ワークフローの on: に
#                 merge_group が無ければ on（workflows は対応するジョブがあるワークフロー）、ジョブの if: で
#                 除いていれば if（workflows は除いたジョブがあるワークフロー）
#   unknown       確かめられないチェックの名前（どのジョブとも対応しないか、ジョブの if: から判定できない）
#   messages      利用者に伝える文（not_running・unknown。それぞれ、当てはまるチェックが無ければ null）。
#                 setup-repo.sh と doctor.sh が同じ文を出すよう、ここで作る
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

# gh api は {owner}/{repo} を今いるリポジトリに置き換える
repo="{owner}/{repo}" branch=""
checks=()
extra='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; repo="$2"; shift 2 ;;
    --branch) need_value "$@"; branch="$2"; shift 2 ;;
    --check) need_value "$@"; checks+=("$2"); shift 2 ;;
    --checks-json)
      need_value "$@"
      extra="$(jq -ce 'if type == "array" and all(.[]; type == "string") then . else error end' <<<"$2" 2>/dev/null)" \
        || dw_die "--checks-json には文字列の JSON の配列を指定してください: $2" 64
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$branch" ] || dw_die "--branch を指定してください" 64

# --checks-json の配列には空の文字列がありうる（文字列の配列かだけを確かめている）ので、足した後にも空を除く
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
checks_json="$(printf '%s\n' ${checks[@]+"${checks[@]}"} \
  | dw_json_lines_nonempty '. + $e | map(select(. != "")) | unique' --argjson e "$extra")"

# 結果に、利用者に伝える文（messages）を添えて出力する。使い方: output <ワークフローの JSON> <チェックごとの結果の JSON>
output() {
  # hits はチェックに対応するジョブごとに、ワークフロー（path）・merge_group で動くか（mg）・if: の判定（status）を持つ
  jq -n --arg b "$branch" --argjson w "$1" --argjson r "$2" '
    def listed: [.[] | "\(.check)（\(.workflows | join("・"))）"] | join("、");
    [$r | to_entries[] | {check: .key, hits: .value}
      | .running = any(.hits[]; .mg == 1 and .status == "run")
      | .unknown_if = any(.hits[]; .mg == 1 and .status == "unknown")
      | .excluded = ([.hits[] | select(.mg == 1 and .status == "exclude") | .path] | unique)] as $all
    | [$all[] | select(.hits != [] and (.running | not) and (.unknown_if | not))
      | if .excluded != [] then {check, workflows: .excluded, reason: "if"}
        else {check, workflows: ([.hits[].path] | unique), reason: "on"} end] as $not
    | [$all[] | select(.hits == []) | .check] as $nojob
    | [$all[] | select((.running | not) and .unknown_if) | .check] as $noif
    | [$not[] | select(.reason == "on")] as $on
    | [$not[] | select(.reason == "if")] as $if
    | {
        branch: $b,
        workflows: $w,
        not_running: $not,
        unknown: ($nojob + $noif | unique),
        messages: {
          not_running: (if $not == [] then null else [
            (if $on == [] then empty else
              "必須のチェックのうち \($on | listed)は、merge_group のイベントで動きません。マージキューのチェックが「待ち」のまま残り、PR がマージされません。ワークフローの on: に merge_group を足してください" end),
            (if $if == [] then empty else
              "必須のチェックのうち \($if | listed)は、ジョブ（または needs: で頼るジョブ）の if: で merge_group のイベントを除いています。飛ばされたジョブのチェックは成功とみなされるので、マージキューは CI を動かさないまま PR をマージします。ジョブの if: を直してください" end)
          ] | join("。") end),
          unknown: (if $nojob + $noif == [] then null else [
            (if $nojob == [] then empty else
              "必須のチェック \($nojob | join("、")) は、\($b) のどのワークフローのジョブか分からないので、merge_group のイベントで動くか確かめられません" end),
            (if $noif == [] then empty else
              "必須のチェック \($noif | join("、")) は、ジョブ（または needs: で頼るジョブ）の if: から、merge_group のイベントで CI が動くかを判定できません" end)
          ] | join("。") end)
        }
      }'
}

if [ "$checks_json" = "[]" ]; then
  output '[]' '{}'
  exit 0
fi

# ワークフローの一覧。ディレクトリが無ければ（404。dw_gh_find は null を出す）ワークフローは無い
ref="$(jq -rn --arg b "$branch" '$b | @uri')"
listing="$(dw_gh_find gh api "repos/$repo/contents/.github/workflows?ref=$ref")"
workflows="$(jq -c '[if type == "array" then .[] else empty end
  | select(.type == "file" and (.name | test("\\.ya?ml$"))) | .path]' <<<"$listing" 2>/dev/null)" \
  || dw_die "${branch} のワークフローの一覧を JSON として読めません"

# ワークフローを読み、merge_group で動くか（「on <0|1>」の1行）と、ジョブのチェックの名前と if: の判定（「job <名前> <判定>」。
# 名前は name: があればその値、無ければ ID。${{ }} の式を含む name: のジョブは出さない。判定は、ジョブと needs: でたどれる
# ジョブの if: が merge_group で動くなら run、除くなら exclude、分からなければ unknown）を出力する。
# 項目は \037 で区切る。インデントは空白だけとみなす（YAML はタブを許さない）
parse_workflow() {
  # strip・unquote・trim は DW_AWK_YAML（lib/common.sh）
  awk "$DW_AWK_YAML"'
    # 式の全体を囲む括弧を外す（「(a) && (b)」のように、先頭と末尾の括弧が対でなければ外さない）
    function unparen(t,   i, c, d, q) {
      while (t ~ /^\(.*\)$/) {
        d = 0; q = 0
        for (i = 1; i < length(t); i++) {
          c = substr(t, i, 1)
          if (c == "\047") q = !q
          else if (!q && c == "(") d++
          else if (!q && c == ")") d--
          if (d == 0) return t
        }
        t = trim(substr(t, 2, length(t) - 2))
      }
      return t
    }
    # 1つの項を判定する：run（merge_group で真）・exclude（merge_group で偽）・unknown
    function term(t,   l, op, v) {
      l = tolower(unparen(trim(t))); v = ""
      if (l ~ /^github\.event_name[ \t]*[!=]=[ \t]*\047[^\047]*\047$/) {
        v = l; sub(/^github\.event_name[ \t]*/, "", v)
        op = substr(v, 1, 2); v = trim(substr(v, 3))
      } else if (l ~ /^\047[^\047]*\047[ \t]*[!=]=[ \t]*github\.event_name$/) {
        v = l; sub(/[ \t]*github\.event_name$/, "", v)
        op = substr(v, length(v) - 1); v = trim(substr(v, 1, length(v) - 2))
      }
      if (v != "") {
        v = substr(v, 2, length(v) - 2)
        return ((op == "==") == (v == "merge_group")) ? "run" : "exclude"
      }
      if (l ~ /github\.(event|head_ref|base_ref|ref)|merge_group/) return "unknown"
      return "run"
    }
    function worse(a, b) {
      if (a == "exclude" || b == "exclude") return "exclude"
      if (a == "unknown" || b == "unknown") return "unknown"
      return "run"
    }
    # if: の式を判定する。${{ }} を外し、括弧と引用符の外の && で項に分ける。括弧の外に || があれば全体を1つの項とする
    function cond(e,   i, c, d, q, n, parts, r) {
      e = trim(e)
      if (e ~ /^[|>][-+0-9]*$/ || e ~ /^[|>][-+0-9]* /) sub(/^[|>][-+0-9]*/, "", e)
      e = unquote(e)
      if (e ~ /^\$\{\{.*\}\}$/) e = substr(e, 4, length(e) - 5)
      e = trim(e)
      if (e == "") return "run"
      d = 0; q = 0; n = 1; parts[1] = ""
      for (i = 1; i <= length(e); i++) {
        c = substr(e, i, 1)
        if (c == "\047") q = !q
        else if (!q && c == "(") d++
        else if (!q && c == ")") d--
        if (!q && d == 0 && substr(e, i, 2) == "||") return term(e)
        if (!q && d == 0 && substr(e, i, 2) == "&&") { parts[++n] = ""; i++; continue }
        parts[n] = parts[n] c
      }
      r = "run"
      for (i = 1; i <= n; i++) r = worse(r, term(parts[i]))
      return r
    }
    # ジョブの判定（自分の if: と、needs: でたどれるジョブの if:）。見つからないジョブや循環は unknown。
    # 状態の関数（always()・cancelled()・failure()）がある if: のジョブは、頼るジョブが飛ばされても動くので、
    # 頼るジョブの exclude を unknown に弱める（暗黙の success() は、状態の関数が無いときだけ付く）
    function judge(j,   n, k, toks, r, st2, status) {
      if (j in st) return st[j]
      if (!(j in known) || (j in visiting)) return "unknown"
      visiting[j] = 1
      r = cond(ifs[j])
      status = (tolower(ifs[j]) ~ /(always|cancelled|failure)[ \t]*\(/)
      n = split(needs[j], toks, /[][, \t]+/)
      for (k = 1; k <= n; k++) {
        if (toks[k] == "" || toks[k] == "-") continue
        st2 = judge(unquote(toks[k]))
        if (status && st2 == "exclude") st2 = "unknown"
        r = worse(r, st2)
      }
      delete visiting[j]
      st[j] = r
      return r
    }
    # GitHub はジョブのチェックを、name: があればその値、無ければ ID で名付ける。式を含む name: は比べないので出さない
    function flush() {
      if (id != "") {
        known[id] = 1; order[++njobs] = id
        label[id] = hasname ? name : id
      }
      id = ""; name = ""; hasname = 0; childind = -1; key = ""
    }
    BEGIN { section = ""; mg = 0; jobind = -1; childind = -1; njobs = 0 }
    {
      s = strip($0)
      if (s ~ /^[ \t]*$/) next
      if (s ~ /^[^ ]/) {
        flush()
        if (s ~ /^("on"|\047on\047|on|true)[ \t]*:/) section = "on"
        else if (s ~ /^jobs[ \t]*:/) section = "jobs"
        else section = ""
      }
      if (section == "on") {
        if ((" " s " ") ~ /[^A-Za-z0-9_-]merge_group[^A-Za-z0-9_-]/) mg = 1
        next
      }
      if (section != "jobs" || s ~ /^[^ ]/) next
      match(s, /^ */); ind = RLENGTH
      if (jobind < 0) jobind = ind
      if (ind == jobind) {
        flush()
        id = s; sub(/:.*$/, "", id); id = unquote(id)
      } else if (ind > jobind && id != "") {
        if (childind < 0) childind = ind
        if (ind == childind && key == "needs" && s ~ /^ *-/) {
          # needs: の下のリストは、needs: と同じ深さにも書ける
          needs[id] = needs[id] " " s
        } else if (ind == childind) {
          key = ""
          if (s ~ /^ *name[ \t]*:/) {
            v = s; sub(/^ *name[ \t]*:/, "", v); name = unquote(v); hasname = 1
          } else if (s ~ /^ *if[ \t]*:/) {
            # 続きの行（複数行の式）は、ジョブの次のキーまで空白でつなぐ
            v = s; sub(/^ *if[ \t]*:/, "", v); ifs[id] = v; key = "if"
          } else if (s ~ /^ *needs[ \t]*:/) {
            v = s; sub(/^ *needs[ \t]*:/, "", v); needs[id] = v; key = "needs"
          }
        } else if (key == "if") {
          ifs[id] = ifs[id] " " trim(s)
        } else if (key == "needs") {
          needs[id] = needs[id] " " s
        }
      }
    }
    END {
      flush()
      for (k = 1; k <= njobs; k++) {
        j = order[k]
        if (label[j] != "" && label[j] !~ /\$\{\{/) printf "job\037%s\037%s\n", label[j], judge(j)
      }
      printf "on\037%d\n", mg
    }
  ' "$1"
}

# チェックの名前と比べる候補（そのまま・matrix の括弧の前・再利用の / の前）を1行ずつ出力する
candidates() {
  printf '%s\n' "$1" "${1% (*}" "${1%% / *}"
}

# 使い方: job_matches <チェックの名前> <ジョブのチェックの名前>
job_matches() {
  local c
  while IFS= read -r c; do
    if [ "$c" = "$2" ]; then
      return 0
    fi
  done <<EOF
$(candidates "$1")
EOF
  return 1
}

sep=$'\037'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# チェックごとに、対応するジョブ（hits）を集める。ジョブごとに、ワークフロー（path）と、そのワークフローが merge_group で
# 動くか（mg）と、ジョブの if: の判定（status）を持つ
result="$(jq -c 'map({key: ., value: []}) | from_entries' <<<"$checks_json")"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  dw_fetch_repo_file "$repo" "$path" "$tmp/workflow" "$branch" || continue
  parsed="$(parse_workflow "$tmp/workflow")"
  mg="$(printf '%s\n' "$parsed" | awk -F "$sep" '$1 == "on" { print $2 }')"
  while IFS= read -r check; do
    while IFS="$sep" read -r kind label status; do
      [ "$kind" = job ] || continue
      if job_matches "$check" "$label"; then
        result="$(jq -c --arg c "$check" --arg p "$path" --argjson mg "$mg" --arg s "$status" \
          '.[$c] += [{path: $p, mg: $mg, status: $s}]' <<<"$result")"
      fi
    done <<EOF
$parsed
EOF
  done < <(jq -r '.[]' <<<"$checks_json")
done < <(jq -r '.[]' <<<"$workflows")

output "$workflows" "$result"
