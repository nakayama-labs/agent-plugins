#!/usr/bin/env bash
# 今のブランチ（作業用のブランチ）が、マージ先のブランチより遅れているかを調べる。マージ先は、開いた PR があれば
# その PR のマージ先、無ければ設定の base_branch にする。
# 何も変更しない（fetch だけ行う）。取り込む作業は今のブランチに対して行うので、調べるのも今のブランチだけにする。
# PR のマージ先を使えない（ブランチ名として使えない・マージ先の違う開いた PR が複数ある）か、取り込み先を取得できないか、
# gh で PR を読めない（gh が失敗した・JSON でない応答）なら、取り違えたマージ先を取り込まないよう、終了コード 2 で止まる
# （規則は lib/common.sh の「PR のマージ先」。gh が無いときだけは、PR が無いものとして設定の base_branch を使う）。
#
# 使い方: branch-status.sh [--merged-from <sha>] [--pulled-from <sha>]
#   --merged-from <sha>   origin/<base> を取り込む前（branch-update の手順2の merge の前）の HEAD。今のブランチの祖先
#                         （HEAD を含む）であること
#   --pulled-from <sha>   origin/<ブランチ> を取り込む前（branch-update の取り込む前の確認の pull の前）の HEAD。
#                         --merged-from の祖先（無ければ今のブランチの祖先）であること。--merged-from が無いとき
#                         （pull の後、merge の前に止めた）は、merge の前を HEAD とみなす
#   どちらかを付けると、push_commits の main・pull・own に、push で入るコミットを分けて出す。値が空か、コミットで
#   ないか、上の祖先の順になっていなければ、終了コード 64 で止まる
#
# 出力（JSON）:
#   branch, base          今のブランチと、取り込み先（開いた PR があればその PR のマージ先、無ければ設定の base_branch）
#   behind                origin/<base> にあって、ブランチに無いコミットの数
#   ahead                 ブランチにあって、origin/<base> に無いコミットの数
#   up_to_date            behind が 0 か（取り込むものが無いか）
#   conflicts             origin/<base> を取り込むと衝突するか。手元で確かめる（git merge-tree。何も変えない）ので、
#                         GitHub がマージできるかを調べている途中（merge_state が UNKNOWN）でも分かる。
#                         behind が 0 なら false。確かめられない（git が 2.38 より古いなど）ときは null
#   dirty                 未コミットの変更（追跡しているファイルの変更。未追跡のファイルと、git が無視するファイルは除く）があるか
#   unpushed              origin/<ブランチ> に無い、手元のコミットの数。origin にブランチが無ければ null
#   unpulled              手元に無い、origin/<ブランチ> のコミットの数（push が拒否される原因になる）。origin にブランチが無ければ null
#   pushed_behind         origin/<base> にあって、origin/<ブランチ>（push 済みのブランチ）に無いコミットの数。
#                         up_to_date が true でこれが 1 以上なら、手元では取り込み済みで、まだ push していない。
#                         origin にブランチが無ければ null
#   pushed_conflicts      origin/<ブランチ>（push 済みのブランチ）に origin/<base> を取り込むと衝突するか。conflicts と同じく
#                         手元で確かめる。GitHub から見た PR がマージ先と衝突しているかが、merge_state が UNKNOWN でも分かる
#                         （手元で取り込み済みで、まだ push していないときや、push していないコミットで手元だけ衝突しない
#                         とき）。pushed_behind が 0 なら false。origin にブランチが無いか、
#                         確かめられないときは null
#   pr                    そのブランチの開いている PR（number・url・merge_state・merge_queue）。無ければ null
#                         merge_state は GitHub の mergeStateStatus（BEHIND・DIRTY・BLOCKED・CLEAN など）。
#                         fork の同じ名前のブランチからの PR は除く。PR が無いか gh が無いときは、pr は null になる
#                         （behind と ahead は gh が無くても出る。gh で PR を読めないときは、上のとおり止まる）
#                         pr.merge_queue はマージキューの状態（enabled・state・position・queued・removed）。enabled は PR のマージ先で
#                         キューが有効か、state・position は PR がキューに並んでいるときの状態（QUEUED・AWAITING_CHECKS・
#                         MERGEABLE・UNMERGEABLE・LOCKED）と順番（1 が先頭）で、並んでいなければ null。
#                         キューに並んだ PR は、merge_state が CLEAN でも、先に並んだ PR と衝突すると state が UNMERGEABLE になり、
#                         すぐにキューから外れる。queued はキューの中か（並んでいる、入れた直後（入れたイベントから10分まで。
#                         common.sh の DW_QUEUE_ADDED_GRACE_MINUTES）でまだ state に出ていない、
#                         または merged の理由で外れた直後（マージの直前）なら true。入れてから10分を過ぎても state に出て
#                         いなければ、warn を出して false）。removed は、PR がキューから外れたままの
#                         ときの、外れた理由と時刻と、push したかを確かめられなかったか（{reason, at, push_unknown}。
#                         reason は GitHub の値で、衝突なら merge_conflict）。
#                         外れた後にキューへ入れ直していれば null。キューに入れた後に PR のブランチへ push していれば（直して、
#                         まだ入れ直していない）、removed は null。push は、リポジトリの activity の push・force_push の時刻で
#                         見る。push を読めなければ、warn を出して外れたままとみなす（push_unknown が true）。
#                         enabled が false なら、queued は false・removed は null で、push は読まない。判定は pr-merge-status.sh と共通
#                         （common.sh の dw_merge_queue_state）。キューの状態を取得できなければ、warn で理由を出し、ブランチの
#                         ルール（REST）でキューを使うかを確かめる。使うなら enabled が true で queued が null（キューの中かは
#                         分からない）、使わないなら enabled が false。ルールも読めなければ merge_queue は null になる
#   push_commits          push で origin に入るコミット（どれも {sha, subject} の配列。新しい順）
#                           to       数える基準。origin にブランチがあれば origin/<ブランチ>、無ければ（初回の push）origin/<base>。
#                                    どの組も、この基準に無いコミットだけを数える（origin に既にあるコミットは数えない）
#                           first_push  origin にブランチが無い（push でブランチが新しく作られる）か
#                           all      push で入るコミットの全部
#                           main     --merged-from より後のコミット（取り込んだ main のコミットと、その後に直したコミット）
#                           pull     pull が作った取り込みのコミット（--pulled-from と --merged-from（無ければ HEAD）の間。fast-forward なら空）
#                           own      取り込む前から手元にあった、push していない自分のコミット
#                         main・pull・own は、--merged-from も --pulled-from も無ければ null（--pulled-from が無ければ pull は空、
#                         --merged-from が無ければ main は空）
#   plan                  branch-update が次にすること（action・reason・queue・fallback）。上の値から branch-plan.sh が決める。
#                         項目の意味と判断の表は、branch-plan.sh --help を参照
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

merged_from="" pulled_from=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --merged-from | --pulled-from)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値（コミットの sha）がありません" 64
      if [ "$1" = --merged-from ]; then merged_from="$2"; else pulled_from="$2"; fi
      shift 2 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

dw_check_queue_now
repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(dw_base_branch "$config")"

branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
[ -n "$branch" ] || dw_die "ブランチの上にいません。取り込む作業用のブランチに切り替えてください" 64
[ "$branch" != "$base" ] || dw_die "${base} には取り込めません。作業用のブランチで実行してください" 64

# 取り込み先は、開いた PR があればその PR のマージ先にする（設定の base_branch と違うことがある。例：release/v1 に向いた PR）。
# PR の選び方と、マージ先を使えないとき（fallback）の規則は lib/common.sh の「PR のマージ先」が正本。branch-update はこの
# 取り込み先を取り込む（変更を加える）ので、ここは止める側：PR のマージ先を使えない（ブランチ名として使えない、マージ先の違う
# PR が複数ある）なら、取り違えたマージ先を取り込まないよう終了コード 2 で止まり、マージ先を取得できなくても止まる
# （読むだけの merge-target.sh は、同じ状況で警告して base_branch で続ける）。
# gh が無いときだけ、PR は無いものとし（pr は null）、設定の base_branch を使う。gh が失敗したか、JSON でない応答を返したときは、
# PR が別のマージ先に向いているかが分からないので、取り違えたマージ先を取り込まないよう終了コード 2 で止まる
pr=null
if command -v gh >/dev/null 2>&1; then
  prs="$(gh pr list --head "$branch" --state open --json number,url,mergeStateStatus,isCrossRepository,baseRefName 2>/dev/null)" \
    || dw_die "${branch} の PR を取得できませんでした。PR のマージ先が分からないので、取り込み先を決めずに止めます（gh auth status などで確かめてください）" 2
  dw_pr_pick_strict "$prs" "$base" "取り込み先を決められないので止めます（PR のマージ先を確かめてください）" \
    || dw_die "${branch} の PR を読めませんでした（gh の応答が JSON ではありません）。PR のマージ先が分からないので、取り込み先を決めずに止めます" 2
  base="$DW_PICK_BASE" pr="$DW_PICK_PR"
  [ "$pr" = null ] || pr="$(jq -c '{number, url, merge_state: .mergeStateStatus}' <<<"$pr")"
fi

# 取り込み先は、取得できなければ（手元の古いもので判断せず）終了コード 2 で止まる
dw_fetch_target_strict "$repo_root" "$base"
ref="refs/remotes/origin/$base"

behind="$(git -C "$repo_root" rev-list --count "refs/heads/$branch..$ref")"
ahead="$(git -C "$repo_root" rev-list --count "$ref..refs/heads/$branch")"

# 2つのコミットを merge すると衝突するかを、true・false・null（確かめられない）で出力する。merge-tree は、
# 衝突なしで 0、衝突で 1、それ以外の失敗（古い git で --write-tree が無いなど）で別の値を返す。
# 結果のツリーはオブジェクトとして書かれるだけで、作業ツリーとブランチは変わらない
# 使い方: merge_conflicts <コミット> <コミット>
merge_conflicts() {
  local rc=0
  git -C "$repo_root" merge-tree --write-tree --no-messages "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo false ;;
    1) echo true ;;
    *) echo null ;;
  esac
}

# 取り込むと衝突するか。遅れていなければ、取り込むものが無いので衝突しない
conflicts=false
[ "$behind" -eq 0 ] || conflicts="$(merge_conflicts "refs/heads/$branch" "$ref")"

# 条件の中のコマンド置換では、git が失敗しても止まらず、変更が無いとみなしてしまうので、先に変数に取って確かめる
dirty=false
changes="$(git -C "$repo_root" status --porcelain --untracked-files=no)" \
  || dw_die "未コミットの変更を調べられませんでした（git が失敗しました）"
[ -z "$changes" ] || dirty=true

# 手元のブランチと origin のブランチのずれ。origin にブランチが無ければ null。origin を読めなければ止まる（dw_remote_has_branch）
unpushed=null unpulled=null pushed_behind=null pushed_conflicts=null
if dw_remote_has_branch "$repo_root" "$branch"; then
  git -C "$repo_root" fetch -q origin -- "$branch" || dw_die "origin/${branch} を取得できませんでした"
  unpushed="$(git -C "$repo_root" rev-list --count "refs/remotes/origin/$branch..refs/heads/$branch")"
  unpulled="$(git -C "$repo_root" rev-list --count "refs/heads/$branch..refs/remotes/origin/$branch")"
  pushed_behind="$(git -C "$repo_root" rev-list --count "refs/remotes/origin/$branch..$ref")"
  pushed_conflicts=false
  [ "$pushed_behind" -eq 0 ] || pushed_conflicts="$(merge_conflicts "refs/remotes/origin/$branch" "$ref")"
fi

# push で入るコミットを、取り込みの前に控えた sha で分ける。どの組も基準（origin/<ブランチ>、初回は origin/<base>）に
# 無いコミットだけを数えるので、pull で取り込んだ origin のコミットや、origin/<base> に既にある main のコミットは入らない
# 使い方: commit_sha <名前> <sha> → コミットの完全な sha。コミットでなければ止まる
commit_sha() {
  git -C "$repo_root" rev-parse -q --verify "$2^{commit}" 2>/dev/null || dw_die "$1 の ${2} はコミットではありません" 64
}
to="$ref" first_push=true
if [ "$unpushed" != null ]; then
  to="refs/remotes/origin/$branch" first_push=false
fi
head_ref="refs/heads/$branch"
# 控えた sha の確かめ。--pulled-from だけのとき（pull の後、merge の前に止めた）は、merge の前を HEAD とみなす
m="$head_ref" p=""
if [ -n "$merged_from" ]; then
  m="$(commit_sha --merged-from "$merged_from")"
  git -C "$repo_root" merge-base --is-ancestor "$m" "$head_ref" \
    || dw_die "--merged-from の ${merged_from} は、${branch} の祖先ではありません" 64
fi
if [ -n "$pulled_from" ]; then
  p="$(commit_sha --pulled-from "$pulled_from")"
  git -C "$repo_root" merge-base --is-ancestor "$p" "$m" \
    || dw_die "--pulled-from の ${pulled_from} は、--merged-from（無ければ ${branch}）の祖先ではありません（順番が逆か、別のコミットです）" 64
fi
grouped=false
[ -z "$merged_from$pulled_from" ] || grouped=true
# 使い方: shas <コミット> → そのコミットから届き、基準に無いコミットの完全な sha の配列（JSON）
shas() { git -C "$repo_root" rev-list "$1" "^$to" -- | dw_json_lines_nonempty; }
# 一覧（push で入るコミット）と、控えた sha から届くコミット（どちらも基準に無いものだけ）を、git でたどって求め、
# jq で組に分ける。それぞれを変数に取り、git が失敗すれば1行のメッセージで止まる（まとめて1つのパイプにすると、
# 途中の失敗が見えず、空の一覧で組を誤る）。一覧は長くなりうる（main のコミットを数千件取り込むなど）ので、jq には
# 引数ではなく標準入力で渡す。署名を表示する設定（log.showSignature）でも、gpg の行が混ざらないようにする。
# 区切りは件名に現れない \x1f
commits="$(git -C "$repo_root" log --no-show-signature --format='%H%x1f%h%x1f%s' "$head_ref" "^$to" -- \
  | dw_json_lines_nonempty 'map(split("\u001f") | {full: .[0], sha: .[1], subject: (.[2:] | join("\u001f"))})')" \
  || dw_die "push で入るコミットを調べられませんでした（git が失敗しました）"
reach_m='[]' reach_p='[]'
if [ -n "$merged_from" ]; then
  reach_m="$(shas "$m")" || dw_die "push で入るコミットを調べられませんでした（git が失敗しました）"
elif $grouped; then
  # --pulled-from だけのときは、merge の前を HEAD とみなすので、一覧のどれもが届く（同じ範囲をたどり直さない）
  reach_m="$(jq -c 'map(.full)' <<<"$commits")"
fi
if [ -n "$p" ]; then
  reach_p="$(shas "$p")" || dw_die "push で入るコミットを調べられませんでした（git が失敗しました）"
fi
push_commits="$(printf '%s\n' "$commits" "$reach_m" "$reach_p" \
  | jq -s -c --arg to "${to#refs/remotes/}" --argjson first_push "$first_push" --argjson grouped "$grouped" --arg p "$p" '
  .[0] as $c
  | (.[1] | map({key: ., value: true}) | from_entries) as $rm
  | (.[2] | map({key: ., value: true}) | from_entries) as $rp
  | def pick(f): map(select(f) | {sha, subject});
    {to: $to, first_push: $first_push, all: ($c | pick(true)),
     main: (if $grouped then $c | pick($rm[.full] | not) else null end),
     pull: (if ($grouped | not) then null elif $p == "" then [] else $c | pick($rm[.full] and ($rp[.full] | not)) end),
     own: (if ($grouped | not) then null elif $p == "" then $c | pick($rm[.full]) else $c | pick($rp[.full]) end)}')"

# マージキューの状態は gh pr list にも REST にも無いので GraphQL で読む（設計書 §10）。読み方と、並んでいる・外れたままの
# 判定は pr-merge-status.sh と共通（common.sh の dw_merge_queue_state。ADR 000323）。取得できないときの扱いは下のとおり。
# 外れた後（キューに入れた後）に PR のブランチへ push していれば、外れたままとはしない（removed は null）。push を読めなければ、
# warn を出して外れたままとみなす（キューの状態は捨てない。捨てると branch-plan.sh がキューを使わないリポジトリとして扱い、
# 遅れていれば取り込んでしまうため）。fork の PR は上で除いているので、push を読むのはこのリポジトリのブランチだけになる
if [ "$pr" != null ]; then
  queue=null
  # 標準エラーは分けて受け、成功したときは（warn を）そのまま出す
  qerr="$(mktemp)"
  if ms="$(dw_merge_queue_state "$(jq -r .url <<<"$pr")" "$branch" false 2>"$qerr")"; then
    queue="$(jq -c 'del(.before_commit)' <<<"$ms")"
    cat "$qerr" >&2
  else
    # 読めなければ、理由を warn で出し、ブランチのルール（REST）でキューを使うかを確かめる。使うと分かれば、enabled を
    # true にして、キューの中かは分からない（queued が null）とする（merge_queue を null にすると、branch-plan.sh が
    # キューを使わないリポジトリとみなし、遅れていれば main を取り込んでしまう。ADR 000210）。使わないと分かれば enabled を
    # false にする。ルールも読めなければ、これまでどおり null にする
    dw_warn "マージキューの状態を読めません: $(tail -n 1 "$qerr")"
    if rules="$(dw_merge_queue_enabled '{owner}/{repo}' "$base")" && { [ "$rules" = true ] || [ "$rules" = false ]; }; then
      queue="$(jq -nc --argjson e "$rules" '{enabled: $e, state: null, position: null,
        queued: (if $e then null else false end), removed: null}')"
    fi
  fi
  rm -f "$qerr"
  pr="$(jq -c --argjson q "$queue" '. + {merge_queue: $q}' <<<"$pr")"
fi

status="$(jq -n --arg branch "$branch" --arg base "$base" --argjson behind "$behind" --argjson ahead "$ahead" \
  --argjson conflicts "$conflicts" --argjson dirty "$dirty" --argjson unpushed "$unpushed" --argjson unpulled "$unpulled" --argjson pushed_behind "$pushed_behind" --argjson pushed_conflicts "$pushed_conflicts" --argjson pr "$pr" \
  '{branch: $branch, base: $base, behind: $behind, ahead: $ahead, up_to_date: ($behind == 0), conflicts: $conflicts, dirty: $dirty,
    unpushed: $unpushed, unpulled: $unpulled, pushed_behind: $pushed_behind, pushed_conflicts: $pushed_conflicts, pr: $pr}')"

# 次にすることの判断は、テストで組み合わせを確かめられるよう、入力の値だけで決める branch-plan.sh に任せる
plan="$("$BASH" "$DW_SCRIPTS_DIR/branch-plan.sh" <<<"$status")"
# push_commits は長くなりうるので、引数ではなく標準入力で渡す
printf '%s\n' "$status" "$push_commits" "$plan" | jq -s '.[0] + {push_commits: .[1], plan: .[2]}'
