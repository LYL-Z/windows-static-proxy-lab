using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

public class ProtocolEvidenceTests
{
    [Fact]
    public void Dns_answer_without_a_receiver_is_path_unknown()
    {
        var evidence = ProtocolEvidence.Dns("system-resolver", "unobserved", queried: true,
            answerReceived: true, receiverSawQuery: false, errorCode: null, timedOut: false, elapsedMs: 12);

        Assert.Equal(ProtocolClass.PathUnknown, evidence.Result);
        Assert.Equal("DNS", evidence.Protocol);
        Assert.Equal("system-resolver", evidence.Initiator);
        Assert.Equal("unobserved", evidence.Receiver);
        Assert.Null(evidence.ErrorCode);
        Assert.Equal(12, evidence.ElapsedMs);
        AssertNoProtectionClaim(evidence);
        Assert.NotEqual(ProtocolClass.Available, evidence.Result);
    }

    [Fact]
    public void Dns_answer_seen_by_a_controlled_resolver_stays_lab_only()
    {
        var evidence = ProtocolEvidence.Dns("node", "lab-dns", queried: true,
            answerReceived: true, receiverSawQuery: true, errorCode: null, timedOut: false, elapsedMs: 4);

        Assert.Equal(ProtocolClass.LabOnly, evidence.Result);
        Assert.Contains("this query only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Dns_that_was_not_queried_is_not_tested()
    {
        var evidence = ProtocolEvidence.Dns("system-resolver", "none", queried: false,
            answerReceived: true, receiverSawQuery: true, errorCode: null, timedOut: false, elapsedMs: 0);

        Assert.Equal(ProtocolClass.NotTested, evidence.Result);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Dns_timeout_is_not_a_refusal()
    {
        var evidence = ProtocolEvidence.Dns("system-resolver", "unobserved", queried: true,
            answerReceived: false, receiverSawQuery: false, errorCode: 10060, timedOut: true, elapsedMs: 2000);

        Assert.Equal(ProtocolClass.TimedOut, evidence.Result);
        Assert.Equal(10060, evidence.ErrorCode);
        Assert.Equal(2000, evidence.ElapsedMs);
        Assert.NotEqual(ProtocolClass.Rejected, evidence.Result);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Dns_access_denied_without_an_answer_is_rejected()
    {
        var evidence = ProtocolEvidence.Dns("node", "lab-dns", queried: true,
            answerReceived: false, receiverSawQuery: false, errorCode: 10013, timedOut: false, elapsedMs: 3);

        Assert.Equal(ProtocolClass.Rejected, evidence.Result);
        Assert.Equal(10013, evidence.ErrorCode);
        AssertNoProtectionClaim(evidence);
    }

    [Theory]
    [InlineData(200)]
    [InlineData(204)]
    [InlineData(403)]
    public void Doh_http_status_without_a_receiver_is_path_unknown(int status)
    {
        var evidence = ProtocolEvidence.Doh("http-client", "dns.google", requested: true,
            httpStatus: status, receiverSawRequest: false, errorCode: null, timedOut: false, elapsedMs: 80);

        Assert.Equal(ProtocolClass.PathUnknown, evidence.Result);
        Assert.Contains($"HTTP {status}", evidence.Coverage, StringComparison.Ordinal);
        Assert.Equal(80, evidence.ElapsedMs);
        Assert.NotEqual(ProtocolClass.Available, evidence.Result);
        AssertNoProtectionClaim(evidence);
    }

    [Theory]
    [InlineData(200)]
    [InlineData(400)]
    public void Doh_http_status_with_a_receiver_stays_lab_only(int status)
    {
        var evidence = ProtocolEvidence.Doh("lab-client", "loopback-doh", requested: true,
            httpStatus: status, receiverSawRequest: true, errorCode: null, timedOut: false, elapsedMs: 15);

        Assert.Equal(ProtocolClass.LabOnly, evidence.Result);
        Assert.Contains("this request only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Doh_that_was_not_requested_is_not_tested()
    {
        var evidence = ProtocolEvidence.Doh("browser", "unknown", requested: false,
            httpStatus: 200, receiverSawRequest: false, errorCode: null, timedOut: false, elapsedMs: 0);

        Assert.Equal(ProtocolClass.NotTested, evidence.Result);
    }

    [Fact]
    public void Doh_timeout_is_timed_out()
    {
        var evidence = ProtocolEvidence.Doh("http-client", "dns.google", requested: true,
            httpStatus: null, receiverSawRequest: false, errorCode: null, timedOut: true, elapsedMs: 8000);

        Assert.Equal(ProtocolClass.TimedOut, evidence.Result);
        Assert.Equal(8000, evidence.ElapsedMs);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Ipv4_loopback_exchange_is_available_for_this_socket_only()
    {
        var evidence = ProtocolEvidence.Ipv4Loopback("test-process", "127.0.0.1", exchanged: true,
            errorCode: null, timedOut: false, elapsedMs: 1);

        Assert.Equal(ProtocolClass.Available, evidence.Result);
        Assert.Equal("IPv4 loopback", evidence.Protocol);
        Assert.Contains("this socket only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        Assert.Null(evidence.ErrorCode);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Ipv4_loopback_lab_exchange_is_lab_only_for_this_socket_only()
    {
        var evidence = ProtocolEvidence.Ipv4Loopback("test-process", "127.0.0.1", exchanged: true,
            errorCode: null, timedOut: false, elapsedMs: 1, labOnly: true);

        Assert.Equal(ProtocolClass.LabOnly, evidence.Result);
        Assert.Contains("this socket only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Ipv4_loopback_timeout_and_refusal_are_not_production_protection()
    {
        var timedOut = ProtocolEvidence.Ipv4Loopback("test-process", "127.0.0.1", exchanged: false,
            errorCode: 10060, timedOut: true, elapsedMs: 1500);
        var refused = ProtocolEvidence.Ipv4Loopback("test-process", "127.0.0.1", exchanged: false,
            errorCode: 10013, timedOut: false, elapsedMs: 2);

        Assert.Equal(ProtocolClass.TimedOut, timedOut.Result);
        Assert.Equal(ProtocolClass.Rejected, refused.Result);
        Assert.Contains("this socket only", timedOut.Coverage, StringComparison.Ordinal);
        Assert.Contains("this socket only", refused.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", timedOut.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", refused.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(timedOut);
        AssertNoProtectionClaim(refused);
    }

    [Fact]
    public void Ipv6_loopback_separates_refusal_timeout_and_a_socket_exchange()
    {
        var refused = ProtocolEvidence.Ipv6Loopback("python", "[::1]", exchanged: false, receiverHits: 0,
            errorCode: 10013, timedOut: false, elapsedMs: 5);
        var timedOut = ProtocolEvidence.Ipv6Loopback("python", "[::1]", exchanged: false, receiverHits: 0,
            errorCode: null, timedOut: true, elapsedMs: 2000);
        var exchanged = ProtocolEvidence.Ipv6Loopback("python", "[::1]", exchanged: true, receiverHits: 1,
            errorCode: null, timedOut: false, elapsedMs: 6);
        var mismatch = ProtocolEvidence.Ipv6Loopback("python", "[::1]", exchanged: true, receiverHits: 0,
            errorCode: null, timedOut: false, elapsedMs: 6);
        var missingStack = ProtocolEvidence.Ipv6Loopback("python", "[::1]", exchanged: false, receiverHits: 0,
            errorCode: 10049, timedOut: false, elapsedMs: 1);

        Assert.Equal(ProtocolClass.Rejected, refused.Result);
        Assert.Equal(10013, refused.ErrorCode);
        Assert.Equal(ProtocolClass.TimedOut, timedOut.Result);
        Assert.Equal(ProtocolClass.Available, exchanged.Result);
        Assert.Contains("this socket only", exchanged.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", exchanged.Coverage, StringComparison.Ordinal);
        Assert.Equal(ProtocolClass.PathUnknown, mismatch.Result);
        Assert.Equal(ProtocolClass.PathUnknown, missingStack.Result);
        Assert.NotEqual(ProtocolClass.Rejected, missingStack.Result);
        AssertNoProtectionClaim(refused);
        AssertNoProtectionClaim(timedOut);
        AssertNoProtectionClaim(exchanged);
    }

    [Fact]
    public void Udp_loopback_exchange_covers_this_socket_only()
    {
        var evidence = ProtocolEvidence.UdpLoopback("test-process", "127.0.0.1", exchanged: true,
            errorCode: null, timedOut: false, elapsedMs: 2);

        Assert.Equal(ProtocolClass.Available, evidence.Result);
        Assert.Equal("UDP loopback", evidence.Protocol);
        Assert.Contains("this socket only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not WebRTC protection", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Udp_loopback_timeout_is_timed_out()
    {
        var evidence = ProtocolEvidence.UdpLoopback("test-process", "127.0.0.1", exchanged: false,
            errorCode: null, timedOut: true, elapsedMs: 1500);

        Assert.Equal(ProtocolClass.TimedOut, evidence.Result);
        Assert.Contains("this socket only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not WebRTC protection", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Webrtc_without_a_browser_capture_is_not_tested()
    {
        var evidence = ProtocolEvidence.WebRtc("chrome", "stun", browserCaptured: false,
            applicationDataMatched: true, receiverSawBrowser: true, errorCode: null, timedOut: false, elapsedMs: 30);

        Assert.Equal(ProtocolClass.NotTested, evidence.Result);
        Assert.Equal("WebRTC", evidence.Protocol);
        Assert.Equal("chrome", evidence.Initiator);
        Assert.Equal("stun", evidence.Receiver);
        Assert.Equal(30, evidence.ElapsedMs);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Webrtc_capture_with_a_receiver_is_lab_only()
    {
        var evidence = ProtocolEvidence.WebRtc("chrome", "local-stun", browserCaptured: true,
            applicationDataMatched: true, receiverSawBrowser: true, errorCode: null, timedOut: false, elapsedMs: 90);

        Assert.Equal(ProtocolClass.LabOnly, evidence.Result);
        Assert.Contains("this sample only", evidence.Coverage, StringComparison.Ordinal);
        Assert.Contains("not production protection", evidence.Coverage, StringComparison.Ordinal);
        Assert.NotEqual(ProtocolClass.Available, evidence.Result);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Webrtc_capture_without_a_receiver_is_path_unknown()
    {
        var evidence = ProtocolEvidence.WebRtc("chrome", "local-stun", browserCaptured: true,
            applicationDataMatched: false, receiverSawBrowser: false, errorCode: null, timedOut: false, elapsedMs: 40);

        Assert.Equal(ProtocolClass.PathUnknown, evidence.Result);
        AssertNoProtectionClaim(evidence);
    }

    [Fact]
    public void Vocabulary_has_no_protected_or_path_known_result()
    {
        var names = Enum.GetNames<ProtocolClass>();
        Assert.Equal(
            new[] { "Available", "Rejected", "TimedOut", "PathUnknown", "NotTested", "LabOnly" },
            names);
        Assert.DoesNotContain("PathKnown", names);
        Assert.DoesNotContain("Protected", names);
    }

    [Fact]
    public void Connection_reset_is_not_an_explicit_refusal()
    {
        var evidence = ProtocolEvidence.Ipv4Loopback("test-process", "127.0.0.1", exchanged: false,
            errorCode: 10061, timedOut: false, elapsedMs: 8);

        Assert.Equal(ProtocolClass.PathUnknown, evidence.Result);
        Assert.Equal(10061, evidence.ErrorCode);
        Assert.Contains("this socket only", evidence.Coverage, StringComparison.Ordinal);
        AssertNoProtectionClaim(evidence);
    }

    private static void AssertNoProtectionClaim(ProtocolEvidence evidence)
    {
        Assert.DoesNotContain("protected", evidence.Coverage, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("PathKnown", evidence.Coverage, StringComparison.Ordinal);
        Assert.DoesNotContain("PathKnown", evidence.Result.ToString(), StringComparison.Ordinal);
        Assert.False(string.IsNullOrWhiteSpace(evidence.Coverage));
    }
}
