# Codex と Claude Code の設定の所有権

`~/.codex/config.toml` と `~/.claude/settings.json` は、このリポジトリとアプリ自身の両方が書き込みます。そのためリポジトリはファイル全体を所有しません。リポジトリが持つのは**管理キー**の集合だけで、`chezmoi apply` のたびに実ファイルへマージします。それ以外のキーは、ローカルのアプリが書いたままです。

## 所有権モデル

| 層 | 内容 | 所有者 |
| --- | --- | --- |
| common | OS 非依存の共通設定（サブエージェント、モデル、承認方針、許可ドメイン） | リポジトリ |
| os overlay | Windows / macOS / Linux 固有（パス、sandbox、notify、権限リスト） | リポジトリ |
| local | アプリが書き換える値: プラグイン、プロジェクト trust、アプリのバージョン値、注入されたフック | ローカルマシン |

local 層にリポジトリは書き込みません。キーがリポジトリのものになるのは、管理断片に書かれたときだけです。

## 方式

各ファイルは chezmoi の `modify_` テンプレート（本文に `chezmoi:modify-template` マーカーを含み、`.tmpl` 拡張子を付けないファイル）で生成します。chezmoi は現在のターゲットを `.chezmoi.stdin` としてテンプレートに渡します。テンプレートはそれを解析し、管理断片をマージして結果を出力します。

- インタープリタ、Python、uv は不要です。同じソースが Windows、macOS、Linux/WSL、Dev Container で動きます。
- `modify_` のターゲットには「前回書き込んだ後に変更された」という確認が出ないため、アプリがファイルを書き換えても `chezmoi apply` は壊れません。
- `chezmoi diff` と `chezmoi apply --dry-run` でマージ結果を確認できます。

| ソース | ターゲット |
| --- | --- |
| `home/dot_codex/modify_private_config.toml` | `~/.codex/config.toml` |
| `home/dot_claude/modify_settings.json` | `~/.claude/settings.json` |
| `home/.chezmoitemplates/codex/{common,darwin,linux,windows}.toml` | Codex の管理断片 |
| `home/.chezmoitemplates/claude/{common,unix,windows}.json` | Claude の管理断片 |
| `home/.chezmoitemplates/merge/union` | 配列の和集合を作る共通テンプレート |

断片は common を先に適用し、続けて `.chezmoi.os` に対応する overlay を適用します。衝突したときは overlay が優先されます。

## マージ規則

- テーブルとスカラー: 管理値がローカル値を上書きします。管理外のキーは保持されます。
- 配列: 管理値で置換します。ただし下記の和集合パスでは、管理側の要素は必ず存在し、ローカルの追加要素は残ります。
- リポジトリ所有の Claude フック: コマンドが Claude ホーム配下のリポジトリ用フックディレクトリを参照するエントリは、リポジトリ所有です。削除して断片から再追加するので、編集しても重複が残りません。それ以外のフックエントリ（他のツールが注入したものなど）は保持されます。
- ターゲットが空または存在しない場合は、空のドキュメントとして扱います。
- ターゲットを解析できない場合はテンプレートが失敗し、`chezmoi apply` はエラーで止まります。ファイルは上書きされません。

結果は再シリアライズされるため、ターゲット内のコメントは消え、テーブルはインデントし直され、キーは並べ替えられます。これはテンプレート方式の既知のコストです。

和集合の配列からリポジトリ側で項目を削除しても、すでにその項目を持つマシンからは削除されません。手動で削除するか、一時的に置換パスの管理キーへ移してください。

## キー分類

### Codex（`config.toml`）

| 管理（リポジトリ） | ローカル（アプリ所有） |
| --- | --- |
| `approval_policy`、`approvals_reviewer`、`default_permissions`、`allow_login_shell`、`model`、`model_reasoning_effort`、`web_search` | `mcp_servers.node_repl` とその `env`（`BROWSER_USE_*`、`NODE_REPL_*`、`CODEX_*`、`SKY_*`） |
| `notify`（macOS のみ） | `marketplaces.*` |
| `permissions.*`、`features.*`、`shell_environment_policy.*`、`windows.sandbox`（Windows のみ） | `plugins.*` |
| `agents.*`、`desktop.*`、`mcp_servers.learn_mcp` | `projects.*` |

Codex に和集合パスはなく、配列はすべて置換です。

### Claude Code（`settings.json`）

| 管理（リポジトリ） | ローカル |
| --- | --- |
| `model`、`advisorModel`、`effortLevel`、`env`、`language`、`cleanupPeriodDays`、`subagentPromptCacheTtl`、`attribution`、通知フラグ、`enableWorkflows` | `enabledPlugins` |
| `permissions`、`sandbox`、`statusLine`、`extraKnownMarketplaces` | リポジトリ所有でないフックエントリ |
| リポジトリのフックスクリプトに対する `hooks` エントリ | アプリが追加するその他のキー |

和集合パス: `permissions.allow`、`permissions.ask`、`permissions.deny`、`sandbox.network.allowedDomains`、`sandbox.filesystem.allowWrite`、`sandbox.excludedCommands`、および各 `hooks.<event>` 配列。

OS の差分は overlay にあります。Windows overlay は `permissions.allow` に PowerShell の読み取りコマンドを使い、`curl` / `wget` を拒否します。Unix overlay は POSIX の同等コマンドを使います。フックのパスは `.chezmoi.homeDir` から組み立て、バックスラッシュをスラッシュに置換します。

## 運用

- 共通設定を追加・変更する: 断片を編集し、`chezmoi diff` と `chezmoi apply` を実行します。
- キーをアプリ所有にする: 断片に書かないだけです。ほかの作業は要りません。
- キーを local から管理へ移す: 断片に追加します。次回の apply でローカル値が上書きされます。
- 移行後の最初の apply: ファイルが一度再シリアライズされます（コメントは消え、キーは並べ替えられます）。アプリ所有のキーは保持されます。

bash（macOS / Linux）:

```bash
chezmoi diff ~/.codex/config.toml
chezmoi apply ~/.codex/config.toml ~/.claude/settings.json
```

PowerShell 7:

```powershell
chezmoi diff ~/.codex/config.toml
chezmoi apply ~/.codex/config.toml ~/.claude/settings.json
```

## 検証

`scripts/tests` は、一時的な chezmoi のソース・宛先・状態にフィクスチャを置いてテンプレートを適用し、次を確認します: 管理キーの適用、アプリ所有キーの保持、和集合と置換の挙動、フックの所有権、2回目の apply での冪等性、不正な入力で失敗してもファイルが変わらないこと。`lint.yml` が ubuntu と windows で実行します。
