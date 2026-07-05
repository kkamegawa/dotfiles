#!/usr/bin/env dotnet
#:property TargetFramework=net10.0

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

var options = CleanupOptions.Parse(args);
var powershell = ResolvePowerShellExecutable();
if (powershell is null)
{
    Console.Error.WriteLine("PowerShell 7 is required. Install pwsh and run this task again.");
    return 1;
}

try
{
    var modules = GetInstalledModulesFromModulePaths(options.Patterns);
    if (modules.Count == 0)
    {
        Console.WriteLine("No matching PowerShell modules were found.");
        return 0;
    }

    var groups = modules
        .Where(module => !string.IsNullOrWhiteSpace(module.Name) && !string.IsNullOrWhiteSpace(module.Version))
        .GroupBy(module => module.Name, StringComparer.OrdinalIgnoreCase)
        .OrderBy(group => group.Key, StringComparer.OrdinalIgnoreCase);

    foreach (var group in groups)
    {
        var orderedModules = group
            .DistinctBy(module => $"{module.Name}\u001f{module.Version}\u001f{module.InstalledLocation}", StringComparer.OrdinalIgnoreCase)
            .OrderBy(module => SemanticVersion.Parse(module.Version), SemanticVersion.Comparer)
            .ToList();

        if (orderedModules.Count <= 1)
        {
            Console.WriteLine($"Keep {group.Key}: only one version is installed.");
            continue;
        }

        var latest = orderedModules[^1];
        Console.WriteLine($"Keep {group.Key} {latest.Version}");

        foreach (var module in orderedModules.Take(orderedModules.Count - 1))
        {
            await RemoveInstalledModuleAsync(powershell, module, options.DryRun);
        }

        RemoveStaleVersionFolders(group.Key, orderedModules, options.DryRun);
    }

    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}

static List<InstalledModule> GetInstalledModulesFromModulePaths(IReadOnlyList<string> patterns)
{
    var modules = new List<InstalledModule>();
    foreach (var modulePath in GetPowerShellModulePaths())
    {
        if (!Directory.Exists(modulePath))
        {
            continue;
        }

        foreach (var moduleDirectory in Directory.EnumerateDirectories(modulePath))
        {
            var moduleName = Path.GetFileName(moduleDirectory);
            if (!patterns.Any(pattern => WildcardMatches(moduleName, pattern)))
            {
                continue;
            }

            foreach (var versionDirectory in Directory.EnumerateDirectories(moduleDirectory))
            {
                var version = Path.GetFileName(versionDirectory);
                if (!SemanticVersion.TryParse(version, out _))
                {
                    continue;
                }

                modules.Add(new InstalledModule(moduleName, version, versionDirectory));
            }
        }
    }

    return modules;
}

static IReadOnlyList<string> GetPowerShellModulePaths()
{
    var paths = new List<string>();
    var psModulePath = Environment.GetEnvironmentVariable("PSModulePath");
    if (!string.IsNullOrWhiteSpace(psModulePath))
    {
        paths.AddRange(psModulePath.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    if (!string.IsNullOrWhiteSpace(home))
    {
        paths.Add(Path.Combine(home, ".local", "share", "powershell", "Modules"));

        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        if (!string.IsNullOrWhiteSpace(documents))
        {
            paths.Add(Path.Combine(documents, "PowerShell", "Modules"));
            paths.Add(Path.Combine(documents, "WindowsPowerShell", "Modules"));
        }
    }

    if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(programFiles))
        {
            paths.Add(Path.Combine(programFiles, "PowerShell", "Modules"));
            paths.Add(Path.Combine(programFiles, "WindowsPowerShell", "Modules"));
        }
    }
    else
    {
        paths.Add("/usr/local/share/powershell/Modules");
        paths.Add("/opt/microsoft/powershell/7/Modules");
    }

    return paths
        .Where(path => !string.IsNullOrWhiteSpace(path))
        .Select(Path.GetFullPath)
        .Distinct(RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal)
        .ToList();
}

static async Task RemoveInstalledModuleAsync(string powershell, InstalledModule module, bool dryRun)
{
    if (dryRun)
    {
        Console.WriteLine($"Would uninstall {module.Name} {module.Version}");
        return;
    }

    Console.WriteLine($"Uninstall {module.Name} {module.Version}");
    var script = $$"""
$ErrorActionPreference = 'Stop'
Uninstall-Module -Name {{ToPowerShellSingleQuotedString(module.Name)}} -RequiredVersion {{ToPowerShellSingleQuotedString(module.Version)}} -Force
""";

    var result = await RunPowerShellAsync(powershell, script);
    if (result.ExitCode != 0)
    {
        throw new InvalidOperationException($"Failed to uninstall {module.Name} {module.Version}: {result.Error.Trim()}");
    }
}

static void RemoveStaleVersionFolders(string moduleName, IReadOnlyList<InstalledModule> modules, bool dryRun)
{
    var moduleRoots = modules
        .Select(module => module.InstalledLocation)
        .Where(location => !string.IsNullOrWhiteSpace(location))
        .Select(location => Path.GetFullPath(location!))
        .Select(Path.GetDirectoryName)
        .Where(root => !string.IsNullOrWhiteSpace(root))
        .Distinct(GetPathComparer())
        .ToList();

    foreach (var moduleRoot in moduleRoots)
    {
        if (!Directory.Exists(moduleRoot))
        {
            continue;
        }

        var moduleDirectory = new DirectoryInfo(moduleRoot);
        if (!string.Equals(moduleDirectory.Name, moduleName, StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"Skip folder cleanup for {moduleRoot}: module root does not match {moduleName}.");
            continue;
        }

        var versionFolders = moduleDirectory
            .EnumerateDirectories()
            .Where(directory => SemanticVersion.TryParse(directory.Name, out _))
            .OrderBy(directory => SemanticVersion.Parse(directory.Name), SemanticVersion.Comparer)
            .ToList();

        if (versionFolders.Count <= 1)
        {
            continue;
        }

        foreach (var folder in versionFolders.Take(versionFolders.Count - 1))
        {
            var fullName = Path.GetFullPath(folder.FullName);
            if (!IsChildPath(moduleDirectory.FullName, fullName))
            {
                throw new InvalidOperationException($"Refusing to delete path outside the module root: {fullName}");
            }

            if (dryRun)
            {
                Console.WriteLine($"Would remove folder {fullName}");
                continue;
            }

            Console.WriteLine($"Remove folder {fullName}");
            Directory.Delete(fullName, recursive: true);
        }
    }
}

static async Task<CommandResult> RunPowerShellAsync(string powershell, string script)
{
    using var process = new Process();
    process.StartInfo.FileName = powershell;
    process.StartInfo.ArgumentList.Add("-NoProfile");
    process.StartInfo.ArgumentList.Add("-NonInteractive");
    process.StartInfo.ArgumentList.Add("-Command");
    process.StartInfo.ArgumentList.Add(script);
    process.StartInfo.RedirectStandardOutput = true;
    process.StartInfo.RedirectStandardError = true;
    process.StartInfo.UseShellExecute = false;

    process.Start();
    var outputTask = process.StandardOutput.ReadToEndAsync();
    var errorTask = process.StandardError.ReadToEndAsync();
    var exitTask = process.WaitForExitAsync();

    await Task.WhenAll(outputTask, errorTask, exitTask);

    return new CommandResult(process.ExitCode, await outputTask, await errorTask);
}

static string? ResolvePowerShellExecutable()
{
    var candidates = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
        ? ["pwsh.exe", "pwsh"]
        : new[] { "pwsh" };

    foreach (var candidate in candidates)
    {
        if (CanStart(candidate))
        {
            return candidate;
        }
    }

    return null;
}

static bool CanStart(string fileName)
{
    try
    {
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = fileName,
            ArgumentList = { "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()" },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (process is null)
        {
            return false;
        }

        process.WaitForExit(5000);
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
            return false;
        }

        if (process.ExitCode != 0)
        {
            return false;
        }

        var versionText = process.StandardOutput.ReadToEnd().Trim();
        return Version.TryParse(versionText, out var version) && version.Major >= 7;
    }
    catch
    {
        return false;
    }
}

static bool IsChildPath(string parentPath, string childPath)
{
    var parent = Path.GetFullPath(parentPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var child = Path.GetFullPath(childPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
    return child.StartsWith(parent, RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}

static string ToPowerShellSingleQuotedString(string value)
{
    return $"'{value.Replace("'", "''")}'";
}

static StringComparer GetPathComparer()
{
    return RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
}

static bool WildcardMatches(string value, string pattern)
{
    var regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
    return Regex.IsMatch(value, regexPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

sealed record InstalledModule(string Name, string Version, string? InstalledLocation);

sealed record CommandResult(int ExitCode, string Output, string Error);

sealed record CleanupOptions(IReadOnlyList<string> Patterns, bool DryRun)
{
    public static CleanupOptions Parse(string[] args)
    {
        var patterns = new List<string> { "Az*", "Microsoft.Entra*", "Microsoft.Graph*" };
        var dryRun = false;

        for (var index = 0; index < args.Length; index++)
        {
            var arg = args[index];
            switch (arg)
            {
                case "--dry-run":
                case "--what-if":
                    dryRun = true;
                    break;
                case "--pattern":
                    if (index + 1 >= args.Length)
                    {
                        throw new ArgumentException("--pattern requires a value.");
                    }

                    patterns.Add(args[++index]);
                    break;
                case "--help":
                case "-h":
                    Console.WriteLine("Usage: dotnet run --file oldpowershellmodule.cs -- [--dry-run] [--pattern <module-pattern>]");
                    Environment.Exit(0);
                    break;
                default:
                    throw new ArgumentException($"Unknown argument: {arg}");
            }
        }

        return new CleanupOptions(patterns.Distinct(StringComparer.OrdinalIgnoreCase).ToList(), dryRun);
    }
}

sealed class SemanticVersion
{
    private static readonly Regex VersionRegex = new(
        @"^(?<version>\d+(?:\.\d+){0,3})(?:-(?<prerelease>[0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$",
        RegexOptions.Compiled);

    public static readonly IComparer<SemanticVersion> Comparer = new SemanticVersionComparer();

    private SemanticVersion(string original, IReadOnlyList<int> parts, IReadOnlyList<string> prerelease)
    {
        Original = original;
        Parts = parts;
        Prerelease = prerelease;
    }

    public string Original { get; }

    public IReadOnlyList<int> Parts { get; }

    public IReadOnlyList<string> Prerelease { get; }

    public static SemanticVersion Parse(string value)
    {
        if (TryParse(value, out var version))
        {
            return version;
        }

        return new SemanticVersion(value, [0], [value]);
    }

    public static bool TryParse(string value, out SemanticVersion version)
    {
        var match = VersionRegex.Match(value);
        if (!match.Success)
        {
            version = null!;
            return false;
        }

        var parts = match.Groups["version"].Value
            .Split('.', StringSplitOptions.RemoveEmptyEntries)
            .Select(int.Parse)
            .ToList();

        var prerelease = match.Groups["prerelease"].Success
            ? match.Groups["prerelease"].Value.Split('.', StringSplitOptions.RemoveEmptyEntries).ToList()
            : [];

        version = new SemanticVersion(value, parts, prerelease);
        return true;
    }

    private sealed class SemanticVersionComparer : IComparer<SemanticVersion>
    {
        public int Compare(SemanticVersion? x, SemanticVersion? y)
        {
            if (ReferenceEquals(x, y))
            {
                return 0;
            }

            if (x is null)
            {
                return -1;
            }

            if (y is null)
            {
                return 1;
            }

            var maxPartCount = Math.Max(x.Parts.Count, y.Parts.Count);
            for (var index = 0; index < maxPartCount; index++)
            {
                var left = index < x.Parts.Count ? x.Parts[index] : 0;
                var right = index < y.Parts.Count ? y.Parts[index] : 0;
                var result = left.CompareTo(right);
                if (result != 0)
                {
                    return result;
                }
            }

            if (x.Prerelease.Count == 0 && y.Prerelease.Count == 0)
            {
                return 0;
            }

            if (x.Prerelease.Count == 0)
            {
                return 1;
            }

            if (y.Prerelease.Count == 0)
            {
                return -1;
            }

            var maxPrereleaseCount = Math.Max(x.Prerelease.Count, y.Prerelease.Count);
            for (var index = 0; index < maxPrereleaseCount; index++)
            {
                if (index >= x.Prerelease.Count)
                {
                    return -1;
                }

                if (index >= y.Prerelease.Count)
                {
                    return 1;
                }

                var left = x.Prerelease[index];
                var right = y.Prerelease[index];
                var leftIsNumber = int.TryParse(left, out var leftNumber);
                var rightIsNumber = int.TryParse(right, out var rightNumber);

                var result = (leftIsNumber, rightIsNumber) switch
                {
                    (true, true) => leftNumber.CompareTo(rightNumber),
                    (true, false) => -1,
                    (false, true) => 1,
                    _ => string.CompareOrdinal(left, right)
                };

                if (result != 0)
                {
                    return result;
                }
            }

            return 0;
        }
    }
}
