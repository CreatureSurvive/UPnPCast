import Foundation

/// Invokes UPnP actions over SOAP.
public struct SOAPClient: Sendable {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    /// Invokes `action` on `service` with ordered arguments and returns the
    /// output arguments. UPnP faults are thrown as ``UPnPError/actionFailed(code:description:)``.
    public func invoke(_ action: String, on service: UPnPService, arguments: KeyValuePairs<String, String> = [:]) async throws -> [String: String] {
        try await invoke(action, on: service, orderedArguments: arguments.map { ($0.key, $0.value) })
    }

    public func invoke(_ action: String, on service: UPnPService, orderedArguments: [(String, String)]) async throws -> [String: String] {
        var request = URLRequest(url: service.controlURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.setValue("UPnPCast/1.0 UPnP/1.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.envelope(action: action, serviceType: service.serviceType, arguments: orderedArguments).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UPnPError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 500, let fault = Self.fault(in: data) { throw fault }
        guard (200...299).contains(status) else { throw UPnPError.httpStatus(status) }
        return try Self.outputArguments(in: data, action: action)
    }

    static func envelope(action: String, serviceType: String, arguments: [(String, String)]) -> String {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        body += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        body += "<s:Body><u:\(action) xmlns:u=\"\(xmlEscape(serviceType))\">"
        for (name, value) in arguments {
            body += "<\(name)>\(xmlEscape(value))</\(name)>"
        }
        body += "</u:\(action)></s:Body></s:Envelope>"
        return body
    }

    static func fault(in data: Data) -> UPnPError? {
        guard let root = try? XMLTree.parse(data), let upnpError = root.descendant("UPnPError") else { return nil }
        let code = upnpError.child("errorCode")?.text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let description = upnpError.child("errorDescription")?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? UPnPErrorCode.description(for: code)
        return .actionFailed(code: code, description: description)
    }

    static func outputArguments(in data: Data, action: String) throws -> [String: String] {
        let root = try XMLTree.parse(data)
        guard let response = root.descendant(action + "Response") else {
            if let fault = fault(in: data) { throw fault }
            throw UPnPError.invalidResponse("Missing \(action)Response")
        }
        var result: [String: String] = [:]
        for child in response.children {
            result[child.name] = child.text ?? ""
        }
        return result
    }
}

/// Descriptions for common UPnP/AVTransport error codes.
public enum UPnPErrorCode {
    public static func description(for code: Int) -> String {
        switch code {
        case 401: "Invalid action"
        case 402: "Invalid arguments"
        case 501: "Action failed"
        case 701: "Transition not available"
        case 702: "No contents"
        case 704: "Playing not supported"
        case 710: "Seek mode not supported"
        case 711: "Illegal seek target"
        case 714: "Illegal MIME type"
        case 716: "Resource not found"
        case 718: "Invalid instance ID"
        default: "Error \(code)"
        }
    }
}

/// Escapes text for XML element content and attribute values.
public func xmlEscape(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": output += "&amp;"
        case "<": output += "&lt;"
        case ">": output += "&gt;"
        case "\"": output += "&quot;"
        case "'": output += "&apos;"
        default:
            // Drop characters that are illegal in XML 1.0.
            let value = scalar.value
            if value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value) {
                output.unicodeScalars.append(scalar)
            }
        }
    }
    return output
}
