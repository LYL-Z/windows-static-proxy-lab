namespace ProxyDoctor;

public enum ProtocolClass
{
    Available,
    Rejected,
    TimedOut,
    PathUnknown,
    NotTested,
    LabOnly
}

public enum ProtocolKind
{
    Dns,
    Doh,
    Ipv4Loopback,
    Ipv6Loopback,
    UdpLoopback,
    WebRtc
}

/// <summary>
/// One observed protocol attempt. Classification reads these fields and does not contact the network.
/// </summary>
public sealed record ProtocolObservation
{
    public required string Protocol { get; init; }
    public required string Initiator { get; init; }
    public required string Receiver { get; init; }
    public ProtocolKind Kind { get; init; }
    public bool Attempted { get; init; }
    public bool Exchanged { get; init; }
    public int ReceiverHits { get; init; }
    public bool AnswerReceived { get; init; }
    public int? HttpStatus { get; init; }
    public bool BrowserCaptured { get; init; }
    public bool LabOnlyExchange { get; init; }
    public int? ErrorCode { get; init; }
    public bool TimedOut { get; init; }
    public long ElapsedMs { get; init; }
}

public sealed record ProtocolEvidence(
    string Protocol,
    string Initiator,
    string Receiver,
    ProtocolClass Result,
    int? ErrorCode,
    long ElapsedMs,
    string Coverage)
{
    private const int AccessDenied = 10013;
    private const int TimedOutCode = 10060;

    public static ProtocolEvidence Classify(ProtocolObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        return observation.Kind switch
        {
            ProtocolKind.Dns => ClassifyDns(observation),
            ProtocolKind.Doh => ClassifyDoh(observation),
            ProtocolKind.Ipv4Loopback => ClassifySocket(observation, webrtcNote: false, requireSingleHit: false),
            ProtocolKind.Ipv6Loopback => ClassifySocket(observation, webrtcNote: false, requireSingleHit: true),
            ProtocolKind.UdpLoopback => ClassifySocket(observation, webrtcNote: true, requireSingleHit: false),
            ProtocolKind.WebRtc => ClassifyWebRtc(observation),
            _ => Finish(observation, ProtocolClass.PathUnknown,
                "This protocol kind is unrecognized, so the path is unknown and this is not protection.")
        };
    }

    public static ProtocolEvidence Dns(
        string initiator,
        string receiver,
        bool queried,
        bool answerReceived,
        bool receiverSawQuery,
        int? errorCode,
        bool timedOut,
        long elapsedMs) =>
        Classify(new ProtocolObservation
        {
            Protocol = "DNS",
            Initiator = initiator,
            Receiver = receiver,
            Kind = ProtocolKind.Dns,
            Attempted = queried,
            AnswerReceived = answerReceived,
            ReceiverHits = receiverSawQuery ? 1 : 0,
            ErrorCode = errorCode,
            TimedOut = timedOut,
            ElapsedMs = elapsedMs
        });

    public static ProtocolEvidence Doh(
        string initiator,
        string receiver,
        bool requested,
        int? httpStatus,
        bool receiverSawRequest,
        int? errorCode,
        bool timedOut,
        long elapsedMs) =>
        Classify(new ProtocolObservation
        {
            Protocol = "DoH",
            Initiator = initiator,
            Receiver = receiver,
            Kind = ProtocolKind.Doh,
            Attempted = requested,
            HttpStatus = httpStatus,
            ReceiverHits = receiverSawRequest ? 1 : 0,
            ErrorCode = errorCode,
            TimedOut = timedOut,
            ElapsedMs = elapsedMs
        });

    public static ProtocolEvidence Ipv4Loopback(
        string initiator,
        string receiver,
        bool exchanged,
        int? errorCode,
        bool timedOut,
        long elapsedMs,
        bool labOnly = false,
        bool tested = true) =>
        Classify(SocketObservation("IPv4 loopback", ProtocolKind.Ipv4Loopback, initiator, receiver,
            exchanged, errorCode, timedOut, elapsedMs, labOnly, tested));

    public static ProtocolEvidence Ipv6Loopback(
        string initiator,
        string receiver,
        bool exchanged,
        int receiverHits,
        int? errorCode,
        bool timedOut,
        long elapsedMs,
        bool labOnly = false,
        bool tested = true) =>
        Classify(new ProtocolObservation
        {
            Protocol = "IPv6 loopback",
            Initiator = initiator,
            Receiver = receiver,
            Kind = ProtocolKind.Ipv6Loopback,
            Attempted = tested,
            Exchanged = exchanged,
            ReceiverHits = receiverHits,
            LabOnlyExchange = labOnly,
            ErrorCode = errorCode,
            TimedOut = timedOut,
            ElapsedMs = elapsedMs
        });

    public static ProtocolEvidence UdpLoopback(
        string initiator,
        string receiver,
        bool exchanged,
        int? errorCode,
        bool timedOut,
        long elapsedMs,
        bool labOnly = false,
        bool tested = true) =>
        Classify(SocketObservation("UDP loopback", ProtocolKind.UdpLoopback, initiator, receiver,
            exchanged, errorCode, timedOut, elapsedMs, labOnly, tested));

    public static ProtocolEvidence WebRtc(
        string initiator,
        string receiver,
        bool browserCaptured,
        bool applicationDataMatched,
        bool receiverSawBrowser,
        int? errorCode,
        bool timedOut,
        long elapsedMs) =>
        Classify(new ProtocolObservation
        {
            Protocol = "WebRTC",
            Initiator = initiator,
            Receiver = receiver,
            Kind = ProtocolKind.WebRtc,
            Attempted = browserCaptured,
            BrowserCaptured = browserCaptured,
            Exchanged = applicationDataMatched,
            ReceiverHits = receiverSawBrowser ? 1 : 0,
            ErrorCode = errorCode,
            TimedOut = timedOut,
            ElapsedMs = elapsedMs
        });

    private static ProtocolObservation SocketObservation(
        string protocol,
        ProtocolKind kind,
        string initiator,
        string receiver,
        bool exchanged,
        int? errorCode,
        bool timedOut,
        long elapsedMs,
        bool labOnly,
        bool tested) =>
        new()
        {
            Protocol = protocol,
            Initiator = initiator,
            Receiver = receiver,
            Kind = kind,
            Attempted = tested,
            Exchanged = exchanged,
            ReceiverHits = exchanged ? 1 : 0,
            LabOnlyExchange = labOnly,
            ErrorCode = errorCode,
            TimedOut = timedOut,
            ElapsedMs = elapsedMs
        };

    private static ProtocolEvidence ClassifyDns(ProtocolObservation observation)
    {
        if (!observation.Attempted)
            return Finish(observation, ProtocolClass.NotTested,
                "DNS was not queried, so the resolver path was not tested and this is not protection.");
        if (IsTimeout(observation))
            return Finish(observation, ProtocolClass.TimedOut,
                "DNS timed out, a timeout does not identify the resolver path, and this is not protection.");
        if (observation.AnswerReceived && observation.ReceiverHits <= 0)
            return Finish(observation, ProtocolClass.PathUnknown,
                "A DNS answer is not a path proof, does not identify the recursive path, and is not protection.");
        if (observation.AnswerReceived && observation.ReceiverHits > 0)
            return Finish(observation, ProtocolClass.LabOnly,
                "The controlled resolver saw this DNS query and the client received an answer, coverage is this query only, and this is not production protection.");
        if (observation.ErrorCode == AccessDenied)
            return Finish(observation, ProtocolClass.Rejected,
                "DNS was refused with error 10013, the resolver path stays unknown, and this refusal is not protection.");
        return Finish(observation, ProtocolClass.PathUnknown,
            "DNS finished without a receiver-confirmed query, the path is unknown, and this is not protection.");
    }

    private static ProtocolEvidence ClassifyDoh(ProtocolObservation observation)
    {
        if (!observation.Attempted)
            return Finish(observation, ProtocolClass.NotTested,
                "DoH was not requested, so the resolver path was not tested and this is not protection.");
        if (IsTimeout(observation))
            return Finish(observation, ProtocolClass.TimedOut,
                "DoH timed out, a timeout does not identify the resolver path, and this is not protection.");
        if (observation.HttpStatus is int status && observation.ReceiverHits <= 0)
            return Finish(observation, ProtocolClass.PathUnknown,
                $"DoH HTTP {status} is not browser DoH and does not identify the resolver path, and this is not protection.");
        if (observation.HttpStatus is int seen && observation.ReceiverHits > 0)
            return Finish(observation, ProtocolClass.LabOnly,
                $"This controlled DoH exchange returned HTTP {seen}, covers this request only, is not browser DoH, and is not production protection.");
        if (observation.ErrorCode == AccessDenied)
            return Finish(observation, ProtocolClass.Rejected,
                "DoH was refused with error 10013, the resolver path stays unknown, and this refusal is not protection.");
        return Finish(observation, ProtocolClass.PathUnknown,
            "DoH finished without a receiver-confirmed request, the path is unknown, and this is not protection.");
    }

    private static ProtocolEvidence ClassifySocket(ProtocolObservation observation, bool webrtcNote, bool requireSingleHit)
    {
        var name = observation.Protocol;
        if (!observation.Attempted)
            return Finish(observation, ProtocolClass.NotTested,
                Sentence(name, "was not tested and is not production protection", socketOnly: true, webrtcNote));
        if (observation.Exchanged && observation.TimedOut)
            return Finish(observation, ProtocolClass.PathUnknown,
                Sentence(name, "observation contradicts itself, so the path is unknown and this is not production protection", socketOnly: true, webrtcNote));
        if (observation.Exchanged && requireSingleHit && observation.ReceiverHits != 1)
            return Finish(observation, ProtocolClass.PathUnknown,
                Sentence(name, "did not match one receiver hit, so the path is unknown and this is not production protection", socketOnly: true, webrtcNote));
        if (!observation.Exchanged && observation.ReceiverHits > 0)
            return Finish(observation, ProtocolClass.PathUnknown,
                Sentence(name, "receiver counted traffic without a matching exchange, so the path is unknown and this is not production protection", socketOnly: true, webrtcNote));
        if (observation.Exchanged)
        {
            var result = observation.LabOnlyExchange ? ProtocolClass.LabOnly : ProtocolClass.Available;
            var how = observation.LabOnlyExchange ? "lab exchange" : "exchange";
            return Finish(observation, result,
                Sentence(name, $"{how} covers this socket only and is not production protection", socketOnly: false, webrtcNote));
        }
        if (IsTimeout(observation))
            return Finish(observation, ProtocolClass.TimedOut,
                Sentence(name, "timed out, a timeout does not show that a filter blocked it, and this is not production protection", socketOnly: true, webrtcNote));
        if (observation.ErrorCode == AccessDenied)
            return Finish(observation, ProtocolClass.Rejected,
                Sentence(name, "was refused with error 10013, the refusing component stays unknown, and this is not production protection", socketOnly: true, webrtcNote));
        if (IsStackUnavailable(observation.ErrorCode))
            return Finish(observation, ProtocolClass.PathUnknown,
                Sentence(name, $"address family is unavailable with error {observation.ErrorCode}, the path is unknown, and this is not production protection", socketOnly: true, webrtcNote));
        return Finish(observation, ProtocolClass.PathUnknown,
            Sentence(name, "ended without a confirmed exchange, the path is unknown, and this is not production protection", socketOnly: true, webrtcNote));
    }

    private static ProtocolEvidence ClassifyWebRtc(ProtocolObservation observation)
    {
        if (!observation.BrowserCaptured)
            return Finish(observation, ProtocolClass.NotTested,
                "WebRTC has no browser capture, so it is not tested and is not protection.");
        if (observation.Exchanged && observation.TimedOut)
            return Finish(observation, ProtocolClass.PathUnknown,
                "WebRTC capture contradicts itself, so the path is unknown and this is not protection.");
        if (IsTimeout(observation))
            return Finish(observation, ProtocolClass.TimedOut,
                "WebRTC capture timed out, a timeout does not identify a path, and this is not protection.");
        if (observation.Exchanged && observation.ReceiverHits > 0)
            return Finish(observation, ProtocolClass.LabOnly,
                "This browser capture covers this sample only and is not production protection.");
        if (observation.ErrorCode == AccessDenied && observation.ReceiverHits <= 0)
            return Finish(observation, ProtocolClass.Rejected,
                "WebRTC capture was refused with error 10013, the path stays unknown, and this refusal is not protection.");
        return Finish(observation, ProtocolClass.PathUnknown,
            "This browser capture does not identify the selected path and is not protection.");
    }

    private static bool IsTimeout(ProtocolObservation observation) =>
        observation.TimedOut || observation.ErrorCode == TimedOutCode;

    private static bool IsStackUnavailable(int? errorCode) =>
        errorCode is 10047 or 10049 or 10051 or 10065;

    private static string Sentence(string protocol, string body, bool socketOnly, bool webrtcNote)
    {
        var socket = socketOnly ? ", and coverage is this socket only" : "";
        var webrtc = webrtcNote ? ", and this is not WebRTC protection" : "";
        var publicIpv6 = protocol == "IPv6 loopback" ? ", and this is not a public IPv6 path" : "";
        return $"{protocol} {body}{socket}{webrtc}{publicIpv6}.";
    }

    private static ProtocolEvidence Finish(ProtocolObservation observation, ProtocolClass result, string coverage)
    {
        if (coverage.Contains("PathKnown", StringComparison.Ordinal) ||
            coverage.Contains("protected", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("A protocol observation cannot be reported as protected or PathKnown.");
        if (result is ProtocolClass.Available &&
            observation.Kind is ProtocolKind.Dns or ProtocolKind.Doh or ProtocolKind.WebRtc)
            throw new InvalidOperationException("DNS, DoH, and WebRTC cannot be classified as Available.");
        return new ProtocolEvidence(
            observation.Protocol,
            observation.Initiator,
            observation.Receiver,
            result,
            observation.ErrorCode,
            observation.ElapsedMs,
            coverage);
    }
}
