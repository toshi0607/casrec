# Task Plan: Codex Security Findings Remediation

## Goal

Close all five validated Codex Security findings on the latest `main`, preserve the newer release/UI work already merged there, and publish the result as one focused pull request.

## Phases

- [x] Revalidate the findings and confirm the legal/usage-notice work is already on `main`.
- [x] Rebase the work onto a fresh `codex/security-hardening` branch from `origin/main`.
- [x] Port the five security fixes and their regression tests onto the current architecture.
- [x] Run tests, warnings-as-errors build, bundle/signature verification, and mutation checks.
- [x] Perform independent review and document the final latest-main result.
- [ ] Commit, push, and open a draft PR.

## Finding Tracks

1. Capture source identity must fail closed for stale/reused windows.
2. Hardened Runtime must remain enabled and be mechanically verified.
3. Library metadata parsing must bound concurrency and per-file GIF work.
4. ffmpeg inputs must be constrained to local MOV/PNG parsing.
5. ffmpeg execution must bound lifetime and diagnostics, survive graceful app termination, and publish outputs without overwrite races.

## Decisions

- The usage notice, MIT license, README, release flow, and redesigned UI already exist on latest `main`; this PR carries only the security remediation.
- Core security files unchanged since the original scan are ported directly; App/UI, Makefile, DESIGN, and task records are adapted to current `main` rather than overwritten.
- The existing release signing identity, entitlements, timestamp, clean bundle rebuild, and leaf-hash verification are preserved.

## Status

**Ready to publish** — latest-main integration, repeated verification, and independent final review pass with no blocker.
