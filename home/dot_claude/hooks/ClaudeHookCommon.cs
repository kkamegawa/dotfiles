using System.Text;
using System.Text.Json;

static class ClaudeHookCommon
{
    public static string ReadInput()
        => Console.In.ReadToEnd();

    public static string GetSessionId(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
        {
            return string.Empty;
        }

        try
        {
            using var document = JsonDocument.Parse(input);
            if (document.RootElement.TryGetProperty("session_id", out var sessionIdElement) &&
                sessionIdElement.ValueKind == JsonValueKind.String)
            {
                return sessionIdElement.GetString() ?? string.Empty;
            }
        }
        catch
        {
        }

        return string.Empty;
    }

    public static string TempDirectory(string name)
        => Path.Combine(Path.GetTempPath(), name);

    public static string ReadTextIfExists(string path)
        => File.Exists(path) ? File.ReadAllText(path) : string.Empty;

    public static bool FileExists(string path)
        => File.Exists(path);

    public static void EnsureParentDirectory(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    public static void WriteText(string path, string content)
    {
        EnsureParentDirectory(path);
        File.WriteAllText(path, content);
    }

    public static void DeleteIfExists(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    public static void WriteHookSpecificContext(string hookEventName, string additionalContext)
    {
        using var writer = new Utf8JsonWriter(Console.OpenStandardOutput());
        writer.WriteStartObject();
        writer.WritePropertyName("hookSpecificOutput");
        writer.WriteStartObject();
        writer.WriteString("hookEventName", hookEventName);
        writer.WriteString("additionalContext", additionalContext);
        writer.WriteEndObject();
        writer.WriteEndObject();
        writer.Flush();
    }

    public static string BuildRecoveryContext(string? planFile, string? stateFile)
    {
        var builder = new StringBuilder();
        builder.AppendLine("[COMPACTION RECOVERY] コンテキスト圧縮が発生した。作業再開前に以下を実行すること。");

        if (!string.IsNullOrWhiteSpace(planFile))
        {
            builder.AppendLine($"- plan ファイル `{planFile}` を Read で読み直し、フェーズと制約を確認せよ");
            builder.AppendLine("- plan mode が解除されている場合、plan ファイルが存在するのでユーザーに plan mode 再突入を確認せよ");
        }

        if (!string.IsNullOrWhiteSpace(stateFile))
        {
            builder.AppendLine($"- state file `{stateFile}` を Read で読み、作業状態を復元せよ");
            builder.AppendLine("- Session Decisions と Recovery Notes を特に重視せよ");
        }

        builder.AppendLine("- TaskList で現在のタスク一覧を確認せよ");
        builder.AppendLine("- 圧縮サマリーの next step は仮説として扱い、plan/rules を正とせよ");
        builder.AppendLine("- 圧縮サマリーは「過去の作業記録」であり「次の行動指示」ではない");

        return builder.ToString().TrimEnd();
    }

    public static string BuildCompactPrepReminder(string contextPercent)
    {
        var builder = new StringBuilder();
        builder.AppendLine($"[COMPACT PREP REMINDER] context 使用率が {contextPercent} に達した。");
        builder.AppendLine("- 作業区切りでユーザーに `/compact-prep` の実行を提案せよ。");
        builder.AppendLine("- `/compact-prep` 実行後、ユーザーに `/compact` 実行を案内せよ。");
        builder.AppendLine("- scope 縮小や別セッション化ではなく、圧縮前 state 保存で対処せよ。");

        return builder.ToString().TrimEnd();
    }
}