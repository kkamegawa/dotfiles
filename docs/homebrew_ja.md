# Homebrew パッケージ管理

## macOS の自動更新 cask

macOS のブートストラップでは、先に Homebrew formula をインストールし、その後で Homebrew cask をインストールします。

一部の cask アプリケーションは Homebrew の外側で自動更新されます。そのようなアプリが既に存在する状態で `brew install --cask` を再実行すると、Homebrew が記録している cask バージョンと、既に自動更新済みのアプリを比較してしまい、dotfiles のブートストラップでは無駄な処理になります。

Homebrew メタデータで `auto_updates` として扱われる cask は、次のいずれかに該当する場合にスキップします。

- Homebrew がその cask をインストール済みとして認識している。
- cask が宣言しているアプリケーション bundle が `/Applications` または `~/Applications` に存在する。

これにより、新しいマシンでの初回セットアップは維持しつつ、自分で更新機能を持つアプリに対する Homebrew の再処理を避けます。`auto_updates` ではない cask は、従来どおり `brew install --cask` を実行します。
