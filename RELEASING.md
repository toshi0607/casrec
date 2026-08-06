# CasRec release procedure

Run the commands in this document from the repository root. Replace every
`<version>` with the release version without a leading `v`, for example
`0.2.0`. Commands that contain `<version>` must not be pasted unchanged.

Do not create a release until the commit to be released is checked out and all
required changes have been committed.

## 1. Check the release certificate

Confirm that the `CasRec Release` certificate is present, that its subject is
correct, and that it has not expired:

```sh
security find-certificate -c "CasRec Release" -p | openssl x509 -noout -subject -dates -fingerprint -sha1
```

The certificate is self-signed. Its SHA-1 fingerprint, after removing colons
and converting it to lowercase, must correspond to the release leaf hash:
`4feed5cfc27c13bd9711823f1edd9a4ee2a96b44`.

## 2. Run the quality gates

Run both commands and resolve any failure before building a release:

```sh
swift build -Xswiftc -warnings-as-errors
make test
```

Check the final test output, including the `Test run with N tests` summary. The
current baseline is 69 tests in 13 suites; the release run must not report fewer
tests or suites.

## 3. Build the release artifacts

Build and package the version being released:

```sh
make release VERSION=<version>
```

This creates `dist/CasRec-<version>.zip` and `dist/checksums.txt`. The command
uses the release certificate and verifies the app signature before it creates
the ZIP archive.

## 4. Confirm the designated requirement

Inspect the designated requirement in the built app:

```sh
codesign -d -r- CasRec.app
```

Its output must include the following leaf requirement from the Makefile's
`EXPECTED_LEAF` value:

```text
certificate leaf = H"4feed5cfc27c13bd9711823f1edd9a4ee2a96b44"
```

`make release` performs this check automatically and exits with an error if the
leaf does not match. This manual check makes the value visible before publishing.

## 5. Manually verify on a Mac

Open the built `CasRec.app` on a physical Mac. Grant Screen Recording and
Microphone permission when prompted, record part of a screen with microphone
audio enabled, stop the recording, and confirm that the resulting video and
audio are usable.

This cannot be automated because TCC permission prompts and the recording GUI
require an interactive Mac session.

## 6. Tag and publish

Create and push an annotated tag after the checks above have passed:

```sh
git tag -a "v<version>" -m "CasRec <version>"
git push origin "v<version>"
```

Copy the release-notes template below into a local file named
`release-notes-<version>.md`, replace every `<version>`, and then create the
GitHub release with the two generated artifacts:

```sh
gh release create "v<version>" "dist/CasRec-<version>.zip" "dist/checksums.txt" --title "CasRec <version>" --notes-file "release-notes-<version>.md"
```

## 7. Update the Homebrew cask

After publishing the GitHub release, update the cask using the checksum created
by `make release`:

```sh
scripts/update-cask.sh <version>
```

By default the script edits the tap checkout Homebrew itself uses, under
`$(brew --repository)/Library/Taps/toshi0607/homebrew-tap`. That matters:
`brew audit` accepts only a cask token, never a path, and the token always
resolves to that checkout. Editing a different clone would leave the audit
reading the previous release and passing on stale content.

Review the displayed diff, then audit the cask:

```sh
brew audit --cask --online toshi0607/tap/casrec
```

The audit downloads the release archive and checks it against the `sha256` in
the cask, so it fails if the tag or the checksum is wrong.

That checkout is an ordinary git clone with a push remote, so commit and push
from it:

```sh
cd "$(brew --repository)/Library/Taps/toshi0607/homebrew-tap"
git add Casks/casrec.rb
git commit -m "casrec <version>"
git push
```

`CASREC_TAP` overrides the target when you keep a separate clone. In that case
the script warns that auditing by token would read Homebrew's copy instead;
push first, then run `brew update` before auditing.

Finally, verify installation from the tap:

```sh
brew install --cask toshi0607/tap/casrec
```

## Release-notes template

Copy this template into `release-notes-<version>.md` before running
`gh release create`.

````md
# CasRec <version>

## Installation

Download `CasRec-<version>.zip`, extract it, and move `CasRec.app` to
`/Applications`.

This release is signed with a developer self-signed certificate. It is not
signed with an Apple Developer ID certificate and has not received Apple
notarization, so Gatekeeper is expected to block the first launch. On macOS 15
or later, first attempt to open the app, then go to System Settings > Privacy &
Security and select **Open Anyway**. Alternatively, run:

```sh
xattr -dr com.apple.quarantine /Applications/CasRec.app
```

## Checksum verification

Download `checksums.txt` with `CasRec-<version>.zip`, then run:

```sh
shasum -a 256 CasRec-<version>.zip
shasum -a 256 -c checksums.txt
```

Compare the first command's output with the `CasRec-<version>.zip` line in
`checksums.txt`. The second command should report `CasRec-<version>.zip: OK`.
````

## If the certificate must be replaced

Creating a new signing certificate changes the leaf hash. This causes every
user's existing Screen Recording permission for CasRec to be revoked at once,
so release notes must instruct users to grant that permission again. Update the
Makefile's `EXPECTED_LEAF` to the new leaf hash before releasing. See
[§2.1, "期限切れ証明書の意味（重要）"](tasks/oss-distribution-spec.md#21-期限切れ証明書の意味重要)
in the distribution specification for the certificate-expiry and replacement
details.
