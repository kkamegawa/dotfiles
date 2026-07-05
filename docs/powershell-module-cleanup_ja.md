# PowerShell モジュールのクリーンアップ

グローバル mise 設定には、古い PowerShell モジュールバージョンを削除するタスクがあります。
このタスクは `~/.config/mise/oldpowershellmodule.cs` の C# file-based app を実行します。

## 対象

タスクは最新バージョンを残し、次のパターンに一致するモジュールの古いバージョンを削除します。

- `Az*`
- `Microsoft.Entra*`
- `Microsoft.Graph*`

アプリは `PSModulePath` と一般的な PowerShell モジュール配置を走査し、バージョンフォルダー名からインストール済みバージョンを検出します。
そのため、Windows と macOS の標準ユーザーモジュール配置で動作します。

## macOS での実行

```bash
# 削除対象を確認します。
mise run clean-old-pwsh-modules-dry-run

# 古いバージョンを削除します。
mise run clean-old-pwsh-modules
```

## Windows での実行

```powershell
# 削除対象を確認します。
mise run clean-old-pwsh-modules-dry-run

# 古いバージョンを削除します。
mise run clean-old-pwsh-modules
```

## 必要なもの

- .NET SDK 10 以降
- PowerShell 7
- PowerShellGet 互換の `Uninstall-Module` コマンド
