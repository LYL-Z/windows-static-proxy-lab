using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace ProxyDoctor;

public static class RecoveryTrust
{
    public const string RollbackSha256 = "32172A5771561BBA9280F7BB11E229DB6D35620C98ED5FFEDF7CE08DFD7DF649";
    public const string LibrarySha256 = "5A694E09B3306493B33ECE7330754705199356C77F9E40FCC73F69CDEA2774FE";
    public const string ScriptSha256 = "4F8CA4BFE9E15CA2DF66C330D4EE29D2603F8B7271CB0D53332A8DE30E61628C";
    public const int ExpectedTransactionExit = 32;

    public static bool IsStrictChild(string parent, string child)
    {
        var parentFull = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var childFull = Path.GetFullPath(child).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var prefix = parentFull + Path.DirectorySeparatorChar;
        return childFull.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    public static string? FinalPath(string path)
    {
        using var handle = Native.CreateFile(path, 0x80, 7, 0, 3, 0x02000000, 0);
        if (handle.IsInvalid) return null;
        var buffer = new char[2048];
        var length = Native.GetFinalPathNameByHandle(handle, buffer, buffer.Length, 0);
        if (length <= 0 || length >= buffer.Length) return null;
        var text = new string(buffer, 0, length);
        return text.StartsWith(@"\\?\", StringComparison.Ordinal) ? text[4..] : text;
    }

    public static bool ContainedAfterResolve(string parent, string child)
    {
        var finalParent = FinalPath(parent);
        var finalChild = FinalPath(child);
        return finalParent is not null && finalChild is not null && IsStrictChild(finalParent, finalChild);
    }

    public static string HashFile(string path)
    {
        var bytes = File.ReadAllBytes(path);
        return Convert.ToHexString(SHA256.HashData(bytes));
    }

    public static string HashScript(string path)
    {
        var text = File.ReadAllText(path).Replace("\r\n", "\n", StringComparison.Ordinal).Replace("\r", "\n", StringComparison.Ordinal);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    public static bool ReviewedFile(string path, string expectedHash)
    {
        if (!File.Exists(path) || IsReparsePoint(path)) return false;
        return HashFile(path).Equals(expectedHash, StringComparison.OrdinalIgnoreCase);
    }

    public static bool ReviewedScript(string path)
    {
        if (!File.Exists(path) || IsReparsePoint(path)) return false;
        return HashScript(path).Equals(ScriptSha256, StringComparison.OrdinalIgnoreCase);
    }

    public const string ExpectedWriteLine = "enabled=0 server=old:8080";

    public static bool WritesMatchScenario(string? writes)
    {
        if (string.IsNullOrEmpty(writes)) return false;
        var lines = writes.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        return lines.Length == 1 && lines[0].Trim() == ExpectedWriteLine;
    }

    public static bool IsComplete(RecoveryResult result) =>
        Verdict(
            result.ScriptStarted,
            result.Cancelled,
            result.TimedOut,
            result.ProcessExit,
            result.TransactionExit,
            result.ExpectedTransactionExit,
            result.ProfileRestored,
            result.WritesMatch,
            result.JournalClear,
            result.LiveUnchanged,
            !string.IsNullOrEmpty(result.Writes),
            result.Writes);

    public static bool IsComplete(JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object) return false;
        if (!TryReadBool(result, "ScriptStarted", out var started)
            || !TryReadBool(result, "Cancelled", out var cancelled)
            || !TryReadBool(result, "TimedOut", out var timedOut)
            || !TryReadBool(result, "ProfileRestored", out var profile)
            || !TryReadBool(result, "WritesMatch", out var writesMatch)
            || !TryReadBool(result, "JournalClear", out var journal)
            || !TryReadBool(result, "LiveUnchanged", out var live)
            || !TryReadInt32(result, "ProcessExit", out var process)
            || !TryReadInt32(result, "TransactionExit", out var transaction)
            || !TryReadInt32(result, "ExpectedTransactionExit", out var expected))
            return false;

        if (result.EnumerateObject().Any(item => item.Name != "Writes" &&
            item.Name.Equals("Writes", StringComparison.OrdinalIgnoreCase))) return false;
        var rawPresent = result.TryGetProperty("Writes", out var writesElement);
        if (rawPresent && writesElement.ValueKind != JsonValueKind.String) return false;
        return Verdict(
            started,
            cancelled,
            timedOut,
            process,
            transaction,
            expected,
            profile,
            writesMatch,
            journal,
            live,
            rawPresent,
            rawPresent ? writesElement.GetString() : null);
    }

    private static bool IsAllowedTransactionExit(int exitCode) =>
        exitCode is 0 or 32 or 33 or 34 or 40 or 41;

    private static bool Verdict(
        bool started,
        bool cancelled,
        bool timedOut,
        int process,
        int transaction,
        int expected,
        bool profile,
        bool writesMatch,
        bool journal,
        bool live,
        bool rawWritesPresent,
        string? writes)
    {
        if (!started || cancelled || timedOut) return false;
        if (process != 0) return false;
        if (transaction != expected || !IsAllowedTransactionExit(expected)) return false;
        if (!profile || !writesMatch || !journal || !live) return false;
        if (rawWritesPresent && !WritesMatchScenario(writes)) return false;
        return true;
    }

    private static bool TryReadBool(JsonElement result, string name, out bool value)
    {
        value = false;
        if (!result.TryGetProperty(name, out var property)) return false;
        if (property.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = property.GetBoolean();
        return true;
    }

    private static bool TryReadInt32(JsonElement result, string name, out int value)
    {
        value = 0;
        if (!result.TryGetProperty(name, out var property)) return false;
        if (property.ValueKind != JsonValueKind.Number) return false;
        return property.TryGetInt32(out value);
    }
}

internal static partial class Native
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(string name, uint access, uint share, nint security, int disposition, uint flags, nint template);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    internal static extern int GetFinalPathNameByHandle(SafeFileHandle handle, char[] buffer, int length, int flags);
}
