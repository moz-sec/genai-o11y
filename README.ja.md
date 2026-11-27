# genai-o11y

[English](README.md)

AI コーディングエージェントのテレメトリを、ローカルだけで可視化するためのツールです。
[Claude Code](https://code.claude.com/docs/en/monitoring-usage) と
[OpenAI Codex CLI](https://developers.openai.com/codex/config-advanced) が出力する
OpenTelemetry のメトリクス、ログ、トレースを集め、ローカルの Grafana ダッシュボードで表示します。

> [!WARNING]
> **開発中です。** 設計は [docs/design.md](docs/design.md) にあります。
> 以下の手順は完成後の使い方で、まだ動かない場合があります。

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
- すぐ使えるダッシュボードが付いている。*Usage & Cost* ではトークン数と推定コスト、セッション数、アクティブ時間、追加・削除した行数を表示する。
  *Activity* ではツールの実行とエラー、レイテンシ、トレース、サニタイズ漏れの確認を表示する。
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
./scripts/verify.sh             # バインドとサニタイズを確認する
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
