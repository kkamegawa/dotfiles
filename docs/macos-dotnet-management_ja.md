# macOS .NET SDK 管理

- 状態: 設計・実装完了。移行は CI ではなくユーザーが実行
- 日付: 2026-10-26
- 範囲: macOS の SDK 管理、CLI/IDE/エージェント環境、保守、切り戻し
- 実装 Issue: 親 Issue #83、子 Issue #84-#86。
- English: [macOS .NET SDK management](macos-dotnet-management.md)

## 目的と範囲

macOS では mise の組み込み .NET バックエンドで SDK を一元管理し、CLI、VS Code、VS Code Insiders、Rider、リポジトリ管理の自動処理が互換性のある SDK とランタイムを使えるようにします。プロジェクト SDK の選択は各プロジェクトの `global.json` が担います。apphost や GUI 起動プロセスのランタイム探索は、シェルの `PATH` やプロジェクト SDK の選択とは別の責務です。

Windows と Linux の SDK 管理は変更しません。移行はユーザーが明示的に実行するスクリプトで行い、chezmoi の移行フックにはしません。他リポジトリのプロジェクトファイルを変更したり、.NET 8 固定プロジェクトを暗黙にアップグレードしたり、IDE のターミナルだけで C# 拡張機能の SDK も正しいと判断したりしません。IDE 固有のランタイムや Rider 内蔵ランタイムは残せます。

## 管理の分担

| 対象 | macOS での管理者 | 契約 |
|---|---|---|
| SDK の導入と更新 | mise 組み込み `dotnet` バックエンド | `~/.local/share/mise/dotnet-root` を共有ルートとして、主要バージョンと明示保持した完全バージョンを管理 |
| プロジェクト SDK 選択 | 各プロジェクトの `global.json` | roll-forward 方針を維持し、不足する完全 SDK を保持対象として導入 |
| CLI のランタイム探索 | シェルとエージェント環境 | `DOTNET_ROOT` と対応するアーキテクチャ変数を設定し、管理対象 host と `~/.dotnet/tools` を `PATH` に含める |
| GUI apphost の探索 | アーキテクチャ別システム登録 | ユーザーが `/etc/dotnet/install_location_arm64` または `_x64` を共有ルートへ設定 |
| .NET global tool | macOS シェル更新フック | mise install 成功後に実行し、`~/.dotnet/tools` を維持。重複する GCM tool は自動更新しない |
| C# フックと mise cleanup task | `dotfiles-dotnet10` runner | 専用 runner ディレクトリで .NET 10 を選び、呼び出し元の `global.json` から独立させる |

`MSBuildSDKsPath` とグローバル `DOTNET_HOST_PATH` は設定しません。プロファイルが安定した基本環境を作った後、`mise activate` がコンテキストに応じた `PATH` と `DOTNET_ROOT` を管理します。アーキテクチャ変数は `DOTNET_ROOT` と一致させます。別ルートや isolated mode を選ぶプロジェクト設定は競合として報告します。

## mise の設定と SDK 保持

macOS では `[tools]` の `dotnet = ["10", "8"]`、既存の `[settings]` の共有ルート `dotnet.dotnet_root` と `dotnet.isolated = false` を使用します。削除するパッケージ宣言は `brew-cask:dotnet-sdk` だけです。TOML テーブルを重複作成せず、他 OS や無関係な cask の管理者は変更しません。

チャンネルは対応する主要バージョンを指定しますが、プロジェクトが必要とする全パッチ SDK を保持するものではありません。完全バージョンは端末ローカルで秘密を含まない `~/.config/dotfiles/dotnet-retained-sdks.json` に保存し、mise 宣言へ反映します。利用状況の調査が終わるまで、既存の 10.0.401 と 8.0.404 を保持します。今後必要となった完全バージョンも同じ manifest に追加します。.NET 8 のサポートは 2026-11-10 に終了します。SDK チャンネルを残してもサポート期間は延長されず、移行時にプロジェクトを暗黙のうちに更新しません。

このリポジトリの設定には mise 2026.10.17 以降を使います。macOS での通常更新は `mise upgrade --global --no-prune dotnet` とし、`--bump` や通常運用での `mise prune` は使いません。更新フックは SDK の導入後に global tool を更新し、失敗時に旧システム SDKへフォールバックしません。bootstrap package apply は宣言から外れたパッケージを削除しません。SDK cask の削除は独立した明示的な最終化操作です。

シェルプロファイルは冪等性ガードより前、`mise activate` より前に安定した .NET 環境を初期化します。PowerShell も同じ規則にします。`.zshenv`、`.zprofile`、`.zshrc` から複数回読み込まれても重複させず、macOS の `path_helper` より後に管理パスが優先されることを確認します。macOS で global tool を更新するのはシェルフックだけにし、PowerShell は tool 処理前に return します。初回セットアップでは SDK を導入してから通常の tool 更新フックが動きます。

## IDE、エージェント、自動処理

### VS Code と Insiders

Finder または Dock から起動するアプリにはログインプロファイルから管理対象 host を渡します。各アプリを完全終了してから再起動し、確認します。C# 拡張機能のランタイム取得設定でプロジェクト SDK を選ばないでください。実際のユーザー、プロファイル、workspace 設定から古い SDK 上書きを調べます。拡張機能固有のランタイムと無関係な設定は維持します。C# project system の SDK/build ログを確認し、代表的なプロジェクトを build、run または test します。統合ターミナルの `dotnet --info` だけでは合格としません。

### Rider

各 solution の Toolset and Build で共有ルートにある絶対パスの `dotnet` を選び、自動 SDK ダウンロードを無効化して、MSBuild が同じ SDK 選択方針を使うことを確認します。この設定は solution ごとなので、既存の設定済み solution を個別に確認します。Rider 内蔵 runtime は残します。Bicep runtime が共有ルートを参照している場合、設定を維持し、移行後に動作確認します。

### Codex と Claude Code

Codex の非ログインシェル設定を維持します。管理する Darwin 環境から絶対パスの `PATH`、`DOTNET_ROOT`、アーキテクチャ別 root を明示し、cache、認証、無関係な環境変数を保持します。Claude Code の hook は絶対パスの .NET 10 runner を使い、Darwin の子プロセスには設定から管理対象環境を渡します。既存の `DOTNET_CLI_HOME` と `~/.dotnet/tools` の管理先は分けて維持します。この構成のために SDK installer の接続先や sandbox の書き込み権限を追加しません。

### .NET 10 runner

`dotfiles-dotnet10` は管理対象 host と専用 `global.json` ディレクトリを使って .NET 10 を選び、絶対パスで指定された C# ファイルを元の引数、標準入出力、終了コードを保って実行します。macOS の Claude PostCompact / UserPromptSubmit hook と4件の .NET file-based mise task から呼び出します。他 OS の実行方法は維持します。runner は SDK を選択するだけで、導入はしません。これにより呼び出し元プロジェクトが .NET 8 に固定されていても .NET 10 の file program を実行できます。

## システム登録と credential helper

Finder/Dock 起動の apphost はプロファイルの環境変数を継承しない場合があります。そのため、アーキテクチャ別 `/etc/dotnet/install_location_*` を展開済みの絶対共有ルートへ設定します。これはホスト全体のランタイム探索だけを担い、CLI 実行ファイルやプロジェクト SDK は選択しません。登録に `~` やシェル変数を書き込みません。旧形式の登録や他アーキテクチャのファイルを維持し、x64 登録を ARM64 root に向けません。システムの `paths.d` をユーザーディレクトリへ向けたり、Homebrew link を代用品として作ったりしません。

macOS の Git は native GCM パッケージの絶対パスを使います。重複する dotnet global tool はインストール状態を維持しますが、自動更新は停止します。Git helper の設定と資格情報を要求しない version コマンドで確認します。credential を取得したり表示したりしません。

## ユーザーが実行する移行スクリプト

Bash スクリプトが実装本体であり、PowerShell 7 スクリプトは引数と終了コードを維持して呼び出す wrapper です。両方とも macOS 以外では停止します。phase を省略した場合は読み取り専用の `plan` を実行します。

```sh
bash scripts/migrate-dotnet-macos.sh plan \
  --state-dir "$HOME/.local/state/dotfiles-dotnet-migration" \
  --project /absolute/path/to/project \
  --sdk 10.0.401 --sdk 8.0.404
```

関係する repository ごとに `--project` を、調査で見つかった完全 SDK ごとに `--sdk` を指定します。state directory と project root は絶対パスにします。変更案を確認してから、`prepare`、`switch`、`verify`、`finalize` を個別に順番どおり実行します。IDE の確認を手動で終えた後だけ `--ide-checks-confirmed` を付けます。問題があれば `rollback` で記録済みの設定と登録を戻します。

スクリプトは phase checkpoint を保存し、同時実行を防ぐ lock を使い、再開時に基準状態を再検証します。バックアップと一覧はユーザー所有の private state directory に保存し、資格情報や全環境変数をログに出しません。hook を無効にして承認対象ファイルだけを反映し、全体の chezmoi apply、無関係なパッケージ更新、`mise prune`、`--zap`、システム全体への SDK 導入は行いません。特権操作は対象アーキテクチャの登録ファイルに限定します。登録変更とパッケージ削除はユーザーが実行します。

| Phase | 操作 | 次へ進むための証拠 |
|---|---|---|
| `plan` | host、SDK、runtime、project、consumer を読み取り調査 | 変更案と不足依存関係を確認 |
| `prepare` | 対象状態をバックアップし、保持 SDK と workload を記録して必要 SDK を導入 | 旧 root が残り必要 SDK が見えること。既存 workload に対応する復元手段がなければ準備を停止 |
| `switch` | 承認済み設定と runner を反映し、システム登録を更新、必要な shim を生成 | CLI、agent、apphost が管理対象 root を参照 |
| `verify` | 対象 project、hook/task、Codex、apphost、GCM、IDE を確認 | 自動確認と手動確認の結果を分けて記録 |
| `finalize` | 明示 attestation 後に旧 SDK cask だけを削除し、重要確認を再実行 | consumer が動作し登録先が共有 root |
| `rollback` | 必要なら旧 runtime を戻してから、登録とバックアップ済みファイルを復元 | 旧選択が動き、登録が存在しない root を指さない |

移行では旧 `~/.dotnet` や共有 root 内の古い runtime を削除しません。rollback point を明示的に廃止するまでバックアップと installer を保持します。元の cask を削除した後に SDK ファイルを復元しても Homebrew の管理情報は復元されません。別途管理を再登録する必要があれば報告します。

### PowerShell 入口

```powershell
& ./scripts/migrate-dotnet-macos.ps1 `
  -Phase plan `
  -StateDirectory "$HOME/.local/state/dotfiles-dotnet-migration" `
  -Project @('/absolute/path/to/project') `
  -Sdk @('10.0.401', '8.0.404')
```

PowerShell では配列引数として複数 project と SDK を渡します。wrapper は同じ phase と引数を Bash に渡し、その終了コードを返します。

## 検証と運用上の制約

自動テストは隔離先と fake executable を使い、read-only plan、失敗時の停止、再開、rollback 競合、SDK 保持、hook 実行順、profile 冪等性、設定 merge を確認します。CI は `sudo`、ユーザーの SDK 変更、パッケージ削除、IDE 操作をしません。mock test の成功は実機移行や GUI 検証の合格を意味しません。

ユーザーの実機検証では、各 project の SDK 選択結果を記録し、対象 build/test/run を行い、SDK 8 固定の hook/task fixture と .NET 10 runner、profile 変数なしの apphost、Finder/Dock からの Code/Insiders 起動、solution ごとの Rider 設定を確認します。最終化後も重要項目を再確認します。失敗と手動確認を分けて報告し、shell 出力から GUI の合格を推測しません。

移行はユーザーが明示的に実行します。2026-10-26 にユーザーが移行を最終化し、旧 SDK 削除後の IDE・エージェント確認を attestation として記録しました。この実機確認は CI では再現されず、他のマシンの移行手順を変更するものではありません。

## 参照資料

リポジトリ文書では外部 URL を placeholder で表します。設計レビュー時に次の資料を確認しました。

| 資料 | 裏付ける内容 |
|---|---|
| `<MISE_DOTNET_REFERENCE>` | mise .NET backend、root と isolated 設定 |
| `<MISE_LIFECYCLE_REFERENCE>` | upgrade 保持と activate の動作 |
| `<DOTNET_GLOBAL_JSON_REFERENCE>` | SDK 選択と roll-forward |
| `<DOTNET_ENVIRONMENT_REFERENCE>` | runtime 環境変数と architecture precedence |
| `<VSCODE_DOTNET_REFERENCE>` | C# 拡張 runtime と project SDK の違い |
| `<RIDER_TOOLSET_REFERENCE>` | solution ごとの CLI 選択と SDK download 設定 |
| `<DOTNET_SUPPORT_POLICY_REFERENCE>` | .NET 8 のサポート期間 |
| `<CODEX_ENVIRONMENT_REFERENCE>` | 非ログイン実行環境の明示設定 |
| `<CLAUDE_ENVIRONMENT_REFERENCE>` | 子プロセス環境の設定 |

## 判断履歴

| 日付 | 以前の判断 | 現在の判断 | 理由 | 承認 |
|---|---|---|---|---|
| 2026-10-26 | Homebrew 管理 SDK と継承環境 | macOS mise 共有 root、shell/agent/IDE の明示的な管理、ユーザー実行の切り戻し可能な移行 | SDK 選択と runtime 探索を揃え、project 方針を維持する | ユーザーが設計を承認。1 台での移行をユーザーが最終化し、CI 外で確認 |
