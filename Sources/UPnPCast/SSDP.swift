import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A response to an SSDP `M-SEARCH` (or a `NOTIFY` announcement).
public struct SSDPResponse: Sendable, Hashable {
    /// URL of the device description (`LOCATION`).
    public var location: URL
    /// Search target / notification type (`ST` or `NT`).
    public var searchTarget: String
    /// Unique service name (`USN`), e.g. `uuid:…::urn:schemas-upnp-org:device:MediaRenderer:1`.
    public var usn: String
    public var server: String?
    /// All headers, keys lowercased.
    public var headers: [String: String]
    /// Address the response came from.
    public var sourceAddress: String

    /// The device UUID portion of the USN (`uuid:…`).
    public var uuid: String? {
        usn.components(separatedBy: "::").first.flatMap { $0.hasPrefix("uuid:") ? $0 : nil }
    }

    /// Parses an SSDP HTTP-over-UDP message.
    public init?(message: String, sourceAddress: String) {
        let lines = message.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let first = lines.first?.uppercased(),
              first.hasPrefix("HTTP/1.1 200") || first.hasPrefix("NOTIFY") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["nts"] == "ssdp:byebye" { return nil }
        guard let locationText = headers["location"], let location = URL(string: locationText) else { return nil }
        self.location = location
        self.searchTarget = headers["st"] ?? headers["nt"] ?? ""
        self.usn = headers["usn"] ?? ""
        self.server = headers["server"]
        self.headers = headers
        self.sourceAddress = sourceAddress
    }
}

/// SSDP (Simple Service Discovery Protocol) search.
///
/// On iOS, tvOS and visionOS, sending multicast requires the
/// `com.apple.developer.networking.multicast` entitlement (request it from
/// Apple) plus `NSLocalNetworkUsageDescription` in Info.plist.
public enum SSDP {
    /// Common search targets.
    public enum SearchTarget {
        public static let all = "ssdp:all"
        public static let rootDevice = "upnp:rootdevice"
        public static let mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
        public static let mediaServer = "urn:schemas-upnp-org:device:MediaServer:1"
        public static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
        public static let dial = "urn:dial-multiscreen-org:service:dial:1"
    }

    /// Builds an `M-SEARCH` request.
    public static func searchMessage(target: String, maxWait: Int = 2) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: \(max(1, min(5, maxWait)))\r\n"
            + "ST: \(target)\r\n"
            + "USER-AGENT: UPnPCast/1.0 UPnP/1.1\r\n\r\n"
    }

    /// Streams responses to an `M-SEARCH` for `target`, re-sending the search
    /// a few times to compensate for UDP loss. The stream finishes after
    /// `duration`. Duplicate responses (same USN and location) are suppressed.
    public static func search(target: String = SearchTarget.all, duration: Duration = .seconds(3)) -> AsyncThrowingStream<SSDPResponse, any Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancellationFlag()
            let thread = Thread {
                do {
                    try runSearch(target: target, duration: duration.seconds, cancelled: cancelled, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "UPnPCast.SSDP"
            thread.start()
            continuation.onTermination = { _ in cancelled.cancel() }
        }
    }

    /// Collects every response received within `duration`.
    public static func discover(target: String = SearchTarget.all, duration: Duration = .seconds(3)) async throws -> [SSDPResponse] {
        var results: [SSDPResponse] = []
        for try await response in search(target: target, duration: duration) {
            results.append(response)
        }
        return results
    }

    private static func runSearch(target: String, duration: TimeInterval, cancelled: CancellationFlag, continuation: AsyncThrowingStream<SSDPResponse, any Error>.Continuation) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UPnPError.network("socket() failed: \(errnoDescription())") }
        defer { close(fd) }

        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)

        let message = Array(searchMessage(target: target, maxWait: Int(max(1, min(5, duration - 0.5)))).utf8)
        func sendSearch() throws {
            let sent = message.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { throw UPnPError.network("sendto() failed: \(errnoDescription())") }
        }

        let start = Date()
        var resendTimes: [TimeInterval] = [0, 0.4, 1.2]
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 65_507)

        while !cancelled.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= duration { break }
            if let next = resendTimes.first, elapsed >= next {
                resendTimes.removeFirst()
                try sendSearch()
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds = Int32(min(100, max(1, (duration - elapsed) * 1000)))
            let ready = poll(&pollDescriptor, 1, waitMilliseconds)
            guard ready > 0 else { continue }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            guard count > 0 else { continue }
            var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &source.sin_addr, &addressBuffer, socklen_t(INET_ADDRSTRLEN))
            let address = String(decoding: addressBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            guard let response = SSDPResponse(message: text, sourceAddress: address) else { continue }
            let key = response.usn + "|" + response.location.absoluteString
            if seen.insert(key).inserted {
                continuation.yield(response)
            }
        }
    }
}

private func errnoDescription() -> String {
    String(decoding: [CChar](UnsafeBufferPointer(start: strerror(errno), count: strlen(strerror(errno)))).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

extension Duration {
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
