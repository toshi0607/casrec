# Codex Security Remediation Report

## Outcome

The five validated findings from scan `e820729f-3c44-4b3d-808f-678cbc7e85fc` are fixed on the latest `main` architecture. The already-merged usage notice, redesigned UI, Homebrew/release documentation, entitlements, timestamping, clean bundle reconstruction, and signing leaf verification are preserved.

Draft pull request: https://github.com/toshi0607/casrec/pull/34

## Remediations

1. Delayed window capture requires one exact `windowID` + owner PID + bundle ID match. Mutable title/application labels and ambiguous identities fail closed.
2. Existing Hardened Runtime signing is now mechanically verified by `make verify-bundle` and CI in addition to the release leaf-hash gate.
3. Library enumeration streams direct children, limits metadata work to four tasks, preserves complete sorting, and refuses GIF duration traversal above 10,000 frames.
4. ffmpeg movie inputs are forced through the MOV demuxer with only the local `file` protocol; data references, absolute aliases, stdin, and unrestricted palette probing are disabled.
5. ffmpeg keeps only a 16 KiB diagnostic suffix, uses a duration-aware 30-minute-to-12-hour deadline, propagates cancellation, and escalates TERM to KILL. Graceful app termination awaits the app-owned queue. Output is staged privately and published via atomic non-overwrite rename.

## Verification

- `git diff --check` — pass.
- `make test` — 83 tests / 14 suites pass in three consecutive full-suite runs.
- `swift build -Xswiftc -warnings-as-errors` — pass.
- `make bundle CODESIGN_IDENTITY=-` and `make verify-bundle` — pass.
- CodeDirectory — `flags=0x10002(adhoc,runtime)`; microphone entitlement remains embedded.
- Security mutations are detected: capture-title fallback (7 failures), unbounded library concurrency (1 failure), unrestricted ffmpeg input prefix (3 failures), and runtime-free signing (`make verify-bundle` exit 2).

## Compatibility and Residual Risk

- Exact live-window/display resolution, title changes on the same owner-bound window, full large-library results, optional GIF/recovery behavior, and the newer navigation/usage-notice flows remain covered.
- Scheduled or quick capture intentionally requires reselection after an app restart or owner identity change.
- ffmpeg remains an optional unsandboxed external dependency; this patch constrains its inputs and process resources but does not replace it with a sandboxed helper.
- Force kill, crash, or power loss cannot execute graceful child cancellation and may leave hidden `.casrec-*` staging files.
- A real GUI ⌘Q during active ffmpeg/AVFoundation export, a full multi-hour conversion, and certificate-signed release packaging remain manual release checks.

## Independent Review

No production or test blocker remains. The reviewer confirmed that all five remediation boundaries and the latest UI, usage-notice, release-signing, and queue integrations remain intact. One low-severity test-stability concern was resolved by increasing the non-timeout heavy-stderr test deadline from 2 to 10 seconds; it passes alone in 0.52 seconds and in three consecutive full-suite runs.
