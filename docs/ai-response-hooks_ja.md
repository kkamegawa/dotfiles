# 日本語の最終応答を確認するフックテンプレート

[English](ai-response-hooks.md)

`reference/ai-response-hooks/` は **任意導入用**です。chezmoi の配布対象外で、
既存フック・設定・ホームは変更しません。Claude Code、Codex、**Copilot CLI**
の主エージェントの最終応答を検査します。Copilot の VS Code / cloud agent /
SDK callback、サブエージェントへの設定を兼ねるものではありません。

## 判定と製品ごとの契約

- fenced code（バッククォート・チルダ、未閉鎖の末尾も含む）と inline code を除外。
- Unicode の文字（letter）だけを数え、30文字未満は許可。
- ひらがな・カタカナ・漢字が文字数の **20%以上**なら許可。
  通常の仮名・半角カタカナ・漢字拡張を含みます。言語判定ではなくヒューリスティックです。
  中国語の漢字も通過し、長い英語の引用やリンクは判定対象です。
- 不合格は終了コード **0** で `{"decision":"block","reason":"..."}` を stdout に出し、
  回答だけを日本語で書き直すよう要求。既に表示された英語を消去・置換する機能ではありません。
- `stop_hook_active: true` は直ちに許可。1回の差し戻し後も英語ならそのまま終了します。
  状態ファイルは作らず、次の独立したターンは再び検査します。
- 許可時は stdout が空。最終文が空・null・取得できない形式なら stderr で診断して
  終了コード0でスキップ。不正JSON・入力型・読み取り・依存不足は stderr と終了コード1。
  エラーを「日本語への書き直し」として扱いません。タイムアウトや無効化もあるため
  日本語を保証する強制ポリシーではありません。

| 製品 | イベント / 入力 | 設定 |
| --- | --- | --- |
| Claude Code | `Stop` / `last_assistant_message` | `claude.settings.unix.json` または `.windows.json` |
| Codex | `Stop` / `last_assistant_message`（nullable） | `codex.hooks.json`、Windows は `commandWindows` |
| Copilot CLI | `agentStop` / `transcriptPath` の JSONL | `copilot.hooks.json`、`bash` / `powershell` |

Claude は Stop 時に transcript に最終文が保存済みとは限らないため、直接の入力を優先し、
Codex も不安定な rollout 形式を推測しません。両者とも transcript fallback はありません。
Copilot の `agentStop` には最終文の直接フィールドがないため、persisted session event の
最新の root `assistant.message.data.content` を使います。subagent / checkpoint /
reasoning / tool結果は除外し、ターン境界で候補を消して過去の回答を誤判定しません。
最後が tool-only・空・commentary の場合も以前の回答には戻りません。
PascalCase `Stop` 設定の `transcript_path` 入力も受け付けます。
**Copilot の transcript は安定した hook API ではありません**。CLI 更新時に形式を確認してください。
`stop_hook_active` がない旧版ではエラーにし、無限の差し戻しを避けます。

## 任意の設定方法

macOS/Linux は POSIX `sh`・`jq`・Perl、Windows は **PowerShell 7+ (`pwsh`)** が必要です。
PowerShell 版には jq/Perl/Node.js は不要です。いずれもフックの PATH から起動できることを確認します。
シェル版は `.gitattributes` に従い LF、その他の追加ファイルは CRLF・UTF-8 BOMなしです。
シェル版を CRLF に変換しないでください。`sh` で起動するため実行権限の追加は不要です。

1. このフォルダーを参照するか、必要なOSのスクリプトを任意の場所へコピーします。
2. 設定テンプレートの `/ABSOLUTE/PATH` / `C:/ABSOLUTE/PATH` を実際の絶対パスに変更。
   空白を含むパスは既存の引用符を保持。Unix のパスの `'` はシェル用に `'"'"'`、
   Copilot の PowerShell の単一引用符内の `'` は `''` にし、JSONのエスケープも守ります。
   Windows のパスには `/` を使うと JSON のバックスラッシュ二重化が不要です。
3. **既存設定を丸ごと上書きせず**、対象イベントの配列にハンドラーを追加します。
   - Claude: OS別テンプレートの `hooks.Stop` を `~/.claude/settings.json` に追加。
   - Codex: `~/.codex/hooks.json` に追加するか、既存の `config.toml` の inline hooks に
     同じハンドラーを追加。既存 inline hooks がある場合はそちらを選び、
     同一層の両形式併用による警告・二重実行を避けます。TOML の Windows キーは
     `command_windows`（`commandWindows` も可）、`timeout = 30`。`/hooks` で確認・信頼します。
   - Copilot CLI: 編集済み設定を `~/.copilot/hooks/japanese-response.json` に配置。
     独自 `COPILOT_HOME` / `CODEX_HOME` がある場合は設定先を合わせます。
4. クライアントを再起動し、読み込まれた設定を確認。使い捨てセッションで無害な英語回答と
   日本語回答を試します。Claude の repo-local settings は Copilot にも読まれるため、
   Claude用の設定を共有リポジトリへ置く場合は二重登録・契約の混同に注意してください。

既存の自動フック配布には追加していません。テンプレートを適用した後も、chezmoi や
他の設定管理がその設定を保持するか確認してください。無効化は追加したハンドラー
（Copilot は独立ファイル）だけを削除し、他のフックを残します。

## ローカル確認

リポジトリルートで実行（ホーム・実CLI・サービスには適用しません）:

```bash
python3 -m unittest discover -s scripts/tests -p test_japanese_response_hooks.py -v
```

```powershell
python -m unittest discover -s scripts/tests -p test_japanese_response_hooks.py -v
if ($LASTEXITCODE -ne 0) { throw "Response hook tests failed" }
```

利用可能なインタープリターだけを実行します。macOS での pwsh テストは Windows での
実機検証ではありません。テストは言語比率の境界、コード除外、差し戻し回避、入力エラー、
一時JSONLの最新文選択と設定構造を確認します。実製品のフック発火・trust・sandbox・
transcript の保存タイミングは実CLIで別途確認が必要です。

## 参照仕様

2026-11-07 に確認:

- [Claude Code Stop](https://code.claude.com/docs/en/hooks#stop)
- [Codex hooks](https://developers.openai.com/codex/hooks)
- [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Copilot SDK persisted event types](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts)
