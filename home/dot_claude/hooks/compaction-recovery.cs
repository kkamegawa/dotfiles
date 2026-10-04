using System.Text.Json.Nodes;

// PostCompact hook (.NET 10 file-based program)
// Saves compact_summary so the next UserPromptSubmit hook can restore it.

try
{
    var input = await Console.In.ReadToEndAsync();
    var data = JsonNode.Parse(input.Length > 0 ? input : "{}");
    var sessionId = data?["session_id"]?.GetValue<string>() ?? "unknown";
    var summary = data?["compact_summary"]?.GetValue<string>() ?? string.Empty;

    var stateDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".claude", "hooks-state");
    Directory.CreateDirectory(stateDir);

    if (!string.IsNullOrWhiteSpace(summary))
    {
        await File.WriteAllTextAsync(
            Path.Combine(stateDir, $"{sessionId}.summary"), summary);
    }
}
catch
{
    // Never block the user's flow
}
