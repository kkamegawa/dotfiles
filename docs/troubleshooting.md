# トラブルシューティング

## chezmoi

### `chezmoi apply` でテンプレートエラーが出る

```
chezmoi: template: ... variable is not defined
```

**原因**: `.chezmoi.toml.tmpl` で定義した変数が未入力。

**対処**:
```sh
# 変数を再設定して再実行
chezmoi init --force
chezmoi apply
```

---

## mise

### `mise: command not found`

```sh
# mise の PATH を確認
echo $PATH | tr ':' '\n' | grep mise

# mise をインストール
curl -fsSL https://mise.run | sh

# シェルを再起動するか PATH を再読み込み
source ~/.profile
```

### mise install が失敗する

**Node.js のビルドに失敗する場合（Linux）**:
```sh
sudo apt-get install -y build-essential libssl-dev
```

---

## git コミット署名

### `error: gpg failed to sign the data`

1Password SSH エージェントが起動していない可能性があります。

**macOS**:
```sh
# エージェント確認
ls ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
```

**一時的に署名を無効化してコミット**:
```sh
git commit --no-gpg-sign -m "your message"
```

---

## Windows DSC

### `winget configure` が途中で止まる

UAC プロンプトが表示されている可能性があります。ウィンドウを確認して承認してください。

### パッケージが見つからないエラー

```
指定されたパッケージが見つかりませんでした
```

**対処**:
```powershell
# winget ソースを更新
winget source update

# 再実行
winget configure -f "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
```

---

## 1Password SSH エージェント

### WSL から SSH 接続に失敗する

```sh
# npiperelay のソケットを確認
ls ~/.1password/agent.sock

# SSH エージェントに登録されているキーを確認
ssh-add -L

# 1Password デスクトップアプリが起動しているか確認（Windows 側）
```

---

## APM

### `apm install` が失敗する

```sh
# GitHub 認証を確認
gh auth status

# 再認証
gh auth login
apm install
```
