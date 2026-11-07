# Claude Code の先頭変数代入フック

[English](claude-command-hooks.md)

管理対象の `PreToolUse` フックは、コマンドの先頭でパスを変数に代入せず、
絶対パスを直接指定するよう Claude Code に促します。これは構文上の好みを
反映する仕組みであり、包括的なシェルのセキュリティ境界ではありません。
フックは受信したコマンドを実行しません。

## 適用方法

必要なものは chezmoi と、Windows では PATH 上の PowerShell **7 以降**
（`pwsh`）、macOS/Linux では POSIX `sh` と Node.js です。
Unix でこのフックを実行するために PowerShell を導入する必要はありません。
Node.js は既存の Claude フックでも使用しています。Windows では
`ConvertFrom-Json` で JSON を読み取り、プロファイルを読み込みません。
Claude Code 側には、このリポジトリの `command` + `args` 形式に対応した
コマンドフックのサポートが必要です。

以下のソースパスを実際のチェックアウト先に置き換えてください。
先に差分を確認し、フックと設定だけを適用します。`--exclude scripts` により
無関係なライフサイクルスクリプトを実行しません。ただし settings の適用では、
このフック以外のリポジトリ管理設定も既存のマージ規則で反映されます。

Bash（macOS/Linux）:

```bash
set -e
chezmoi --source "/absolute/path/to/dotfiles" diff --exclude scripts \
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
chezmoi --source "/absolute/path/to/dotfiles" apply --exclude scripts \
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
```

PowerShell 7（Windows）:

```powershell
chezmoi --source "C:/absolute/path/to/dotfiles" diff --exclude scripts `
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
if ($LASTEXITCODE -ne 0) { throw "chezmoi preview failed" }
chezmoi --source "C:/absolute/path/to/dotfiles" apply --exclude scripts `
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
if ($LASTEXITCODE -ne 0) { throw "chezmoi apply failed" }
```

ここでの `$HOME` は引数内での既存変数の参照であり、先頭の代入ではありません。
フックの絶対パスは JSON の個別引数としてシリアライズされるため、空白や
日本語を含むパスも扱えます。ソースの編集や一時ディレクトリでのテストだけでは、
実ユーザーの設定は変わりません。明示的な chezmoi apply 時に変更されます。
その後 Claude Code の `/hooks` で `PreToolUse` への登録を確認してください。
必要であれば Claude Code を再起動して設定を再読み込みします。

## 登録と既存設定

- Windows: `pwsh -NoLogo -NoProfile -NonInteractive -File` で
  `leading-assignment.ps1` を実行します。
  matcher は `^(Bash|PowerShell|powershell)$` です。
- macOS/Linux: `sh` で `leading-assignment.sh` を実行します。
  matcher は `^Bash$` です。Unix では PowerShell 構文を検査しません。
- OS に必要な方の代入フックだけを配置します。スクリプトのパスは Claude home
  テンプレート由来の絶対パスで、タイムアウトは 10 秒です。
- `PowerShell` と `powershell` は明示したツール名です。別名の MCP ツールや、
  コマンドが `tool_input.command` 以外に入るクライアントには、登録・検証の
  調整が必要です。

既存の `guard.mjs` は変更せず独立したフックとして残します。ユーザー管理の
無関係なフックは保持し、管理対象のフックは再作成するため、繰り返し適用しても
重複しません。permissions の allow/ask/deny のマージ動作は維持されます。
このフック自身は allow を返しません。問題のないコマンドは通常の権限判定に
進み、拒否時は Claude Code で他フックの承認よりブロックが優先されます。

## 検査する構文と限界

先頭の空白・改行を除いた位置にある次の構文を拒否します。

- 両 OS: ASCII のシェル識別子による `NAME=value` と `NAME+=value`。
  `R='/a path'; git ...`、`R=/repo git ...`、代入だけの `R=/repo` も対象です。
  名前と代入演算子の間に空白がある構文はシェル代入として扱いません。
- Windows: `$root = 'C:/repo'`、`$env:ROOT='C:/repo'`、
  `${root}='C:/repo'`、`${script:root}='C:/repo'` など。
  名前は Unicode の文字・数字・アンダースコアで、数字で始まらないものです。
  同じ形式のスコープ／プロバイダー接頭辞を一つ付けられます。
  `=`、`+=`、`-=`、`*=`、`/=`、`%=`、`??=` を検査します。
  Bash と明示した PowerShell ツール名の両方に適用します。

比較の `$root -eq 'x'` や `$root == 'x'`、引数内の `git -C $root status`、
`git -c key=value status`、文字列内の `echo "R=/repo"` は拒否しません。

**意図的な対象外:** `export R=...` と `env R=... command` は、先頭がラッパー
なので通過します。コマンド途中、コメントの後、スクリプトブロックやサブシェル
内、入れ子の `pwsh`／シェル呼び出しの代入は追跡しません。
`$object.Path=...`、`$root[0]=...`、特殊な波括弧付き変数名、
`Set-Variable`、`New-Variable` も対象外です。引数内の既存変数参照は許可します。
`cd`、コマンド連結などに新たな禁止規則は追加しません。
同等の変数利用をすべて防ぐものではありません。

## 終了状態とテスト

- **0**: stdout/stderr は空。対象の先頭代入がない場合、または正常な JSON
  オブジェクトで無関係なツール名の場合です。権限の承認ではありません。
- **2**: stdout は空、stderr に絶対パスを直接指定するよう促すメッセージ。
  対象の先頭代入を検出した場合です。
- **2**: stdout は空、stderr に連携設定の修正を促す診断。
  不正 JSON、オブジェクトでない値、欠落・不正な `tool_name`、対象ツールでの
  欠落・文字列でない `tool_input.command` を拒否します。Unix では Node.js の
  不在や実行失敗も報告します。

実スクリプトを空白・日本語を含むパスから実行し、許可する例・対象外の例も
検査します。chezmoi のマージテストは一時配置先を使います。
3 OS のテンプレート描画は、その OS 上の実行確認とは異なります。

リポジトリのルートから、Bash:

```bash
set -e
python -m unittest discover -s scripts/tests -p 'test_claude_assignment_hooks.py' -v
python -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
```

PowerShell 7:

```powershell
python -m unittest discover -s scripts/tests -p 'test_claude_assignment_hooks.py' -v
if ($LASTEXITCODE -ne 0) { throw "Hook tests failed" }
python -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
if ($LASTEXITCODE -ne 0) { throw "Merge tests failed" }
```

必要な実行ツールがないテストは明示的にスキップされます。Claude Code 本体の
起動や、実セッション内でのフック優先順位の確認はこれらのテストには含みません。
