#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s <version>\n' "${0##*/}" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ "$#" -ne 1 || -z "$1" ]]; then
  usage
  exit 1
fi

version="$1"
dist_dir="dist"
checksums_file="$dist_dir/checksums.txt"
archive="CasRec-$version.zip"

# `brew audit` only accepts a cask token, never a path, and a token always
# resolves to Homebrew's own tap checkout. Editing any other clone would leave
# the audit reading the previous release. Default to the checkout Homebrew
# itself uses so the two cannot drift; it is a normal git clone with a remote,
# so the commit and push happen there too.
homebrew_tap_dir=""
if brew_repo="$(brew --repository 2>/dev/null)"; then
  homebrew_tap_dir="$brew_repo/Library/Taps/toshi0607/homebrew-tap"
fi
if [[ -n "${CASREC_TAP:-}" ]]; then
  tap_dir="$CASREC_TAP"
elif [[ -n "$homebrew_tap_dir" && -d "$homebrew_tap_dir" ]]; then
  tap_dir="$homebrew_tap_dir"
else
  tap_dir="../homebrew-tap"
fi

if [[ ! -d "$dist_dir" ]]; then
  die "dist/ does not exist. Run 'make release VERSION=$version' first."
fi

if [[ ! -f "$checksums_file" ]]; then
  die "Missing $checksums_file. Run 'make release VERSION=$version' first."
fi

if ! sha256="$(awk -v archive="$archive" '
  $2 == archive { count += 1; digest = $1 }
  END {
    if (count == 1) {
      print digest
      exit 0
    }
    exit 1
  }
' "$checksums_file")"; then
  die "Could not find exactly one checksum for $archive in $checksums_file."
fi

if [[ ! "$sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
  die "Invalid SHA256 for $archive in $checksums_file."
fi

if [[ ! -d "$tap_dir" ]]; then
  die "Tap repository not found: $tap_dir. Set CASREC_TAP to its path."
fi

cask_file="$tap_dir/Casks/casrec.rb"
if [[ ! -f "$cask_file" ]]; then
  die "Cask file not found: $cask_file."
fi

version_lines="$(grep -Ec '^[[:space:]]*version[[:space:]]+"' "$cask_file" || true)"
sha256_lines="$(grep -Ec '^[[:space:]]*sha256[[:space:]]+"' "$cask_file" || true)"
if [[ "$version_lines" -ne 1 || "$sha256_lines" -ne 1 ]]; then
  die "Expected exactly one version line and one sha256 line in $cask_file."
fi

original_file="$(mktemp "${TMPDIR:-/tmp}/casrec-cask.XXXXXX")"
trap 'rm -f "$original_file"' EXIT
cp "$cask_file" "$original_file"

CASREC_CASK_VERSION="$version" CASREC_CASK_SHA256="$sha256" perl -pi -e '
  s/^(\s*version\s+")[^"]*(".*)$/$1 . $ENV{CASREC_CASK_VERSION} . $2/me;
  s/^(\s*sha256\s+")[^"]*(".*)$/$1 . $ENV{CASREC_CASK_SHA256} . $2/me;
' "$cask_file"

diff -u "$original_file" "$cask_file" || true

audits_edited_file=false
if [[ -n "$homebrew_tap_dir" && -d "$homebrew_tap_dir" ]] &&
   [[ "$(cd "$tap_dir" && pwd -P)" == "$(cd "$homebrew_tap_dir" && pwd -P)" ]]; then
  audits_edited_file=true
fi

if [[ "$audits_edited_file" == true ]]; then
  printf '\nUpdated %s\nRun the following command to audit it:\n' "$cask_file" >&2
  printf '  brew audit --cask --online toshi0607/tap/casrec\n' >&2
else
  printf '\nUpdated %s\n' "$cask_file" >&2
  printf 'WARNING: this is not the checkout Homebrew reads.\n' >&2
  printf '  brew audit only accepts a cask token, and that token resolves to\n' >&2
  printf '  %s\n' "${homebrew_tap_dir:-the tap checkout under brew --repository}" >&2
  printf '  Auditing now would check the previous release, not this change.\n' >&2
  printf '  Commit and push this file, then run:\n' >&2
  printf '    brew update && brew audit --cask --online toshi0607/tap/casrec\n' >&2
fi
