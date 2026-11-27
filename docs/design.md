# genai-o11y 設計書

## 1. 目的と背景

Claude Code と OpenAI Codex CLI の利用状況（使用量・コスト・ツール実行・エラー・トレース）を分かりやすく見られるようにする。
表示にはローカルで動く Grafana ダッシュボードを使う。
テレメトリはローカルで完結させ、外部への転送はしない。

## 2. ゴール / 非ゴール / アンチゴール

### ゴール

- `docker compose up -d` だけで `grafana/otel-lgtm` が起動する。これは Grafana + Prometheus + Loki + Tempo + OTel Collector をまとめた単一イメージである。
- 公開ポートはすべて `127.0.0.1` にバインドする。`0.0.0.0` では待ち受けない。
- Claude Code と Codex のテレメトリが `localhost` の OTLP エンドポイントに届き、Grafana で見られる。
- ダッシュボードは 2 枚をプロビジョニング済みで用意し、`service.name`（Claude / Codex）で絞り込めるようにする。
  1. **Usage & Cost** ではトークン数（種別・モデル別）とコスト、セッション数、アクティブ時間、追加・削除した行数を表示する。
  2. **Activity** ではツールの実行回数・成功率・所要時間、API エラー、API レイテンシを表示し、トレース（Tempo）への導線を置く。
- `.env` の `PROFILE=strict|standard` で、Collector の設定（サニタイズの強さ）を切り替えられる。デフォルトは `strict` にする。
- エージェント側の設定はプロファイルごとのひな形と適用スクリプトで用意する。対象は Claude の `~/.claude/settings.json` の `env` と、Codex の `~/.codex/config.toml` の `[otel]` である。
- イメージはバージョンと digest で固定する。

### 非ゴール

- Apple container 対応（後で追加する。設定ファイルはランタイムに依存しない形で作っておく。そうすれば、起動スクリプトと `verify.sh` のポート確認を足すだけで済む）
- 複数の端末や組織でのテレメトリの中央集約
- コンテナからの Egress 制御（localhost からだけ見られればよいため）
- Claude / Codex 以外のエージェントへの対応
- アラート通知

### アンチゴール（動いても失敗とみなすもの）

- ポートが `0.0.0.0` で公開され、LAN から Grafana や OTLP に届く。
- `strict` プロファイルで、プロンプト本文、メールアドレス、アカウント ID、ツール引数（Bash コマンドやファイルパス）が Loki・Tempo・Prometheus に保存される。
- `strict` プロファイルで、サニタイズの設定ミスがあっても、気づかないうちにデータが保存され続ける（検証手段がない）。
- エージェント側の設定を適用するとき、ユーザーの既存の `~/.claude/settings.json` や `~/.codex/config.toml` を壊したり、上書きしたりする。

## 3. 制約と前提（2026-11-26 時点の調査結果）

### grafana/docker-otel-lgtm

- 最新は `0.41.1`（2026-11-20）。digest は `sha256:1b852b77d7bcadb7699bfe7c78a51d059dff85168de674728cf7abf4474645e5`。実装時に `docker buildx imagetools inspect grafana/otel-lgtm:0.41.1` で再確認する。
- 同梱の Collector は `otelcol-contrib` v0.165.0。そのため `attributes`、`transform`、`redaction`、`deltatocumulative` などのプロセッサが使えるはず。実装時に `components` サブコマンドで確認する。
- Collector の設定は `/otel-lgtm/otelcol-config.yaml`。bind mount で丸ごと差し替える。
- ダッシュボードは `/otel-lgtm/grafana/conf/provisioning/dashboards/` 配下に、JSON とプロバイダ YAML をマウントする。
- データは `/data` 配下に保存される。named volume に永続化する。
- ポート: 3000（Grafana）、4317 / 4318（OTLP）、9090（Prometheus）、3200（Tempo）、4040（Pyroscope）
- Grafana の初期設定は匿名 Admin（`GF_AUTH_ANONYMOUS_ENABLED=true`）。`GF_*` 環境変数で上書きできる。
- 公式には開発・検証用のイメージとされている。

### Claude Code

- `~/.claude/settings.json` の `env` ブロックで設定する。リポジトリ側の `.claude/settings.json` に書いた OTEL 関連の値は無視される。
- メトリクスの例: `claude_code.token.usage`、`cost.usage`、`session.count`、`lines_of_code.count`、`active_time.total`。ほかに `code_edit_tool.decision`、`commit.count`、`pull_request.count` もある。
- イベント（ログ）の例: `user_prompt`、`tool_result`、`tool_decision`、`api_request`、`api_error` など
- トレースはベータ機能。`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` と `OTEL_TRACES_EXPORTER=otlp` で有効になる。
- デフォルトのプロトコルは `http/protobuf`、デフォルトのテンポラリティは **delta**。
- 機微な属性: `user.email`、`user.account_uuid`、`user.account_id`、`user.id`、`organization.id`、`host.name`、`host.id`。`prompt` と `prompt_text` はデフォルトでオフ。`tool_parameters` と `tool_input` は `OTEL_LOG_TOOL_DETAILS=1` のときだけ出力される。

### Codex CLI

- `~/.codex/config.toml` の `[otel]` で設定する。プロジェクト側の設定では無視される。
- ログは `exporter`、トレースは `trace_exporter`、メトリクスは `metrics_exporter` で指定する。それぞれ `otlp-http` か `otlp-grpc` を選ぶ。HTTP のエンドポイントには `/v1/logs` などのパスまで含める。
- `metrics_exporter` のデフォルト値は `statsig`（OpenAI に送られる）。明示的に `otlp-http` にする。
- イベントの例: `codex.conversation_starts`、`api_request`、`sse_event`（トークン数）。ほかに `tool_decision`、`tool_result`、`turn_cost` などがある。
- 機微な属性: `user.email`、`user.account_id`。`tool_result` の `arguments` と `output` は**ログでは常に出力される**（output は 2KB で切り詰め）。
- `service.name` の値、メトリクスのテンポラリティ、対応している最小バージョンは**未確認**。実装時に実データで確かめる。

### 実行環境

- 対象は Apple silicon の macOS と Docker Desktop。

## 4. 検討したアプローチ

| 案 | 内容 | 判断 |
| --- | --- | --- |
| **A. 単一イメージ + 設定マウント** | `grafana/otel-lgtm` を 1 コンテナで動かし、プロファイル別の Collector 設定とダッシュボードをマウントする | **採用**（ユーザーが選択） |
| B. 別コンテナの Collector を前段に置く | 公式の contrib Collector でサニタイズしてから lgtm に転送する | イメージに同梱された Collector の設定パスに依存しない点は良い。ただしコンテナとイメージが増え、今の要件には過剰 |
| C. Grafana / Loki / Tempo / Prometheus を個別に構成 | 本番を想定した構成 | ローカルで見るだけの用途には過剰 |

A を選ぶ理由: コンテナが 1 つで済み、管理するイメージも最小になる。弱点は同梱 Collector の設定パスと内容がイメージのバージョンに依存すること。イメージを更新するときは、同梱の `otelcol-config.yaml` との差分を確認する手順を README に書いておく。

## 5. 設計

### 5.1 リポジトリ構成（案）

```text
genai-o11y/
├── compose.yaml
├── .env.example              # PROFILE, GRAFANA_ADMIN_PASSWORD, イメージ digest など
├── collector/
│   ├── base.yaml             # 受信・エクスポート・共通処理（同梱設定をもとに作る）
│   ├── strict.yaml           # 強めのサニタイズ（デフォルト）
│   └── standard.yaml         # プロンプトだけを削除
├── grafana/
│   ├── provisioning/dashboards/genai.yaml
│   └── dashboards/
│       ├── usage-cost.json
│       └── activity.json
├── agents/
│   ├── claude/{strict,standard}.env.json # settings.json の env に入れる値
│   └── codex/{strict,standard}.toml      # [otel] ブロック
├── scripts/
│   ├── apply-agent-config.sh  # バックアップしてからマージ。既定は dry-run
│   └── verify.sh              # ポートのバインドとサニタイズを確認
├── docs/
│   └── design.md              # この設計書
├── AGENTS.md                  # コーディングエージェント向けの規約
├── LICENSE / SECURITY.md / CONTRIBUTING.md
├── README.md / README.ja.md
└── .gitignore / .editorconfig / .markdownlint-cli2.jsonc
```

Collector の設定の組み方は 2 通りある。1 つは OTel Collector の複数 `--config` マージ機能（`base.yaml` + プロファイル）を使う方法。もう 1 つはプロファイルごとに完結したファイルを 2 つ用意し、マウント先を切り替える方法。どちらにするかは実装者が決めてよい。条件は同梱の起動スクリプトとぶつからないこと。

### 5.2 データの流れ

```text
Claude Code ─┐  OTLP/HTTP  http://localhost:4318
Codex CLI   ─┘        │
                      ▼  (127.0.0.1 バインド)
       ┌─ grafana/otel-lgtm コンテナ ──────────────────┐
       │ otelcol-contrib                               │
       │  receivers: otlp                              │
       │  processors: (プロファイル別サニタイズ)        │
       │              deltatocumulative, batch         │
       │  → Prometheus / Loki / Tempo                  │
       │ Grafana :3000 （プロビジョニング済みダッシュボード）│
       └───────────────────────────────────────────────┘
                      │  volume: genai-o11y-data:/data
```

- プロトコルは OTLP/HTTP（4318）にそろえる。Claude のデフォルト値に合わせるためと、Codex の HTTP エンドポイント指定がシンプルなため。4317 も `127.0.0.1` で公開しておく。
- テンポラリティ: Collector に `deltatocumulative` を入れる。これで、どのエージェントから delta が来ても Prometheus へ取り込める。加えて、Claude 側でも `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` を設定しておく。
- 9090 / 3200 / 4040 は公開しない（Grafana 経由で見られるため）。

### 5.3 収集ポリシー

| 項目 | `strict` | `standard` |
| --- | --- | --- |
| メトリクス | 有効 | 有効 |
| ログ（イベント） | 有効、サニタイズあり | 有効 |
| トレース | 有効（Claude はベータ） | 有効 |
| プロンプト本文 | エージェント側でオフ、Collector でも削除 | エージェント側でオフ、Collector でも削除 |
| アシスタント応答本文 | オフ、Collector でも削除 | オフ |
| ツール引数・出力 | Claude: `OTEL_LOG_TOOL_DETAILS` はオフ。Collector で `tool_parameters`、`tool_input`、`error`（本文。`status_code` と `error_type` は残す）、Codex の `arguments`、`output` を削除 | Claude: `OTEL_LOG_TOOL_DETAILS=1`。Codex もそのまま残す |
| 個人識別属性（`user.email`、`user.account_*`、`user.id`、`organization.id`、`host.name`、`host.id`） | Collector で削除。Claude は `OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false` | 残す |
| 生の API ボディ | オフ、Collector で該当イベントを破棄 | オフ |
| `session.id` / `conversation.id` | 残す（セッション単位の集計に必要） | 残す |

`strict` の Collector では属性名を削除する（`attributes` / `transform`）。加えて、属性名は将来変わりうるため、メールアドレスらしい文字列のマスク（`redaction` / `transform` の正規表現）を最後の防御として入れる。

両プロファイルとも、プロンプト本文は Collector でも削除する（エージェント側の設定を誤ったときの保険）。

### 5.4 Grafana

- 匿名 Admin は無効にし、`.env` の `GRAFANA_ADMIN_PASSWORD` でログインする。これは localhost だけでも同じ Mac 上のブラウザやほかのプロセスから操作できてしまうことへの最低限の対策である。設定コストもほぼない。
- ホームダッシュボードは Usage & Cost にする。
- コストの扱い: Claude は `claude_code.cost.usage` をそのまま使う。Codex は `codex.turn_cost`（`usage.estimated_usd`）が実データで取れればそれを使い、取れなければトークン数だけを表示する。料金表は持たない（保守が必要になるため）。どちらも「推定値」と表示する（サブスクリプション利用では実際の請求額と一致しないため）。
- Codex のトークン数やコストがメトリクスとして出ていない場合は、Loki のログから集計するクエリ（LogQL の `sum_over_time` など）で代用する。Collector でログをメトリクスに変換する処理は作らない。
- 両ダッシュボードに、変数 `service`（claude-code / codex）、`model` を置く。
- Claude と Codex ではメトリクス名と属性名が違うため、パネルはエージェントごとにクエリを分けるか、`or` で合成する。どちらかは実装者に任せる。「Claude と Codex のトークン数とコストを同じ時間軸で比べられること」が満たされればよい。
- Prometheus でのメトリクス名（単位や `_total` が付くかどうか）は、実データを流して確かめてからクエリを書く。

### 5.5 エージェント設定の適用

- `scripts/apply-agent-config.sh <strict|standard>`
  - デフォルトは dry-run で、差分を表示するだけ。`--apply` を付けたときだけ書き込む。
  - 書き込む前に、タイムスタンプ付きのバックアップを作る。
  - Claude: `jq` を使い、`~/.claude/settings.json` の `env` に必要なキーだけをマージする。ほかのキーには触れない。同じキーに別の値（たとえば別のエンドポイント）が入っていたら、上書きせずに中止して差分を表示する。
  - managed settings に OTEL 関連のキーがある場合は、警告を出して中止する。対象のファイルは `/Library/Application Support/ClaudeCode/managed-settings.json` である。managed settings はユーザー設定より優先されるため、適用しても効かない。
  - Codex: `~/.codex/config.toml` に `[otel]` がなければ追記する。すでにある場合は書き換えず、差分を表示して手で直してもらう（TOML を安全にマージするための依存を増やさないため）。
- Codex の `metrics_exporter` は必ず `otlp-http` にする（デフォルトの `statsig` を避ける）。

### 5.6 データ保持

- 保持期間は 30 日。同梱の起動スクリプトが読む `*_EXTRA_ARGS` 環境変数で、各サービスに引数を渡して設定する。設定ファイルは差し替えない。
  - Prometheus：`PROMETHEUS_EXTRA_ARGS=--storage.tsdb.retention.time=30d`（デフォルトは 15 日）
  - Loki：`LOKI_EXTRA_ARGS` で compactor の retention を有効にし、`-store.retention=720h` を指定する（デフォルトでは削除しない）
  - Tempo 3.x：`TEMPO_EXTRA_ARGS` で `-backend-worker.compaction.block-retention=720h` などを指定する（デフォルトは 14 日）
- データを消すときは `docker compose down -v` を使う。README に書く。

### 5.7 検証（`scripts/verify.sh`）

1. `docker compose ps` / `docker port` で、全ポートが `127.0.0.1` にバインドされていることを確認する。LAN の IP から 3000 / 4318 に接続できないことも確認する。
2. 匿名で Grafana API にアクセスすると 401 が返ることを確認する。
3. `strict` プロファイル: テスト用の OTLP ログ・メトリクス・スパン（`user.email`、`prompt`、`tool_parameters` を含むもの）を 4318 に送る。Loki、Tempo、Prometheus（`target_info` のラベルを含む）を検索し、それらが残っていないことを確認する。失敗したら非ゼロで終了する。
4. 継続的な確認として、Activity ダッシュボードに「サニタイズ漏れ」パネルを置く。`strict` プロファイルでは Loki でメールアドレスらしい文字列や削除対象の属性名を含むログの件数を数え、0 でなければ赤く表示する。起動時に止める仕組みや定期実行はしない（ローカル用途には過剰なため）。
5. Claude Code と Codex を実際に少し動かし、両方のダッシュボードにデータが出ることを目で確認する（手動手順として README に書く）。

## 6. 決まっていること / 実装者に任せること

### ユーザーが決めたこと

- `grafana/otel-lgtm` の単一イメージ構成（案 A）を採用する。
- 実行環境はまず Docker Desktop にする。Apple container は後で対応する。
- localhost からだけ見られればよい。`0.0.0.0` で公開しないことが必須条件。Egress の制御は不要。
- 対象は Claude Code と Codex。ダッシュボードで分かりやすく見られることが目的。
- 目的はローカルでの可視化に絞り、特定の利用シーンは前提にしない。
- 収集プロファイルは `strict`（強めのサニタイズ）と `standard`（プロンプトだけを削除）の 2 つにする。

### 設計者（Claude）の判断（ユーザーが確認する前提）

- OTLP/HTTP にそろえる。9090 / 3200 / 4040 は公開しない。
- Grafana の匿名 Admin を無効にし、パスワード認証にする。
- `standard` プロファイルではツール引数・個人識別属性を残す。
- プロファイルのデフォルトは `strict` にする（公開するツールのため、安全側に倒す）。
- 適用スクリプトはデフォルトを dry-run にし、バックアップを取る。Codex の `[otel]` が既にある場合は書き換えない。
- 保持期間は 30 日を目安にし、無理な設定の差し替えはしない。

### 実装者に任せること

- Collector 設定の分け方（マージするか、ファイルを丸ごと分けるか）
- ダッシュボードのパネル構成の細部とクエリの書き方
- テストデータの送り方（`telemetrygen`、`curl` で OTLP/JSON を送る、など）
- 未確認事項の確認（Codex の `service.name`、メトリクスのテンポラリティ、Prometheus でのメトリクス名）と、その結果に合わせた調整
