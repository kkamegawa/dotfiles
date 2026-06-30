# WinGet 構成追加候補一覧

作成日: 2026-06-04

## 前提

- 比較元: `reference/windows/configuration.dsc.yaml`
- 現在の端末に入っているソフトは、Windows のアンインストール情報を元に確認
- このセッションでは `winget.exe` を直接実行できなかったため、`PackageIdentifier` は既存の公開情報と一般的な ID 規則を元に補完
- そのため、追加前に `winget search` または `winget show --id <PackageIdentifier>` で最終確認する想定

## 追加優先度が高い候補

| DisplayName | 想定 PackageIdentifier | 理由 |
| --- | --- | --- |
| 7-Zip 26.01 (x64) | `7zip.7zip` | 開発端末の定番で、再現性の高いベースラインに向く |
| Azure Cosmos DB Emulator | `Microsoft.Azure.CosmosEmulator` | Azure ローカル開発用途として再現性が高い |
| Azure Data CLI | `Microsoft.AzureDataCLI` | Azure 系 CLI として既存の Azure セットアップ方針に合う |
| CMake | `Kitware.CMake` | C/C++ 系ビルドやネイティブ開発の基盤として妥当 |
| HashiCorp Packer | `HashiCorp.Packer` | IaC / イメージビルド用途として端末再現性が高い |
| Kubernetes - Minikube - A Local Kubernetes Development Environment | `Kubernetes.minikube` | ローカル Kubernetes 開発環境として再現性が高い |
| Wireshark 4.6.6 x64 | `WiresharkFoundation.Wireshark` | ネットワーク調査用途として再利用性がある |

## 追加してもよさそうだが、用途確認を入れたい候補

| DisplayName | 想定 PackageIdentifier | 保留理由 |
| --- | --- | --- |
| Mozilla Firefox (x64 en-CA) | `Mozilla.Firefox` | Chrome / Edge は既に管理対象。追加するなら標準ブラウザ方針の確認が必要 |
| OBS Studio | `OBSProject.OBSStudio` | 収録・配信用途が常用なら候補。全端末標準かは要確認 |
| SQL Server Management Studio 22 | `Microsoft.SQLServerManagementStudio` | DB 管理用途としては有力だが、利用頻度の確認を入れたい |
| Python 3.12.10 | `Python.Python.3.12` | 既存構成は `mise` と `uv` を採用済み。グローバル Python も固定で持つか判断が必要 |
| Copilot | `Microsoft.Copilot` | 個人設定やプリインストール寄りのため、ベースライン化は要検討 |
| SharePoint Online Management Shell | `Microsoft.Online.SharePoint.PowerShell` | 業務で常用なら候補だが、PowerShell module 化との役割分担を確認したい |

## 構成に入れないほうがよさそうな候補

- Adobe Creative Cloud 関連一式
- Maxon / Cinema 4D / Magic Bullet 関連
- LightWave
- ゲーム類
- Canon / Dell / QNAP / REALFORCE などデバイス固有ツール
- e-Tax や筆まめのような個人用途アプリ
- Visual Studio や Windows SDK が展開した多数の副次コンポーネント

## 次にやるとよいこと

1. 上の「追加優先度が高い候補」を `winget show --id ...` で確認する
2. 問題なければ `reference/windows/configuration.dsc.yaml` に追記する
3. `winget export` が使える環境で再度差分を見て、漏れを最終確認する
