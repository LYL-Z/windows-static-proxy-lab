using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

/// <summary>
/// F69/F70: the packaged engine folder must be self-sufficient and must refuse
/// anything that does not match the reviewed hashes or the expected version.
/// These tests build real folders under TEMP; nothing touches the live machine.
/// </summary>
public class EnginePackageTests
{
    [Fact]
    public void Packaged_engine_validates_without_a_source_checkout()
    {
        using var temp = new TempFolder();
        var engine = CreateEngine(temp.Path);

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.True(resolution.Ok, resolution.Detail);
        Assert.Equal(engine, resolution.EngineRoot);
        Assert.Equal(Path.Combine(engine, EnginePackage.ScriptRelative), resolution.ScriptPath);
        Assert.Equal(3, resolution.Files.Count);
        Assert.Contains(EnginePackage.RequiredEngineVersion, resolution.Detail);
    }

    [Fact]
    public void Tampered_file_with_a_consistent_manifest_is_refused()
    {
        using var temp = new TempFolder();
        // The manifest is regenerated from the tampered bytes, so only the
        // reviewed hash compiled into the build can catch this.
        var engine = CreateEngine(temp.Path, tamperRelative: EnginePackage.LibraryRelative);

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Null(resolution.EngineRoot);
        Assert.Contains("reviewed", resolution.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void File_changed_after_the_manifest_is_refused()
    {
        using var temp = new TempFolder();
        var engine = CreateEngine(temp.Path);
        File.AppendAllText(Path.Combine(engine, EnginePackage.RollbackRelative), "\r\n# tampered after manifest\r\n");

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Contains("SHA-256 mismatch", resolution.Detail);
        Assert.Contains("rollback-v4.ps1", resolution.Detail);
    }

    [Fact]
    public void Missing_engine_file_is_refused()
    {
        using var temp = new TempFolder();
        var engine = CreateEngine(temp.Path);
        File.Delete(Path.Combine(engine, EnginePackage.RollbackRelative));

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Contains("Missing engine file", resolution.Detail);
    }

    [Fact]
    public void Missing_manifest_is_refused()
    {
        using var temp = new TempFolder();
        var engine = CreateEngine(temp.Path);
        File.Delete(Path.Combine(engine, EnginePackage.ManifestFileName));

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Contains(EnginePackage.ManifestFileName, resolution.Detail);
    }

    [Fact]
    public void Incompatible_engine_version_is_refused()
    {
        using var temp = new TempFolder();
        CreateEngine(temp.Path, engineVersion: "v9.9");

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Contains("v9.9", resolution.Detail);
        Assert.Contains("incompatible", resolution.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Manifest_entry_outside_the_whitelist_is_refused()
    {
        using var temp = new TempFolder();
        var engine = CreateEngine(temp.Path);
        // A private file that must never be packaged, listed in the manifest.
        var extra = Path.Combine(engine, "settings.json");
        File.WriteAllText(extra, "{}");
        var manifestPath = Path.Combine(engine, EnginePackage.ManifestFileName);
        var text = File.ReadAllText(manifestPath);
        var injected = text.Replace(
            "\"files\":[",
            "\"files\":[{\"path\":\"settings.json\",\"sha256\":\"" + RecoveryTrust.HashFile(extra) + "\"},");
        File.WriteAllText(manifestPath, injected);

        var resolution = EnginePackage.Resolve(temp.Path, allowRepositorySearch: false);

        Assert.False(resolution.Ok);
        Assert.Contains("whitelist", resolution.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Release_style_resolution_never_walks_up_to_a_repository()
    {
        using var temp = new TempFolder();
        // A source-checkout shaped tree *above* the published folder.
        var checkout = temp.Path;
        Directory.CreateDirectory(Path.Combine(checkout, "proxy_v4", "lib"));
        Directory.CreateDirectory(Path.Combine(checkout, "desktop", "scripts"));
        File.Copy(SourceFile("proxy_v4", "rollback-v4.ps1"), Path.Combine(checkout, "proxy_v4", "rollback-v4.ps1"));
        File.Copy(SourceFile("proxy_v4", "lib", "V4.ps1"), Path.Combine(checkout, "proxy_v4", "lib", "V4.ps1"));
        File.Copy(SourceFile("desktop", "scripts", "Invoke-IsolatedRecovery.ps1"),
            Path.Combine(checkout, "desktop", "scripts", "Invoke-IsolatedRecovery.ps1"));
        var published = Path.Combine(checkout, "publish");
        Directory.CreateDirectory(published);

        var refused = EnginePackage.Resolve(published, allowRepositorySearch: false);
        Assert.False(refused.Ok);
        Assert.Contains(EnginePackage.DirectoryName, refused.Detail);

        // The search still exists for development builds, which is exactly why it
        // is compile-time gated: this proves the fallback is real, not that it is on.
        var development = EnginePackage.Resolve(published, allowRepositorySearch: true);
        Assert.True(development.Ok, development.Detail);
        Assert.Equal(checkout.TrimEnd('\\', '/'), development.EngineRoot);
    }

    [Fact]
    public void Repository_source_files_match_the_reviewed_hashes()
    {
        Assert.Equal(RecoveryTrust.RollbackSha256,
            RecoveryTrust.HashFile(SourceFile("proxy_v4", "rollback-v4.ps1")));
        Assert.Equal(RecoveryTrust.LibrarySha256,
            RecoveryTrust.HashFile(SourceFile("proxy_v4", "lib", "V4.ps1")));
        Assert.Equal(RecoveryTrust.ScriptSha256,
            RecoveryTrust.HashScript(SourceFile("desktop", "scripts", "Invoke-IsolatedRecovery.ps1")));
    }

    private static string CreateEngine(
        string parent,
        string engineVersion = EnginePackage.RequiredEngineVersion,
        string? tamperRelative = null)
    {
        var engine = Path.Combine(parent, EnginePackage.DirectoryName);
        Directory.CreateDirectory(Path.Combine(engine, "proxy_v4", "lib"));
        Directory.CreateDirectory(Path.Combine(engine, "scripts"));
        File.Copy(SourceFile("proxy_v4", "rollback-v4.ps1"), Path.Combine(engine, EnginePackage.RollbackRelative));
        File.Copy(SourceFile("proxy_v4", "lib", "V4.ps1"), Path.Combine(engine, EnginePackage.LibraryRelative));
        File.Copy(SourceFile("desktop", "scripts", "Invoke-IsolatedRecovery.ps1"),
            Path.Combine(engine, EnginePackage.ScriptRelative));
        if (tamperRelative is not null)
            File.AppendAllText(Path.Combine(engine, tamperRelative), "\r\n# tampered\r\n");
        WriteManifest(engine, engineVersion);
        return engine;
    }

    private static void WriteManifest(string engine, string engineVersion)
    {
        var files = string.Join(",",
            EnginePackage.Whitelist.Select(relative =>
                "{\"path\":\"" + relative.Replace('\\', '/') + "\",\"sha256\":\"" +
                RecoveryTrust.HashFile(Path.Combine(engine, relative)) + "\"}"));
        var json = "{\"schemaVersion\":" + EnginePackage.ManifestSchemaVersion + ",\"engineVersion\":\"" +
                   engineVersion + "\",\"files\":[" + files + "]}";
        File.WriteAllText(Path.Combine(engine, EnginePackage.ManifestFileName), json);
    }

    private static string SourceFile(params string[] parts) =>
        Path.Combine(new[] { LocateRepoRoot() }.Concat(parts).ToArray());

    private static string LocateRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 10 && dir is not null; i++, dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "proxy_v4", "rollback-v4.ps1")))
                return dir.FullName;
        throw new DirectoryNotFoundException("repository root with proxy_v4 was not found");
    }

    private sealed class TempFolder : IDisposable
    {
        public TempFolder()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "proxy-doctor-engine-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); } catch { /* best effort */ }
        }
    }
}
