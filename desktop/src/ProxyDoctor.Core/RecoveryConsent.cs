using Microsoft.Win32;

namespace ProxyDoctor;

/// <summary>
/// F72: authorization for the isolated recovery exercise is bound to one operation
/// and one target that were read from this machine at the moment of the request.
///
/// The program never supplies its own authorization. A person supplies it, either by
/// typing the phrase (CLI and Skill) or by confirming the desktop dialog, and this
/// type is the only place that decides whether such a grant is well formed.
/// </summary>
public sealed record RecoveryApproval
{
    private RecoveryApproval(string target, string grantedBy)
    {
        Target = target;
        GrantedBy = grantedBy;
    }

    public string Operation => RecoveryConsent.OperationName;

    /// <summary>The endpoint the grant was bound to. See <see cref="RecoveryConsent.ReadTarget"/>.</summary>
    public string Target { get; }

    /// <summary><see cref="RecoveryConsent.GrantByPhrase"/> or <see cref="RecoveryConsent.GrantByDialog"/>.</summary>
    public string GrantedBy { get; }

    /// <summary>
    /// A typed phrase is bound to the target read right now. A phrase for another
    /// target, another case, an extra word or a bare "--yes" is not a grant.
    /// </summary>
    public static RecoveryApproval? FromPhrase(string? typedPhrase)
    {
        var target = RecoveryConsent.ReadTarget();
        return RecoveryConsent.PhraseMatches(typedPhrase, target) ? new RecoveryApproval(target, RecoveryConsent.GrantByPhrase) : null;
    }

    /// <summary>
    /// Called by the desktop only after the person clicked confirm in the dialog that
    /// showed this same target, scope, resources, system-proxy answer and rollback.
    /// </summary>
    public static RecoveryApproval FromDialog(string target) =>
        new(RecoveryConsent.Normalize(target), RecoveryConsent.GrantByDialog);

    public bool IsWellFormed =>
        !string.IsNullOrWhiteSpace(Target) &&
        GrantedBy is RecoveryConsent.GrantByPhrase or RecoveryConsent.GrantByDialog;
}

/// <summary>The one consent text every surface shows before a grant can happen.</summary>
public sealed record RecoveryConsentBrief(
    string Target,
    string Phrase,
    string Scope,
    string AffectedResources,
    string SystemProxy,
    string Rollback,
    string NotImplemented,
    string Refusal,
    IReadOnlyList<string> Lines);

/// <summary>
/// F71/F72: one canonical description of what "isolated exercise" means, shared by the
/// CLI, the desktop dialog and the Skill entry script, so a person sees the same facts
/// on every surface before authorizing.
/// </summary>
public static class RecoveryConsent
{
    public const string OperationName = "RECOVER-ISOLATED";
    public const string ModeLabel = "隔离演练";
    public const string ProductionWriteLabel = "真实生产写入：未实现";

    public const string TargetOff = "off";
    public const string TargetOther = "other";
    public const string TargetUnknown = "unknown";

    public const string GrantByPhrase = "phrase";
    public const string GrantByDialog = "desktop-dialog";

    public const string ScopeText =
        "在 %TEMP% 下新建一次性目录，把随包且哈希相符的 rollback-v4.ps1 与 V4.ps1 复制进去，" +
        "用 V4_TEST_MODE=1 运行一次回滚演练。只运行随包 Engine，不实现别的恢复逻辑。";

    public const string ResourcesText =
        "只影响这次的一次性临时目录和其中的测试夹具。不写 HKCU Internet Settings，不改注册表，" +
        "不重启客户端，不读写凭据，不启动或关闭任何客户端进程。";

    public const string SystemProxyText =
        "否。执行前后各读一次 ProxyEnable/ProxyServer；这只证明两次读取相同，不能证明中间没有写入。";

    public const string RollbackText =
        "结束时删除这个临时目录。当前用户代理没有被本次操作改动，因此没有系统状态需要回滚。";

    public const string NotImplementedText =
        "真实生产写入：未实现。Executor 固定 V4_TEST_MODE + stub，不会写真实系统代理。";

    public const string RefusalText = "拒绝授权后仍可继续只读诊断。";

    public static string Phrase(string target) => OperationName + " " + Normalize(target);

    public static string Normalize(string? target) =>
        string.IsNullOrWhiteSpace(target) ? TargetUnknown : target.Trim();

    /// <summary>
    /// Operation plus target, compared exactly (only surrounding whitespace is
    /// ignored). Case, extra words and a one-key "--yes" never match.
    /// </summary>
    public static bool PhraseMatches(string? typedPhrase, string target) =>
        typedPhrase is not null &&
        string.Equals(typedPhrase.Trim(), Phrase(target), StringComparison.Ordinal);

    /// <summary>
    /// Read-only: which endpoint the exercise is bound to right now. It reads the same
    /// two values <see cref="NetworkReader.LiveProxyStamp"/> compares, and never writes.
    /// </summary>
    public static string ReadTarget()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            if (key is null) return TargetUnknown;
            var enable = key.GetValue("ProxyEnable");
            if (enable is not int number) return TargetUnknown;
            if (number == 0) return TargetOff;
            if (number != 1) return TargetUnknown;
            return NetworkReader.TryParseLoopback(key.GetValue("ProxyServer") as string, out var normalized)
                ? normalized
                : TargetOther;
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return TargetUnknown;
        }
    }

    public static string DescribeTarget(string target) => Normalize(target) switch
    {
        TargetOff => "当前用户代理未启用",
        TargetOther => "当前用户代理不是可识别的本机回环端点",
        TargetUnknown => "读不到当前用户代理选择",
        _ => "当前用户代理选择的本机端点"
    };

    public static RecoveryConsentBrief Describe(string? target = null)
    {
        var actual = target is null ? ReadTarget() : Normalize(target);
        var phrase = Phrase(actual);
        var lines = new List<string>
        {
            "隔离演练授权（不是真实生产写入）",
            "操作：" + OperationName + "（" + ModeLabel + "）",
            "目标：" + actual + "（" + DescribeTarget(actual) + "）",
            "操作范围：" + ScopeText,
            "受影响资源：" + ResourcesText,
            "是否写系统代理：" + SystemProxyText,
            "回滚方式：" + RollbackText,
            NotImplementedText,
            RefusalText,
            "确认短语：" + phrase
        };
        return new RecoveryConsentBrief(
            actual, phrase, ScopeText, ResourcesText, SystemProxyText, RollbackText,
            NotImplementedText, RefusalText, lines);
    }
}
