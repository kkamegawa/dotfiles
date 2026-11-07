# Claude Code のコマンドフック

[English](claude-command-hooks.md)

管理対象の `PreToolUse` フックは、先頭の変数代入や
`cd /repo && python3 script.py` のようなディレクトリ変更を使わず、
絶対パスを直接指定するよう Claude Code に促します。代入ガードと
ディレクトリ変更ガードは独立しています。これは構文上の好みを
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
  `leading-assignment.ps1` と `deny-cd.ps1` をそれぞれ実行します。
  matcher は `^(Bash|PowerShell|powershell)$` です。
- macOS/Linux: `sh` で `leading-assignment.sh` と `deny-cd.sh` をそれぞれ実行します。
  matcher は `^Bash$` です。Unix では PowerShell 構文を検査しません。
- 各ガードについて OS に必要な方だけを配置します。スクリプトのパスは Claude home
  テンプレート由来の絶対パスで、タイムアウトは 10 秒です。
- `PowerShell` と `powershell` は明示したツール名です。別名の MCP ツールや、
  コマンドが `tool_input.command` 以外に入るクライアントには、登録・検証の
  調整が必要です。

既存の `guard.mjs` は変更せず独立したフックとして残します。ユーザー管理の
無関係なフックは保持し、管理対象のフックは再作成するため、繰り返し適用しても
重複しません。permissions の allow/ask/deny のマージ動作は維持されます。
このフック自身は allow を返しません。問題のないコマンドは通常の権限判定に
進み、拒否時は Claude Code で他フックの承認よりブロックが優先されます。

## 先頭代入の構文と限界（既存動作は変更なし）

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
同等の変数利用をすべて防ぐものではありません。

## ディレクトリ変更の構文と限界

`deny-cd.sh` は `cd`、`pushd`、`popd`、`chdir` を大文字・小文字を
区別して拒否します。`deny-cd.ps1` はさらに `sl`、`Set-Location`、
`Push-Location`、`Pop-Location` を拒否し、すべてのコマンド名で
大文字・小文字を区別しません。Windows の Bash ツールにもこの規則を適用します。
Unix の対象ツールは `Bash` のみ、Windows は上記の正確な 3 ツール名です。

先頭、または `;`、`&&`、`||`、`|`、`&`、実際の CR/LF 改行、
丸括弧、波括弧、バッククォートの後を検査します。グループ化、
スクリプトブロック、一般的なコマンド置換にも対応します。
境界直後の空白・タブ、および独立した制御トークン `if`、`then`、`elif`、
`else`、`while`、`until`、`do`、`!` の繰り返しを認識します。
コマンド名の直後は空白、入力末尾、またはリダイレクトを含むシェル区切り文字
である必要があります。引数なしの `cd`、`cd -`、`cd -- /repo` も拒否します。
`cdrom`、`pushdown`、`echo then cd` は拒否せず、識別子内の
制御キーワード部分文字列を境界として扱いません。

代わりに `git -C '/absolute/repo' status` や
`python3 '/absolute/path/script.py'` を使います。通常の絶対パス指定や
無関係なツールは無出力で通過します。対象のディレクトリ変更がなければ
コマンド連結自体は禁止しません。

**意図的な限界:** 引用や入れ子を完全に解析するシェルパーサーではなく、
保守的な構文チェックです。`echo "text; cd /repo"` のように引用文字列内に
境界があると誤検知することがあります。エスケープ、引用したコマンド名
（`'cd' /repo`）、ラッパー（`env cd`、`command cd`、`builtin cd`）、
モジュール修飾名、独自エイリアス／関数、入れ子のインタープリターの意味は
解決しません。入れ子の文字列に認識する境界があれば検出する場合がありますが、
網羅的な解析はしません。Python の `os.chdir(...)` などのライブラリー呼び出し、
外部スクリプト、その他同等の作業ディレクトリ変更は意図的な迂回方法として
対象外です。このフックはセキュリティサンドボックスではありません。

Unix では既存依存の Node.js で厳密な JSON 検証と照合を行い、jq などの
依存は追加しません。PowerShell 7 は `JsonDocument` で厳密に検証してから
`ConvertFrom-Json -AsHashtable` で読み取ります。`.sh` は `.gitattributes`
の規約どおり LF とし、実行ビットや shebang に頼らず `sh` で明示的に起動します。

## 終了状態とテスト

- **0**: stdout/stderr は空。各ガードの対象構文がない場合、または正常な JSON
  オブジェクトで無関係なツール名の場合です。権限の承認ではありません。
- **2**: stdout は空、stderr に絶対パスを直接指定するよう促すメッセージ。
  対象の先頭代入またはディレクトリ変更を検出した場合です。
  ディレクトリ変更の診断には `git -C` と `python3` の代替例も含めます。
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
python3 -m unittest discover -s scripts/tests -p 'test_claude_*hooks.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
```

PowerShell 7:

```powershell
python -m unittest discover -s scripts/tests -p 'test_claude_*hooks.py' -v
if ($LASTEXITCODE -ne 0) { throw "Hook tests failed" }
python -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
if ($LASTEXITCODE -ne 0) { throw "Merge tests failed" }
```

必要な実行ツールがないテストは明示的にスキップされます。Claude Code 本体の
起動や、実セッション内でのフック優先順位の確認はこれらのテストには含みません。
