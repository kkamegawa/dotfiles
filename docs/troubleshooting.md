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

1Password SSH エージェントが起動していないか、`op-ssh-sign` 実行ファイルが想定パスに存在しない可能性があります。

この dotfiles では `chezmoi apply` 実行時に `op-ssh-sign` の存在を確認し、見つからない環境では `commit.gpgsign = false` を生成してコミット署名を自動で無効化します。

1Password をインストールまたは修復した後は、再度 `chezmoi apply` を実行してください。

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

### `chezmoi apply` 後に APM のプロファイルが更新されない

```sh
# APM CLI と Python が使えるか確認
apm --version
python3 --version

# GitHub 認証を確認
gh auth status

# ステージングと反映を再実行
chezmoi apply
```

Windows PowerShell 7:

```powershell
# APM CLI と Python が使えるか確認
apm --version
python --version

# GitHub 認証を確認し、ステージングと反映を再実行
gh auth status
chezmoi apply
```

APM CLI、マニフェスト、Python が見つからない場合、フックは警告を出して更新をスキップします。APM の取得または検証が失敗した場合、既存のユーザープロファイルは変更されません。必要なツールをインストールするか認証を直してから、`chezmoi apply` を再実行してください。

### APM の反映が競合で中止される

反映先に所有権のないファイル、手動編集された APM 管理ファイル、または想定外のシンボリックリンクがある場合、フックは上書きを中止します。エラーに表示されたパスを確認し、必要なファイルをバックアップしたうえで競合を解消してから、もう一度 `chezmoi apply` を実行してください。所有台帳 `~/.config/apm-profile/ownership.json` を手動で編集・削除しないでください。

---

## Claude Code フック

### フックが動かない（`Cannot find module '...\__CLAUDE_HOME__\hooks\...'`）

`~/.claude/settings.json` に `__CLAUDE_HOME__` が残っていると、フックのパスがセッションの作業ディレクトリ基準で解決され、すべてのフックが失敗します（エラーは non-blocking のため気付きにくい）。現在のテンプレートは絶対パスを生成するので、最新のソースで再適用します。

```sh
chezmoi update
grep -c __CLAUDE_HOME__ ~/.claude/settings.json   # 0 になること
```

```powershell
chezmoi update
(Select-String -Path ~/.claude/settings.json -Pattern '__CLAUDE_HOME__').Count   # 0 になること
```

### 60% で自動圧縮されない

`~/.claude/settings.json` の `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` が `"60"` になっているかを確認します。設定変更は新しいセッションから有効になります。

