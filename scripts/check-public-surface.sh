#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

personal_paths="$({
  git grep -n -E '/Users/[^/[:space:]]+/' -- . ':(exclude)scripts/check-public-surface.sh' || true
} | grep -Ev '/Users/(example|tester|private|me|<you>)/' || true)"
if [[ -n "$personal_paths" ]]; then
  printf 'Tracked personal paths found:\n%s\n' "$personal_paths" >&2
  exit 1
fi

capture='tests/e2e/fixtures/fx-render-bug-20260510-075848.tar.gz'
archive_listing="$(tar -tzvf "$capture")"
unexpected_owners="$(grep -Ev '[[:space:]]root([/]|[[:space:]]+)root[[:space:]]' <<<"$archive_listing" || true)"
if [[ -n "$unexpected_owners" ]]; then
  printf 'Render fixture archive metadata contains a non-root owner:\n%s\n' "$unexpected_owners" >&2
  exit 1
fi
if grep -Eq '/\._' <<<"$archive_listing"; then
  printf 'Render fixture contains macOS AppleDouble metadata\n' >&2
  exit 1
fi

extract_dir="$(mktemp -d)"
trap 'rm -rf "$extract_dir"' EXIT
tar -xzf "$capture" -C "$extract_dir"

archive_matches="$({
  grep -R -a -n -E '/Users/[^/[:space:]]+/' "$extract_dir" || true
} | grep -Ev '/Users/(guest|example|tester|private|me)/' || true)"
if [[ -n "$archive_matches" ]]; then
  printf 'Render fixture contains personal or internal data:\n%s\n' "$archive_matches" >&2
  exit 1
fi

if ! grep -R -a -q 'sanitized-v1' "$extract_dir"; then
  printf 'Render fixture is missing its sanitized branch marker\n' >&2
  exit 1
fi
