using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ProxyDoctor;

public static class RecoveryTrust
{
    public const string RollbackSha256 = "32172A5771561BBA9280F7BB11E229DB6D35620C98ED5FFEDF7CE08DFD7DF649";
    public const string LibrarySha256 = "5F19B7539DFBBA8B7D89741D1D34D52FD2A5C929CBD48C6EA86662A913D66C01";
    public const string ScriptSha256 = "42AAF034CBE3D52971B59AEE726C0E33053A70186B5C142D73D56AA0FAE03194";
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
        result.ScriptStarted
        && !result.Cancelled
        && !result.TimedOut
        && result.ProcessExit == 0
        && result.TransactionExit == result.ExpectedTransactionExit
        && result.ProfileRestored
        && result.WritesMatch
        && result.JournalClear
        && result.LiveUnchanged;
}

internal static partial class Native
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(string name, uint access, uint share, nint security, int disposition, uint flags, nint template);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    internal static extern int GetFinalPathNameByHandle(SafeFileHandle handle, char[] buffer, int length, int flags);
}
