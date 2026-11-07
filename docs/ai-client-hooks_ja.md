# Claude・Codex・Copilot CLI の共通フック

[English](ai-client-hooks.md)

Claude の既存の登録・スクリプトは変更しません。Codex と Copilot CLI には、
Claude の実際のコマンドガードを chezmoi の include で
`~/.local/share/dotfiles/ai-hooks/` に配布します。ルールの複製によるずれを避け、
実行時に `~/.claude` がインストールされていることも要求しません。

## 対応範囲と制限

| Claude の既存機能 | Codex | Copilot CLI |
| --- | --- | --- |
| `guard.mjs` のシェルへのパイプ拒否・信頼対象 `gh pr` / `gh issue` 操作の承認 | `PreToolUse` | `PreToolUse` |
| 先頭の変数代入・ディレクトリ変更の拒否 | `PreToolUse` | `PreToolUse` |
| Edit/Write 後の `format.mjs` | 非同期 `PostToolUse` | 同期 `PostToolUse` |
| 圧縮要約の保存・次の入力時に一度だけ復元 | `PostCompact` + `UserPromptSubmit`、ベストエフォート | 非対応・登録しない |
| `statusline.mjs` | 移植しない | 移植しない |

**現在の formatter は JSON を読み取って終了するだけで、ファイルを変更しません。**
この動作をそのまま共有し、Codex の `apply_patch` や Copilot の
`edit` / `create` / `apply_patch` の PATCH 本文をファイルパスとして扱いません。
Copilot の command hook 設定に Codex 型の `async` はないため、軽い no-op を同期実行します。

Codex の標準 PostCompact payload には Claude の `compact_summary` がありません。
この値が存在すれば使い、なければ `transcript_path` の最新の
`{"type":"compacted","payload":{"message":"..."}}` レコードだけを読み取ります。
**transcript は安定した API ではありません。** 未知の形式や要約の欠如は診断を出して
復元をスキップし、読み取り・解析・保存の失敗はフックエラーとして報告します。
復元などの補助フックのエラーは終了コード 1 で報告し、入力を拒否する終了コード 2 は使いません。
新しい圧縮では古い保存状態を最初に消し、古い要約を誤って復元しません。
セッション ID はハッシュ化し、共通ディレクトリ内の `state/codex` に分離して保存し、
一度だけ復元します。Node のアダプターで既存 C# フックの保存・復元動作を合わせ、
Claude の `.claude/hooks-state` は変更せず、他クライアントに .NET も要求しません。

Copilot にあるのは **PreCompact** だけで、PostCompact はありません。
設定ファイルの UserPromptSubmit command hook の出力も取り込まれません。
圧縮前に復元を代用したり、存在しないイベントを登録したりはしません。
status line は Claude 固有の表示機能であり、ライフサイクルフックではありません。
対象はローカル CLI で、Copilot cloud agent や VS Code への配布ではありません。

## 設定・エラー・所有権

- Codex は既存の `~/.codex/config.toml` に inline `[hooks]` をマージします。
  管理対象 `hooks.json` は作りません。既存の `hooks.json` があれば Codex は両方を読み、
  警告します。同じ定義を重複登録せず、ローカルの設定元を確認してください。
- Copilot は `~/.copilot/hooks/dotfiles.json` の version 1、PascalCase イベント
  （snake_case 互換 payload）、直接起動の `exec` + `args`、`timeoutSec` を使います。
  `exec` と command/bash/powershell は併用しません。他のフックファイルや inline 設定は
  変更しません。独自の `COPILOT_HOME` / `CODEX_HOME` には配布先の調整が必要です。
- 共通 `ai-hooks/adapter.*` を参照するハンドラーだけを再登録します。
  同じ Codex matcher グループ内の外部ハンドラー、別イベント、メタデータも保持し、
  再適用で重複しません。
- macOS/Linux は POSIX `sh` と Node.js、Windows は PowerShell **7+** (`pwsh`) と
  Node.js が必要です。OS に対応するシェル版だけを配布します。
  Codex は PowerShell ホストでも標準の `Bash` を通知します。
  Copilot の `bash` / `powershell` も共通ガード向けに正規化します。
- 代入・ディレクトリガードを**信頼対象の承認より先に**実行します。
  不正なシェル payload、依存スクリプト・インタープリターの欠如、ガード失敗は
  明示的な deny と終了コード 2 で拒否します。payload のコマンドは実行しません。
  通常の成功時は何も出力せず、通常の権限確認に委ねます。
  Copilot は直接の permissionDecision、Codex は hookSpecificOutput を受け取ります。
  OS 別の構文上の限界は [Claude コマンドフック](claude-command-hooks_ja.md) と同じです。
  完全なシェル安全性の境界ではなく、クライアント側の信頼・無効化・対象ツール・
  タイムアウトの制約も残ります。特に Copilot のタイムアウトは fail-open になり得るため、
  ユーザーフックを管理者ポリシーの代わりにはできません。

## インストールと確認

自分の checkout の絶対パスで、先にプレビューしてください。

```bash
set -e
chezmoi --source "/absolute/path/to/dotfiles" diff --exclude scripts \
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
chezmoi --source "/absolute/path/to/dotfiles" apply --exclude scripts \
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
```

```powershell
chezmoi --source "C:/absolute/path/to/dotfiles" diff --exclude scripts `
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
if ($LASTEXITCODE -ne 0) { throw "chezmoi preview failed" }
chezmoi --source "C:/absolute/path/to/dotfiles" apply --exclude scripts `
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
if ($LASTEXITCODE -ne 0) { throw "chezmoi apply failed" }
```

個別 apply では親ディレクトリが事前に必要です（通常の全体 apply では作成されます）。
Codex の対象は他の管理設定もマージします。テストによるインストール、実 HOME への適用、
フックの信頼確認の迂回は行いません。

適用後はクライアントを再起動します。Codex の **`/hooks` で新しい定義を確認・信頼**
してください。未確認のフックはスキップされます。この手順は迂回しません。
Copilot では読み込まれたフックを確認し、使い捨てセッションで無害な許可コマンドと
拒否対象のディレクトリ変更を確認してください。

テストは一時 HOME で全 OS の生成・配布、生成された起動コマンド、外部フック保持、
再適用、不正入力・依存欠如の拒否、sh/PowerShell の実アダプター、
fixture による Codex の一度だけの復元を確認します。
macOS 上で Windows/Linux 用を実行しても、実 OS や実 CLI セッションでの検証とは異なります。

## 仕様の参照先

- [GitHub Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Codex hooks](https://developers.openai.com/codex/hooks)

対応範囲はこれらの公開仕様に従います。CLI での実セッションの確認は別途必要です。
