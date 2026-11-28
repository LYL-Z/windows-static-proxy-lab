using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

/// <summary>
/// F72: authorization is bound to one operation and one target, and every surface
/// (CLI, desktop dialog, Skill) shows the same five facts before a person grants it.
/// These tests never start the wrapper; they only inspect the contract text and the
/// values the three surfaces share.
/// </summary>
public class RecoveryConsentTests
{
    [Fact]
    public void Phrase_is_the_operation_plus_the_target()
    {
        Assert.Equal("RECOVER-ISOLATED 127.0.0.1:7897", RecoveryConsent.Phrase("127.0.0.1:7897"));
        Assert.Equal("RECOVER-ISOLATED off", RecoveryConsent.Phrase("off"));
        Assert.Equal("RECOVER-ISOLATED unknown", RecoveryConsent.Phrase(null));
        Assert.Equal("RECOVER-ISOLATED 127.0.0.1:7897", RecoveryConsent.Phrase("  127.0.0.1:7897  "));
    }

    [Fact]
    public void Matching_requires_the_exact_bound_phrase()
    {
        const string target = "127.0.0.1:7897";
        Assert.True(RecoveryConsent.PhraseMatches("RECOVER-ISOLATED 127.0.0.1:7897", target));
        Assert.True(RecoveryConsent.PhraseMatches("  RECOVER-ISOLATED 127.0.0.1:7897  ", target));
        Assert.False(RecoveryConsent.PhraseMatches("RECOVER-ISOLATED 127.0.0.1:7898", target));
        Assert.False(RecoveryConsent.PhraseMatches("recover-isolated 127.0.0.1:7897", target));
        Assert.False(RecoveryConsent.PhraseMatches("RECOVER-ISOLATED 127.0.0.1:7897 now", target));
        Assert.False(RecoveryConsent.PhraseMatches("YES", target));
        Assert.False(RecoveryConsent.PhraseMatches("--yes", target));
        Assert.False(RecoveryConsent.PhraseMatches("", target));
        Assert.False(RecoveryConsent.PhraseMatches(null, target));
        // The phrase for one target never authorizes another target.
        Assert.False(RecoveryConsent.PhraseMatches(RecoveryConsent.Phrase("127.0.0.1:7897"), "off"));
    }

    [Fact]
    public void Brief_states_scope_resources_system_proxy_rollback_and_the_gap()
    {
        var brief = RecoveryConsent.Describe("127.0.0.1:7897");
        Assert.Equal("127.0.0.1:7897", brief.Target);
        Assert.Equal("RECOVER-ISOLATED 127.0.0.1:7897", brief.Phrase);
        Assert.Equal(RecoveryConsent.ScopeText, brief.Scope);
        Assert.Equal(RecoveryConsent.ResourcesText, brief.AffectedResources);
        Assert.Equal(RecoveryConsent.SystemProxyText, brief.SystemProxy);
        Assert.Equal(RecoveryConsent.RollbackText, brief.Rollback);
        Assert.Equal(RecoveryConsent.NotImplementedText, brief.NotImplemented);
        Assert.Equal(RecoveryConsent.RefusalText, brief.Refusal);
        Assert.Contains("否。", brief.SystemProxy);
        Assert.Contains("真实生产写入：未实现", brief.NotImplemented);
        Assert.Contains(brief.Lines, line => line.EndsWith(brief.Phrase, StringComparison.Ordinal));
        Assert.Contains(brief.Lines, line => line.Contains("拒绝授权后仍可继续只读诊断"));
    }

    [Fact]
    public void Describe_without_a_target_reads_the_live_target()
    {
        var live = RecoveryConsent.ReadTarget();
        Assert.False(string.IsNullOrWhiteSpace(live));
        var brief = RecoveryConsent.Describe();
        Assert.Equal(live, brief.Target);
        Assert.Equal(RecoveryConsent.Phrase(live), brief.Phrase);
        // An explicit target is never replaced by the live one.
        Assert.Equal("off", RecoveryConsent.Describe("off").Target);
    }

    [Fact]
    public void A_dialog_grant_is_well_formed_only_from_a_known_source()
    {
        var approval = RecoveryApproval.FromDialog("127.0.0.1:7897");
        Assert.True(approval.IsWellFormed);
        Assert.Equal(RecoveryConsent.OperationName, approval.Operation);
        Assert.Equal(RecoveryConsent.GrantByDialog, approval.GrantedBy);
        Assert.Equal("127.0.0.1:7897", approval.Target);
        Assert.Null(RecoveryApproval.FromPhrase("--yes"));
    }

    /// <summary>
    /// The desktop dialog, the CLI and the Skill entry must show the same consent
    /// text. The Skill carries its own copy, so this asserts the copies still match.
    /// </summary>
    [Fact]
    public void Skill_entry_shows_the_same_consent_text_and_reviewed_hashes()
    {
        var skill = File.ReadAllText(Path.Combine(LocateRepoRoot(), "skills", "windows-proxy-doctor", "recovery", "Invoke-Recovery.ps1"));
        Assert.Contains(RecoveryConsent.OperationName, skill);
        Assert.Contains(RecoveryConsent.ScopeText, skill);
        Assert.Contains(RecoveryConsent.ResourcesText, skill);
        Assert.Contains(RecoveryConsent.SystemProxyText, skill);
        Assert.Contains(RecoveryConsent.RollbackText, skill);
        Assert.Contains(RecoveryConsent.NotImplementedText, skill);
        Assert.Contains(RecoveryConsent.RefusalText, skill);
        Assert.Contains(RecoveryTrust.RollbackSha256, skill);
        Assert.Contains(RecoveryTrust.LibrarySha256, skill);
        Assert.Contains(RecoveryTrust.ScriptSha256, skill);
        Assert.Contains("Invoke-IsolatedRecovery.ps1", skill);
        Assert.Contains("engine-manifest.json", skill);
    }

    private static string LocateRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 10 && dir is not null; i++, dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "proxy_v4", "rollback-v4.ps1")))
                return dir.FullName;
        throw new DirectoryNotFoundException("repository root with proxy_v4 was not found");
    }
}
