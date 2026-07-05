using System.Text.Json.Nodes;

// UserPromptSubmit hook: compaction recovery (.NET 10 file-based program)
// If a compact_summary was saved by the PostCompact hook, inject it as
// additionalContext so Claude knows the prior session state.

try
{
    var input = await Console.In.ReadToEndAsync();
    var data = JsonNode.Parse(input.Length > 0 ? input : "{}");
    var sessionId = data?["session_id"]?.GetValue<string>() ?? "unknown";

    var stateDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".claude", "hooks-state");
    var summaryFile = Path.Combine(stateDir, $"{sessionId}.summary");

    if (!File.Exists(summaryFile))
        return;

    var summary = await File.ReadAllTextAsync(summaryFile);

    var output = new JsonObject
    {
        ["hookSpecificOutput"] = new JsonObject
        {
            ["hookEventName"] = "UserPromptSubmit",
            ["additionalContext"] =
                "[Post-compact recovery] The context window was compacted. " +
                $"Summary of the previous session:\n{summary}"
        }
    };
    Console.Write(output.ToJsonString());

    File.Delete(summaryFile); // One-shot: inject once then discard
}
catch
{
    // Never block the user's flow
}
