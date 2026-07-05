# Pairwise

A fast, fully peer-to-peer pair-programming app for macOS — a Tuple clone with
no accounts and no cloud. Add a peer by IP address, or by a shared code that
rendezvouses through a tiny Cloudflare Worker; either way media flows directly
between the two machines.

## Features

- **Menu bar app** — lives in the status bar, no Dock icon.
- **Direct P2P calls** — add a peer's IP, hit Call; they get a ring panel with
  Accept / Decline. Signaling runs over TCP (port 47800), media over UDP
  (port 47801). Nothing ever touches a third-party server.
- **Shared-code calls (no Tailscale/VPN needed)** — both people add the same
  code word instead of an IP. A Cloudflare Worker + Durable Object
  (`server/`) acts as a rendezvous room: it carries presence and the tiny
  JSON call-signaling messages, while audio/video are hole-punched directly
  peer-to-peer over UDP (STUN via Cloudflare/Google for the public endpoint;
  no media relay, so it fails rather than falls back if both NATs block
  punching — LAN and Tailscale paths are tried too).
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

Releases are automatic: every push to `main` runs the GitHub Actions
`Release` workflow (`.github/workflows/release.yml`), which picks the next
`1.N` version from the newest tag and runs `release.sh` on the runner —
build, sign, notarize, staple, zip, EdDSA-sign the update, add an appcast
entry, create the GitHub release, and push. Don't run `release.sh` locally.

Release notes (on both the GitHub release and Sparkle's update dialog) are
the commit subjects since the previous release tag — usually the single
commit that triggered the release.

The workflow needs these repository secrets (documented at the top of
`release.yml`): `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, `SPARKLE_PRIVATE_KEY`.

## Using it

**With a shared code (easiest):**

1. Agree on a code word with your pair (e.g. `ben-jerome`).
2. Both: **Add Peer…** → enter the other person's name and the code word.
3. The presence dot turns green when they're online; **Call `<name>`** rings
   them, and media connects directly via UDP hole punching.

**With an IP address:**

1. Both people run Pairwise on the same network (or with UDP/TCP ports 47800
   + 47801 reachable, e.g. via Tailscale or port forwarding).
2. Find your IP (for Tailscale: `tailscale ip -4`) and tell it to your pair.
3. **Add Peer…** → enter their name and IP.

Then: **Call `<name>`** — they accept, and audio + your camera start
immediately. **Share My Screen** from the menu; their viewer window opens
automatically and they can draw on it any time. Only one person shares at a
time — starting a share while your pair is sharing takes it over.

Currently IPv4 only.

## Rendezvous server (`server/`)

A Cloudflare Worker with one Durable Object per room code, using the
WebSocket Hibernation API (idle rooms cost nothing). It only ever sees
presence events and small JSON signaling messages — never media. Deployed at
`https://pairwise-rendezvous.benborgers.workers.dev`; the app can be pointed
elsewhere via
`defaults write dev.benborgers.pairwise pairwise.rendezvousURL wss://…`.

Pushes to `main` that touch `server/` deploy it automatically
(`.github/workflows/deploy-server.yml`, needs the `CLOUDFLARE_API_TOKEN`
repository secret); those pushes don't cut an app release. Manual deploy:

```sh
cd server && npx wrangler deploy
```

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
