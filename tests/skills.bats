#!/usr/bin/env bats
# スキル（SKILL.md）の書き方を確かめる。

load test_helper

SKILLS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/skills"
SKILL_SCRIPTS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts"
# 独自の観点をレビューする agent（review スキルが起動する）
AGENT="$BATS_TEST_DIRNAME/../plugins/dev-workflow/agents/perspective-reviewer.md"

# 使い方: frontmatter <SKILL.md> → 先頭の --- で囲まれた部分
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$1"; }

# 使い方: step <SKILL.md> <番号> [終わりの見出しの正規表現] → 「### <番号>.」の節の本文
# （次の「## 」か「### 」の見出しの前まで。「#### 」の見出しでは終わらない。終わりの見出しを渡すと、その見出しでも終わる）
step() { awk -v n="$2" -v end="$3" 'on && ($0 ~ /^###? / || (end != "" && $0 ~ end)) { exit } $0 ~ ("^### " n "[.]") { on = 1; next } on' "$1"; }

# 使い方: section <SKILL.md> <見出し> → 「## 」の見出し（行全体が一致）の節の本文（次の「## 」の見出しの前まで）
section() { awk -v h="$2" '$0 == h { on = 1; next } on && /^## / { exit } on' "$1"; }

# 使い方: has <名前> <本文> <語>... → 本文にどの語もあること（固定の文字列として探す）
has() {
  local name="$1" text="$2" term; shift 2
  [ -n "$text" ] || fail "${name}がありません"
  for term in "$@"; do
    grep -qF -e "$term" <<<"$text" || fail "${name}に「${term}」がありません"
  done
}

@test "どのスキルにも name（ディレクトリ名と同じ）と description がある" {
  for f in "$SKILLS"/*/SKILL.md; do
    name="$(basename "$(dirname "$f")")"
    assert_equal "$(frontmatter "$f" | sed -n 's/^name: //p')" "$name"
    [ -n "$(frontmatter "$f" | sed -n 's/^description: //p')" ] || fail "$name に description がありません"
  done
}

@test "どのスキルも自動で呼べる（disable-model-invocation を付けない）" {
  for f in "$SKILLS"/*/SKILL.md; do
    if frontmatter "$f" | grep -q '^disable-model-invocation:'; then
      fail "$(basename "$(dirname "$f")") に disable-model-invocation があります（外部に影響する前は確認を取る方針。設計書 §8）"
    fi
  done
}

@test "task-start・task-status・task-finish は実行の確認を取らずに進める（ワークツリーを作るかと、PR の無いタスクを閉じるかだけは聞く。設計書 §8・ADR 000162）" {
  for name in task-start task-status task-finish; do
    f="$SKILLS/$name/SKILL.md"
    if grep -n -e '承認' -e '--dry-run' "$f"; then
      fail "${name} に実行の承認や dry-run の手順があります（依頼で結果が決まるので確認を取らない）"
    fi
    grep -q '確認を取らない' "$f" || fail "${name} に「確認を取らない」と書かれていません"
  done
}

@test "確認を残すスキルに、選択肢の説明の書き方がある（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup branch-update gh-pr-check task-start task-finish; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '選択肢の説明には、選ぶと実際に何が起きるか' "$f" \
      || fail "${name} に選択肢の説明の書き方（選ぶと何が起きるかを書く）がありません"
    grep -q '内部の手順は書かない' "$f" \
      || fail "${name} に「内部の手順は書かない」と書かれていません"
  done
}

@test "確認を残すスキルは、確認に必要な内容を質問の中にも入れる（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup review review-perspective-add task-finish branch-update gh-pr-check task-start; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '質問の中にも入れる' "$f" \
      || fail "${name} に、確認に必要な内容を質問の中にも入れることが書かれていません（別の端末から使うと、質問の直前の文章が見えない）"
  done
}

@test "観点の追加・修正は、きっかけになったタスクの PR に含める（設計書 §7）" {
  f="$SKILLS/review-perspective-add/SKILL.md"
  grep -q '今のタスクのワークツリー' "$f" \
    || fail "review-perspective-add に、リポジトリの層の観点を今のタスクのワークツリーに作ることが書かれていません"
  grep -q 'work_branch' "$f" \
    || fail "review-perspective-add に、作業用のブランチの上でないときに伝えることが書かれていません"
  grep -q 'きっかけになったタスクの PR に含める' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/issue-requirements.md" \
    || fail "issue-requirements に、観点の追加・修正を範囲外として指摘しないことが書かれていません"
}

@test "Issue の番号を取るスキルは、引数で番号を受け取れる（設計書 §8）" {
  for name in task-start task-status task-finish task-cancel task-auto; do
    f="$SKILLS/$name/SKILL.md"
    frontmatter "$f" | grep -q '^argument-hint: .*Issue番号' \
      || fail "${name} の frontmatter に argument-hint（Issue番号）がありません"
    grep -q '引数があれば' "$f" || fail "${name} に、引数の Issue の番号の扱い（引数があれば…）が書かれていません"
    grep -qF "\`#12\`" "$f" || fail "${name} に、12 と #12 のどちらも受けることが書かれていません"
  done
}

@test "task-create は、親と子をまとめて起票する手順（木の preview・親は Story Point なし・親から先に起票）を持つ" {
  f="$SKILLS/task-create/SKILL.md"
  grep -q '親と子をまとめて起票するとき' "$f" || fail "親と子をまとめて起票する手順がありません"
  grep -q '親子の木と各 Issue の本文の全文' "$f" || fail "確認の preview に親子の木と本文を入れることが書かれていません"
  grep -q '親には Story Point を付けず、子にだけ付ける' "$f" || fail "親に Story Point を付けないことが書かれていません"
  grep -q '既にある Issue を親にする' "$f" || fail "既存の Issue を親にする場合が書かれていません"
  grep -q '大きな依頼を、詰めたり縦に切ったりして子に分ける手法そのものは、この手順の範囲外' "$f" || fail "大きな依頼の分割の手法が範囲外であることが書かれていません"
  grep -q -e '--parent <親の番号>' "$f" || fail "子を --parent で起票する手順がありません"
  grep -q '新しい親なら、先に' "$f" || fail "親から先に起票する手順がありません"
  grep -q '親が閉じていれば' "$f" || fail "閉じた親の扱いが書かれていません"
  grep -q 'サブ Issue を読み直し' "$f" || fail "失敗後の再開で読み直す手順が書かれていません"
  grep -qF 'gh api --paginate repos/{owner}/{repo}/issues/<親の番号>/sub_issues' "$f" \
    || fail "サブ Issue を読み直す gh api に --paginate がありません（30件を超える子を取りこぼす）"
}

@test "task-create は、下書きの前に開いている Issue から重複と親の候補を探し、重複があれば起票の前に聞く" {
  f="$SKILLS/task-create/SKILL.md"
  # 手順2（下書きを作る）の中で、下書きの項目より前に探す
  step2="$(step "$f" 2 '^#### 下書きの項目')"
  grep -q '重複と親の候補を探す' <<<"$step2" || fail "手順2の最初に、重複と親の候補を探す手順がありません"
  grep -qF 'gh issue list --state open' <<<"$step2" || fail "開いている Issue を読む手順がありません"
  grep -qF 'subIssuesSummary' <<<"$step2" || fail "サブ Issue の数を、開いている Issue の一覧と一緒に読んでいません"
  grep -q 'AskUserQuestion' <<<"$step2" || fail "重複があるときにユーザーに聞く手順がありません"
  for choice in '既にある Issue で進める' '重ならない部分だけを起票する' 'そのまま起票する' '既にある Issue を親にする'; do
    grep -q "$choice" <<<"$step2" || fail "重複があるときの選択肢「${choice}」がありません"
  done
  grep -q '親の候補は、重なりとして数えない' <<<"$step2" || fail "指定された親と親の候補を、重なりから外すことが書かれていません"
  grep -q 'サブ Issue を既に持つ Issue.*だけを候補にする' <<<"$step2" \
    || fail "親の候補が、サブ Issue を持つ仕様の Issue に限られていません（作業の Issue を親にすると Story Point が消える）"
  grep -q 'サブ Issue を持たない Issue は.*重なりとして扱う' <<<"$step2" \
    || fail "サブ Issue を持たない広い Issue を重なりとして扱うことが書かれていません"
  grep -q '明らかな親' "$f" && fail "親の候補が、探した結果ではなく「明らかな親」のままです"
  step3="$(step "$f" 3)"
  grep -q '手順2で探した結果' <<<"$step3" || fail "手順3の確認に、探した結果がありません"
}

@test "task-create は、分けた Issue も手順2で読んだ一覧と照らし、重なりの問いを手順3の確認に1回にまとめる" {
  f="$SKILLS/task-create/SKILL.md"
  step2="$(step "$f" 2)"
  step3="$(step "$f" 3)"
  grep -q '分けた Issue の重複と親の候補を照らす' <<<"$step2" || fail "手順2に、分けた Issue を照らす節がありません"
  grep -q '一覧は読み直さない' <<<"$step2" || fail "開いている Issue の一覧を読み直さないことが書かれていません"
  grep -q '残りの分けた Issue の下書きは止めない' <<<"$step2" || fail "重なった Issue だけを対象にし、全体を止めないことが書かれていません"
  grep -q '案の親子の木で決め' <<<"$step2" || fail "親の候補と案の親子の木がぶつかるときの扱いが書かれていません"
  grep -q '手順3の確認の中で1回にまとめる' <<<"$step2" || fail "重なりの問いを1回にまとめることが書かれていません"
  grep -q '分けた Issue が既にある Issue と重なるとき' <<<"$step3" || fail "手順3の確認に、分けた Issue の重なりの問いがありません"
  for choice in '外す' '重ならない部分だけにする' 'そのまま起票する'; do
    grep -q "\*\*${choice}\*\*" <<<"$step2" || fail "手順2に、重なった Issue の扱い「${choice}」がありません"
    grep -q "\*\*${choice}\*\*" <<<"$step3" || fail "手順3に、手順2と同じ言葉の選択肢「${choice}」がありません"
  done
  grep -q '選択肢が4つを超えないように' <<<"$step3" || fail "重なりの3択が起票の選択肢の代わりであることが書かれていません"
  grep -q '手順3で分割を提案するときに、その案を照らす' <<<"$step2" || fail "21/34 の分割を照らすタイミング（手順3の分割の提案）が手順2に書かれていません"
  grep -q '下の Story Point 21/34 の分割の段落の、分割の案を見せる確認.*の中で同じ3つを聞く' <<<"$step3" || fail "手順3の分割の確認の中で重なりを聞くことが書かれていません"
  grep -q '「分割する」を、重なりの3つの扱い' <<<"$step3" || fail "21/34 の分割の段落に、「分割する」を3つの扱いごとの選択肢に置き換えることが書かれていません"
  grep -q '「このまま設定する」と合わせて4つにする' <<<"$step3" || fail "21/34 の分割の段落に、選択肢を4つに収めることが書かれていません"
  grep -q '外した親の代わりとして使う例外' <<<"$step2" || fail "親を外すときの扱いが書かれていません"
  grep -q '子を親なしで起票し' <<<"$step2" || fail "外した親の代わりの Issue を親にできないときの扱いが書かれていません"
  # 親にできるかは、スクリプトの出力の action で決める（SKILL.md に条件の組み合わせを書いて判断させない）
  grep -qF 'parent-candidate.sh --issue <重なる既にある Issue の番号> --levels' <<<"$step2" || fail "外した親の代わりを parent-candidate.sh で判定することが書かれていません"
  grep -qF "\`use_as_parent\` なら" <<<"$step2" || fail "action が use_as_parent のときにすることが書かれていません"
  grep -qF "\`no_parent\` なら" <<<"$step2" || fail "action が no_parent のときにすることが書かれていません"
  # 止まったときにユーザーに親にするかを聞くと、issue-create.sh は確かめ直さないので、防ぐはずの紐付けが起きる
  # 一時的な失敗で親の紐付けを失わないよう、1回だけ実行し直してから、親なしにする
  grep -qF '通信などの一時的な失敗のこともあるので、1回だけ実行し直し' <<<"$step2" || fail "parent-candidate.sh が止まったときに実行し直すことが書かれていません"
  grep -qF "それでも止まったら \`no_parent\` と同じに扱う" <<<"$step2" || fail "parent-candidate.sh が止まり続けたときに親なしで起票することが書かれていません"
  # 直らない失敗（設定の誤り・引数の誤り）は実行し直さない
  grep -qF "2（設定の誤り）か 64（引数の誤り）なら、実行し直しても直らないので、実行し直さずに \`no_parent\` と同じに扱う" <<<"$step2" \
    || fail "parent-candidate.sh が終了コード 2・64 で止まったときに、実行し直さないことが書かれていません"
  grep -qF '後で GitHub の画面などから子を重なる既にある Issue に紐付けられる' <<<"$step2" || fail "親なしで起票したときに、後で紐付けられることを伝えると書かれていません"
  ! grep -qF '親にするかをユーザーに聞く' <<<"$step2" || fail "parent-candidate.sh が止まったときに、親にするかをユーザーに聞くと書かれています"
  [ -x "$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts/parent-candidate.sh" ] || fail "parent-candidate.sh が実行できません"
  grep -q '外した親のさらに上の親にする' <<<"$step2" || fail "木の途中の親を外すときの扱いが書かれていません"
  grep -qF "依存先を既にある Issue の \`#N\` に付け替え" <<<"$step2" || fail "依存先の付け替えが書かれていません"
}

@test "task-next は読み取り専用（確認を取らず、Issue や列を変えるスクリプトを呼ばない。設計書 §8）" {
  f="$SKILLS/task-next/SKILL.md"
  grep -q 'next-tasks.sh' "$f" || fail "task-next が next-tasks.sh を使っていません"
  if grep -n -e 'AskUserQuestion' -e 'status-set.sh' -e 'task-start.sh' -e 'issue-create.sh' -e 'issue-cancel.sh' "$f"; then
    fail "task-next に、確認や書き込みのスクリプトがあります（何も変えない読み取り専用）"
  fi
}

@test "task-next は、親の Issue を候補に入れず、開いている子を案内する（設計書 §4）" {
  # 親の Issue に着手したセッションが、親として進めるか子に着手し直すかを聞いて止まった（#142）
  f="$SKILLS/task-next/SKILL.md"
  grep -q "\`parent\`" "$f" || fail "出力の parent の見方が書かれていません"
  grep -q '待ちでも親でもないもの' "$f" || fail "並列にできないものから、親の Issue が除かれていません"
  step2="$(step "$f" 2)"
  grep -q '\*\*親の Issue\*\*' <<<"$step2" || fail "手順2に、親の Issue の伝え方がありません"
  # 子の読み方・案内のしかたは task-start の手順2を参照し、書き写さない（孫や別のリポジトリの子の扱いがずれないように）
  grep -q 'task-start の手順2と同じように' <<<"$step2" || fail "親の子の案内が、task-start の手順2を参照していません"
  grep -q 'subIssues' <<<"$step2" && fail "task-start の手順2の、子の読み方を書き写しています"
  grep -q '親を閉じる' <<<"$step2" || fail "開いている子が無い親を閉じるよう伝えることが書かれていません"
  # task-start の手順2に、参照する内容（子の読み方・孫・別のリポジトリの子）がある
  start2="$(step "$SKILLS/task-start/SKILL.md" 2)"
  grep -q 'subIssues' <<<"$start2" || fail "task-start の手順2に、子の読み方がありません"
  grep -q '孫を案内' <<<"$start2" || fail "task-start の手順2に、孫の案内がありません"
  grep -q '別のリポジトリの子' <<<"$start2" || fail "task-start の手順2に、別のリポジトリの子の扱いがありません"
}

@test "review は、局所の指摘でも水平展開の要否を判定し、反映のときに同じ場所も直す（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  grep -q '水平展開の要否' "$f" || fail "手順4に水平展開の要否の判定がありません"
  grep -q '局所の指摘でも' "$f" || fail "局所の指摘でも水平展開を判定することが書かれていません"
  grep -q '同じ誤りが残っていれば' "$f" || fail "同じ誤りが残る場所を一覧に加えることが書かれていません"
  # 手順6（反映する）の中に、水平展開の場所を直すことと再検索がある
  step6="$(step "$f" 6)"
  grep -q '水平展開' <<<"$step6" || fail "手順6に、水平展開の場所を直すことがありません"
  grep -q '同じ検索' <<<"$step6" || fail "手順6に、直した後の再検索がありません"
}

@test "review は、終えるときに見落としの指摘と今後も要らない指摘を観点に残すかを尋ねる（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step9="$(step "$f" 9)"
  [ -n "$step9" ] || fail "手順9（観点に残すか確かめる）がありません"
  grep -q '見落とし' <<<"$step9" || fail "見落としの指摘を拾うことが書かれていません"
  grep -q '今後も要らない指摘' <<<"$step9" || fail "今後も要らない指摘を拾うことが書かれていません"
  grep -q '一般的なバグ' <<<"$step9" || fail "一般的なバグを対象にしないことが書かれていません"
  grep -q 'その場限りの好み' <<<"$step9" || fail "その場限りの好みを対象にしないことが書かれていません"
  grep -q '自動では変えない' <<<"$step9" || fail "ユーザーが選んだものだけを変えることが書かれていません"
  grep -q 'review-perspective-add' <<<"$step9" || fail "review-perspective-add の手順で作ることが書かれていません"
  grep -q '既にある観点' <<<"$step9" || fail "既にある観点を直す案が書かれていません"
  grep -q '「〜を指摘しない」だけの観点は新しく作らない' <<<"$step9" || fail "指摘しないだけの観点を作らないことが書かれていません"
  grep -q -- '--builtin code-review' <<<"$step9" || fail "code-review の除外を上位の層に作ることが書かれていません"
  # 周回を終える出口（手順8）と、指摘が無い・何も選ばれないときの終わり方が、手順9へ進む
  step8="$(step "$f" 8)"
  grep -q '手順9へ進む' <<<"$step8" || fail "手順8で終えるときに手順9へ進むことが書かれていません"
  [ "$(grep -c '手順9へ進む' "$f")" -ge 3 ] || fail "手順4・5の終わり方が手順9へ進んでいません"
  # /code-review の指摘は、code-review の観点ファイルの「指摘しないこと」で外す
  step4="$(step "$f" 4)"
  grep -q '## 指摘しないこと' <<<"$step4" || fail "手順4で /code-review の指摘を除外の決まりと照らすことが書かれていません"
  grep -q '外した件数' <<<"$step4" || fail "外した件数を伝えることが書かれていません"
  # 同梱の code-review.md 自体には、除外の節を書かない（書くと全員の指摘が外れる）
  grep -q '^## 指摘しないこと' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/code-review.md" \
    && fail "同梱の code-review.md に除外の節があります"
  grep -q 'dev-workflow:review` の手順9（観点に残すか確かめる）' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" \
    || fail "SessionStart の流れ（defaults/task-flow.md）に、レビューの後の指摘を観点に残すことがありません"
  grep -q '「〜を指摘しない」ことだけを書いた観点は作らない' "$SKILLS/review-perspective-add/SKILL.md" \
    || fail "review-perspective-add に、指摘しないだけの観点を作らないことが書かれていません"
}

@test "不具合の修正の手順に、同じ原因の他の箇所を探すことがある（CONTRIBUTING・task-flow・設計書）" {
  grep -q '同じ原因の他の箇所' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md" || fail "CONTRIBUTING のテストのルールにありません"
  grep -q '同じ原因の他の箇所' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" || fail "SessionStart の流れ（defaults/task-flow.md）にありません"
  grep -q '同じ原因の他の箇所を' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書にありません"
}

@test "task-finish は、別のリポジトリの Issue の確認・クローズに --repo を付けて案内する" {
  f="$SKILLS/task-finish/SKILL.md"
  grep -q 'gh issue view <番号>' "$f"
  grep -q 'gh issue close <番号>' "$f"
  # shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
  grep -q 'どちらのコマンドにも `--repo <owner/repo>` を付けて案内する' "$f"
}

@test "task-start は、ワークツリーを作るかを本文から判断して提案し、作らないなら --no-worktree で着手する（設計書 §4）" {
  f="$SKILLS/task-start/SKILL.md"
  grep -q 'ワークツリーを作って着手する' "$f" || fail "作って着手する選択肢がありません"
  grep -q 'ワークツリーを作らずに着手する' "$f" || fail "作らずに着手する選択肢がありません"
  grep -q 'task-start.sh --issue <番号> --no-worktree' "$f" || fail "作らないときの実行のしかたがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-start は、ワークツリーを作るかを聞く前に、着手中の Issue との重なりを task-next と同じ判定で確かめる" {
  # task-next を通らずに着手すると、着手中の Issue と同じファイルを変える Issue に、気付かずに着手していた（#241）
  f="$SKILLS/task-start/SKILL.md"
  overlap="$(step "$f" 3)"
  grep -q 'next-tasks.sh --issue <番号>' <<<"$overlap" || fail "手順3で next-tasks.sh --issue を使っていません"
  grep -q '3. 着手中のタスクとの重なりを確かめる' "$f" || fail "重なりを確かめる手順がありません"
  grep -q '4. ワークツリーを作るかを決める' "$f" || fail "重なりを確かめた後に、ワークツリーを作るかを決めていません"
  ask="$(step "$f" 4)"
  # 重なるときは「今は着手しない」も選べ、選んだら重なる Issue への依存を足す
  grep -q '「今は着手しない」' <<<"$ask" || fail "重なるときの「今は着手しない」の選択肢がありません"
  grep -q 'issue-depend.sh --issue <番号> --blocked-by' <<<"$ask" || fail "今は着手しないときに依存を足していません"
  # ワークツリーを作るかが依頼で決まっていても、重なるときは聞く
  grep -q '`issue.overlap` が `conflict` なら、聞かずに進めない' <<<"$ask" || fail "質問を飛ばすときに、重なりがあれば聞くことが書かれていません"
  # 重なる・分からない・重ならないの判断は、スクリプトの値（overlap・can_defer）で決め、値の組み合わせを文章で決めない
  for v in conflict unknown none; do
    grep -q "\`${v}\`" <<<"$overlap" || fail "手順3に overlap の ${v} の扱いがありません"
  done
  grep -q 'issue.can_defer' <<<"$overlap" || fail "手順3に can_defer の扱いがありません"
  # 依存先が全部閉じていたかは、スクリプトの all_closed で決める（blocked_by と skipped_closed を文章で突き合わせない）
  grep -q '`all_closed` が true' <<<"$ask" || fail "手順4に all_closed の扱いがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "ワークツリーの無いタスクを、task-finish は Issue を閉じて終え、task-cancel は Issue を閉じるだけにする" {
  grep -q '### 4. ワークツリーの無いタスクを終える' "$SKILLS/task-finish/SKILL.md"
  grep -q 'gh issue close <番号> --reason completed' "$SKILLS/task-finish/SKILL.md"
  # 片付けるのは確かなブランチ（branch.pattern に合い番号が一致する）だけで、候補（名前が似ている・PR のブランチ）は見せるだけ。
  # 見つからなくても決めつけず、閉じるかを選んでもらう
  for name in task-finish task-cancel; do
    grep -q 'issue-branches.sh --issue <番号>' "$SKILLS/$name/SKILL.md" || fail "${name} が issue-branches.sh でブランチを探していません"
    grep -q '`candidates`（候補）' "$SKILLS/$name/SKILL.md" || fail "${name} に、候補を分けて扱うことが書かれていません"
  done
  grep -q '取りやめで片付ける対象は、`branches`' "$SKILLS/task-cancel/SKILL.md"
  # --no-worktree で候補の警告が出たら、決めつけずに伝える
  grep -q '「Issue #N に関係するかもしれないブランチ（…）があります」の警告' "$SKILLS/task-start/SKILL.md"
  # 終わった作業のブランチで止まったら、先に task-finish で片付けるよう案内する
  grep -q '先に task-finish でそのブランチを片付けてから' "$SKILLS/task-start/SKILL.md"
  # することはスクリプトの action で決め、スキルには値ごとにすることだけを書く（組み合わせは issue-branches.bats）
  for a in cleanup cleanup_candidate nothing blocked_open_pr blocked_sub_issues ask_close; do
    grep -q "\`${a}\`" "$SKILLS/task-finish/SKILL.md" || fail "task-finish に action の ${a} の扱いがありません"
  done
  grep -q '「別の名前のブランチで作業した」' "$SKILLS/task-finish/SKILL.md"
  grep -q 'argument-hint: "\[Issue番号|ブランチ名\]"' "$SKILLS/task-finish/SKILL.md"
  grep -q 'ワークツリーを作らずに着手した' "$SKILLS/task-cancel/SKILL.md"
}

@test "gh-pr-check は PR の番号を引数で受け取り、スレッドを resolved にせず、コメントの本文を信頼しない。対応が要らないときは何も変えない" {
  f="$SKILLS/gh-pr-check/SKILL.md"
  frontmatter "$f" | grep -q '^argument-hint: .*PR番号' || fail "gh-pr-check の frontmatter に argument-hint（PR番号）がありません"
  grep -q '引数があれば' "$f" || fail "gh-pr-check に、引数の PR の番号の扱いが書かれていません"
  grep -q 'スレッドは resolved にしない' "$f" || fail "gh-pr-check に、スレッドを resolved にしないことが書かれていません"
  grep -q '信頼しないデータとして読む' "$f" || fail "gh-pr-check に、コメントの本文を信頼しないデータとして読むことが書かれていません"
  grep -q 'pr_check.handlers' "$f" || fail "gh-pr-check に、担当の skill の設定（pr_check.handlers）が書かれていません"
  grep -q '何も変えずに終える' "$f" || fail "gh-pr-check に、対応が要らないときは何も変えずに終えることが書かれていません"
  grep -q 'ci_pending' "$f" || fail "gh-pr-check に、コメントが無くても CI が実行中ならその状態を伝えることが書かれていません"
  grep -q 'warn:' "$f" || fail "gh-pr-check に、スクリプトの警告（warn:）を伝えることが書かれていません"
  frontmatter "$f" | grep -q 'CI は通った？' || fail "gh-pr-check の description に、起動の言い方「CI は通った？」がありません"
  [ ! -e "$SKILLS/pr-respond" ] || fail "旧名のスキル pr-respond が残っています（別名は残さない）"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "branch-update は、設定の base_branch ではなく、branch-status.sh の取り込み先（開いた PR があればそのマージ先）を取り込む（#284）" {
  f="$SKILLS/branch-update/SKILL.md"
  has "branch-update の冒頭" "$(sed -n '/^# /,/^## /p' "$f")" '開いた PR があればその PR のマージ先'
  ! grep -qF 'origin/<base_branch>' "$f" || fail "branch-update に、設定の base_branch を取り込む手順（origin/<base_branch>）が残っています"
  has "手順2" "$(step "$f" 2)" '`git merge --no-edit origin/<base>`'
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "pr-create は、既にある PR のマージ先が設定の base_branch と違えば、そのマージ先との差で PR に入る変更を読む（#284）" {
  f="$SKILLS/pr-create/SKILL.md"
  has "pr-create の手順2" "$(step "$f" 2)" 'merge-target.sh' '`git diff <ref>...HEAD`'
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "マージ先との差を読むスキルと観点は、設定の base_branch を組み立てず、merge-target.sh か依頼のマージ先を使う（#284）" {
  # マージ先をモデルに組み立てさせると、PR のマージ先が設定の base_branch と違うとき（release/v1 に向いた PR）に誤る
  for f in "$SKILLS"/*/SKILL.md "$SKILLS/../review/"*.md "$AGENT"; do
    ! grep -qF 'origin/<base_branch>' "$f" || fail "${f} に、設定の base_branch との差を読む手順（origin/<base_branch>）が残っています"
  done
  grep -qF '`merge-target.sh` を実行し' "$SKILLS/task-auto/SKILL.md" || fail "task-auto が、コミットがあるかを merge-target.sh のマージ先で確かめていません"
  grep -qF '<ref>..HEAD' "$SKILLS/task-auto/SKILL.md" || fail "task-auto が、merge-target.sh の ref との差でコミットを確かめていません"
  grep -qF '`BEHIND` は PR のマージ先' "$SKILLS/gh-pr-check/SKILL.md" || fail "gh-pr-check の BEHIND の説明が、PR のマージ先になっていません"
  # main-drift は、review が渡すマージ先を使う（観点の担当者に渡るのは、パス・基点・マージ先・Issue だけ）
  grep -qF '依頼に書かれたマージ先' "$SKILLS/../review/main-drift.md" || fail "main-drift が、依頼のマージ先を使っていません"
  grep -qF 'マージ先: <context の target>' "$SKILLS/review/SKILL.md" || fail "review が、観点の担当者にマージ先を渡していません"
  grep -qF '基点・マージ先・Issue の番号' "$AGENT" || fail "perspective-reviewer が、依頼のマージ先を受け取っていません"
  # PR のマージ先をそのまま使えなかった（fallback）ことを伝える
  for f in pr-create task-auto; do
    grep -qF '`fallback` が null でなければ' "$SKILLS/$f/SKILL.md" || fail "$f が、merge-target.sh の fallback を伝えていません"
  done
  grep -qF '`context` の `fallback` が null でなければ' "$SKILLS/review/SKILL.md" || fail "review が、context.fallback を伝えていません"
  grep -qF '新しく作る PR のマージ先' "$SKILLS/pr-create/SKILL.md" || fail "pr-create の設定の一覧で、base_branch が PR のマージ先のままです"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "gh-pr-check の手順1は、終えるかと伝えることを pr-watch.sh の値（respond・reasons）で決め、スレッドの件数だけで未解決なしと言わない（#279・#358）" {
  f="$SKILLS/gh-pr-check/SKILL.md"
  s1="$(sed -n '/^### 1\./,/^### 2\./p' "$f")"
  grep -q 'pr-watch.sh' <<<"$s1" || fail "gh-pr-check の手順1に、pr-watch.sh を実行することが書かれていません"
  grep -q '`respond` が true.*手順2へ進む' <<<"$s1" || fail "gh-pr-check の手順1に、respond が true なら手順2へ進むことが書かれていません"
  grep -q '`respond` が false.*何も変えずに終える' <<<"$s1" || fail "gh-pr-check の手順1に、respond が false なら何も変えずに終えることが書かれていません"
  # 手順1に書いた reasons の値は、pr-watch.sh が出す値と同じでなければならない
  for v in not_open ci_pending merge_blocked awaiting_review mergeable_unknown in_merge_queue draft fork conflicting behind; do
    grep -q "\`$v" <<<"$s1" || fail "gh-pr-check の手順1に、reasons の値 ${v} が書かれていません"
    grep -q "$v" "$SKILL_SCRIPTS/pr-watch.sh" || fail "pr-watch.sh に、手順1が使う reasons の値 ${v} がありません"
  done
  # branch-update の案内は respond の値によらず、reasons の conflicting・behind で出す
  grep -q '^- `reasons` に `conflicting`・`behind` があれば、`respond` の値によらず.*branch-update' <<<"$s1" \
    || fail "gh-pr-check の手順1に、respond によらず conflicting・behind で branch-update を案内することが書かれていません"
  # 判断を文章で書き直さない（値ごとにすることだけを書く）。feedback が空か・checks.state・merge_state の組み合わせで決める書き方は残さない
  if grep -q '`feedback` が空で' "$f"; then fail "gh-pr-check に、feedback が空かで終える判断が文章で残っています（pr-watch.sh の respond で決める）"; fi
  grep -q '選べる指摘・質問が1つも無ければ.*聞かずに' "$f" \
    || fail "gh-pr-check に、選べる指摘・質問が無ければ聞かずに進むことが書かれていません"
  s4="$(sed -n '/^### 4\./,/^### 5\./p' "$f")"
  grep -q '担当の skill の分があれば、手順8へ進んで任せる' <<<"$s4" || fail "gh-pr-check の手順4に、担当の skill の分があれば手順8へ進むことが書かれていません"
  grep -q '無ければ、手順9へ進んで結果を伝える' <<<"$s4" || fail "gh-pr-check の手順4に、担当の skill の分が無ければ手順9へ進むことが書かれていません"
  grep -q '返事をしていないものを対応済みと言わない' <<<"$s4" || fail "gh-pr-check の手順4に、返事をしていない感想・承認を対応済みと数えないことが書かれていません"
  s9="$(sed -n '/^### 9\./,$p' "$f")"
  grep -q '手順4で選べる指摘・質問が無くて来たときは.*CI・マージの状態' <<<"$s9" \
    || fail "gh-pr-check の手順9に、手順4から来たときに件数と CI・マージの状態を伝えることが書かれていません"
  grep -q 'counts.threads.*だけを見て' "$f" || fail "gh-pr-check に、スレッドの件数だけで未解決なしと言わないことが書かれていません"
  grep -q '`reviews`・`comments`・`needs_attention`・`counts.unanswered`・`counts.awaiting` を落とさない' "$f" \
    || fail "gh-pr-check に、出力を絞って読むときも reviews・comments を落とさないことが書かれていません"
  grep -q '`needs_attention` が true の項目.*必ず一覧に入れる' "$f" || fail "gh-pr-check に、needs_attention が true の項目を必ず一覧に入れることが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートは文書の本文の文字で、展開させない
@test "pr-feedback.sh の needs_attention・replied・counts.unanswered の意味は、--help の1か所だけに書き、SKILL.md・設計書・README は参照する（#361）" {
  script="$SKILL_SCRIPTS/pr-feedback.sh"
  help="$(bash "$script" --help)"
  # 正本：--help の「意味」に、3つのキーの意味がある
  grep -q '^意味' <<<"$help" || fail "pr-feedback.sh --help に「意味」の節がありません"
  for k in replied needs_attention counts.unanswered; do
    grep -qE "^  $k " <<<"$help" || fail "pr-feedback.sh --help の「意味」に ${k} がありません"
  done
  # 参照する文書（SKILL.md・設計書・README）は、意味を --help の「意味」に任せ、意味の言い回しを書き写さない
  for f in "$SKILLS/gh-pr-check/SKILL.md" "$BATS_TEST_DIRNAME/../docs/design.md" "$BATS_TEST_DIRNAME/../README.md"; do
    grep -q 'pr-feedback.sh --help' "$f" || fail "${f} に、意味は pr-feedback.sh --help を参照する、という文がありません"
    # 正本の言い回し、または改める前の古い言い方
    for stale in '時刻だけで決めた目安' '返事をしていないものがあるか' 'の最後のコメントの後に PR の作者が書' '持ち主の最後のコメント' \
      '対応が要るかの目印' 'needs_attention`[^。]*対応が要るか'; do
      if grep -qE "$stale" "$f"; then fail "${f} に、意味の言い回し「${stale}」が残っています（意味は pr-feedback.sh --help の1か所だけに書く）: $(grep -nE "$stale" "$f" | head -1 | cut -c1-120)"; fi
    done
  done
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "branch-update は、衝突を直すどの場面でも、両立できると判断した衝突も含めて、直す前に直し方の方針の確認を取る（設計書 §8・ADR 000237）" {
  # 両立できると判断した衝突を確かめずに直し、push の前の確認の時点で直したコミットが既にできていた（#237）
  # 文の言い回しに縛られないよう、箇条（見出しの語や選択肢の名前）で場所を決め、その中の要の語だけを確かめる
  f="$SKILLS/branch-update/SKILL.md"
  # 確認の手順は1つの節にまとめ、衝突を直す場面はどれもそこに従う（場面ごとに規則を書くと、抜ける場面が出る）
  conf="$(section "$f" "## 衝突の直し方の確認")"
  has "「## 衝突の直し方の確認」の節" "$conf" '両立できると判断した衝突も含めて' '直す前'
  has "手順1の pull" "$(grep -F 'git pull --no-rebase' <<<"$(step "$f" 1)")" '「衝突の直し方の確認」'
  has "手順2" "$(step "$f" 2)" '「衝突の直し方の確認」'
  has "手順3" "$(step "$f" 3)" '「衝突の直し方の確認」' '「直し方を変えるとき」'
  # 場面：pull・merge・手順3（push として進めたときの前の取り込みの分も）
  has "節の場面" "$conf" 'git pull --no-rebase' '`origin/<base>`' '`push` として進めた'
  # 箇条ごとの要の語
  bullet() { grep -e "^- \*\*$1\*\*" <<<"$conf"; }
  option() { grep -e "^ *- 「$1」：" <<<"$conf"; }
  has "箇条「読む」" "$(bullet 読む)" 'まだファイルを直さない'
  has "箇条「判断できない衝突を聞く」" "$(bullet 判断できない衝突を聞く)" 'AskUserQuestion' '先に' '「取り込みをやめる」' 'ほかの答えによらず'
  has "箇条「方針の確認」" "$(bullet 方針の確認)" 'AskUserQuestion' 'ほかの質問と混ぜない' '省いて' '「Other」' 'この確認に入れる'
  has "箇条「直す」" "$(bullet 直す)" '「判断できない衝突を聞く」' '「方針の確認」' '省かない' 'どの質問の「取り込みをやめる」' '直し終えたファイルも元に戻る' 'git checkout -m <ファイル>'
  has "箇条「コミットする」" "$(bullet コミットする)" 'git add' 'git rev-parse --git-path MERGE_MSG'
  has "選択肢「この方針で直す」" "$(option この方針で直す)" 'push はまだしない'
  has "選択肢「直し方を変える」" "$(option 直し方を変える)" '「判断できない衝突を聞く」' '「方針の確認」'
  has "選択肢「取り込みをやめる」" "$(option 取り込みをやめる | head -n 1)" 'git merge --abort' '「抜けたとき」'
  has "選択肢「この直し方に変える」" "$(option この直し方に変える)" 'テストとチェックをもう一度'
  has "選択肢「変えずに止める」" "$(option 変えずに止める | head -n 1)" '「抜けたとき」'
  # 判断できない衝突は先に聞き、方針の確認は後で取り、その後に直して、コミットする
  undecided="$(grep -n -m1 '^- \*\*判断できない衝突を聞く\*\*' <<<"$conf" | cut -d: -f1)"
  ask="$(grep -n -m1 '^- \*\*方針の確認\*\*' <<<"$conf" | cut -d: -f1)"
  fix="$(grep -n -m1 '^- \*\*直す\*\*' <<<"$conf" | cut -d: -f1)"
  add="$(grep -n -m1 '^- \*\*コミットする\*\*' <<<"$conf" | cut -d: -f1)"
  [ "$undecided" -lt "$ask" ] || fail "判断できない衝突を聞くのが、方針の確認より後にあります"
  [ "$ask" -lt "$fix" ] || fail "方針の確認が、直すより後にあります"
  [ "$fix" -lt "$add" ] || fail "直すのが、コミットするより後にあります"
  # 「両立」と書いた行に、確かめずに直す書き方が無い
  if grep '両立できる' "$f" | grep -v -e '方針' -e '確認'; then
    fail "両立できる衝突を、方針の確認を取らずに直す書き方があります"
  fi
  if grep '両立' "$f" | grep -e '確認せず' -e '確認を取らず' -e '確かめず' -e '聞かず' -e 'そのまま直す'; then
    fail "両立できる衝突を、確かめずに直す書き方があります"
  fi
  # 抜けたときは push・CI・キューの案内をせず、手元に残ったものを伝える。手順6はそこを参照する
  exits="$(awk '/^\*\*抜けたとき\*\*/ { on = 1 } on' <<<"$conf")"
  has "「抜けたとき」" "$(head -n 1 <<<"$exits")" 'push・CI・キュー' '伝えない'
  has "抜けたときの「取り込みをやめる」" "$(grep -e '^- 「取り込みをやめる」：' <<<"$exits")" '衝突したまま' 'fast-forward'
  stop_line="$(grep -e '^- 「変えずに止める」：' <<<"$exits")"
  has "抜けたときの「変えずに止める」" "$stop_line" 'push していない' 'そのときの状態で決まる'
  if grep -E 'push( するか)?から進む|取り込みから進む' <<<"$stop_line"; then
    fail "変えずに止めた後の次の動きを、決めつけて伝えています（次にすることはそのときの状態で決まる）"
  fi
  has "手順6" "$(step "$f" 6)" '「抜けたとき」'
  has "手順4（push の前の確認）" "$(step "$f" 4)" '直し方を変えたなら' '`push` として進めた' '方針や前の取り込みの直し方から変えたところ'
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "branch-update は、無人で直すとき、確認を指示役の判断に置き換え、決められなければ Issue にコメントして保留の列に移して止まる（ADR 000285）" {
  f="$SKILLS/branch-update/SKILL.md"
  un="$(section "$f" "## 無人で直すとき")"
  has "「## 無人で直すとき」の節" "$un" 'AskUserQuestion は使わない' '強制 push をしない' '--force-with-lease' 'マージはしない' 'キューに入れ直さない' \
    'コンフリクトだけ' '信用できない入力'
  # 次にすることは repair-next.sh が決め、SKILL.md には action ごとにすることだけを書く
  nx="$(sed -n '/^### 次にすることの決め方/,/^### 衝突の直し方/p' <<<"$un")"
  has "次にすることの決め方" "$nx" 'repair-next.sh' '`plan.fallback` は使わない' 'キューから外れたとき' '`confirm`・`infer`' '`unconfirmed`' \
    '"dirty":<branch-status.sh の dirty>' '`push_check_ok` は null に戻す' '`push_check_ok` を null に戻す' 'repair-push-check.sh --base-branch <base>' '通常の `git push origin' '値を組み合わせて決め直さない'
  for a in finish recheck pull merge checks fix push_check push stop; do
    grep -qF "| \`$a\` |" <<<"$nx" || fail "repair-next.sh の action「${a}」のすることが表にありません"
  done
  has "衝突の直し方" "$(sed -n '/^### 衝突の直し方/,/^### PR のコメント/p' <<<"$un")" \
    '指示役が次のとおりに決める' '止まる衝突' '`repair-push-check.sh` が止めるパス' '正本は `repair-push-check.sh --help`' '同じ範囲'
  has "PR のコメント" "$(sed -n '/^### PR のコメント/,/^### 止まる/p' <<<"$un")" '<!-- dev-workflow:repair-run head=<head の sha> -->' 'git rev-parse origin/<ブランチ>' 'refs/remotes/origin/<ブランチ>' 'gh pr view <PR番号> --json headRefOid' 'scripts/repair-run-count.sh' "gh api --paginate --slurp 'repos/{owner}/{repo}/issues/<PR番号>/comments?per_page=100'" '全部を返さないことがあり' 'PR の head が `head` の sha から進んだもの' '数えない' '代わりに決めたこと' 'issues/comments/<ID>' '-X PATCH' '`--edit-last` は使わない' '追記する'
  has "止まる" "$(sed -n '/^### 止まる$/,/^### 結果を返す/p' <<<"$un")" \
    'git merge --abort' 'auto-hold.sh --issue <番号> --run-id <実行の id> --reason-file <ファイル> --repair-reason <理由の種類>' '`reason`（`dirty`・`same_failure`・`forbidden_paths` など）をそのまま渡し' '`other` を渡す' '本文には書かない' 'push はしない'
  # repair-run の head は、push 前の origin の head から取る。gh の headRefOid は、origin/<ブランチ> が無いときの1か所だけで使う
  # 1つのコマンド（--json headRefOid --jq .headRefOid）を1か所と数える
  [ "$(grep -o 'json headRefOid' <<<"$un" | wc -l | tr -d ' ')" = 1 ] || fail "無人の節で headRefOid を使う箇所が1か所ではありません"
  [ "$(grep -c 'headRefOid' <<<"$un")" = 1 ] || fail "無人の節で headRefOid を書いた行が1行ではありません"
  line="$(grep -F 'headRefOid' <<<"$un")"
  sentence="$(grep -F 'headRefOid' <<<"${line//。/$'\n'}")"
  grep -qF '`origin/<ブランチ>` が無い' <<<"$sentence" || fail "headRefOid を使う文に、origin にブランチが無いときの条件がありません: $sentence"
  # 無人で GitHub に書き込まない／resolve しない
  ! grep -q 'resolveReviewThread' <<<"$un" || fail "無人の節で resolveReviewThread を呼ぶ手順があります"
  # description で、無人の使い方に触れている
  frontmatter "$f" | grep -q '無人で直す' || fail "branch-update の description に、無人で直す使い方がありません"
  [ -x "$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts/repair-push-check.sh" ] || fail "repair-push-check.sh が実行できません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "branch-update は、push しなかったどの出口でも、push・CI・キューへの入れ直しの案内をせず、止めた理由と手元に残ったものを伝える" {
  # push しなかった出口でも、手順6が push・CI・キューへの入れ直しの案内を伝えていた（#242）
  f="$SKILLS/branch-update/SKILL.md"
  s6="$(step "$f" 6)"
  nopush="$(awk '/^\*\*push しなかったとき\*\*/ { on = 1 } /^\*\*push したとき\*\*/ { exit } on' <<<"$s6")"
  pushed="$(awk '/^\*\*push したとき\*\*/ { on = 1 } on' <<<"$s6")"
  has "手順6の「push しなかったとき」" "$(head -n 1 <<<"$nopush")" 'どこで止めたときも' 'push・CI・キュー' '伝えない' '止めた理由' 'push していないコミット' \
    '`branch-status.sh` を実行し直して' '`push_commits` をそのまま見せる' '範囲を自分で組み立てない' '箇条で言い切らない'
  # 出口ごとに添えること
  has "手順6の「push しなかったとき」の出口" "$nopush" '取り込む前の確認で止めた' '`ask_base`' '`recheck`' '取り込み（pull・merge）が衝突以外で失敗した' '手順3で直せなかった' '「push しない」' 'push が拒否された' '「抜けたとき」'
  # 手元に何があるかは一覧で示し、出口ごとの箇条では言い切らない（どこまで進めてから止めたかで変わる）
  # （言い回しに縛られないよう、「手元・取り込みは〜していない」「取り込み・自分・pull・main のコミットが〜ある・残る」
  #   「コミットが手元にある・残る」「手元には何も残っていない」の形で探す。push が拒否されたときの
  #   「手元に無いコミットがある」は origin の状態なので、コミットの前に「無い」が来る形は探さない）
  if grep -e '^- ' <<<"$nopush" \
    | grep -E '(手元|取り込み)[^。、]*(は[^。、]*していない|変えていない)|(取り込み|自分|pull|main) ?の?コミットが[^。、]*(ある|残)|コミットが手元に(ある|残)|手元には?何も(残|無|な)'; then
    fail "出口ごとの箇条で、手元に何があるかを言い切っています（push_commits の一覧で示す）"
  fi
  # キューへの入れ直しの案内は、push したときだけ
  has "手順6の「push したとき」" "$pushed" 'もう一度キューに入れてください'
  if grep -F 'キューに入れてください' <<<"$nopush"; then
    fail "push しなかったときに、キューへの入れ直しを案内しています"
  fi
  # push せずに止める出口は、どれも手順6の「push しなかったとき」に従う
  has "手順1（取り込む前の確認・ask_base・recheck で止めたとき）" "$(step "$f" 1)" '「push しなかったとき」'
  # 衝突以外で失敗したときの扱いは、pull と merge のどちらも、手順1の終わりの1か所の規則に従う
  has "手順1（取り込みが衝突以外で失敗したとき）" "$(grep -F '衝突以外で失敗したら' <<<"$(step "$f" 1)")" '`git pull --no-rebase`' '`git merge`' '「push しなかったとき」'
  has "手順2（衝突以外で失敗したとき）" "$(step "$f" 2)" '手順1の終わりのとおり'
  has "手順3" "$(step "$f" 3)" '「push しなかったとき」'
  has "手順5" "$(step "$f" 5)" '「push しなかったとき」'
  conf="$(section "$f" "## 衝突の直し方の確認")"
  has "「抜けたとき」" "$(grep -e '^\*\*抜けたとき\*\*' <<<"$conf")" '「push しなかったとき」'
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "branch-update は、push の前の確認で、push で入るコミットの分け方を、branch-status.sh の push_commits に任せる" {
  # 控える sha が手順2の merge の前なので、pull で作った取り込みのコミットが自分のコミットに数えられていた。
  # 範囲を SKILL.md の文章で組み立てると、初回の push などで数え違える（#242）。分け方は branch-status.bats で確かめる
  f="$SKILLS/branch-update/SKILL.md"
  # pull の前の sha は、pull の直前（未コミットの変更をコミットした後）に控える
  # pull の箇条は、控えるかを「控える sha」の規則に任せ、自分では控えると書かない（push として進めるときは控えない）
  has "手順1の pull" "$(grep -F 'git pull --no-rebase' <<<"$(step "$f" 1)")" '「控える sha」に従う'
  if grep -F 'git pull --no-rebase' <<<"$(step "$f" 1)" | sed 's/控えるかは//g; s/「控える sha」//g' | grep -F '控え'; then
    fail "pull の箇条が、規則とは別に sha を控えると書いています（push として進めるときも控えてしまう）"
  fi
  # 控える sha は1か所の規則にまとめ、手順4・6はそれに従う（手順ごとに書くと、控え直しや片方だけ渡すことが起きる）
  # 見出しの行から、箇条の終わり（2つ目の空行）まで
  sha_rule="$(awk '/^控える sha/ { on = 1 } on && /^$/ && n++ > 0 { exit } on' <<<"$(step "$f" 1)")"
  has "手順1の「控える sha」" "$sha_rule" '`merge` として進めるときだけ' '`push` として進めるときは' '手順2より前' '1回だけ' 'pull を実行する直前に' 'コミットした後で' \
    '手順2の後に pull するとき' '控えない' 'そのまま渡す' '`--merged-from`' '`--pulled-from`' '控えていないものは付けない'
  has "手順2" "$(step "$f" 2)" '「控える sha」'
  has "手順6" "$(step "$f" 6)" '「控える sha」'
  s4="$(step "$f" 4)"
  has "手順4" "$s4" '「控える sha」' '--merged-from <merge の前の sha>' '--pulled-from <pull の前の sha>' '`push_commits.all`' '`push_commits.first_push`' '`main`' '`pull`' '`own`' '数え直さない'
  # 取り直した unpulled が 1 以上なら、push の確認をせずに、pull するかの確認に戻る
  has "手順4（unpulled）" "$(grep -F '`unpulled` が 1 以上なら' <<<"$s4")" 'push の確認はせずに' 'この pull の前の sha は控えない' '`push_commits` の `main` に入る'
  # 範囲は SKILL.md のどこでも組み立てない（手順6の手元に残ったものも push_commits で示す）
  if grep -nE 'git log --oneline [^`]*\.\.' "$f"; then
    fail "コミットの範囲を、SKILL.md の文章で組み立てています（branch-status.sh の push_commits を使う）"
  fi
}

# shellcheck disable=SC2016 # バッククォートは文書の文字で、展開させない
@test "スキルと観点がコミットの一覧を出す git log には、署名の表示を止める --no-show-signature を付ける" {
  # log.showSignature を有効にした利用者では、gpg の行が一覧に混ざる（#242 のレビュー）
  root="$BATS_TEST_DIRNAME/../plugins/dev-workflow"
  # 文書では、引数が続く git log（バッククォートの中でも、コードブロックの中でも。引数の無い `git log` は、
  # コマンドの名前として挙げたもの）。引数は1行に書き、続きの行に分けない
  if grep -rn --include='*.md' -E 'git( -[cC] [^ ]+| --[a-z-]+)* log [-<a-zA-Z]' "$root" | grep -v -e '--no-show-signature'; then
    fail "スキルや観点の git log に --no-show-signature がありません"
  fi
  # スクリプトでは、コメントを除いた git log の呼び出し（git と log の間のオプションも許す。.bash も含める）
  if grep -rn --include='*.sh' --include='*.bash' -E '\bgit( -[cC] [^ ]+| --[a-z-]+)* log\b' "$root" \
    | grep -v -E '^[^:]+:[0-9]+: *#' | grep -v -e '--no-show-signature'; then
    fail "スクリプトの git log に --no-show-signature がありません"
  fi
}

@test "pr-create と task-finish は gh-pr-check に依存しない（使わなくてもマージから後片付けまで進める）" {
  for name in pr-create task-finish; do
    if grep -n 'gh-pr-check' "$SKILLS/$name/SKILL.md"; then
      fail "${name} が gh-pr-check に触れています（gh-pr-check は任意の寄り道）"
    fi
  done
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "review は、設定 review.model があるときだけ、観点と /code-review をそのモデルのサブエージェントで動かす（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step3="$(step "$f" 3)"
  grep -q 'の `model` が null でなければ、Agent ツールの `model` にその値を渡す' <<<"$step3" \
    || fail "手順3に、観点のサブエージェントへ model を渡すことが書かれていません"
  grep -q '「`/code-review` を任せるサブエージェントへの指示」' <<<"$step3" \
    || fail "手順3に、/code-review をサブエージェントに任せることが書かれていません"
  grep -q 'null なら、手順3はセッションと同じモデルで動かす' "$f" \
    || fail "設定が null のときにセッションと同じモデルで動かすことが書かれていません"
  step8="$(step "$f" 8)"
  grep -q '手順3のとおりサブエージェントに任せる' <<<"$step8" \
    || fail "再レビュー（手順8）でも /code-review をサブエージェントに任せることが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "review は、設定 review.code_review_effort があるときだけ、1周目と再レビューの /code-review にその段階を渡す（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step3="$(step "$f" 3)"
  [ -n "$step3" ] || fail "手順3が見つかりません"
  # 段階の付け方の決まりは、手順3の1か所（「`/code-review` に渡す引数」）だけに書く
  rule="$(grep -F '`<段階> <対象>`' "$f" || true)"
  [ "$(grep -c . <<<"$rule")" -eq 1 ] || fail "段階の付け方（<段階> <対象>）を書いた行が1つではありません: ${rule}"
  grep -qF -e "$rule" <<<"$step3" || fail "段階の付け方の決まりが、手順3にありません: ${rule}"
  has "段階の付け方の決まり" "$rule" '`context` の `code_review_effort` が null でなければ' 'null なら `<対象>` だけ'
  target="$(grep -F '`<対象>` は' <<<"$step3" || true)"
  has "<対象> の決まり" "$target" '1周目は今のブランチ名' '再レビューは反映したコミットの sha' '何も反映していない'
  grep -qE '何も反映していない.*今のブランチ名' <<<"$target" || fail "再レビューで反映が無いときの <対象> がブランチ名だと書かれていません: ${target}"
  # 指示のブロックは、<引数> を決まりで決めた値に置き換えて含める（文字どおり渡さない）
  use="$(grep -F '「`/code-review` を任せるサブエージェントへの指示」を' <<<"$step3" || true)"
  has "指示のブロックを含める文" "$use" '`<引数>`' '置き換え'
  ! grep -nF '指示」をそのまま含める' <<<"$step3" || fail "指示のブロックを、<引数> を置き換えずにそのまま含めるとしています"
  # 指示のブロックのプレースホルダは、決まりで決めた <引数> の1つだけにし、角括弧の書き方を使わない
  grep -qF 'Skill ツールの code-review を、引数 <引数> で実行する。' <<<"$step3" \
    || fail "/code-review を任せるサブエージェントへの指示が、引数 <引数> で実行する形になっていません"
  ! grep -nF '[<段階>' "$f" || fail "段階を角括弧の書き方で書いています"
  # 手順1・手順8は決まりを参照するだけにし、書き写さない
  for n in 1 8; do
    body="$(step "$f" "$n")"
    grep -qF '「`/code-review` に渡す引数」' <<<"$body" || fail "手順${n}が、手順3の「/code-review に渡す引数」を参照していません"
    ! grep -nF '<段階>' <<<"$body" || fail "手順${n}に、段階の付け方を書き写しています"
  done
  ! grep -nF '引数の先頭にその段階を付ける' "$f" || fail "段階の付け方を書き写した文が残っています"
}

@test "repo-setup は、レビューに使うモデルを決めていなければ、使うかと保存する層を聞き、使わないことも保存する" {
  f="$SKILLS/repo-setup/SKILL.md"
  step2="$(step "$f" 2)"
  grep -q 'review.decided' <<<"$step2" || fail "手順2に、決めてあれば聞かないことが書かれていません"
  grep -q -- '--review-model off' <<<"$step2" || fail "手順2に、使わないことも保存することが書かれていません"
  grep -q -- '--models-scope' <<<"$step2" || fail "手順2に、保存する層を渡すことが書かれていません"
  grep -q 'models.actions' "$f" || fail "手順3の予定に、レビューのモデルの変更が入っていません"
}

@test "task-start は、ワークツリーを作って着手したら結果を伝えた後に止まらず実装に続け、決まらないときは AskUserQuestion で聞く（#239）" {
  s7="$(step "$SKILLS/task-start/SKILL.md" 7)"
  # shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
  has "手順7" "$s7" '止まらず、そのまま同じワークツリーで Issue の「やること」の作業（実装）に取りかかる' 'AskUserQuestion で聞いてから進める' 'ワークツリーを作らずに着手したとき（`worktree` が `null`）'
  # task-auto は手順7の続行をしない（実装は作業役に任せる）
  grep -qF 'task-start 手順7の、結果を伝えた後に実装へ続ける動きは、ここでは行わない' "$SKILLS/task-auto/SKILL.md" || fail "task-auto が手順7の続行を行わないと書かれていません"
}

@test "task-start は、既にブランチがあって --no-worktree が止まったら、そのワークツリーで作業するよう案内する" {
  grep -q '「Issue #N には既にブランチ … があります」で止まったら' "$SKILLS/task-start/SKILL.md"
}

@test "「変更するファイル・領域」の書き方に、ファイルを変えないタスクの「なし」がある（task-create・Issue テンプレート・task-start）" {
  grep -q 'リポジトリのファイルを変えないタスクなら「- なし」と書く' "$SKILLS/task-create/SKILL.md"
  for f in "$BATS_TEST_DIRNAME/../plugins/dev-workflow/templates/ISSUE_TEMPLATE/task.md" "$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/task.md"; do
    grep -q 'リポジトリのファイルを変えないタスクなら「なし」と書きます' "$f" || fail "$f に「なし」の書き方がありません"
  done
  grep -q '「変更するファイル・領域」が「- なし」なら、変えないタスクとして書かれている' "$SKILLS/task-start/SKILL.md"
}

@test "README に、ワークツリーの要らないタスクの流れと、task-finish にブランチ名を渡せることが書いてある" {
  readme="$BATS_TEST_DIRNAME/../README.md"
  grep -q 'リポジトリのファイルを変えないタスクの流れ（ワークツリーを作らずに着手し' "$readme" || fail "タスクの進め方に、ワークツリーの要らない流れがありません"
  # shellcheck disable=SC2016 # バッククォートは README の文字で、展開させない
  grep -q '`task-finish` は、`/dev-workflow:task-finish fix-typo` のように、番号の代わりにブランチ名も渡せます' "$readme" || fail "引数の説明に、task-finish のブランチ名がありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "review は、独自の観点をプラグインの agent（ファイルを編集するツールを持たない）でレビューする（設計書 §7）" {
  [ -f "$AGENT" ] || fail "agents/perspective-reviewer.md がありません"
  assert_equal "$(frontmatter "$AGENT" | sed -n 's/^name: //p')" "perspective-reviewer"
  tools="$(frontmatter "$AGENT" | sed -n 's/^tools: //p')"
  assert_equal "$tools" "Read, Grep, Glob, Bash"
  rule="$(grep '1つずつ実行し' "$AGENT")" || fail "agent の定義に、Bash のコマンドを1つずつ実行する決まりがありません（つなぐと承認されないことがある）"
  for w in '`cd`' '`&&`' '`;`' '`|`'; do
    grep -qF "$w" <<<"$rule" || fail "agent の、Bash のコマンドを1つずつ実行する決まりに ${w} がありません"
  done
  grep -q '観点ファイルがつないだコマンド.*1つずつに分けて' "$AGENT" \
    || fail "agent の定義に、観点ファイルがつないだコマンドを指示したときの扱いがありません"
  grep -q '1つずつのコマンドで確かめられなければ.*`notes`' "$AGENT" \
    || fail "agent の定義に、分けて確かめられないときに notes に書くことがありません"

  f="$SKILLS/review/SKILL.md"
  step3="$(step "$f" 3)"
  grep -q 'subagent_type.*dev-workflow:perspective-reviewer' <<<"$step3" \
    || fail "手順3に、独自の観点を subagent_type で agent に任せることが書かれていません"
  step8="$(step "$f" 8)"
  grep -q 'dev-workflow:perspective-reviewer' <<<"$step8" \
    || fail "再レビュー（手順8）で、独自の観点を agent で起動することが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "perspective-reviewer は findings と notes の1つの形で返し、review はどの部分も捨てずに読んで、伝言を手順4・5・7・8で伝える（設計書 §7）" {
  grep -q '{"findings": ' "$AGENT" || fail "agent の定義に、findings と notes の形がありません"
  grep -q '"suggestion"' "$AGENT" || fail "agent の定義に、指摘の項目（file・line・summary・detail・suggestion）がありません"
  grep -q '`notes`' "$AGENT" || fail "agent の定義に、notes の説明がありません"
  grep -q '問題は `notes` に書かない' "$AGENT" \
    || fail "agent の定義に、問題を notes に入れない決まりがありません（伝言は番号が付かず選べない）"
  grep -q 'とだけ返す」と決めていても' "$AGENT" \
    || fail "agent の定義に、観点ファイルが返し方を決めていても形を変えない決まりがありません"
  f="$SKILLS/review/SKILL.md"
  if grep -n '"suggestion"' "$f"; then
    fail "review の SKILL.md に、返す JSON の形式が残っています（agent の定義だけに書く）"
  fi
  step3="$(step "$f" 3)"
  grep -q '囲まれていたり、前置き' <<<"$step3" \
    || fail "手順3に、囲みや前置きがあっても返事の JSON を読むことが書かれていません"
  grep -q '包まれていない配列.*`file` と `summary` を持つときだけ' <<<"$step3" \
    || fail "手順3に、包まれていない配列を、指摘の形のときだけ読むことが書かれていません"
  grep -q '配列の各項目を、手順4の一覧' <<<"$step3" \
    || fail "手順3に、findings を一覧の指摘にすることが書かれていません"
  grep -q '`notes` と、指摘として読まなかった部分.*伝言' <<<"$step3" \
    || fail "手順3に、notes と指摘として読まなかった部分を伝言にすることが書かれていません"
  grep -q '読めない返事は、指摘にはせず' <<<"$step3" \
    || fail "手順3に、オブジェクトを読めない返事の扱いが書かれていません"
  grep -q '伝言は、観点の名前を添えて' <<<"$step3" \
    || fail "手順3に、伝言の伝え方（観点の名前を添える）が書かれていません"
  step4="$(step "$f" 4)"
  grep -q '^- 指摘が1つも無ければ.*観点からの伝言' <<<"$step4" \
    || fail "手順4の、指摘が無いときに伝えることに、観点からの伝言が入っていません"
  grep -q '^- 表の後に.*観点からの伝言' <<<"$step4" \
    || fail "手順4の、表の後に添えることに、観点からの伝言が入っていません"
  step5="$(step "$f" 5)"
  grep -q '観点からの伝言.*質問の中にも入れる' <<<"$step5" \
    || fail "手順5に、観点からの伝言を質問の中に入れることが書かれていません"
  step7="$(step "$f" 7)"
  grep -q 'これまでの周の観点からの伝言' <<<"$step7" \
    || fail "手順7に、観点からの伝言を改めて伝えることが書かれていません"
  grep -q '前の周の伝言は.*どの手順から手順9へ進むときも' <<<"$step3" \
    || fail "手順3に、レビューを終えるときに前の周の伝言もまとめて伝えることが書かれていません"
  step8="$(step "$f" 8)"
  grep -q '^1\. \*\*今の周が上限に達していて.*これまでの周の観点からの伝言' <<<"$step8" \
    || fail "手順8の上限の周の質問に、観点からの伝言が入っていません"
  grep -q '^- 新しい指摘が無ければ.*手順4' <<<"$step8" \
    || fail "手順8の、新しい指摘が無いときに、手順4のとおり伝えることが書かれていません"
}

@test "観点ファイルは結果の形を書かず、review-perspective-add は結果の形を決める agent を案内する（設計書 §7）" {
  # 結果の形（findings と notes）は agent perspective-reviewer が決める。観点ファイルが返し方を書くと、agent の決まりと食い違う
  # 「[] を返す」「JSON で返す」「とだけ返す」は拾い、「gh が返す JSON」のような文は拾わない
  if grep -nE '(を|で|と|だけ)返す' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/"*.md; then
    fail "同梱の観点ファイルに、返し方が書かれています（「〜と伝える」と書けば notes で伝わる）"
  fi
  grep -q 'agents/perspective-reviewer.md' "$SKILLS/review-perspective-add/SKILL.md" \
    || fail "review-perspective-add に、結果の形を決めるのが agent perspective-reviewer だと書かれていません"
}

@test "task-create は、分け方の提案でも呼ばれ、起票を頼まれていなければ起票せずに止められる（#169）" {
  f="$SKILLS/task-create/SKILL.md"
  frontmatter "$f" | grep -qF 'Issue の分け方・親子の構成を提案するときに使う' || fail "description に分け方の提案が書かれていません"
  # 相談のときの違いは1つの節にまとめ、手順の中に書き分けない（書き分けると、手順の間の継ぎ目が抜けるため）
  consult="$(section "$f" "## 起票を頼まれていない相談で呼ばれたとき")"
  [ -n "$consult" ] || fail "相談で呼ばれたときの節がありません"
  # 導入していないリポジトリでは使わずに止まる。導入したかは config.sh の set_up で読む（設定ファイルを自分で探さない。#244）
  grep -qF 'config.sh .set_up' <<<"$consult" || fail "相談の節に、導入したかを config.sh .set_up で確かめることが書かれていません"
  # shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
  grep -qF '`false`' <<<"$consult" && grep -qF 'このスキルを使わずに止め' <<<"$consult" || fail "相談の節に、導入していなければ使わずに止まることが書かれていません"
  grep -qF '設定ファイルを自分で探さない' <<<"$consult" || fail "相談の節に、設定ファイルを自分で探さないことが書かれていません"
  grep -qF '手順1〜3は起票を頼まれたときと同じに進める' <<<"$consult" || fail "相談の節に、手順は起票と同じに進めることが書かれていません"
  grep -qF 'ラベルと説明を「起票する」ではなく「下書きする」と書く' <<<"$consult" || fail "相談の節に、選択肢の書き方がありません"
  grep -qF '「このまま設定する」は「この値で下書きする」と書く' <<<"$consult" || fail "相談の節に、分割の提案の選択肢の書き方がありません"
  grep -qF '「起票しない（提案だけにする）」を足し、選ばれたら起票せずに止める' <<<"$consult" || fail "相談の節に、提案だけで止めることが書かれていません"
  for n in 1 2 3 4; do
    if step "$f" "$n" | grep -n '相談'; then
      fail "手順${n}に、相談のときの書き分けがあります（相談の節にまとめる）"
    fi
  done
  # 分け方の案は、相談・親と子をまとめて起票する依頼・独立した作業を含む依頼でだけ下書きする（SP が大きいだけなら手順3の分割の提案）
  draft="$(step "$f" 2 '^#### 親と子をまとめて')"
  grep -qF '分け方の提案を頼まれたときと、親と子をまとめて起票する依頼か、独立して着手できる作業をいくつも含む依頼で' <<<"$draft" \
    || fail "下書きの項目に、分け方の案を下書きする場合が書かれていません"
  grep -qF '1本に収まる普通の依頼は、分け方を聞かずに1つの Issue として下書きする' <<<"$draft" || fail "下書きの項目に、普通の依頼では分け方を聞かないことが書かれていません"
  grep -qF 'Story Point が 21 以上になりそうなだけのときは、ここでは分けず、手順3の分割の提案に任せる' <<<"$draft" || fail "下書きの項目に、SP が大きいだけのときの扱いが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "ADR にすべき判断の基準は adr-create の1か所にあり、task-create・pr-create はそこを読んで提案する（設計書 §8）" {
  adr="$SKILLS/adr-create/SKILL.md"
  grep -q '^## ADR にすべき判断$' "$adr" || fail "adr-create に基準の節がありません"
  grep -q '^## ADR の作成の提案（task-create・pr-create）$' "$adr" || fail "adr-create に提案の決まりの節がありません"
  # 断った記録の形は、正本と pr-create で同じにする
  grep -qF -- '- [ ] ~~<判断の短い説明>を ADR に残す~~（不要）' "$adr" || fail "adr-create に断った記録の形がありません"
  grep -qF -- '--add-task "~~<判断の短い説明>を ADR に残す~~（不要）"' "$SKILLS/pr-create/SKILL.md" || fail "pr-create が断った記録を足しません"
  for s in task-create pr-create; do
    f="$SKILLS/$s/SKILL.md"
    grep -q 'skills/adr-create/SKILL.md` の「ADR にすべき判断」と「ADR の作成の提案」の節' "$f" || fail "$s が基準の正本を読みません"
    grep -q 'adr-list.sh' "$f" || fail "$s が adr-list.sh で設定を確かめません"
    grep -q '同じ質問の中で' "$f" || fail "$s が提案を確認の質問の中で行いません"
  done
  # 基準を写さない（正本は1か所）
  for s in task-create pr-create; do
    run grep -c '元に戻しにくい判断：' "$SKILLS/$s/SKILL.md"
    assert_output 0
  done
  # 提案するかの状態の組み合わせは adr-list.sh の proposal で決め、pr-create はその値ごとにすることだけを書く
  for v in disabled exists pending "done" declined judge; do
    grep -q "| \`$v\` |" "$SKILLS/adr-create/SKILL.md" || fail "adr-create に proposal の $v がありません"
  done
  grep -q '出力の `proposal` に従う' "$SKILLS/pr-create/SKILL.md" || fail "pr-create が proposal に従いません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "adr-create は、採択した ADR を書き換えないことと、一部だけ変える ADR の補足に関係を書くことを書く（設計書 §8）" {
  adr="$SKILLS/adr-create/SKILL.md"
  grep -qF '書き終えた ADR の本文は、後から書き換えない' "$adr" || fail "adr-create に、ADR を書き換えないことがありません"
  grep -qF '「補足」に、その ADR へのリンクと、何を変えるかを書く（MADR の判断 0009）' "$adr" || fail "adr-create に、一部だけ変える ADR の補足の決まりがありません"
  grep -qF '全部を覆すなら `--supersedes` で置き換える' "$adr" || fail "adr-create に、全部を覆すときは置き換えることがありません"
  grep -qF '書き終えた ADR の本文は、後から書き換えない' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書に、書き換えないことがありません"
  grep -qF '関係を新しい ADR の「補足」に書く' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書に、補足に関係を書くことがありません"
  grep -qF '「補足」に、その ADR へのリンクと、何を変えるかを書きます（MADR の判断 0009）' "$BATS_TEST_DIRNAME/../README.md" || fail "README に、補足に関係を書くことがありません"
  tr="$BATS_TEST_DIRNAME/../plugins/dev-workflow/templates/adr/README.md"
  grep -qF '`date` は、MADR では「判断を最後に更新した日」ですが、書き換えないので、判断をした日にします' "$tr" || fail "テンプレートの README に date の扱いがありません"
  grep -qF '書き終えた ADR の本文は、後から書き換えません' "$tr" || fail "テンプレートの README に、編集しないことがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "proposed の ADR を採択するときは、status を accepted に、date を採択した日に書き換え、それだけを例外にする（#311・ADR 000338）" {
  adr="$SKILLS/adr-create/SKILL.md"
  has "adr-create の手順3" "$(step "$adr" 3)" \
    '`proposed` の ADR を採択するときは、`status` を `accepted` に書き換え、`date` を採択した日に更新する' \
    '例外は、置き換えたときの status の行と、`proposed` の ADR を採択するときの `status` と `date` の2つの行だけ' \
    'ADR を書き換えない決まりの例外は、置き換えたときの status の行のほかは、この2つの行の書き換えだけで、ほかの行は書き換えない'
  has "adr-create の手順4" "$(step "$adr" 4)" '後で採択するときは、手順3のとおり `status` と `date` の行だけを書き換える'
  grep -qF '`proposed` の ADR を採択するときは、`status` を `accepted` に書き換え、`date` を採択した日に更新する**' "$BATS_TEST_DIRNAME/../docs/design.md" \
    || fail "設計書に、採択するときの status と date の扱いがありません"
  grep -qF '例外は、置き換えたときの `status` の行（`superseded by <新しい ADR>` にする。`adr-create.sh --supersedes`）と、下の `proposed` の ADR を採択するときの `status` と `date` の2つの行だけにする' \
    "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書に、書き換えない決まりの例外がありません"
  grep -qF '例外は、置き換えたときの `status` の行（`superseded by <新しい ADR>` にします）と、`proposed` の ADR を採択するときの `status` と `date` の2つの行だけです' \
    "$BATS_TEST_DIRNAME/../README.md" || fail "README に、書き換えない決まりの例外がありません"
  grep -qF 'これを ADR を書き換えない決まりの例外にする' "$BATS_TEST_DIRNAME/../docs/adr/000338-adopt-proposed-adr-in-place.md" \
    || fail "ADR 000338 に、採択時の書き換えを例外とする判断がありません"
  grep -qF '`proposed` の ADR を採択するときは、`status` を `accepted` に書き換え、`date` を採択した日に更新します' \
    "$BATS_TEST_DIRNAME/../plugins/dev-workflow/templates/adr/README.md" || fail "テンプレートの README に、採択するときの扱いがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "adr-create の重複の確認は、adr-list.sh の cited_in_supplements で、近い ADR を一部だけ変えている ADR も読む（#310）" {
  adr="$SKILLS/adr-create/SKILL.md"
  has "adr-create の手順1" "$(step "$adr" 1)" '`cited_in_supplements`' '「補足」も読み' '一部だけ変えていないかを確かめる'
  grep -qF '`cited_in_supplements`' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書に、補足からの逆引きがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、auto-check.sh の action ごとにすることを書き、無効なら何もしない（設計書 §8・ADR 000267）" {
  f="$SKILLS/task-auto/SKILL.md"
  s1="$(step "$f" 1)"
  has "task-auto の手順1" "$s1" 'auto-check.sh --issue <番号>'
  for v in disabled no_hold not_startable hold proceed; do
    grep -qF -- "- \`$v\`：" <<<"$s1" || fail "task-auto の手順1に action の $v の扱いがありません"
  done
  # Issue は auto-check.sh が読んだものを使い、読み直さない（判定に使った本文と同じものであいまいかを判断する）
  grep -qF 'Issue を読み直さない' <<<"$s1" || fail "手順1に、auto-check.sh の issue を使うことが書かれていません"
  if grep -qF 'gh issue view' <<<"$s1"; then fail "手順1で Issue を読み直しています"; fi
  # 実行し直したときは、前の作業のブランチ（resume）を使い回す
  has "task-auto の手順2" "$(step "$f" 2)" '`resume` があれば' '--branch "<resume の branch>"' '名前を作り直さずに'
  # 無効なら、今のスキルで代わりに進めない（確認を取る今の振る舞いを変えない）
  grep -qF 'task-start など、ほかのスキルを代わりに始めない' <<<"$s1" || fail "無効のときに、ほかのスキルを始めないことが書かれていません"
  # 書き込まずに止まる action と、Issue に書いて止まる action を分ける
  grep -qF '`disabled`・`no_hold`・`not_startable` のとき（task-auto の手順1）は、この手順では止まらない（何も書き込まない）' "$f" \
    || fail "書き込まずに止まる action が書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、確認を取らずに止まる条件で止まり、理由を Issue にコメントして保留の列に移す（設計書 §8）" {
  f="$SKILLS/task-auto/SKILL.md"
  grep -qF '**AskUserQuestion は使わない**' "$f" || fail "AskUserQuestion を使わないことが書かれていません"
  stop="$(section "$f" '## 止まる')"
  has "止まる条件" "$stop" 'auto.max_fix_attempts' 'ADR にすべき判断' 'Issue があいまい' \
    '「確認の代わりに決めること」に無い確認' 'auto-hold.sh --issue <番号> --run-id <実行の id> --reason-file <ファイル>' \
    '止まった理由' 'それまでの判断' '残したもの' '続けるには' 'ワークツリーとブランチは消さない'
  # 実行の id の出どころは、「止まる」の節の1（作業役にコミットさせる）と取り違えないよう、task-auto の手順1と書く
  has "止まる条件" "$stop" '実行の id は、task-auto の手順1「進めるかを決める」で決めたもの。この節の1ではない'
  # breaking ラベルなど、スクリプトが決める条件は auto-check.sh に任せる
  has "止まる条件" "$stop" '`auto-check.sh` の `action` が `hold`'
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、今のスキルの確認に代わりに答える表を持ち、どのスキルの確認も扱う" {
  f="$SKILLS/task-auto/SKILL.md"
  table="$(section "$f" '## 確認の代わりに決めること')"
  for row in 'task-start 手順4' 'task-start 手順5' 'commit 手順2' 'review 手順5' 'review 手順6' 'review 手順8' 'review 手順9' \
    'task-create 手順2・3' 'pr-create 手順2・5' 'pr-create 手順5' '| どの場面でも |'; do
    grep -qF -- "$row" <<<"$table" || fail "確認の代わりに決めることの表に「${row}」がありません"
  done
  grep -qF 'この表に無い確認は、止まる' <<<"$table" || fail "表に無い確認で止まることが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、作業役に任せ、範囲外の指摘を上限まで起票し、自動で決めたことを書いた、draft でない PR を出す（マージしない）" {
  f="$SKILLS/task-auto/SKILL.md"
  has "task-auto の手順3" "$(step "$f" 3)" 'subagent_type' 'AskUserQuestion は使いません' '/dev-workflow:commit' \
    'GitHub に書き込む操作をしない' 'うのみにせず' 'max_fix_attempts' 'SendMessage'
  has "task-auto の手順4" "$(step "$f" 4)" '/dev-workflow:review' '範囲内の指摘はすべて反映する' 'この差分より前からある不具合' 'review の手順9：行わない'
  has "task-auto の手順5" "$(step "$f" 5)" '同じ内容の Issue があるかを探す' 'max_new_issues' 'Story Point・親・依存は付けない' 'issue-create.sh'
  s6="$(step "$f" 6)"
  has "task-auto の手順6" "$s6" '--no-draft --dry-run' '必ず `--no-draft` を付ける' '「自動で決めたこと」の節' '`pending` なら止まる' '`--add-task` は付けない'
  grep -qF 'マージはしない（`allow_ai_merge` にかかわらず）' "$f" || fail "マージしないことが書かれていません"
  # draft で出さない（PR の自動レビューの多くは draft をレビューしない。ADR 000280）。--draft の語そのものを手順6に書かない（--no-draft は許す）
  ! grep -qF -e '--draft' <<<"${s6//--no-draft/}" || fail "手順6に --draft が書かれています"
  grep -qF 'PR は draft にせず、レビューできる状態（オープン）で出す' "$f" || fail "draft にせず出すことが書かれていません"
  # 上限の周の指摘は、反映してコミットしたら止まらずに PR へ進み、未レビューの反映を本文に書く
  has "task-auto の手順4" "$(step "$f" 4)" 'もう1周せずに手順5・6へ進む。止まらない' '上限の周の反映（未レビュー）'
  has "task-auto の手順6" "$s6" '上限の周の反映（未レビュー）'
  stopcond="$(sed -n '/^次のどれかに当たったら/,/^止まるときは/p' "$f")"
  has "止まる条件の節" "$stopcond" 'auto-check.sh'
  ! grep -qF 'review.max_rounds' <<<"$stopcond" || fail "止まる条件に、上限の周の指摘が残っています"
  grep -qF '| review 手順8 | 上限の周でも指摘が出たら、もう1周するか | もう1周しない。範囲内の指摘を反映してコミットし、テストとチェックが通れば、止まらずに PR の作成（手順6）へ進む' "$f" \
    || fail "表の review 手順8が、PR の作成へ進むことになっていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、既にある下書きの PR を使うときは下書きのまま残し（gh pr ready を実行しない）、人に ready にするよう伝える（#282）" {
  f="$SKILLS/task-auto/SKILL.md"
  grep -qF '既にある下書きの PR を使うときは、下書きのまま残し、`gh pr ready` は実行しない' "$f" || fail "決まりにありません"
  table="$(section "$f" '## 確認の代わりに決めること')"
  grep -qF '下書きなら下書きのまま残し（`gh pr ready` は実行しない）、人に ready にするよう伝える' <<<"$table" \
    || fail "確認の代わりに決めることの表にありません"
  has "task-auto の手順6" "$(step "$f" 6)" '`created: false`' '`draft` が true なら' '下書きのまま残す。`gh pr ready` は実行しない' \
    '手順7で、人に ready にするよう伝える'
  has "task-auto の手順7" "$(step "$f" 7)" '`created` が false で `draft` が true' '下書きのまま残したこと' \
    '人が ready にする（`gh pr ready <PR番号>`）よう伝える'
  # ready にする手順を書かない（実行するのは人。手順7の案内の中の `gh pr ready <PR番号>` と、実行しないと書いた句だけを許す）。
  # 許した句を含む行をまるごと除くと、同じ行に足された別の実行の指示を見逃すので、句だけを取り除いてから探す
  rest="$(cat "$f")"
  rest="${rest//'`gh pr ready <PR番号>`'/}"
  rest="${rest//'`gh pr ready` は実行しない'/}"
  bad="$(grep -nF 'gh pr ready' <<<"$rest" || true)"
  [ -z "$bad" ] || fail "gh pr ready を実行する手順があります: $bad"
  grep -qF '下書きのまま残し、`gh pr ready` は実行しない' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書にありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、「起票した Issue：なし」と書く前と結果を伝えるときに、範囲外とした指摘の数と起票の内訳が合うかを確かめる（#307）" {
  f="$SKILLS/task-auto/SKILL.md"
  # 内訳の分け方と「内訳が合う」の定義は手順5の1か所にだけ書き、手順6・7と設計書はそれを参照する（書き写すと食い違うため）
  s5="$(step "$f" 5)"
  has "task-auto の手順5" "$s5" '分けられない指摘は、起票し忘れたもの' \
    '- 起票した（' '- 重複していたので起票しなかった' '- 破壊的変更になるので起票しなかった' '- 上限で起票しなかった' '- 起票に失敗した' \
    '**内訳が合う**とは、手順4のレビューのすべての周の一覧から、範囲外とした指摘（同じ指摘は1件）を数え直した数と、上で分けた数の合計が同じであること' \
    '最後の周の一覧だけでは数えない' 'この書き出しや覚えた記録の数ではなく、レビューの一覧から数え直して確かめる'
  # 「内訳が合う」の定義は1つだけ（書き出した数と比べる、という別の定義を書かない）
  ! grep -qF '分けた数の合計が範囲外とした指摘の数と同じなら' <<<"$s5" || fail "手順5に、内訳が合うの別の定義が残っています"
  [ "$(grep -cF '**内訳が合う**' <<<"$s5")" -eq 1 ] || fail "手順5に、内訳が合うの定義が1つではありません"
  # 書き出しは、すべての周の一覧から、起票の繰り返しより前に行う（起票を飛ばしたら、書き出しも飛ばしてしまわないように）
  before="$(step "$f" 5 '^1\. 開いている Issue を読み')"
  has "task-auto の手順5の起票の繰り返しの前" "$before" \
    '**範囲外の指摘の内訳**：起票を始める前に、task-auto の手順4のレビューのすべての周の一覧から、範囲外とした指摘（同じ指摘は1件と数える）の数と、1件ずつの要約'
  s6="$(step "$f" 6)" s7="$(step "$f" 7)"
  # 確かめるときは、手順5の記録どうしではなく、手順4のレビューのすべての周の一覧から数え直す（手順5を飛ばすと、空の記録どうしで合ってしまう）
  has "task-auto の手順6" "$s6" '「起票した Issue」を「なし」と書く前に、手順5の「範囲外の指摘の内訳」が合うか（手順5の「内訳が合う」のとおり、手順4のレビューのすべての周の一覧から数え直す）を確かめる' \
    '「なし」と書かずに、手順5に戻ってその指摘を起票してから本文を書く'
  has "task-auto の手順7" "$s7" '手順5の「範囲外の指摘の内訳」を伝え、内訳が合うこと（手順5の「内訳が合う」のとおり、手順4のレビューのすべての周の一覧から数え直す）を確かめて伝える' \
    '手順5に戻って起票し'
  design="$(grep -F '**範囲外の指摘の起票**' "$BATS_TEST_DIRNAME/../docs/design.md")"
  has "設計書の範囲外の指摘の起票" "$design" '分け方の正本は task-auto の SKILL.md の手順5「範囲外の指摘の内訳」' 'レビューのすべての周の一覧から範囲外とした指摘を数え直して'
  for s in "$s6" "$s7" "$design"; do
    for w in '破壊的変更' '起票の失敗' '起票に失敗'; do
      ! grep -qF "$w" <<<"$s" || fail "手順6・7か設計書に、内訳の分け方（${w}）を書き写しています: $(grep -F "$w" <<<"$s")"
    done
  done
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、範囲外の指摘をファイルに記録し、PR を作る前に auto-findings.sh で検査する（#378）" {
  f="$SKILLS/task-auto/SKILL.md"
  has "task-auto の手順5" "$(step "$f" 5)" '**範囲外の指摘の記録**' 'task-auto-<実行の id>-findings.json' '`filed`' '`duplicate`' '`breaking`' '`limit`' '`failed`' \
    '範囲外の指摘が1件も無ければ `[]` を書く'
  s6="$(step "$f" 6)"
  has "task-auto の手順6" "$s6" 'auto-findings.sh --file' '--expect <数え直した数>' '記録の件数ではなく、一覧から数え直した数にする' \
    '終了コードが 0 でなければ（2 のほか、記録のファイルが無い・引数の誤りの 64 も含む）、PR を作らずに手順5に戻る' '同じ要約の指摘の重複' '検査が通るまで、次へ進まない'
  # 検査は、pr-create の手順に従う前（PR を作る前）にある
  before="$(step "$f" 6 '^pr-create の手順1〜4に従い')"
  has "task-auto の手順6の pr-create の前" "$before" 'auto-findings.sh --file'
  ! grep -qF 'auto-findings.sh' <<<"$(section "$f" '## 確認の代わりに決めること')" || fail "確認の表に auto-findings.sh があります"
  grep -qF '`${CLAUDE_PLUGIN_ROOT}/scripts/auto-findings.sh`' "$f" || fail "スクリプトの一覧にありません"
  design="$BATS_TEST_DIRNAME/../docs/design.md"
  grep -qF '| `auto-findings.sh` |' "$design" || fail "設計書のスクリプトの表にありません"
  grep -qF '**範囲外の指摘の記録**（#378）' "$design" || fail "設計書に記録の説明がありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-auto は、手順7で後から起票した Issue を、自分で作った PR に限り、PR へのコメントで足す（本文は直さない。#378）" {
  f="$SKILLS/task-auto/SKILL.md"
  s7="$(step "$f" 7)"
  has "task-auto の手順7" "$s7" '手順6の出力の `created` が true' '`gh pr comment <PR番号> --body-file <ファイル>`' \
    '既にあった PR（`created` が false。人や前の実行が作ったもの）には、コメントしない' '本文は直さない' 'コメントできなかったら、止まらずに'
  grep -qF '手順7で後から起票した Issue を、task-auto が自分で作った PR に付けるコメント' "$f" || fail "GitHub に書き込むものに PR へのコメントがありません"
  grep -qF 'PR の本文は、作るとき以外は直さない' "$f" || fail "PR の本文を直さないことが書かれていません"
  # PR に書き込むのは、gh pr comment だけ（gh pr edit で本文を直す手順を書かない）
  ! grep -qF 'gh pr edit' "$f" || fail "task-auto が gh pr edit を使う手順があります"
  design="$BATS_TEST_DIRNAME/../docs/design.md"
  grep -qF 'task-auto が自分で作った PR へのコメント' "$design" || fail "設計書に、書き込むものへの追加がありません"
  grep -qF '**後から起票した Issue の PR への伝え方**（#378）' "$design" || fail "設計書にありません"
}

@test "スキルが直接実行するスクリプト（scripts/ と scripts/setup/ の .sh）は、git で実行権限が付いている（lib/ は読み込むだけなので除く）" {
  # bats はスクリプトを bash で起動するので、実行権限が無くても通ってしまう。スキルは ${CLAUDE_PLUGIN_ROOT}/scripts/… を
  # そのまま実行するので、権限が無いと Permission denied で止まる（task-auto の eval で見つかった）
  run git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- 'plugins/dev-workflow/scripts/*.sh' 'plugins/dev-workflow/scripts/setup/*.sh'
  assert_success
  [ -n "$output" ] || fail "スクリプトが見つかりません"
  bad="$(awk '$1 != "100755" && $4 !~ /\/lib\// { print $4 }' <<<"$output")"
  [ -z "$bad" ] || fail "実行権限がありません（git update-index --chmod=+x で付けてください）: ${bad}"
}

@test "branch-update・gh-pr-check・review は、テストとチェックのコマンドを checks-commands.sh で決める（設定 checks.commands）" {
  for name in branch-update gh-pr-check review; do
    f="$SKILLS/$name/SKILL.md"
    grep -q 'checks-commands.sh' "$f" || fail "${name} に、checks-commands.sh で実行するコマンドを決めることが書かれていません"
    grep -q 'checks.commands' "$f" || fail "${name} に、設定 checks.commands が書かれていません"
    grep -q -- '--save' "$f" || fail "${name} に、聞いた答えを設定に保存することが書かれていません"
    for word in action "\`run\`" "\`confirm\`" "\`none\`" "\`infer\`"; do
      grep -q -- "$word" "$f" || fail "${name} に、checks-commands.sh の action（${word}）に従うことが書かれていません"
    done
    grep -q '確認が取れるまで実行しない' "$f" || fail "${name} に、confirm のとき確認が取れるまで実行しないことが書かれていません"
  done
}

@test "task-finish・task-cancel・task-flow.md に、次のタスクの前に /clear を勧めることがある" {
  grep -q "次のタスクに着手する前に \`/clear\` するよう勧める" "$SKILLS/task-finish/SKILL.md" || fail "task-finish にありません"
  grep -q "次のタスクに着手する前に \`/clear\` するよう勧める" "$SKILLS/task-cancel/SKILL.md" || fail "task-cancel にありません"
  local flow="$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md"
  [ "$(grep -c "次のタスクに着手する前に \`/clear\` するよう勧めます" "$flow")" -ge 2 ] || fail "task-flow.md の後片付けと取りやめの両方にありません"
  grep -q "タスクの切れ目で \`/clear\` を勧める" "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書にありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "pr-create は、PR を出した後の案内を merge_queue で切り替える（キューがあればキューに入れ、無ければ branch-update で取り込む。#178）" {
  step7="$(step "$SKILLS/pr-create/SKILL.md" 7)"
  has "pr-create の手順7" "$step7" '出力の `merge_queue`' '- `true`：' '- `false`：' '- `null`'
  # マージ先は、設定の base_branch（base）ではなく、出力の pr_base（既にある PR は、マージ先を変えていることがある）
  has "pr-create の手順7" "$step7" '出力の `pr_base`' 'PR のマージ先'
  # 下書きの案内は、merge_queue の値の項目から切り離し、どの値でも添える
  draft_line="$(grep -F -- '出力の `draft` が true' <<<"$step7")"
  has "pr-create の手順7の下書きの案内" "$draft_line" '`merge_queue` の値にかかわらず' 'Ready for review' 'gh pr ready'
  # 既にある PR を使ったときの draft は、その PR の今の状態（--draft の指定ではない）
  has "pr-create の手順7の下書きの案内" "$draft_line" 'その PR の今の状態'
  if grep -E -- '^- `(true|false|null)' <<<"$step7" | grep -q -e 'gh pr ready' -e '下書き'; then
    fail "pr-create の手順7の下書きの案内が、merge_queue の値の項目の中にあります（どの値でも添える）"
  fi
  # キューがあるときは、キューに入れることと、取り込むのはコンフリクトしたときだけであることを案内する
  has "pr-create の手順7のキューがあるときの案内" "$(grep -F -- '- `true`：' <<<"$step7")" \
    'キューに入れる' 'Merge when ready' 'コンフリクトしたときだけ' 'branch-update' \
    'ルールセットが求めるもの' 'リポジトリによって違う'
  # キューが無いときは、マージ先が進んだら branch-update で取り込むことを案内する
  has "pr-create の手順7のキューが無いときの案内" "$(grep -F -- '- `false`：' <<<"$step7")" 'branch-update'
  if grep -F -- '- `false`：' <<<"$step7" | grep -q 'キュー'; then
    fail "pr-create の手順7のキューが無いときの案内に、キューのことが書かれています"
  fi
}

@test "task-finish・task-cancel は、削除するワークツリーの外へ移る先を main-root.sh で求め、git-common-dir/.. からは求めない（#233）" {
  for s in task-finish task-cancel; do
    grep -q 'main-root\.sh' "$SKILLS/$s/SKILL.md" || fail "$s に main-root.sh の手順がありません"
    # shellcheck disable=SC2016 # バッククォートや $( は検索する文字で、展開させない
    if grep -qF '$(git rev-parse --git-common-dir)/..' "$SKILLS/$s/SKILL.md"; then
      fail "$s が git rev-parse --git-common-dir から移る先を求めています（サブモジュールや bare の配置で、cleanup.sh を実行できない場所に移る）"
    fi
  done
  # 求められないときは移らずに止まる
  grep -q '移らずに' "$SKILLS/task-finish/SKILL.md"
  grep -q '移らずに' "$SKILLS/task-cancel/SKILL.md"
}

@test "task-finish と task-cancel は、子がすべて閉じた親を閉じるかを確認する手順を持ち、task-start・task-status は親の列を伝える（設計書 §4）" {
  for name in task-finish task-cancel; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '### [0-9]*\. 子がすべて閉じた親を閉じるか確認する' "$f" || fail "${name} に親を閉じるかの確認の手順がありません"
    grep -q 'parent-state.sh' "$f" || fail "${name} が parent-state.sh を使っていません"
    grep -q 'AskUserQuestion' "$f" || fail "${name} に確認（AskUserQuestion）がありません"
    grep -q '下の親から順に' "$f" || fail "${name} に、上の親も下から順に確認することがありません"
  done
  grep -q 'not_planned' "$SKILLS/task-cancel/SKILL.md" || fail "task-cancel に、子がすべて取りやめのときの案がありません"
  for name in task-start task-status; do
    grep -q 'parents' "$SKILLS/$name/SKILL.md" || fail "${name} に、親の列の移動を伝えることがありません"
  done
  [ -x "$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts/parent-state.sh" ]
}

@test "親を閉じる確認は suggest が null でない親だけを対象にし、not_planned は issue-cancel.sh で閉じる。task-finish は複数の Issue をまとめて渡す" {
  for name in task-finish task-cancel; do
    f="$SKILLS/$name/SKILL.md"
    grep -qF 'が null でないものがあれば' "$f" || fail "${name} に、suggest が null でない親だけを確認することがありません"
    grep -q 'issue-cancel.sh --issue <親の番号> --reason' "$f" || fail "${name} に、not_planned を issue-cancel.sh で閉じる手順がありません"
    grep -q -e '--sub-issues keep' "$f" || fail "${name} に --sub-issues keep がありません"
  done
  grep -q '二重に聞かない' "$SKILLS/task-finish/SKILL.md" || fail "task-finish に、同じ親を二重に聞かないことがありません"
  grep -q '<番号1>,<番号2>' "$SKILLS/task-finish/SKILL.md" || fail "task-finish に、閉じる Issue をまとめて渡すことがありません"
  grep -qF 'parent-state.sh --issue <番号> --assume-closed <番号>:<理由>' "$SKILLS/task-cancel/SKILL.md" || fail "task-cancel が取りやめた Issue を --assume-closed で渡していません"
  grep -q '「Issue だけ閉じる」を選んだときも含む' "$SKILLS/task-cancel/SKILL.md" || fail "task-cancel の手順8の実行条件がありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-finish は、マージ前に呼ばれたとき pr-merge-status.sh でマージキューの CI を待つか選んでもらい、外れていれば失敗を伝えて止まる" {
  f="$SKILLS/task-finish/SKILL.md"
  grep -q 'scripts/pr-merge-status.sh`' "$f"
  grep -q 'pr-merge-status.sh --branch <ブランチ> --wait' "$f"
  grep -q 'run_in_background' "$f"
  grep -q 'キューの CI を待ってから後片付けする' "$f"
  grep -q '`removed`' "$f"
  grep -q '失敗したチェック' "$f"
  # ブランチが決まっていないときは、2-1 を飛ばして 2-2 に進む
  grep -q 'ブランチが決まっていないとき.*この手順を飛ばして2-2に進む' "$f"
  # バックグラウンドの --wait が JSON を出さずに終わったときは、止まらずに2-2に進む
  grep -q 'JSON が出ずに異常終了したとき.*止まらずに.*2-2に進む' "$f"
  [ -x "$SCRIPTS/pr-merge-status.sh" ]
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "task-create は、着手まで頼まれていなければ、起票の後に着手するかを聞いてから task-start に進む（task-create・task-flow・設計書）" {
  local f="$SKILLS/task-create/SKILL.md"
  grep -q '^### 6. 着手するかを聞く' "$f" || fail "task-create に、着手するかを聞く手順がありません"
  grep -q "候補は着手できる子の Issue だけで、新しく起票した親は除く" "$f" || fail "task-create の手順6に、候補から新しい親を除くことがありません"
  grep -q "着手まで頼まれていて、子が特定されていないとき：着手する子を AskUserQuestion で聞き、選ばれた子の番号を渡す" "$f" || fail "task-create の手順6に、親子で子が特定されていないときに子を聞くことがありません"
  grep -q '「起票して着手して」のように着手まで頼まれたときは、通常は聞かずに `task-start` に進む' "$f" || fail "着手まで頼まれたときは聞かないことがありません"
  grep -q '今は着手しない' "$f" || fail "「今は着手しない」の選択肢がありません"
  grep -q '起票した後に着手するかは使う人が決める' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" || fail "task-flow.md にありません"
  grep -q '着手するかを聞いてから `task-start` に進む' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書にありません"
  grep -q 'task-create 手順6 | 起票した後に着手するか | 聞かず、着手しない' "$SKILLS/task-auto/SKILL.md" || fail "task-auto の確認の代わりの表にありません"
  grep -q '手順6（着手するかを聞く）は行わず' "$SKILLS/task-auto/SKILL.md" || fail "task-auto の手順5にありません"
  grep -q '既存の Issue に「着手して」と言ったときは、もう一度聞きません' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" || fail "task-flow.md に既存の Issue の扱いがありません"
  grep -q '起票した後に着手するか（着手まで頼まれていないとき）' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書の確認を取る操作の列にありません"
}
