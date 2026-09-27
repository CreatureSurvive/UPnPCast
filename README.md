# UPnPCast

[![CI](https://github.com/CreatureSurvive/UPnPCast/actions/workflows/ci.yml/badge.svg)](https://github.com/CreatureSurvive/UPnPCast/actions/workflows/ci.yml)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20visionOS-blue)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#installation)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

Cast to smart TVs, AV receivers and speakers over **DLNA/UPnP** from Swift. It includes modern
async SSDP discovery, UPnP device descriptions, SOAP actions, and a high-level `MediaRenderer`
controller.

```swift
import UPnPCast

let renderers = try await MediaRenderer.discover()
let tv = renderers.first { $0.name.contains("Living Room") }!

try await tv.play(MediaItem(
    url: streamURL,
    mimeType: "video/mp4",
    title: "Big Buck Bunny",
    duration: 596,
    subtitles: [.init(url: subtitleURL, format: "srt", language: "en")]
))
try await tv.seek(to: 120)
try await tv.setVolume(25)
```

## Why

Most TVs sold in the last decade (Samsung, LG, Sony, Panasonic, Philips) are DLNA
MediaRenderers, as are Kodi, VLC, many AV receivers and Sonos speakers. Media apps like Infuse and
VLC support "Play To" for exactly this reason. Swift has had no maintained way to do it: the
existing libraries are Objective-C or abandoned, and depend on outdated XML and socket stacks.

UPnPCast complements Google Cast libraries such as SwiftCast and AirPlay (`AVRoutePickerView`),
so a media app can reach nearly every screen in the house.

## Features

- **SSDP discovery**: `M-SEARCH` with retransmission, deduplication and `NOTIFY` parsing, streamed
  as an `AsyncThrowingStream`.
- **Device descriptions**: full parsing including embedded devices (Sonos-style), `URLBase`,
  relative URL resolution, icons, and namespace-tolerant parsing for sloppy firmware.
- **SOAP**: invoke any action on any service. UPnP faults are thrown with their code and
  description.
- **`MediaRenderer`**:
  - AVTransport: load, play, pause, stop, seek, next, previous, `SetNextAVTransportURI`, transport
    info, position info
  - RenderingControl: volume and mute
  - ConnectionManager: supported formats, plus `supports(mimeType:)`
  - `status()` fetches transport, position and volume in parallel, and `statusUpdates()` polls
    changes as an async stream
- **DIDL-Lite metadata** with correct double escaping, DLNA `protocolInfo` flags that renderers
  accept for seekable streams, artwork, duration and size. External subtitles are included using
  both `sec:CaptionInfoEx` (Samsung and others) and extra `<res>` entries.
- **`UPnPTime`** parsing and formatting, including fractional (`F0/F1`) forms and `NOT_IMPLEMENTED`.
- Swift 6 strict concurrency; everything is `Sendable`.

## Installation

Add UPnPCast to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CreatureSurvive/UPnPCast.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["UPnPCast"]),
]
```

Or in Xcode, choose **File › Add Package Dependencies…** and enter
`https://github.com/CreatureSurvive/UPnPCast`.

### Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| visionOS | 1.0 |

Swift 6.0 (Xcode 16) or later, in Swift 6 language mode. No third-party dependencies.

### Entitlements (iOS, tvOS, visionOS)

SSDP uses UDP multicast, which Apple gates behind an entitlement:

1. Request **com.apple.developer.networking.multicast** from Apple
   ([form](https://developer.apple.com/contact/request/networking-multicast)) and add it to your
   entitlements.
2. Add `NSLocalNetworkUsageDescription` to Info.plist.

You can skip discovery by connecting to a known renderer with
`MediaRenderer.connect(descriptionURL:)`, which only needs local network permission. macOS needs no
entitlement.

## Usage

### Discovery

```swift
// Media renderers, ready to control
let renderers = try await MediaRenderer.discover(duration: .seconds(3))

// Anything UPnP
for try await response in SSDP.search(target: SSDP.SearchTarget.all) {
    let device = try await UPnPDevice.load(from: response.location)
    print(device.friendlyName, device.deviceType)
}
```

### Playback and status

```swift
try await tv.load(item)          // SetAVTransportURI
try await tv.play()
try await tv.pause()
try await tv.setNext(nextItem)   // gapless, where supported

for try await status in tv.statusUpdates(every: .seconds(1)) {
    print(status.transport.state, status.position.position ?? 0, status.position.duration ?? 0)
}
```

### Format negotiation

```swift
if await tv.supports(mimeType: "video/x-matroska") {
    // direct play
} else {
    // ask your server (Jellyfin, Plex, …) for an MP4/HLS transcode
}
```

### Raw SOAP

```swift
let service = device.service(ofType: UPnPServiceType.avTransport)!
let output = try await SOAPClient().invoke("GetMediaInfo", on: service, arguments: ["InstanceID": "0"])
print(output["NrTracks"], output["CurrentURI"])
```

## Tips for media servers

- Serve media over plain HTTP on the LAN. Many renderers reject HTTPS and self-signed
  certificates.
- Put auth tokens in the URL query (for example Jellyfin's `api_key`). Renderers can't send custom
  headers.
- Support HTTP `Range` requests. Renderers seek with byte ranges.

## Testing

`swift test` runs parsing, formatting and escaping tests, plus end-to-end `MediaRenderer` tests
against an in-process mock renderer that serves a real description document and SOAP responses,
including faults. `UPNP_LIVE_TESTS=1 swift test` also discovers and describes the real UPnP devices
on your network.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Releases follow [Semantic Versioning](https://semver.org).

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request, and
add tests for new behavior.

## License

Available under the MIT license. See [LICENSE](LICENSE) for details.
