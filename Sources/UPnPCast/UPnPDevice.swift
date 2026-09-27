import Foundation

/// Errors produced by UPnPCast.
public enum UPnPError: Error, Sendable, Equatable, LocalizedError {
    case network(String)
    case httpStatus(Int)
    case invalidXML(String)
    /// A UPnP SOAP fault, e.g. `(701, "Transition not available")`.
    case actionFailed(code: Int, description: String)
    case serviceNotFound(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .network(let message): "Network error: \(message)"
        case .httpStatus(let code): "The device responded with HTTP \(code)."
        case .invalidXML(let message): "Invalid XML: \(message)"
        case .actionFailed(let code, let description): "The device rejected the action (\(code)): \(description)"
        case .serviceNotFound(let type): "The device does not provide \(type)."
        case .invalidResponse(let message): "Invalid response: \(message)"
        }
    }
}

/// A service advertised by a UPnP device.
public struct UPnPService: Sendable, Hashable {
    public var serviceType: String
    public var serviceID: String
    /// Absolute URLs.
    public var controlURL: URL
    public var eventSubscriptionURL: URL?
    public var descriptionURL: URL?

    /// The service type without its version, e.g. `urn:schemas-upnp-org:service:AVTransport`.
    public var unversionedType: String {
        guard let colon = serviceType.lastIndex(of: ":"), Int(serviceType[serviceType.index(after: colon)...]) != nil else { return serviceType }
        return String(serviceType[..<colon])
    }
}

/// An icon advertised by a device.
public struct UPnPIcon: Sendable, Hashable {
    public var url: URL
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
}

/// A UPnP device parsed from its description document.
public struct UPnPDevice: Sendable, Hashable, Identifiable {
    /// `UDN`, e.g. `uuid:…`.
    public var udn: String
    public var deviceType: String
    public var friendlyName: String
    public var manufacturer: String?
    public var modelName: String?
    public var modelNumber: String?
    public var serialNumber: String?
    public var presentationURL: URL?
    public var icons: [UPnPIcon]
    public var services: [UPnPService]
    public var embeddedDevices: [UPnPDevice]
    /// Where the description was loaded from.
    public var descriptionURL: URL

    public var id: String { udn }

    /// This device and all embedded devices, depth first.
    public var allDevices: [UPnPDevice] {
        [self] + embeddedDevices.flatMap(\.allDevices)
    }

    /// Finds a service by type (ignoring version) in this device or any embedded device.
    public func service(ofType type: String) -> UPnPService? {
        let wanted = UPnPService(serviceType: type, serviceID: "", controlURL: descriptionURL).unversionedType
        for device in allDevices {
            if let service = device.services.first(where: { $0.unversionedType == wanted }) { return service }
        }
        return nil
    }

    /// Whether this device (or an embedded one) is a DLNA/UPnP media renderer.
    public var isMediaRenderer: Bool {
        allDevices.contains { $0.deviceType.hasPrefix("urn:schemas-upnp-org:device:MediaRenderer") }
            || service(ofType: UPnPServiceType.avTransport) != nil
    }

    /// The largest PNG/JPEG icon, if any.
    public var bestIcon: UPnPIcon? {
        icons.max { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }
    }

    /// Downloads and parses a device description.
    public static func load(from url: URL, session: URLSession = .shared) async throws -> UPnPDevice {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("UPnPCast/1.0 UPnP/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UPnPError.httpStatus(http.statusCode)
        }
        return try parse(data, descriptionURL: url)
    }

    /// Parses a device description document.
    public static func parse(_ data: Data, descriptionURL: URL) throws -> UPnPDevice {
        let root = try XMLTree.parse(data)
        let base = root.child("URLBase")?.text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? descriptionURL
        guard let deviceElement = root.child("device") else { throw UPnPError.invalidXML("Missing <device>") }
        return device(from: deviceElement, base: base, descriptionURL: descriptionURL)
    }

    private static func device(from element: XMLTree.Element, base: URL, descriptionURL: URL) -> UPnPDevice {
        func text(_ name: String) -> String? {
            element.child(name)?.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func resolve(_ value: String?) -> URL? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        let services = element.child("serviceList")?.children(named: "service").compactMap { service -> UPnPService? in
            func serviceText(_ name: String) -> String? { service.child(name)?.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let type = serviceText("serviceType"), let control = resolve(serviceText("controlURL")) else { return nil }
            return UPnPService(
                serviceType: type,
                serviceID: serviceText("serviceId") ?? "",
                controlURL: control,
                eventSubscriptionURL: resolve(serviceText("eventSubURL")),
                descriptionURL: resolve(serviceText("SCPDURL"))
            )
        } ?? []
        let icons = element.child("iconList")?.children(named: "icon").compactMap { icon -> UPnPIcon? in
            guard let url = resolve(icon.child("url")?.text) else { return nil }
            return UPnPIcon(
                url: url,
                mimeType: icon.child("mimetype")?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                width: icon.child("width")?.text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                height: icon.child("height")?.text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            )
        } ?? []
        let embedded = element.child("deviceList")?.children(named: "device").map {
            device(from: $0, base: base, descriptionURL: descriptionURL)
        } ?? []
        return UPnPDevice(
            udn: text("UDN") ?? "",
            deviceType: text("deviceType") ?? "",
            friendlyName: text("friendlyName") ?? descriptionURL.host ?? "Unknown",
            manufacturer: text("manufacturer"),
            modelName: text("modelName"),
            modelNumber: text("modelNumber"),
            serialNumber: text("serialNumber"),
            presentationURL: resolve(text("presentationURL")),
            icons: icons,
            services: services,
            embeddedDevices: embedded,
            descriptionURL: descriptionURL
        )
    }
}

/// Well-known UPnP service types.
public enum UPnPServiceType {
    public static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
    public static let connectionManager = "urn:schemas-upnp-org:service:ConnectionManager:1"
    public static let contentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1"
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Minimal namespace-agnostic XML tree

/// A small DOM built with `XMLParser`. Element names are stored without
/// namespace prefixes so documents from sloppy devices still match.
enum XMLTree {
    final class Element: @unchecked Sendable {
        let name: String
        var attributes: [String: String]
        var children: [Element] = []
        var textParts: [String] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        var text: String? { textParts.isEmpty ? nil : textParts.joined() }

        func child(_ name: String) -> Element? {
            children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        func children(named name: String) -> [Element] {
            children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// Depth-first search for the first element named `name`.
        func descendant(_ name: String) -> Element? {
            if self.name.caseInsensitiveCompare(name) == .orderedSame { return self }
            for child in children {
                if let found = child.descendant(name) { return found }
            }
            return nil
        }
    }

    static func parse(_ data: Data) throws -> Element {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw UPnPError.invalidXML(parser.parserError?.localizedDescription ?? "Empty document")
        }
        return root
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let element = Element(name: local, attributes: attributes)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.textParts.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.textParts.append(String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
