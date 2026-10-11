# ADR のテンプレート

[MADR](https://github.com/adr/madr)（Markdown Architectural Decision Records）4.0.0 の4つのテンプレートを、日本語に訳したものです。`adr-create` スキルが、判断に合うものを選んで ADR の出発点にします。

| ファイル | 節 | 説明 |
| --- | --- | --- |
| `adr-template.md` | 全部 | あり |
| `adr-template-minimal.md` | 必須だけ | あり |
| `adr-template-bare.md` | 全部 | なし |
| `adr-template-bare-minimal.md` | 必須だけ | なし |

## 元にした版とライセンス

- 出典：<https://github.com/adr/madr> の `template/` （タグ `4.0.0`、2024-09-17）
- ライセンス：MIT OR CC0-1.0（どちらかを選べます）。このリポジトリでは MIT の条件に従い、下に著作権表示と許諾文を載せます（`LICENSE.MIT` の全文）
- 訳：見出し・説明・プレースホルダーを日本語にしました（公式のドイツ語訳と同じ扱いです）。front matter のキーと `status` の値は、元のままです

MADR の版が上がったときは、上の出典のタグどうしの差分（`git diff 4.0.0 <新しいタグ> -- template/`）を、この訳に反映します。反映したら、上の「元にした版」も更新します。

## MADR から変えたところ

- front matter に `issue`（判断をした Issue の番号）を足しました。ADR のファイル名の先頭の番号と同じです
- minimal の2つには、元の MADR には無い front matter（`status`・`date`・`issue`）を足しました。置き換えた ADR の `status` を `superseded by ...` に書き換えるのに、`status` が要るためです
- minimal の2つには、元の MADR の minimal には無い「補足」（More Information）の節を足しました。過去の判断を一部だけ変える ADR は、変えた ADR へのリンクを「補足」に書く決まりで、`adr-list.sh` はこの節のリンクから、変えられた側の `cited_in_supplements`（逆引き）を作ります。minimal に節が無いと、リンクを別の節に書くことになり、逆引きにも `adr-create` の重複の確認にも出ません。節は任意で、書くことが無ければ消します
- 書き終えた ADR の本文は、後から書き換えません（例外は、置き換えたときの `status` の行と、下の採択のときの `status`・`date` の行）。MADR は、採択した ADR を編集してよいかを決めていません
- `date` は、MADR では「判断を最後に更新した日」ですが、書き換えないので、判断をした日にします（`proposed` の ADR は、下のとおり採択した日にします）
- `proposed` の ADR を採択するときは、`status` を `accepted` に書き換え、`date` を採択した日に更新します（採択した日が、判断をした日です。`adr-create.sh --accept` がこの2行だけを書き換え、`proposed` でなければ止まります）。ADR を書き換えない決まりの例外は、置き換えたときの `status` の行のほかは、この2つの行の書き換えだけです
- 過去の判断を一部だけ変える・覆す ADR は、「補足」にその ADR へのリンクと、何を変えるかを書きます（MADR の判断 0009 が、ADR どうしの関係を More Information に書くと決めています）。全部を覆すときは、置き換え（`superseded`）にします

## MADR のライセンス（MIT）

Copyright (c) 2017-2022 Oliver Kopp, Olaf Zimmermann

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
