# Pairwise

## Releasing

- Releases are fully automatic: every push to `main` triggers the GitHub
  Actions `Release` workflow (.github/workflows/release.yml), which derives
  the next version from the newest `v1.*` tag and runs `release.sh` on the
  runner (build → sign → notarize → GitHub release → appcast commit).
- Never run `./release.sh` locally — just push to `main`.
- Versioning: 1.1, 1.2, 1.3, … — the minor version increments by one for
  every release regardless of the size of the changes (CI handles this).
