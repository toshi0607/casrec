# Notes: Codex Security Findings Remediation

## Source Scan

- Scan ID: `e820729f-3c44-4b3d-808f-678cbc7e85fc`
- Findings: two medium and three low.

## Security Invariants

- Delayed capture resolves exactly one owner-bound window identity; title and app display name are never authorization attributes.
- Library cardinality and GIF frame count cannot create unbounded concurrent metadata work.
- ffmpeg accepts the selected local MOV plus CasRec-owned local palette/output paths only.
- Child lifetime, stderr memory, cancellation, and graceful application shutdown remain bounded and supervised.
- Output cleanup removes only private staging paths; final publication is atomic and never overwrites.
- Bundle verification fails when the Hardened Runtime flag is absent.

## Latest-main Integration

- `origin/main` already contains the legal/usage-notice work, a redesigned navigation UI, distribution entitlements, release timestamping, clean bundle reconstruction, and signing leaf verification.
- Security integration preserves those newer controls and adds runtime-flag verification to the existing signing gates.

## Verification Evidence

- `git diff --check`: pass.
- `make test`: 83 tests in 14 suites pass on latest `main`; the final suite passed three consecutive times after increasing the heavy-stderr test deadline from 2 to 10 seconds.
- `swift build -Xswiftc -warnings-as-errors`: pass with no warnings.
- `make bundle CODESIGN_IDENTITY=-` and `make verify-bundle`: pass; `CodeDirectory flags=0x10002(adhoc,runtime)` and microphone entitlement remain embedded.
- Capture mutation: replacing exact owner-bound resolution with kind/title matching makes 7 resolver assertions fail.
- Library mutation: removing the four-worker backpressure makes the concurrency-bound assertion fail.
- ffmpeg mutation: removing the forced local MOV prefix makes 3 command-policy assertions fail.
- Signing mutation: re-signing without `--options runtime` remains signature-valid but `make verify-bundle` exits 2 with the repair-oriented error.
- Queue shutdown uses a TERM-ignoring `/bin/sh` PID test and returns only after the child no longer exists.
- UUID staging plus `renameatx_np(..., RENAME_EXCL)` tests preserve foreign destinations and publish successful output atomically.
- Independent latest-main review found no production or test blocker. Its only low-severity test-stability concern was the heavy-stderr deadline; the adjusted test also passes alone in 0.52 seconds.
