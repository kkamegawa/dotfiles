using System.Text.Json.Nodes;

// UserPromptSubmit hook: compact prep reminder (.NET 10 file-based program)
// If the statusLine script has set a warned marker (context >= 60%), inject
// a reminder to run /compact before the context window fills up.

try
{
    var input = await Console.In.ReadToEndAsync();
    var data = JsonNode.Parse(input.Length > 0 ? input : "{}");
    var sessionId = data?["session_id"]?.GetValue<string>() ?? "unknown";

    var stateDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".claude", "hooks-state");
    var warnFile = Path.Combine(stateDir, $"{sessionId}.warned");

    if (!File.Exists(warnFile))
        return;

    var output = new JsonObject
    {
        ["hookSpecificOutput"] = new JsonObject
        {
            ["hookEventName"] = "UserPromptSubmit",
            ["additionalContext"] =
                "Context window usage has reached 60% or more. " +
                "Consider running /compact soon to avoid losing context."
        }
    };
    Console.Write(output.ToJsonString());
}
catch
{
    // Never block the user's flow
}
