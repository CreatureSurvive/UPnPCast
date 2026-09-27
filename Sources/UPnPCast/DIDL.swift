import Foundation

/// Metadata describing media for a DLNA renderer, serialized as DIDL-Lite.
public struct MediaItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case video = "object.item.videoItem"
        case movie = "object.item.videoItem.movie"
        case episode = "object.item.videoItem.videoBroadcast"
        case music = "object.item.audioItem.musicTrack"
        case audio = "object.item.audioItem"
        case photo = "object.item.imageItem.photo"
    }

    /// An external subtitle file.
    public struct Subtitle: Sendable, Hashable {
        public var url: URL
        /// File type such as `srt`, `vtt`, `smi`.
        public var format: String
        public var language: String?

        public init(url: URL, format: String = "srt", language: String? = nil) {
            self.url = url
            self.format = format
            self.language = language
        }
    }

    public var url: URL
    /// MIME type, e.g. `video/mp4`.
    public var mimeType: String
    public var title: String
    public var kind: Kind
    public var artist: String?
    public var album: String?
    /// Poster or album art.
    public var artworkURL: URL?
    /// Duration in seconds, if known.
    public var duration: TimeInterval?
    public var size: Int64?
    /// e.g. `1920x1080`.
    public var resolution: String?
    public var subtitles: [Subtitle]
    /// The DLNA fourth field of `protocolInfo`. The default allows seeking by
    /// byte range and streaming transfer, which most renderers require.
    public var dlnaFlags: String

    public init(
        url: URL,
        mimeType: String,
        title: String,
        kind: Kind = .video,
        artist: String? = nil,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        size: Int64? = nil,
        resolution: String? = nil,
        subtitles: [Subtitle] = [],
        dlnaFlags: String = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
    ) {
        self.url = url
        self.mimeType = mimeType
        self.title = title
        self.kind = kind
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.size = size
        self.resolution = resolution
        self.subtitles = subtitles
        self.dlnaFlags = dlnaFlags
    }

    /// `http-get:*:<mime>:<dlna flags>`.
    public var protocolInfo: String { "http-get:*:\(mimeType):\(dlnaFlags)" }

    /// DIDL-Lite XML for `CurrentURIMetaData`.
    public var didlLite: String {
        var xml = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
        xml += " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
        xml += " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
        xml += " xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\""
        xml += " xmlns:sec=\"http://www.sec.co.kr/\">"
        xml += "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
        xml += "<dc:title>\(xmlEscape(title))</dc:title>"
        xml += "<upnp:class>\(kind.rawValue)</upnp:class>"
        if let artist { xml += "<upnp:artist>\(xmlEscape(artist))</upnp:artist><dc:creator>\(xmlEscape(artist))</dc:creator>" }
        if let album { xml += "<upnp:album>\(xmlEscape(album))</upnp:album>" }
        if let artworkURL { xml += "<upnp:albumArtURI>\(xmlEscape(artworkURL.absoluteString))</upnp:albumArtURI>" }
        for subtitle in subtitles {
            // Samsung's convention, also honored by several other renderers.
            xml += "<sec:CaptionInfoEx sec:type=\"\(xmlEscape(subtitle.format))\">\(xmlEscape(subtitle.url.absoluteString))</sec:CaptionInfoEx>"
        }
        var resAttributes = " protocolInfo=\"\(xmlEscape(protocolInfo))\""
        if let duration { resAttributes += " duration=\"\(UPnPTime.format(duration, fractional: true))\"" }
        if let size { resAttributes += " size=\"\(size)\"" }
        if let resolution { resAttributes += " resolution=\"\(xmlEscape(resolution))\"" }
        xml += "<res\(resAttributes)>\(xmlEscape(url.absoluteString))</res>"
        for subtitle in subtitles {
            let mime = subtitle.format == "vtt" ? "text/vtt" : "text/srt"
            xml += "<res protocolInfo=\"http-get:*:\(mime):*\">\(xmlEscape(subtitle.url.absoluteString))</res>"
        }
        xml += "</item></DIDL-Lite>"
        return xml
    }
}

/// UPnP `H+:MM:SS[.F+]` time values.
public enum UPnPTime {
    /// Formats seconds as `H:MM:SS` (or `H:MM:SS.mmm`).
    public static func format(_ seconds: TimeInterval, fractional: Bool = false) -> String {
        // Clamp to 999,999 hours so absurd values cannot overflow Int.
        let clamped = min(3_599_999_999, max(0, seconds.isFinite ? seconds : 0))
        let whole = Int(clamped)
        let base = String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
        guard fractional else { return base }
        let milliseconds = Int(((clamped - Double(whole)) * 1000).rounded())
        return base + String(format: ".%03d", min(999, milliseconds))
    }

    /// Parses `H+:MM:SS[.F+]` or `H+:MM:SS[.F0/F1]`. Returns `nil` for
    /// `NOT_IMPLEMENTED` and malformed values.
    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "NOT_IMPLEMENTED" else { return nil }
        var sign = 1.0
        var body = Substring(trimmed)
        if body.first == "-" || body.first == "+" {
            sign = body.first == "-" ? -1 : 1
            body = body.dropFirst()
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
        var secondsText = parts[2]
        var fraction = 0.0
        if let dot = secondsText.firstIndex(of: ".") {
            let fractionText = secondsText[secondsText.index(after: dot)...]
            if let slash = fractionText.firstIndex(of: "/") {
                if let numerator = Double(fractionText[..<slash]), let denominator = Double(fractionText[fractionText.index(after: slash)...]), denominator > 0 {
                    fraction = numerator / denominator
                }
            } else {
                fraction = Double("0." + fractionText) ?? 0
            }
            secondsText = secondsText[..<dot]
        }
        guard let seconds = Double(secondsText) else { return nil }
        return sign * (hours * 3600 + minutes * 60 + seconds + fraction)
    }
}
