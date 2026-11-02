# PoC 2: Ruby Agent フレームワーク比較

RubyLLM と Anthropic Ruby SDK に、同じ小さな Ruby 差分をレビューさせる使い捨て CLI。
Rails / DB / Webhook は不要。GitHub API は呼ばず、レビューの投稿も行わない。

## 検証範囲

前の Chat の計画は Tool Use、構造化出力、Claude API / Bedrock 切替、レビュー品質、トークン消費、エラーハンドリング。
クロスリポジトリ自動探索は PoC 3、ECS 統合は PoC 4。

今回は以下を比較する。新しい製品仕様や本実装の採用決定ではない。

| 項目 | この CLI で見るもの |
| --- | --- |
| Tool Use | モデルが `read_source` を呼び、Ruby が渡す全文を利用できるか |
| 構造化出力 | Tool Use と JSON Schema を同じ会話で使えるか。結果をローカルでも検証 |
| 接続先切替 | 両 adapter を `anthropic` / `bedrock` で実行できるか |
| 品質 | 整数除算の退行を指摘し、意味が同じ変更では指摘しないか |
| 消費 | ツール往復を含む全 assistant turn のトークン数と所要時間 |
| エラー | 認証・モデル・ツールの失敗が成功結果や APPROVE にならないか |

RubyLLM は自動ツールループ、公式 SDK は Messages API の短い手動ループを使う。
SDK の beta tool runner の比較ではない。まずこの 2 候補で必要な機能を評価し、
不足が判明した場合に、前の計画の「必要なら Claude Agent SDK」を検討する。

`instructions.txt`、schema、fixture は共通。モデルに期待解答は渡さない。
ツールはこの fixture の全文を返すだけで、リポジトリ探索は行わない。

## 準備

Ruby 3.2 以上と Bundler が必要。

```sh
cd poc-02-ruby-agent
bundle install
bundle exec ruby test_review.rb
mkdir -p results
```

主要 SDK は RubyLLM 2.1.1 / anthropic 2.3.0 に固定。
この Work 環境には Ruby がないため、bundle install・Ruby 構文チェック・テスト・実 API 呼び出しは未実施。
Gemfile.lock は捏造せず、手元で生成されるものを使う。比較中は bundle update しない。
結果に Ruby と使用 gem のバージョンも記録する。

## 1. Claude API で比較

`ANTHROPIC_API_KEY` を手元の環境変数に設定する。`.env` は自動読込しない。
同じ Claude モデル ID を両方に渡す。モデルはアカウントで利用可能かつ Tool Use・
構造化出力に対応するものを選ぶ。以下の `MODEL` に設定する。

```sh
export MODEL='利用する-Claude-モデル-ID'
for adapter in rubyllm anthropic; do
  for testcase in bug clean; do
    bundle exec ruby review.rb --adapter "$adapter" --provider anthropic \
      --model "$MODEL" --case "$testcase" > "results/${adapter}-anthropic-${testcase}.json"
  done
done
```

まずは上の 4 実行だけでよい。API 利用料金が発生する。

## 2. Bedrock で同じ比較

手元で認証済みの AWS profile または AWS SDK 標準の認証情報を利用する。
SSO の場合は先にログインを済ませる。`AWS_REGION` と、利用許可がある Bedrock の
モデル ID または inference profile ID を明示する。可能なら API 側と同じモデルの版を選ぶ。
モデルの版が異なる結果をフレームワークだけの差と解釈しない。

```sh
export AWS_PROFILE='利用する-profile'
export AWS_REGION='ap-northeast-1'
export BEDROCK_MODEL='利用する-Bedrock-モデルまたは-inference-profile-ID'
for adapter in rubyllm anthropic; do
  for testcase in bug clean; do
    bundle exec ruby review.rb --adapter "$adapter" --provider bedrock \
      --model "$BEDROCK_MODEL" --case "$testcase" > "results/${adapter}-bedrock-${testcase}.json"
  done
done
```

Bedrock の経路は RubyLLM の provider が選ぶ経路と、公式 SDK の `BedrockClient`
（bedrock-runtime / InvokeModel）を使用。接続先を切り替えても機能が成立するかを見る。
経路の違いもあるため、レイテンシ差を SDK のオーバーヘッドと断定しない。
構造化出力の対応状況はモデル・リージョン・経路にも依存する。
失敗時の自動フォールバックは行わず、非対応・設定不備も結果として残す。

## 3. 最小のエラー確認

ツール例外の注入。各コマンドは終了コード 1、`status: error` になり、`event` を含まないこと。

```sh
for adapter in rubyllm anthropic; do
  bundle exec ruby review.rb --adapter "$adapter" --provider anthropic \
    --model "$MODEL" --tool-error > "results/${adapter}-tool-error.json"
done
```

認証失敗。下記はコマンド内だけ不正キーに差し替える（元のキーは保持）。
終了コード 1、認証エラーになり、`event` を含まないこと。

```sh
for adapter in rubyllm anthropic; do
  ANTHROPIC_API_KEY=poc-invalid-key bundle exec ruby review.rb \
    --adapter "$adapter" --provider anthropic --model "$MODEL" \
    > "results/${adapter}-auth-error.json"
done
```

SDK のリトライは 0、リクエストタイムアウトは 60 秒、実行全体は 180 秒。
ツール呼び出し上限 4。429 や配信失敗の再試行機構は作らない。
これらは PoC の実行上限であり、本実装の運用仕様ではない。

## 結果の見方と受け入れの目安

- 正常時 `status: ok`、`tool_calls` に `read_source` が含まれる。
- `bug`: `average.rb:4` に、`[1, 2]` の平均が 1.5 から 1 になる説明がある。
- `clean`: findings が空で `event: APPROVE`。
- 指摘ありは既定で `event: COMMENT`。`--findings-event REQUEST_CHANGES` で切替できる。
- `expected_shape_matches` は場所／指摘有無だけの簡易チェック。指摘本文の正しさは人が確認する。
- 同じケースの `input_sha256` が一致していること。adapter が変換する wire payload 自体の一致は意味しない。
- `usage_by_turn` は各 SDK の報告値。`token_totals` は入力・出力・cache を別々に集計。
  未報告は null。失敗したリクエストの消費は取得できない場合があり、完全な請求額集計ではない。
- エラー時は終了コード 1、設定引数エラーは 2。エラー時に APPROVE などの判断は出さない。

`results/*.json` を返してもらえれば、対応可否・レビュー内容・トークン数を並べて比較できる。
1 回・2 ケースは疎通確認で、品質や費用の優劣を決めるベンチマークではない。
不安定な結果が出た場合だけ同じ条件で再実行する。

## 参照した公式資料

- https://rubyllm.com/tools/
- https://rubyllm.com/structured-output/
- https://rubyllm.com/configuration-providers/
- https://github.com/crmne/ruby_llm/tree/v2.1.1
- https://github.com/anthropics/anthropic-sdk-ruby/tree/v2.3.0
- https://github.com/anthropics/anthropic-sdk-ruby/blob/main/helpers.md
