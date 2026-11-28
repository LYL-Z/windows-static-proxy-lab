using System.Text.Json;

namespace ProxyDoctor;

public sealed record EngineFileEntry(string Path, string Sha256);

/// <summary>
/// Where the recovery engine lives and whether it may be trusted.
/// <see cref="Detail"/> is user-facing: it is shown verbatim when recovery is refused.
/// </summary>
public sealed record EngineResolution(
    bool Ok,
    string Detail,
    string? EngineRoot,
    string? ScriptPath,
    IReadOnlyList<EngineFileEntry> Files)
{
    public static EngineResolution Failed(string detail) =>
        new(false, detail, null, null, Array.Empty<EngineFileEntry>());
}

/// <summary>
/// The reviewed recovery engine ships beside the executable under <c>engine\</c>:
///
/// <code>
/// engine\engine-manifest.json
/// engine\proxy_v4\rollback-v4.ps1
/// engine\proxy_v4\lib\V4.ps1
/// engine\scripts\Invoke-IsolatedRecovery.ps1
/// </code>
///
/// The layout keeps the <c>proxy_v4\</c> nesting because the hash-pinned wrapper
/// script loads <c>Join-Path $EngineRoot 'proxy_v4\rollback-v4.ps1'</c>. The wrapper
/// is byte-identical to the reviewed source; only the C# locator changed.
///
/// Trust is two independent checks that must both pass:
/// 1. <c>engine-manifest.json</c> pins the raw SHA-256 of every shipped file.
/// 2. The same files must match the reviewed hashes compiled into <see cref="RecoveryTrust"/>.
///
/// Missing files, a hash mismatch or an incompatible engine version are refusals,
/// never silent fallbacks. A Release build additionally never walks up the directory
/// tree, so a stray source checkout can never satisfy a published install.
/// </summary>
public static class EnginePackage
{
    public const string DirectoryName = "engine";
    public const string ManifestFileName = "engine-manifest.json";
    public const int ManifestSchemaVersion = 1;

    /// <summary>Must stay in sync with &lt;EnginePackageVersion&gt; in packaging\engine-manifest.targets.</summary>
    public const string RequiredEngineVersion = "v4.0";

    public const string RollbackRelative = @"proxy_v4\rollback-v4.ps1";
    public const string LibraryRelative = @"proxy_v4\lib\V4.ps1";
    public const string ScriptRelative = @"scripts\Invoke-IsolatedRecovery.ps1";

    /// <summary>
    /// The complete set of files allowed in the packaged engine. Nothing else is
    /// copied: no settings.json, owner.json, backup\, logs\, evidence\ or credentials.
    /// </summary>
    public static readonly IReadOnlyList<string> Whitelist = new[]
    {
        RollbackRelative,
        LibraryRelative,
        ScriptRelative
    };

    /// <summary>
    /// Development builds may fall back to a source checkout. Distribution (Release)
    /// builds never search parent directories: a published app either carries a valid
    /// <c>engine\</c> folder or refuses to run recovery.
    /// </summary>
#if DEBUG
    public static bool AllowRepositorySearch { get; } = true;
#else
    public static bool AllowRepositorySearch { get; } = false;
#endif

    public static EngineResolution Resolve() => Resolve(AppContext.BaseDirectory, AllowRepositorySearch);

    public static EngineResolution Resolve(string baseDirectory, bool allowRepositorySearch)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(baseDirectory);
        var root = Path.GetFullPath(baseDirectory);
        var packaged = Validate(Path.Combine(root, DirectoryName));
        if (packaged.Ok || !allowRepositorySearch) return packaged;

        // Development-only fallback. Gated by AllowRepositorySearch, which is a
        // compile-time constant, so it cannot be switched on in a Release binary.
        var checkout = LocateInRepository(root);
        if (checkout is not null) return checkout;

        return packaged with
        {
            Detail = packaged.Detail +
                " This build also refuses to guess a source checkout location; recovery is disabled."
        };
    }

    /// <summary>Validates a directory that is expected to be the <c>engine\</c> folder itself.</summary>
    public static EngineResolution Validate(string engineRoot)
    {
        if (string.IsNullOrWhiteSpace(engineRoot))
            return EngineResolution.Failed("Engine path is empty.");

        var root = Path.GetFullPath(engineRoot).TrimEnd('\\', '/');
        if (!Directory.Exists(root))
            return EngineResolution.Failed("Missing engine directory: " + root + ".");

        var manifestPath = Path.Combine(root, ManifestFileName);
        if (!File.Exists(manifestPath))
            return EngineResolution.Failed("Missing " + ManifestFileName + " in " + root + ".");
        if (RecoveryTrust.IsReparsePoint(manifestPath))
            return EngineResolution.Failed(ManifestFileName + " is a reparse point and is refused: " + manifestPath);

        EngineManifest manifest;
        try
        {
            manifest = ReadManifest(manifestPath);
        }
        catch (Exception error) when (error is FormatException or JsonException or IOException or UnauthorizedAccessException)
        {
            return EngineResolution.Failed("Cannot read " + ManifestFileName + ": " + error.Message);
        }

        if (manifest.SchemaVersion != ManifestSchemaVersion)
            return EngineResolution.Failed(
                "Engine manifest schema " + manifest.SchemaVersion + " is not supported; this build reads schema " +
                ManifestSchemaVersion + ".");

        if (!string.Equals(manifest.EngineVersion, RequiredEngineVersion, StringComparison.Ordinal))
            return EngineResolution.Failed(
                "Engine version '" + manifest.EngineVersion + "' is incompatible with this build (requires '" +
                RequiredEngineVersion + "').");

        var declared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in manifest.Files)
        {
            var relative = NormalizeRelative(entry.Path);
            if (relative is null)
                return EngineResolution.Failed("Engine manifest contains an unsafe path: '" + entry.Path + "'.");
            if (!Whitelist.Contains(relative, StringComparer.OrdinalIgnoreCase))
                return EngineResolution.Failed(
                    "Engine manifest lists '" + relative + "', which is outside the approved whitelist.");
            if (!declared.Add(relative))
                return EngineResolution.Failed("Engine manifest lists '" + relative + "' more than once.");
            if (!IsHex64(entry.Sha256))
                return EngineResolution.Failed(
                    "Engine manifest sha256 for '" + relative + "' is not a 64 character hex digest.");
        }

        foreach (var required in Whitelist)
            if (!declared.Contains(required))
                return EngineResolution.Failed("Engine manifest does not list required file '" + required + "'.");

        foreach (var entry in manifest.Files)
        {
            var relative = NormalizeRelative(entry.Path)!;
            var full = Path.Combine(root, relative);
            if (!RecoveryTrust.IsStrictChild(root, full))
                return EngineResolution.Failed("Engine path escapes the engine directory: '" + relative + "'.");
            if (!File.Exists(full))
                return EngineResolution.Failed("Missing engine file: " + full + ".");
            if (RecoveryTrust.IsReparsePoint(full))
                return EngineResolution.Failed("Engine file is a reparse point and is refused: " + full);

            var actual = RecoveryTrust.HashFile(full);
            if (!actual.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                return EngineResolution.Failed(
                    "SHA-256 mismatch for '" + relative + "': manifest says " + entry.Sha256 + ", file is " + actual + ".");

            var reviewed = ReviewedHashProblem(relative, full);
            if (reviewed is not null) return EngineResolution.Failed(reviewed);
        }

        return new EngineResolution(
            true,
            "Engine " + RequiredEngineVersion + " validated from " + root + " with " + manifest.Files.Count +
            " manifest-verified files.",
            root,
            Path.Combine(root, ScriptRelative),
            manifest.Files);
    }

    /// <summary>Compares an engine file against the reviewed hash compiled into this build.</summary>
    public static string? ReviewedHashProblem(string relative, string fullPath)
    {
        var normalized = NormalizeRelative(relative);
        if (normalized is null) return "Unsafe engine path: '" + relative + "'.";

        if (normalized.Equals(RollbackRelative, StringComparison.OrdinalIgnoreCase))
            return RecoveryTrust.HashFile(fullPath).Equals(RecoveryTrust.RollbackSha256, StringComparison.OrdinalIgnoreCase)
                ? null
                : "Engine file '" + normalized + "' does not match the reviewed rollback-v4.ps1 hash.";

        if (normalized.Equals(LibraryRelative, StringComparison.OrdinalIgnoreCase))
            return RecoveryTrust.HashFile(fullPath).Equals(RecoveryTrust.LibrarySha256, StringComparison.OrdinalIgnoreCase)
                ? null
                : "Engine file '" + normalized + "' does not match the reviewed V4.ps1 hash.";

        if (normalized.Equals(ScriptRelative, StringComparison.OrdinalIgnoreCase))
            return RecoveryTrust.HashScript(fullPath).Equals(RecoveryTrust.ScriptSha256, StringComparison.OrdinalIgnoreCase)
                ? null
                : "Engine file '" + normalized + "' does not match the reviewed wrapper script hash.";

        return "Engine file '" + normalized + "' is outside the approved whitelist.";
    }

    private static EngineResolution? LocateInRepository(string baseDirectory)
    {
        var dir = new DirectoryInfo(baseDirectory);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent)
        {
            var rollback = Path.Combine(dir.FullName, "proxy_v4", "rollback-v4.ps1");
            var library = Path.Combine(dir.FullName, "proxy_v4", "lib", "V4.ps1");
            var script = Path.Combine(dir.FullName, "desktop", "scripts", "Invoke-IsolatedRecovery.ps1");
            if (RecoveryTrust.ReviewedFile(rollback, RecoveryTrust.RollbackSha256) &&
                RecoveryTrust.ReviewedFile(library, RecoveryTrust.LibrarySha256) &&
                RecoveryTrust.ReviewedScript(script))
            {
                return new EngineResolution(
                    true,
                    "Engine resolved from a source checkout at " + dir.FullName +
                    " (development builds only; a Release build refuses this path).",
                    dir.FullName.TrimEnd('\\', '/'),
                    script,
                    new[]
                    {
                        new EngineFileEntry(RollbackRelative, RecoveryTrust.RollbackSha256),
                        new EngineFileEntry(LibraryRelative, RecoveryTrust.LibrarySha256),
                        new EngineFileEntry(ScriptRelative, RecoveryTrust.ScriptSha256)
                    });
            }
        }

        return null;
    }

    private static EngineManifest ReadManifest(string path)
    {
        var text = File.ReadAllText(path).TrimStart('\uFEFF');
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
            throw new FormatException("manifest root is not a JSON object.");

        if (!root.TryGetProperty("schemaVersion", out var schema) ||
            schema.ValueKind != JsonValueKind.Number ||
            !schema.TryGetInt32(out var schemaVersion))
            throw new FormatException("manifest schemaVersion is missing or not an integer.");

        if (!root.TryGetProperty("engineVersion", out var version) || version.ValueKind != JsonValueKind.String)
            throw new FormatException("manifest engineVersion is missing or not a string.");

        if (!root.TryGetProperty("files", out var files) || files.ValueKind != JsonValueKind.Array)
            throw new FormatException("manifest files is missing or not an array.");

        var entries = new List<EngineFileEntry>();
        foreach (var item in files.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
                throw new FormatException("manifest file entry is not an object.");
            if (!item.TryGetProperty("path", out var itemPath) || itemPath.ValueKind != JsonValueKind.String)
                throw new FormatException("manifest file entry has no path.");
            if (!item.TryGetProperty("sha256", out var itemHash) || itemHash.ValueKind != JsonValueKind.String)
                throw new FormatException("manifest file entry has no sha256.");
            entries.Add(new EngineFileEntry(itemPath.GetString() ?? "", itemHash.GetString() ?? ""));
        }

        return new EngineManifest(schemaVersion, version.GetString() ?? "", entries);
    }

    public static string? NormalizeRelative(string? relative)
    {
        if (string.IsNullOrWhiteSpace(relative)) return null;
        var text = relative.Replace('/', '\\').Trim();
        if (text.Length == 0 || text.StartsWith('\\')) return null;
        if (text.Any(character => character < 32 ||
                                  character is ':' or '*' or '?' or '"' or '<' or '>' or '|'))
            return null;
        if (Path.IsPathRooted(text)) return null;
        var parts = text.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        if (parts.Any(part => part is "." or "..")) return null;
        return string.Join('\\', parts);
    }

    private static bool IsHex64(string? value) =>
        value is { Length: 64 } && value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F');

    private sealed record EngineManifest(int SchemaVersion, string EngineVersion, IReadOnlyList<EngineFileEntry> Files);
}
