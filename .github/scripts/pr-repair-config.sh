#!/usr/bin/env bash
# pr-repair.yml が、この実行だけ見回りを有効にする個人の層の設定（config.local.json）を書く。
# チームの設定（config.json）には書かない（手元のセッションで常に有効にならないよう、gitignore 済みの個人の層に書く）。
# find ジョブと repair ジョブ（信頼する側とPR 側の両方）が同じ内容を書くので、1か所にまとめる。
#
# 使い方: pr-repair-config.sh <出力ファイル>
#
# 環境変数:
#   APP_SLUG         GitHub App の slug（必須）。ログイン名は <slug>[bot]。自動で作った PR の作成者と、無人の返信・push の投稿者になる
#   ALLOWED_AUTHORS  指摘に対応してよい投稿者（, 区切り。空でもよい）
set -euo pipefail

[ $# -eq 1 ] && [ -n "$1" ] || { echo "使い方: pr-repair-config.sh <出力ファイル>" >&2; exit 64; }
: "${APP_SLUG:?APP_SLUG が必要です}"

jq -n --arg app "${APP_SLUG}[bot]" --arg allowed "${ALLOWED_AUTHORS:-}" \
  '{repair: {enabled: true,
             allowed_authors: ($allowed | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
             bot_logins: [$app], reply_logins: [$app]}}' >"$1"
