#:include ClaudeHookCommon.cs

var input = ClaudeHookCommon.ReadInput();
var sessionId = ClaudeHookCommon.GetSessionId(input);

if (string.IsNullOrWhiteSpace(sessionId))
{
    return;
}

var warnedDirectory = ClaudeHookCommon.TempDirectory("claude-compact-warn");
var warnedMarkerPath = Path.Combine(warnedDirectory, sessionId);

if (!ClaudeHookCommon.FileExists(warnedMarkerPath))
{
    return;
}

var contextPercent = ClaudeHookCommon.ReadTextIfExists(warnedMarkerPath).Trim();
if (string.IsNullOrWhiteSpace(contextPercent))
{
    contextPercent = "?";
}

ClaudeHookCommon.DeleteIfExists(warnedMarkerPath);

var warnedCooldownDirectory = ClaudeHookCommon.TempDirectory("claude-compact-warned");
Directory.CreateDirectory(warnedCooldownDirectory);
ClaudeHookCommon.WriteText(Path.Combine(warnedCooldownDirectory, sessionId), DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString());

var context = ClaudeHookCommon.BuildCompactPrepReminder(contextPercent);
ClaudeHookCommon.WriteHookSpecificContext("UserPromptSubmit", context);