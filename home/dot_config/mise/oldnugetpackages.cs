#!/usr/bin/env dotnet
#:property TargetFramework=net10.0

using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

var options = CleanupOptions.Parse(args);

try
{
    var packages = GetInstalledPackages(options.Patterns);
    if (packages.Count == 0)
    {
        Console.WriteLine("No matching NuGet packages were found.");
        return 0;
    }

    var groups = packages
        .Where(p => !string.IsNullOrWhiteSpace(p.Name) && !string.IsNullOrWhiteSpace(p.Version))
        .GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
        .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase);

    foreach (var group in groups)
    {
        var orderedPackages = group
            .DistinctBy(p => $"{p.Name}\u001f{p.Version}", StringComparer.OrdinalIgnoreCase)
            .OrderBy(p => SemanticVersion.Parse(p.Version), SemanticVersion.Comparer)
            .ToList();

        if (orderedPackages.Count <= 1)
        {
            Console.WriteLine($"Keep {group.Key}: only one version is installed.");
            continue;
        }

        var latest = orderedPackages[^1];
        Console.WriteLine($"Keep {group.Key} {latest.Version}");

        foreach (var package in orderedPackages.Take(orderedPackages.Count - 1))
        {
            RemovePackage(package, options.DryRun);
        }
    }

    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}

static List<InstalledPackage> GetInstalledPackages(IReadOnlyList<string> patterns)
{
    var nugetRoot = GetNuGetPackagesRoot();
    var packages = new List<InstalledPackage>();

    if (!Directory.Exists(nugetRoot))
    {
        Console.Error.WriteLine($"NuGet packages directory not found: {nugetRoot}");
        return packages;
    }

    foreach (var packageDirectory in Directory.EnumerateDirectories(nugetRoot))
    {
        var packageName = Path.GetFileName(packageDirectory);
        if (patterns.Count > 0 && !patterns.Any(pattern => WildcardMatches(packageName, pattern)))
        {
            continue;
        }

        foreach (var versionDirectory in Directory.EnumerateDirectories(packageDirectory))
        {
            var version = Path.GetFileName(versionDirectory);
            if (!SemanticVersion.TryParse(version, out _))
            {
                continue;
            }

            packages.Add(new InstalledPackage(packageName, version, versionDirectory));
        }
    }

    return packages;
}

static string GetNuGetPackagesRoot()
{
    // NUGET_PACKAGES 環境変数が設定されていれば優先
    var envPath = Environment.GetEnvironmentVariable("NUGET_PACKAGES");
    if (!string.IsNullOrWhiteSpace(envPath))
    {
        return Path.GetFullPath(envPath);
    }

    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    return Path.Combine(home, ".nuget", "packages");
}

static void RemovePackage(InstalledPackage package, bool dryRun)
{
    var fullPath = Path.GetFullPath(package.InstalledLocation);

    if (!IsChildPath(GetNuGetPackagesRoot(), fullPath))
    {
        throw new InvalidOperationException($"Refusing to delete path outside the NuGet packages root: {fullPath}");
    }

    if (dryRun)
    {
        Console.WriteLine($"Would remove {package.Name} {package.Version}: {fullPath}");
        return;
    }

    Console.WriteLine($"Remove {package.Name} {package.Version}: {fullPath}");

    if (!Directory.Exists(fullPath))
    {
        Console.Error.WriteLine($"Warning: Directory not found for {package.Name} {package.Version}, skipping.");
        return;
    }

    try
    {
        Directory.Delete(fullPath, recursive: true);
        Console.WriteLine($"Removed {fullPath}");
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Warning: Failed to remove {fullPath}: {ex.Message}");
    }
}

static bool IsChildPath(string parentPath, string childPath)
{
    var parent = Path.GetFullPath(parentPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var child = Path.GetFullPath(childPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
    return child.StartsWith(parent, RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}

static bool WildcardMatches(string value, string pattern)
{
    var regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
    return Regex.IsMatch(value, regexPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

sealed record InstalledPackage(string Name, string Version, string InstalledLocation);

sealed record CleanupOptions(IReadOnlyList<string> Patterns, bool DryRun)
{
    public static CleanupOptions Parse(string[] args)
    {
        // パターン未指定時はすべてのパッケージを対象にする
        var patterns = new List<string>();
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
                    Console.WriteLine("Usage: dotnet run --file oldnugetpackages.cs -- [--dry-run] [--pattern <package-pattern>]");
                    Console.WriteLine();
                    Console.WriteLine("Options:");
                    Console.WriteLine("  --dry-run, --what-if       Show what would be removed without deleting anything.");
                    Console.WriteLine("  --pattern <package-pattern> Wildcard pattern to filter packages (can be specified multiple times).");
                    Console.WriteLine("                              If omitted, all packages in the NuGet cache are processed.");
                    Console.WriteLine();
                    Console.WriteLine("Examples:");
                    Console.WriteLine("  dotnet run --file oldnugetpackages.cs -- --dry-run");
                    Console.WriteLine("  dotnet run --file oldnugetpackages.cs -- --pattern \"Microsoft.*\"");
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
