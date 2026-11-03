# Homebrew パッケージ管理

## macOS cask の更新

macOS のコマンドラインツール、アプリケーション、フォントは `home/dot_config/mise/config.toml.tmpl` の `[bootstrap.packages]` に宣言し、初回セットアップでは mise の `brew` / `brew-cask` manager で導入します。`chezmoi apply` または `chezmoi update` のたびに `run_after_20-mise-upgrade.sh` が実行され、mise のグローバルツール、設定済み formula、mise 管理 cask を mise で更新します。

Homebrew が管理する cask は mise では更新されないため、Homebrew が利用可能な場合は同じフックから `brew upgrade --cask` を実行します。mise 管理 cask は mise が、Homebrew 管理 cask は Homebrew が更新し、既存の管理元は変更しません。Homebrew の通常の更新ルールを使い、`--greedy` は指定しません。

## Azure CLI preview cask

macOS では、Azure CLI を Homebrew core の formula ではなく、Microsoft Learn の preview 手順に沿った Homebrew cask 方式でインストールします。

- tap: `azure/azure-cli`
- cask: `azure-cli-preview`

preview 期間中は `azure-cli` formula をインストールせず、cask ベースのインストール方式と競合しないようにしています。

## cask の sudo 処理

Formula のインストール中は sudo を維持しません。cask のインストールを開始する直前に `sudo -v` を一度だけ実行し、cask の一括処理が続いている間だけ sudo のタイムスタンプを維持します。これにより、cask インストーラーによるパスワードの再入力を避けつつ、ブートストラップ完了後に sudo 維持プロセスを残しません。

## Apple Container の署名付き pkg

Apple Container は Apple silicon と macOS 26 以降を対象に、`run_once_after_35-install-apple-container.sh` が Apple 署名済みのバージョン付きインストーラ pkg から一度だけ導入します。フックは `com.apple.container-installer` の pkg receipt があれば何も変更せず、未導入の場合はリリースの SHA-256 とインストーラ署名を確認してから導入します。Docker / Docker Desktop の削除や、別の `container` インストールの上書きは行いません。通常の chezmoi 実行では Apple Container を更新しません。

更新する場合は、先に `container system stop` でサービスを停止してから `/usr/local/bin/update-container.sh` を実行します。更新には管理者権限が必要で、サービス実行中は updater が更新を拒否します。フックは未署名 pkg へフォールバックしません。
