# Changes, versions and verification

Every delivered change belongs in Git and in the English `CHANGELOG.md`. Describe the user-visible problem, changed behavior, and verification. Offline tests are not live game verification.

Bundle versioning begins at `2.0.0`. Increase patch for compatible fixes, minor for compatible features, and major for incompatible changes. Update `VERSION`, `versions.json`, the README release label, and changelog together. Each published release uses an annotated Git tag `vX.Y.Z` on the exact verified commit. Never retag a published release.

Components retain independent versions. For changed components, increment their versions and update `versions.json`, the README table, and displayed version strings. Do not rename installation folders or change persisted setting keys merely to match a version.

Before publication:

1. Review changed functions and callers. Trace callback rejection, synchronous/late completion, cancellation, and ownership transfer.
2. Add regressions for confirmed defects or materially risky behavior, using actual modules where feasible.
3. Run `python3 audit/check_release.py --base vX.Y.Z` against the previous release tag (omit `--base` for the first release), then `python3 audit/tests/run_tests.py`.
4. Save verification results and identify required live-client checks.
5. Commit source, English changelog and version updates together; tag and push the verified release.

Preserve original credits. Do not commit credentials, private logs, local settings, proprietary packs, or QQT binaries. The project cover's generation record is in `assets/branding/README.md`.
