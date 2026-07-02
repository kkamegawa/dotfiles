# Homebrew パッケージ管理

## macOS の自動更新 cask

macOS のブートストラップでは、先に Homebrew formula をインストールし、その後で Homebrew cask をインストールします。

一部の cask アプリケーションは Homebrew の外側で自動更新されます。そのようなアプリが既に存在する状態で `brew install --cask` を再実行すると、Homebrew が記録している cask バージョンと、既に自動更新済みのアプリを比較してしまい、dotfiles のブートストラップでは無駄な処理になります。

dotfiles のセットアップでは、cask をインストール専用として扱います。Homebrew がその cask をインストール済みとして認識している場合はスキップし、ブートストラップ中の `brew install --cask` が暗黙的なアップグレードを始めないようにします。

Homebrew メタデータで `auto_updates` として扱われる cask は、初回の正常なインストールだけを Homebrew 管理のインストールとして扱います。以降の実行では、Homebrew メタデータがインストール済みと記録していればスキップします。Homebrew 以外の方法でインストール済みの場合も、cask が宣言しているアプリケーション bundle が `/Applications`、`~/Applications`、または cask メタデータ内の絶対 `.app` パスに存在すればスキップします。

これにより、新しいマシンでの初回セットアップは維持しつつ、自分で更新機能を持つアプリに対する Homebrew の再処理を避けます。未インストールの cask は、従来どおり `brew install --cask` を実行します。

## Azure CLI preview cask

macOS では、Azure CLI を Homebrew core の formula ではなく、Microsoft Learn の preview 手順に沿った Homebrew cask 方式でインストールします。

- tap: `azure/azure-cli`
- cask: `azure-cli-preview`

preview 期間中は `azure-cli` formula をインストールせず、cask ベースのインストール方式と競合しないようにしています。

## cask の sudo 処理

Formula のインストール中は sudo を維持しません。cask のインストールを開始する直前に `sudo -v` を一度だけ実行し、cask の一括処理が続いている間だけ sudo のタイムスタンプを維持します。これにより、cask インストーラーによるパスワードの再入力を避けつつ、ブートストラップ完了後に sudo 維持プロセスを残しません。
