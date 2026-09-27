import Foundation
import Testing
@testable import UPnPCast

@Suite("SSDP")
struct SSDPTests {
    @Test func parsesSearchResponses() throws {
        let message = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.20:9197/dmr\r\nSERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\nEXT:\r\n\r\n"
        let response = try #require(SSDPResponse(message: message, sourceAddress: "192.168.1.20"))
        #expect(response.location == URL(string: "http://192.168.1.20:9197/dmr"))
        #expect(response.searchTarget == SSDP.SearchTarget.mediaRenderer)
        #expect(response.uuid == "uuid:abc-123")
        #expect(response.server?.contains("Samsung") == true)
        #expect(response.headers["cache-control"] == "max-age=1800")
    }

    @Test func parsesNotifyAndIgnoresByeBye() {
        let alive = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: upnp:rootdevice\r\nNTS: ssdp:alive\r\nLOCATION: http://10.0.0.2/d.xml\r\nUSN: uuid:x::upnp:rootdevice\r\n\r\n"
        #expect(SSDPResponse(message: alive, sourceAddress: "10.0.0.2")?.searchTarget == "upnp:rootdevice")
        let bye = alive.replacingOccurrences(of: "ssdp:alive", with: "ssdp:byebye")
        #expect(SSDPResponse(message: bye, sourceAddress: "10.0.0.2") == nil)
        #expect(SSDPResponse(message: "M-SEARCH * HTTP/1.1\r\n\r\n", sourceAddress: "x") == nil)
        #expect(SSDPResponse(message: "HTTP/1.1 200 OK\r\nST: x\r\n\r\n", sourceAddress: "x") == nil) // no location
    }

    @Test func buildsSearchMessage() {
        let message = SSDP.searchMessage(target: "ssdp:all", maxWait: 9)
        #expect(message.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        #expect(message.contains("MAN: \"ssdp:discover\"\r\n"))
        #expect(message.contains("MX: 5\r\n"))
        #expect(message.hasSuffix("\r\n\r\n"))
    }

    /// Discovers real devices on the local network. Run with `UPNP_LIVE_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UPNP_LIVE_TESTS"] == "1"))
    func discoversLiveDevices() async throws {
        let responses = try await SSDP.discover(target: SSDP.SearchTarget.rootDevice, duration: .seconds(3))
        #expect(!responses.isEmpty)
        for location in Set(responses.map(\.location)) {
            let device = try await UPnPDevice.load(from: location)
            print("Found \(device.friendlyName) [\(device.deviceType)] services=\(device.allDevices.flatMap(\.services).count)")
            #expect(!device.udn.isEmpty)
        }
    }
}

@Suite("Device descriptions")
struct DeviceDescriptionTests {
    @Test func parsesAndResolvesURLs() throws {
        let url = URL(string: "http://10.0.0.5:9197/dmr")!
        let device = try UPnPDevice.parse(Data(MockRenderer.description.utf8), descriptionURL: url)
        #expect(device.friendlyName == "[TV] Living Room")
        #expect(device.manufacturer == "Samsung Electronics")
        #expect(device.udn == "uuid:11111111-2222-3333-4444-555555555555")
        #expect(device.isMediaRenderer)
        #expect(device.services.count == 3)
        #expect(device.service(ofType: UPnPServiceType.avTransport)?.controlURL == URL(string: "http://10.0.0.5:9197/upnp/control/AVTransport1"))
        // Relative control URL without a leading slash resolves against the description URL.
        #expect(device.service(ofType: "urn:schemas-upnp-org:service:ConnectionManager:2")?.controlURL == URL(string: "http://10.0.0.5:9197/upnp/control/ConnectionManager1"))
        #expect(device.bestIcon?.url == URL(string: "http://10.0.0.5:9197/icon120.png"))
    }

    @Test func honorsURLBaseAndEmbeddedDevices() throws {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <URLBase>http://192.168.1.9:1400/</URLBase>
          <device>
            <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
            <friendlyName>Kitchen</friendlyName>
            <UDN>uuid:RINCON_1</UDN>
            <deviceList>
              <device>
                <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
                <friendlyName>Kitchen - Renderer</friendlyName>
                <UDN>uuid:RINCON_1_MR</UDN>
                <serviceList><service>
                  <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                  <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
                  <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
                  <eventSubURL>/MediaRenderer/AVTransport/Event</eventSubURL>
                  <SCPDURL>/xml/AVTransport1.xml</SCPDURL>
                </service></serviceList>
              </device>
            </deviceList>
          </device>
        </root>
        """
        let device = try UPnPDevice.parse(Data(xml.utf8), descriptionURL: URL(string: "http://192.168.1.9:1400/xml/device_description.xml")!)
        #expect(device.allDevices.count == 2)
        #expect(device.isMediaRenderer)
        let renderer = try MediaRenderer(device: device)
        #expect(renderer.avTransport.controlURL == URL(string: "http://192.168.1.9:1400/MediaRenderer/AVTransport/Control"))
        #expect(renderer.renderingControl == nil)
    }

    @Test func rejectsInvalidDocuments() {
        #expect(throws: UPnPError.self) { try UPnPDevice.parse(Data("<root><nodevice/></root>".utf8), descriptionURL: URL(string: "http://x")!) }
        #expect(throws: UPnPError.self) { try UPnPDevice.parse(Data("not xml".utf8), descriptionURL: URL(string: "http://x")!) }
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func formatsAndParsesTimes() {
        #expect(UPnPTime.format(3725) == "1:02:05")
        #expect(UPnPTime.format(59.25, fractional: true) == "0:00:59.250")
        #expect(UPnPTime.format(-5) == "0:00:00")
        #expect(UPnPTime.parse("1:02:05") == 3725)
        #expect(UPnPTime.parse("00:00:10.5") == 10.5)
        #expect(UPnPTime.parse("0:00:01.1/4") == 1.25)
        #expect(UPnPTime.parse("NOT_IMPLEMENTED") == nil)
        #expect(UPnPTime.parse("garbage") == nil)
    }

    @Test func buildsDIDLLite() throws {
        let item = MediaItem(
            url: URL(string: "http://server/video.mp4?a=1&b=2")!,
            mimeType: "video/mp4",
            title: "Tom & Jerry <Special>",
            kind: .movie,
            artworkURL: URL(string: "http://server/poster.jpg"),
            duration: 5400,
            size: 123456,
            subtitles: [.init(url: URL(string: "http://server/en.srt")!, format: "srt", language: "en")]
        )
        let didl = item.didlLite
        #expect(didl.contains("<dc:title>Tom &amp; Jerry &lt;Special&gt;</dc:title>"))
        #expect(didl.contains("http://server/video.mp4?a=1&amp;b=2"))
        #expect(didl.contains("duration=\"1:30:00.000\""))
        #expect(didl.contains("<upnp:class>object.item.videoItem.movie</upnp:class>"))
        #expect(didl.contains("sec:CaptionInfoEx sec:type=\"srt\""))
        // Must be well-formed XML.
        let parser = XMLParser(data: Data(didl.utf8))
        #expect(parser.parse())
    }

    @Test func escapesXMLAndStripsIllegalCharacters() {
        #expect(xmlEscape("a<b>&\"'\u{0}\u{1}c") == "a&lt;b&gt;&amp;&quot;&apos;c")
    }

    @Test func soapEnvelopeIsWellFormedAndEscaped() {
        let envelope = SOAPClient.envelope(action: "SetAVTransportURI", serviceType: UPnPServiceType.avTransport, arguments: [("InstanceID", "0"), ("CurrentURIMetaData", "<DIDL-Lite>&</DIDL-Lite>")])
        #expect(envelope.contains("<CurrentURIMetaData>&lt;DIDL-Lite&gt;&amp;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>"))
        #expect(XMLParser(data: Data(envelope.utf8)).parse())
    }
}

@Suite("MediaRenderer", .timeLimit(.minutes(1)))
struct MediaRendererTests {
    func connect() async throws -> (MediaRenderer, MockRenderer) {
        let mock = try MockRenderer()
        try await mock.start()
        let renderer = try await MediaRenderer.connect(descriptionURL: mock.descriptionURL)
        return (renderer, mock)
    }

    @Test func loadsAndControlsPlayback() async throws {
        let (renderer, mock) = try await connect()
        defer { mock.stop() }
        #expect(renderer.name == "[TV] Living Room")
        #expect(try await renderer.transportInfo().state == .noMediaPresent)

        let item = MediaItem(url: URL(string: "http://server/v.mp4")!, mimeType: "video/mp4", title: "Movie & Friends")
        try await renderer.play(item)
        #expect(try await renderer.transportInfo().state == .playing)

        let set = try #require(mock.requests.first { $0.soapAction?.contains("#SetAVTransportURI") == true })
        #expect(set.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        #expect(set.path == "/upnp/control/AVTransport1")
        #expect(set.body.contains("<CurrentURI>http://server/v.mp4</CurrentURI>"))
        // DIDL is escaped once inside the SOAP body; its own escaping is preserved.
        #expect(set.body.contains("&lt;dc:title&gt;Movie &amp;amp; Friends&lt;/dc:title&gt;"))

        try await renderer.pause()
        #expect(try await renderer.transportInfo().state == .paused)
        try await renderer.seek(to: 65)
        #expect(mock.requests.last?.body.contains("<Target>0:01:05</Target>") == true)
        try await renderer.stop()
        #expect(try await renderer.transportInfo().state == .stopped)
    }

    @Test func reportsPositionAndVolume() async throws {
        let (renderer, mock) = try await connect()
        defer { mock.stop() }
        let position = try await renderer.positionInfo()
        #expect(position.duration == 600.5)
        #expect(position.position == 65)
        #expect(position.track == 1)

        #expect(try await renderer.volume() == 30)
        try await renderer.setVolume(150) // clamped
        #expect(try await renderer.volume() == 100)
        try await renderer.setMuted(true)
        #expect(try await renderer.isMuted())

        let status = try await renderer.status()
        #expect(status.volume == 100)
        #expect(status.isMuted == true)
    }

    @Test func surfacesUPnPFaults() async throws {
        let (renderer, mock) = try await connect()
        defer { mock.stop() }
        await #expect(throws: UPnPError.actionFailed(code: 701, description: "Transition not available")) {
            try await renderer.play()
        }
        await #expect(throws: UPnPError.actionFailed(code: 711, description: "Illegal seek target")) {
            try await renderer.seek(to: 99 * 3600)
        }
    }

    @Test func checksSupportedFormats() async throws {
        let (renderer, mock) = try await connect()
        defer { mock.stop() }
        #expect(try await renderer.supportedProtocols().count == 3)
        #expect(await renderer.supports(mimeType: "video/mp4"))
        #expect(await renderer.supports(mimeType: "audio/flac"))
        #expect(await renderer.supports(mimeType: "video/x-matroska"))
        #expect(await !renderer.supports(mimeType: "video/webm"))
    }

    @Test func streamsStatusUpdates() async throws {
        let (renderer, mock) = try await connect()
        defer { mock.stop() }
        try await renderer.load(MediaItem(url: URL(string: "http://server/v.mp4")!, mimeType: "video/mp4", title: "x"))
        var iterator = renderer.statusUpdates(every: .milliseconds(50)).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.transport.state == .stopped)
        try await renderer.play()
        var sawPlaying = false
        while let status = try await iterator.next() {
            if status.transport.state == .playing { sawPlaying = true; break }
        }
        #expect(sawPlaying)
    }

    @Test func rejectsDevicesWithoutAVTransport() throws {
        let xml = "<root><device><deviceType>urn:x:device:Other:1</deviceType><friendlyName>X</friendlyName><UDN>uuid:x</UDN></device></root>"
        let device = try UPnPDevice.parse(Data(xml.utf8), descriptionURL: URL(string: "http://x")!)
        #expect(throws: UPnPError.serviceNotFound(UPnPServiceType.avTransport)) { try MediaRenderer(device: device) }
    }
}
