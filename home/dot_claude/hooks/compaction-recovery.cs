#:include ClaudeHookCommon.cs

var input = ClaudeHookCommon.ReadInput();
var sessionId = ClaudeHookCommon.GetSessionId(input);

if (string.IsNullOrWhiteSpace(sessionId))
{
    return;
}

var markerDirectory = ClaudeHookCommon.TempDirectory("claude-compacted");
Directory.CreateDirectory(markerDirectory);
ClaudeHookCommon.WriteText(Path.Combine(markerDirectory, sessionId), DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString());

var warnedDirectory = ClaudeHookCommon.TempDirectory("claude-compact-warned");
ClaudeHookCommon.DeleteIfExists(Path.Combine(warnedDirectory, sessionId));