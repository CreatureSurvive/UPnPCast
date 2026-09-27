import Foundation
import Network
import os

/// An in-process DLNA MediaRenderer: serves a device description and answers SOAP actions.
final class MockRenderer: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var soapAction: String?
        var body: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockRenderer")
    private let state = OSAllocatedUnfairLock(initialState: (requests: [Request](), volume: 30, muted: false, transport: "NO_MEDIA_PRESENT", uri: ""))
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var descriptionURL: URL { URL(string: "http://127.0.0.1:\(port)/desc.xml")! }
    var requests: [Request] { state.withLock { $0.requests } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self!.queue)
                self?.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                var headers: [String: String] = [:]
                for line in head.components(separatedBy: "\r\n").dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    self.respond(path: path, soapAction: headers["soapaction"], body: String(decoding: body.prefix(length), as: UTF8.self), on: connection)
                    return
                }
            }
            if complete || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(path: String, soapAction: String?, body: String, on connection: NWConnection) {
        state.withLock { $0.requests.append(Request(path: path, soapAction: soapAction, body: body)) }
        if path == "/desc.xml" {
            send(200, Self.description, on: connection)
            return
        }
        let action = soapAction?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).components(separatedBy: "#").last ?? ""
        let service = soapAction?.contains("RenderingControl") == true ? "RenderingControl" : soapAction?.contains("ConnectionManager") == true ? "ConnectionManager" : "AVTransport"
        @Sendable func value(_ tag: String) -> String? {
            guard let start = body.range(of: "<\(tag)>"), let end = body.range(of: "</\(tag)>", range: start.upperBound..<body.endIndex) else { return nil }
            return String(body[start.upperBound..<end.lowerBound])
        }
        var output: [(String, String)] = []
        switch action {
        case "SetAVTransportURI":
            state.withLock { $0.transport = "STOPPED"; $0.uri = value("CurrentURI") ?? "" }
        case "Play":
            let hasMedia = state.withLock { $0.transport != "NO_MEDIA_PRESENT" }
            guard hasMedia else {
                send(500, Self.fault(701, "Transition not available"), on: connection)
                return
            }
            state.withLock { $0.transport = "PLAYING" }
        case "Pause": state.withLock { $0.transport = "PAUSED_PLAYBACK" }
        case "Stop": state.withLock { $0.transport = "STOPPED" }
        case "Seek":
            if value("Target") == "99:00:00" {
                send(500, Self.fault(711, "Illegal seek target"), on: connection)
                return
            }
        case "GetTransportInfo":
            output = [("CurrentTransportState", state.withLock { $0.transport }), ("CurrentTransportStatus", "OK"), ("CurrentSpeed", "1")]
        case "GetPositionInfo":
            output = [("Track", "1"), ("TrackDuration", "0:10:00.500"), ("TrackMetaData", ""), ("TrackURI", state.withLock { $0.uri }), ("RelTime", "0:01:05"), ("AbsTime", "NOT_IMPLEMENTED")]
        case "GetVolume": output = [("CurrentVolume", String(state.withLock { $0.volume }))]
        case "SetVolume": state.withLock { $0.volume = Int(value("DesiredVolume") ?? "0") ?? 0 }
        case "GetMute": output = [("CurrentMute", state.withLock { $0.muted } ? "1" : "0")]
        case "SetMute": state.withLock { $0.muted = value("DesiredMute") == "1" }
        case "GetProtocolInfo":
            output = [("Source", ""), ("Sink", "http-get:*:video/mp4:*,http-get:*:audio/*:*,http-get:*:video/x-matroska:DLNA.ORG_PN=MKV")]
        default:
            send(500, Self.fault(401, "Invalid Action"), on: connection)
            return
        }
        var xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
        xml += "<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">"
        for (key, value) in output { xml += "<\(key)>\(value)</\(key)>" }
        xml += "</u:\(action)Response></s:Body></s:Envelope>"
        send(200, xml, on: connection)
    }

    private func send(_ status: Int, _ body: String, on connection: NWConnection) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Internal Server Error")\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func fault(_ code: Int, _ description: String) -> String {
        """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode><errorDescription>\(description)</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
    }

    static let description = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>[TV] Living Room</friendlyName>
        <manufacturer>Samsung Electronics</manufacturer>
        <modelName>UE55</modelName>
        <UDN>uuid:11111111-2222-3333-4444-555555555555</UDN>
        <iconList>
          <icon><mimetype>image/png</mimetype><width>48</width><height>48</height><depth>24</depth><url>/icon48.png</url></icon>
          <icon><mimetype>image/png</mimetype><width>120</width><height>120</height><depth>24</depth><url>/icon120.png</url></icon>
        </iconList>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
            <controlURL>/upnp/control/RenderingControl1</controlURL>
            <eventSubURL>/upnp/event/RenderingControl1</eventSubURL>
            <SCPDURL>/RenderingControl_1.xml</SCPDURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
            <controlURL>upnp/control/ConnectionManager1</controlURL>
            <eventSubURL>/upnp/event/ConnectionManager1</eventSubURL>
            <SCPDURL>/ConnectionManager_1.xml</SCPDURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
            <controlURL>/upnp/control/AVTransport1</controlURL>
            <eventSubURL>/upnp/event/AVTransport1</eventSubURL>
            <SCPDURL>/AVTransport_1.xml</SCPDURL>
          </service>
        </serviceList>
      </device>
    </root>
    """
}
