using System.Text.Json;
using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

public class RecoveryFixtureTests
{
    private static readonly string[] RequiredCases =
    {
        "complete-success",
        "exit-code-alone",
        "decimal-32.5",
        "string-true",
        "missing-field",
        "extra-write-line",
        "writesmatch-true-raw-differs",
        "cancelled",
        "timed-out",
        "illegal-expected-99",
        "empty-object"
    };

    [Fact]
    public void Fixture_cases_assert_complete_success()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(LocateFixture()));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString() ?? "";
            seen.Add(name);
            var expected = item.GetProperty("completeSuccess").GetBoolean();
            var actual = RecoveryTrust.IsComplete(item.GetProperty("result"));
            Assert.True(actual == expected, name + " expected " + expected + " actual " + actual);
        }

        foreach (var name in RequiredCases)
            Assert.Contains(name, seen);

        Assert.Equal(
            "LiveUnchanged 只比较开始和结束两次读取的 ProxyEnable 与 ProxyServer。它不能证明这两次读取之间没有写入。",
            RecoveryResult.ScopeLabel);
    }

    private static string LocateFixture()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "contracts", "recovery-fixtures.json");
            if (File.Exists(candidate)) return candidate;
        }

        throw new FileNotFoundException("recovery-fixtures.json");
    }
}
