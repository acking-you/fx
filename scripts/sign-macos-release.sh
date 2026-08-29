#!/bin/bash

set -euo pipefail

binary_path="${1:?usage: sign-macos-release.sh <binary-path>}"
signing_identifier="${FX_SIGNING_IDENTIFIER:-fx}"
codesign_bin="${FX_SIGNING_CODESIGN_BIN:-/usr/bin/codesign}"

required_secrets=(
    APPLE_DEVELOPER_ID_P12_BASE64
    APPLE_DEVELOPER_ID_P12_PASSWORD
    APPLE_NOTARY_KEY_P8_BASE64
    APPLE_NOTARY_KEY_ID
    APPLE_NOTARY_ISSUER_ID
)
configured_secrets=0
for required_name in "${required_secrets[@]}"; do
    if [[ -n "${!required_name:-}" ]]; then
        ((configured_secrets += 1))
    fi
done

if [[ "${configured_secrets}" -eq "${#required_secrets[@]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "${script_dir}/sign-and-notarize-macos.sh" "${binary_path}"
fi

if [[ "${configured_secrets}" -ne 0 ]]; then
    echo "Apple release signing credentials are only partially configured" >&2
    exit 1
fi

"${codesign_bin}" \
    --force \
    --sign - \
    --identifier "${signing_identifier}" \
    "${binary_path}"
"${codesign_bin}" --verify --strict --verbose=4 "${binary_path}"

signature_details="$(
    "${codesign_bin}" --display --verbose=4 "${binary_path}" 2>&1
)"
if [[ "${signature_details}" != *"Identifier=${signing_identifier}"* ]]; then
    echo "Ad-hoc signed binary has the wrong signing identifier" >&2
    exit 1
fi
if [[ "${signature_details}" != *"Signature=adhoc"* ]]; then
    echo "Expected an ad-hoc macOS signature" >&2
    exit 1
fi

echo "Ad-hoc signed ${binary_path}; Apple notarization skipped because release credentials are not configured"
