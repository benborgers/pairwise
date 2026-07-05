# Pairwise

## Releasing

- Releases are fully automatic: every push to `main` triggers the GitHub
  Actions `Release` workflow (.github/workflows/release.yml), which derives
  the next version from the newest `v1.*` tag and runs `release.sh` on the
  runner (build → sign → notarize → GitHub release → appcast commit).
- Never run `./release.sh` locally — just push to `main`.
- Versioning: 1.1, 1.2, 1.3, … — the minor version increments by one for
  every release regardless of the size of the changes (CI handles this).
- Release notes are generated from the commit subjects since the previous
  tag, so write commit messages that read well to users.

## Rendezvous server

- `server/` is a Cloudflare Worker + Durable Object (WebSocket rooms) used
  by shared-code peers for presence and call signaling; media stays P2P via
  UDP hole punching.
- Pushes to `main` that touch `server/` deploy it automatically via the
  `Deploy Server` workflow (.github/workflows/deploy-server.yml); server-only
  pushes do NOT cut an app release. To deploy manually:
  `cd server && npx wrangler deploy`.
