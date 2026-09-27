import Foundation

/// The transport state of a renderer (`AVTransport` `TransportState`).
public enum TransportState: Sendable, Hashable {
    case stopped, playing, paused, transitioning, noMediaPresent, recording
    case other(String)

    init(_ raw: String) {
        switch raw.uppercased() {
        case "STOPPED": self = .stopped
        case "PLAYING": self = .playing
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING": self = .paused
        case "TRANSITIONING": self = .transitioning
        case "NO_MEDIA_PRESENT": self = .noMediaPresent
        case "RECORDING": self = .recording
        default: self = .other(raw)
        }
    }
}

/// Playback position reported by `GetPositionInfo`.
public struct PositionInfo: Sendable, Hashable {
    public var track: Int?
    public var duration: TimeInterval?
    public var position: TimeInterval?
    public var trackURI: String?
    public var trackMetadata: String?
}

/// Transport information reported by `GetTransportInfo`.
public struct TransportInfo: Sendable, Hashable {
    public var state: TransportState
    /// `OK` or `ERROR_OCCURRED`.
    public var status: String
    public var speed: String
}

/// A snapshot combining transport and position information.
public struct RendererStatus: Sendable, Hashable {
    public var transport: TransportInfo
    public var position: PositionInfo
    public var volume: Int?
    public var isMuted: Bool?
}

/// Controls a DLNA/UPnP MediaRenderer (smart TVs, AV receivers, speakers,
/// Kodi, VLC, …) through its AVTransport and RenderingControl services.
///
/// ```swift
/// let renderers = try await MediaRenderer.discover()
/// let tv = renderers.first!
/// try await tv.load(MediaItem(url: videoURL, mimeType: "video/mp4", title: "Movie"))
/// try await tv.play()
/// ```
public struct MediaRenderer: Sendable, Hashable, Identifiable {
    public let device: UPnPDevice
    public let avTransport: UPnPService
    public let renderingControl: UPnPService?
    public let connectionManager: UPnPService?
    public var soap: SOAPClient
    public var instanceID = "0"

    public var id: String { device.udn }
    public var name: String { device.friendlyName }

    public init(device: UPnPDevice, soap: SOAPClient = SOAPClient()) throws {
        guard let avTransport = device.service(ofType: UPnPServiceType.avTransport) else {
            throw UPnPError.serviceNotFound(UPnPServiceType.avTransport)
        }
        self.device = device
        self.avTransport = avTransport
        self.renderingControl = device.service(ofType: UPnPServiceType.renderingControl)
        self.connectionManager = device.service(ofType: UPnPServiceType.connectionManager)
        self.soap = soap
    }

    public static func == (lhs: MediaRenderer, rhs: MediaRenderer) -> Bool { lhs.device == rhs.device }
    public func hash(into hasher: inout Hasher) { hasher.combine(device) }

    /// Discovers media renderers on the local network.
    public static func discover(duration: Duration = .seconds(3), session: URLSession = .shared) async throws -> [MediaRenderer] {
        let responses = try await SSDP.discover(target: SSDP.SearchTarget.mediaRenderer, duration: duration)
        let locations = Set(responses.map(\.location))
        return await withTaskGroup(of: MediaRenderer?.self) { group in
            for location in locations {
                group.addTask {
                    guard let device = try? await UPnPDevice.load(from: location, session: session) else { return nil }
                    return try? MediaRenderer(device: device, soap: SOAPClient(session: session))
                }
            }
            var byID: [String: MediaRenderer] = [:]
            for await renderer in group {
                if let renderer, byID[renderer.id] == nil { byID[renderer.id] = renderer }
            }
            return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Connects to a renderer whose description URL is known.
    public static func connect(descriptionURL: URL, session: URLSession = .shared) async throws -> MediaRenderer {
        try MediaRenderer(device: try await UPnPDevice.load(from: descriptionURL, session: session), soap: SOAPClient(session: session))
    }

    // MARK: - AVTransport

    /// Sets the media to play (`SetAVTransportURI`). Call ``play()`` afterwards.
    public func load(_ item: MediaItem) async throws {
        _ = try await transport("SetAVTransportURI", [
            ("InstanceID", instanceID),
            ("CurrentURI", item.url.absoluteString),
            ("CurrentURIMetaData", item.didlLite),
        ])
    }

    /// Loads and immediately plays media.
    public func play(_ item: MediaItem) async throws {
        try await load(item)
        try await play()
    }

    /// Queues the next item for gapless playback (`SetNextAVTransportURI`).
    public func setNext(_ item: MediaItem) async throws {
        _ = try await transport("SetNextAVTransportURI", [
            ("InstanceID", instanceID),
            ("NextURI", item.url.absoluteString),
            ("NextURIMetaData", item.didlLite),
        ])
    }

    public func play(speed: String = "1") async throws {
        _ = try await transport("Play", [("InstanceID", instanceID), ("Speed", speed)])
    }

    public func pause() async throws {
        _ = try await transport("Pause", [("InstanceID", instanceID)])
    }

    public func stop() async throws {
        _ = try await transport("Stop", [("InstanceID", instanceID)])
    }

    public func next() async throws {
        _ = try await transport("Next", [("InstanceID", instanceID)])
    }

    public func previous() async throws {
        _ = try await transport("Previous", [("InstanceID", instanceID)])
    }

    /// Seeks to an absolute position.
    public func seek(to seconds: TimeInterval) async throws {
        _ = try await transport("Seek", [("InstanceID", instanceID), ("Unit", "REL_TIME"), ("Target", UPnPTime.format(seconds))])
    }

    public func transportInfo() async throws -> TransportInfo {
        let output = try await transport("GetTransportInfo", [("InstanceID", instanceID)])
        return TransportInfo(
            state: TransportState(output["CurrentTransportState"] ?? ""),
            status: output["CurrentTransportStatus"] ?? "",
            speed: output["CurrentSpeed"] ?? "1"
        )
    }

    public func positionInfo() async throws -> PositionInfo {
        let output = try await transport("GetPositionInfo", [("InstanceID", instanceID)])
        return PositionInfo(
            track: output["Track"].flatMap { Int($0) },
            duration: output["TrackDuration"].flatMap(UPnPTime.parse),
            position: output["RelTime"].flatMap(UPnPTime.parse) ?? output["AbsTime"].flatMap(UPnPTime.parse),
            trackURI: output["TrackURI"]?.nilIfEmpty,
            trackMetadata: output["TrackMetaData"]?.nilIfEmpty
        )
    }

    /// Fetches transport, position and (if available) volume in parallel.
    public func status() async throws -> RendererStatus {
        async let transport = transportInfo()
        async let position = positionInfo()
        async let volume = try? volume()
        async let muted = try? isMuted()
        return try await RendererStatus(transport: transport, position: position, volume: volume, isMuted: muted)
    }

    /// Polls ``status()`` at `interval` until the consuming task is cancelled.
    public func statusUpdates(every interval: Duration = .seconds(1)) -> AsyncThrowingStream<RendererStatus, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var previous: RendererStatus?
                var failures = 0
                while !Task.isCancelled {
                    do {
                        let current = try await status()
                        failures = 0
                        if current != previous { continuation.yield(current) }
                        previous = current
                    } catch {
                        failures += 1
                        if failures >= 3 {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - RenderingControl

    /// Volume 0–100.
    public func volume() async throws -> Int {
        let output = try await rendering("GetVolume", [("InstanceID", instanceID), ("Channel", "Master")])
        guard let value = output["CurrentVolume"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            throw UPnPError.invalidResponse("Missing CurrentVolume")
        }
        return value
    }

    public func setVolume(_ volume: Int) async throws {
        _ = try await rendering("SetVolume", [("InstanceID", instanceID), ("Channel", "Master"), ("DesiredVolume", String(min(100, max(0, volume))))])
    }

    public func isMuted() async throws -> Bool {
        let output = try await rendering("GetMute", [("InstanceID", instanceID), ("Channel", "Master")])
        let value = output["CurrentMute"]?.trimmingCharacters(in: .whitespaces).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public func setMuted(_ muted: Bool) async throws {
        _ = try await rendering("SetMute", [("InstanceID", instanceID), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")])
    }

    // MARK: - ConnectionManager

    /// The renderer's supported formats (`Sink` protocol infos).
    public func supportedProtocols() async throws -> [String] {
        guard let connectionManager else { throw UPnPError.serviceNotFound(UPnPServiceType.connectionManager) }
        let output = try await soap.invoke("GetProtocolInfo", on: connectionManager, orderedArguments: [])
        return (output["Sink"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the renderer advertises support for a MIME type.
    /// Returns `true` when the renderer does not report its formats.
    public func supports(mimeType: String) async -> Bool {
        guard let protocols = try? await supportedProtocols(), !protocols.isEmpty else { return true }
        let wanted = mimeType.lowercased()
        return protocols.contains { info in
            let fields = info.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return false }
            let mime = fields[2].lowercased()
            return mime == wanted || mime == "*" || (mime.hasSuffix("/*") && wanted.hasPrefix(mime.dropLast()))
        }
    }

    // MARK: - Private

    private func transport(_ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        try await soap.invoke(action, on: avTransport, orderedArguments: arguments)
    }

    private func rendering(_ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        guard let renderingControl else { throw UPnPError.serviceNotFound(UPnPServiceType.renderingControl) }
        return try await soap.invoke(action, on: renderingControl, orderedArguments: arguments)
    }
}
