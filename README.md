# Pairwise

A fast, fully peer-to-peer pair-programming app for macOS — a Tuple clone with
no servers, no accounts, and no cloud. You add a peer by IP address and media
flows directly between the two machines.

## Features

- **Menu bar app** — lives in the status bar, no Dock icon.
- **Direct P2P calls** — add a peer's IP, hit Call; they get a ring panel with
  Accept / Decline. Signaling runs over TCP (port 47800), media over UDP
  (port 47801). Nothing ever touches a third-party server.
- **Floating video window** — a small always-on-top square showing the peer's
  camera. Hover over the video and it turns translucent and click-through, so
  it never blocks your work; drag it by its top bar. Toggle camera and mic
  from the menu bar.
- **Low-latency screen sharing** — ScreenCaptureKit capture → hardware H.264
  (VideoToolbox low-latency rate control, up to 60 fps, native resolution) →
  UDP → hardware decode. No retransmission delays: lost frames trigger an
  instant keyframe request instead of stalling the stream.
- **Annotations** — the viewer click-drags on your shared screen to draw;
  strokes appear live on the sharer's actual screen (excluded from capture so
  they don't echo) and fade after a few seconds.
- **Voice** — Opus at 48 kHz with Apple's voice processing (echo cancellation
  + noise suppression), 20 ms frames.

## Build & run

```sh
./build.sh
open build/Pairwise.app
```

Requires macOS 14+. On first use macOS will prompt for microphone, camera,
and (when you share) screen-recording permission.

`build.sh` signs with your "Developer ID Application" certificate if one is in
the keychain (hardened runtime, notarization-ready); otherwise it falls back
to ad-hoc signing for local development.

## Releasing an update

Updates ship via [Sparkle](https://sparkle-project.org): the app checks
`appcast.xml` on the `main` branch and downloads the zip from the matching
GitHub release.

```sh
./release.sh 1.1
```

This builds, signs, notarizes, staples, zips, EdDSA-signs the update, adds an
appcast entry, creates the GitHub release, and pushes. One-time setup:

1. A "Developer ID Application" certificate in the keychain
   (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
2. Notarization credentials:
   `xcrun notarytool store-credentials pairwise-notary --apple-id <apple-id> --team-id <team-id>`
   (create an app-specific password at appleid.apple.com).
3. The Sparkle EdDSA private key in the login keychain
   (`.build/artifacts/sparkle/Sparkle/bin/generate_keys`, already done on this machine).

## Using it

1. Both people run Pairwise on the same network (or with UDP/TCP ports 47800
   + 47801 reachable, e.g. via Tailscale or port forwarding).
2. Find your IP (for Tailscale: `tailscale ip -4`) and tell it to your pair.
3. **Add Peer…** → enter their name and IP.
4. **Call `<name>`** — they accept, and audio + your camera start immediately.
5. **Share My Screen** from the menu; their viewer window opens automatically.
   They can draw on it any time; you'll see the strokes on your screen.

Currently IPv4 only. Works great over Tailscale for pairing across networks.

## Architecture

| Piece | Technology |
|---|---|
| Signaling / control | `Network.framework` TCP, length-prefixed JSON |
| Media transport | Raw BSD UDP socket, custom fragmentation (1200-byte MTU), keyframe-request loss recovery |
| Video encode | VideoToolbox H.264, low-latency rate control, real-time mode |
| Video decode + display | `AVSampleBufferDisplayLayer` (hardware decode, display-immediately) |
| Screen capture | ScreenCaptureKit, native pixel scale, 60 fps |
| Audio | `AVAudioEngine` + voice processing, Opus via `AVAudioConverter` (PCM fallback) |
| UI | AppKit (status item, borderless floating windows, overlay windows) |
