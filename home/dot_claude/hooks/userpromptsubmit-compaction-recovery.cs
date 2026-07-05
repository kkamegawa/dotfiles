#:include ClaudeHookCommon.cs

var input = ClaudeHookCommon.ReadInput();
var sessionId = ClaudeHookCommon.GetSessionId(input);

if (string.IsNullOrWhiteSpace(sessionId))
{
    return;
}

var markerDirectory = ClaudeHookCommon.TempDirectory("claude-compacted");
var markerPath = Path.Combine(markerDirectory, sessionId);

if (!ClaudeHookCommon.FileExists(markerPath))
{
    return;
}

ClaudeHookCommon.DeleteIfExists(markerPath);

var planDirectory = ClaudeHookCommon.TempDirectory("claude-active-plan");
var planPointerPath = Path.Combine(planDirectory, sessionId);
var planFile = string.Empty;

if (ClaudeHookCommon.FileExists(planPointerPath))
{
    planFile = ClaudeHookCommon.ReadTextIfExists(planPointerPath).Trim();
    if (!string.IsNullOrWhiteSpace(planFile) && !ClaudeHookCommon.FileExists(planFile))
    {
        planFile = string.Empty;
    }
}

var stateFile = Path.Combine(ClaudeHookCommon.TempDirectory("claude-compact-state"), $"{sessionId}.md");
var context = ClaudeHookCommon.BuildRecoveryContext(planFile, ClaudeHookCommon.FileExists(stateFile) ? stateFile : string.Empty);

ClaudeHookCommon.WriteHookSpecificContext("UserPromptSubmit", context);