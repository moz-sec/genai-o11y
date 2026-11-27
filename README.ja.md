# genai-o11y

[English](README.md)

AI コーディングエージェントのテレメトリを、ローカルだけで可視化するためのツールです。
[Claude Code](https://code.claude.com/docs/en/monitoring-usage) と
[OpenAI Codex CLI](https://developers.openai.com/codex/config-advanced) が出力する
OpenTelemetry のメトリクス、ログ、トレースを集め、ローカルの Grafana ダッシュボードで表示します。

## 特徴

- コンテナは 1 つだけで、公式イメージの
  [`grafana/otel-lgtm`](https://github.com/grafana/docker-otel-lgtm)
  （Grafana、Prometheus、Loki、Tempo、OpenTelemetry Collector）を使う。
  バージョンと digest は固定する。
- 公開するポートはすべて `127.0.0.1` にバインドし、localhost に限定する。
  テレメトリを端末の外に送ることはない。
- 収集プロファイルは 2 つある。`strict`（デフォルト）では保存する前に Collector でプロンプト、ツール引数、エラー本文を削除する。
  メールアドレス、アカウント ID、ホスト名も削除する。
  `standard` はプロンプトだけを削除し、分析のためにより多くの情報を残す。
- すぐ使えるダッシュボードが付いている。*Usage & Cost* ではトークン数と推定コスト、セッション数、プロンプト数、API リクエスト数とエラー数、アクティブ時間、コミット数、追加・削除した行数、編集の承認率、モデル別の内訳、コストの高いセッションを表示する。
  *Activity* ではツールの実行とエラー、レイテンシ、イベントのログ、トレース（クリックするとスパンを表示）、サニタイズ漏れの確認を表示する。
  Codex は実データでの確認がまだである。*Usage & Cost* は Claude Code だけを表示し、*Activity* には Codex のログを分かる範囲で含める。
- 必要な設定はスクリプトでエージェントの設定ファイルに安全にマージする。
  対象は `~/.claude/settings.json` と `~/.codex/config.toml` である。デフォルトは dry-run で、書き込む前にバックアップを取り、
  既存の値とぶつかったら中止する。
  設定ファイルを変えたくない場合は、いま使っているシェルでだけ有効にもできる。

## 必要なもの

- Apple silicon の macOS
- Docker Desktop
- `jq`
- Claude Code と Codex CLI の一方、または両方

## はじめかた

```sh
cp .env.example .env            # PROFILE=strict|standard と GRAFANA_ADMIN_PASSWORD を設定する
docker compose up -d
./scripts/verify.sh             # バインド、ログイン、サニタイズ、ダッシュボードを確認する
```

次に、エージェントのテレメトリを有効にします。次の 2 つの方法から選んでください。

**ずっと有効にする**：エージェントの設定ファイルに書き込みます。

```sh
./scripts/apply-agent-config.sh strict          # dry-run（差分を表示するだけ）
./scripts/apply-agent-config.sh strict --apply  # バックアップを取ってから書き込む
```

**このシェルだけで有効にする**：`~/.claude` と `~/.codex` には何も書き込みません。

```sh
eval "$(./scripts/agent-env.sh strict)"   # Claude Code 用の環境変数を設定する
claude                                    # Claude Code はこの環境変数を読む
codex-otel                                # [otel] の設定を -c で渡して codex を起動する
eval "$(./scripts/agent-env.sh --off)"    # 元に戻す
```

Codex にはこれらの設定を環境変数で渡す方法がないため、`codex` の代わりに `codex-otel` を使います。
`codex-otel` は `codex` を呼ぶので、自分で定義した `codex` のシェル関数があればそれも動きます。
`~/.claude/settings.json` の `env` に同じキーがある場合は、そちらの値が優先されます。

<http://localhost:3000> を開き、`admin` でログインします。

## 動作の確認

`./scripts/verify.sh` は、偽のテレメトリを送って、何が保存されたかを確かめます。
確認ごとに `PASS` か `FAIL` を 1 行ずつ出し、1 つでも失敗すると終了コード 1 を返します。
1 つだけ実行するときは `./scripts/verify.sh <ports|auth|collector|sanitize|dashboards>` とします。

続けて、実際のエージェントで確かめます。

1. テレメトリを有効にした Claude Code（または Codex）を数分使います。
   ファイルを読む、コマンドを実行するなど、ツールを使う依頼をしてください。
2. *GenAI Usage & Cost*（ホームのダッシュボード）を開きます。
   トークン数、推定コスト、セッション数に値が出ます。
3. *GenAI Activity* を開きます。ツールの実行数、API のレイテンシ、*Events* に値が出ます。
   *Recent traces* のトレース ID をクリックすると、*Trace detail* にそのトレースのスパンが出ます。
   `PROFILE=strict` なら、*Sanitization leaks* は 0（緑）になります。

メトリクスはおよそ 1 分ごとに Prometheus に届くため、最初の値が出るまで 1 分ほどかかります。
Codex は実データでの確認がまだです。

## プロファイルの切り替え

1. `.env` の `PROFILE` を変えます。
2. `docker compose up -d` を実行します。コンテナが新しいプロファイルで作り直されます。
3. 新しいプロファイルでエージェントの設定を適用します
   （`apply-agent-config.sh <profile>` か `agent-env.sh <profile>`）。
   `apply-agent-config.sh` は、すでに別の値が入っているキーがあると中止します。
   その場合は、表示されたキーを手で直してください。

切り替える前に保存したデータは、そのまま残ります。
`standard` から `strict` に移るときは、`docker compose down -v` で消してから始め直してください
（保存したテレメトリはすべて消えます）。

## イメージの更新

1. 新しい `grafana/otel-lgtm:<version>@sha256:<digest>` を、
   `.env.example` と自分の `.env` の `LGTM_IMAGE` に設定します。
2. 同梱の Collector の設定と `collector/base.yaml` を比べます。

   ```sh
   docker run --rm --entrypoint cat "$LGTM_IMAGE" /otel-lgtm/otelcol-config.yaml | diff - collector/base.yaml
   ```

   バージョンによって、exporter のエンドポイントやコンポーネントの名前が変わることがあります。
3. `docker compose up -d` と `./scripts/verify.sh` を実行します。

## 収集プロファイル

| 項目 | `strict`（デフォルト） | `standard` |
| --- | --- | --- |
| メトリクス | 有効 | 有効 |
| ログ（イベント） | 有効（サニタイズあり） | 有効 |
| トレース | 有効（Claude Code はベータ） | 有効 |
| プロンプト本文 | 削除 | 削除 |
| ツールの引数・出力 | 削除 | 残す |
| メールアドレス、アカウント ID、ホスト名 | 削除 | 残す |
| エラー本文 | 削除（ステータスコードと種類は残す） | 残す |

削除する属性の一覧は [docs/design.md](docs/design.md) を見てください。

## セキュリティについて

- `grafana/otel-lgtm` は開発・検証用のイメージである。
  ローカルに保存するだけでも、テレメトリには機微な情報が含まれうる。
  使う端末に適用される規定があれば、事前に確認すること。
- ポートを `127.0.0.1` にバインドすると、ほかの端末からの接続は防げる。
  ただし、コンテナから外への通信は止まらない。
- 保存したデータを守るため、ディスクの暗号化（FileVault）を有効にすること。
- メトリクス、ログ、トレースは 30 日間保存する。
  保存したテレメトリをすべて消すときは、`docker compose down -v` を実行する。

脆弱性を見つけたときの報告方法は [SECURITY.md](SECURITY.md) にあります。

## コントリビュート

[CONTRIBUTING.md](CONTRIBUTING.md) を読んでください。
コーディングエージェントは [AGENTS.md](AGENTS.md) も読んでください。

## ライセンス

[MIT](LICENSE)
