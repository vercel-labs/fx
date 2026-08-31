#!/bin/bash

set -euo pipefail

umask 077

signing_identity="Developer ID Application: Vercel, Inc (JW6Y669B67)"
signing_identifier="com.vercel.fx"
signing_team_id="JW6Y669B67"

openssl_bin="${FX_SIGNING_OPENSSL_BIN:-/usr/bin/openssl}"
security_bin="${FX_SIGNING_SECURITY_BIN:-/usr/bin/security}"
codesign_bin="${FX_SIGNING_CODESIGN_BIN:-/usr/bin/codesign}"
ditto_bin="${FX_SIGNING_DITTO_BIN:-/usr/bin/ditto}"
xcrun_bin="${FX_SIGNING_XCRUN_BIN:-/usr/bin/xcrun}"
jq_bin="${FX_SIGNING_JQ_BIN:-/usr/bin/jq}"

binary_path="${1:?usage: sign-and-notarize-macos.sh <binary-path>}"
for required_name in \
    APPLE_DEVELOPER_ID_P12_BASE64 \
    APPLE_DEVELOPER_ID_P12_PASSWORD \
    APPLE_NOTARY_KEY_P8_BASE64 \
    APPLE_NOTARY_KEY_ID \
    APPLE_NOTARY_ISSUER_ID; do
    if [[ -z "${!required_name:-}" ]]; then
        echo "Missing required environment variable: ${required_name}" >&2
        exit 1
    fi
done

runner_temp="${RUNNER_TEMP:-/private/tmp}"
signing_temp_dir="$(mktemp -d "${runner_temp}/fx-signing.XXXXXX")"
signing_keychain="${signing_temp_dir}/signing.keychain-db"
certificate_path="${signing_temp_dir}/developer-id.p12"
notary_key_path="${signing_temp_dir}/notary-key.p8"
notary_archive_path="${signing_temp_dir}/fx-notary.zip"
notary_result_path="${signing_temp_dir}/notary-result.json"
notary_log_path="${signing_temp_dir}/notary-log.json"
keychain_password="$(${openssl_bin} rand -hex 32)"

cleanup() {
    set +e
    "${security_bin}" delete-keychain "${signing_keychain}" >/dev/null 2>&1
    /bin/rm -rf "${signing_temp_dir}"
}
trap cleanup EXIT

fail_stage() {
    echo "Apple signing failed during $1" >&2
    exit 1
}

printf '%s' "${APPLE_DEVELOPER_ID_P12_BASE64}" \
    | "${openssl_bin}" base64 -d -A -out "${certificate_path}"
printf '%s' "${APPLE_NOTARY_KEY_P8_BASE64}" \
    | "${openssl_bin}" base64 -d -A -out "${notary_key_path}"

"${security_bin}" create-keychain -p "${keychain_password}" "${signing_keychain}"
"${security_bin}" set-keychain-settings -lut 21600 "${signing_keychain}"
"${security_bin}" unlock-keychain -p "${keychain_password}" "${signing_keychain}"
if ! "${security_bin}" import "${certificate_path}" \
    -k "${signing_keychain}" \
    -P "${APPLE_DEVELOPER_ID_P12_PASSWORD}" \
    -f pkcs12 \
    -T /usr/bin/codesign \
    -T /usr/bin/security; then
    fail_stage "PKCS#12 import"
fi
if ! "${security_bin}" list-keychains -d user -s "${signing_keychain}"; then
    fail_stage "keychain search configuration"
fi

if ! signing_identities="$(
    "${security_bin}" find-identity -v -p codesigning "${signing_keychain}"
)"; then
    fail_stage "signing identity lookup"
fi
if [[ "${signing_identities}" != *"${signing_identity}"* ]]; then
    echo "Developer ID signing identity is unavailable" >&2
    exit 1
fi

if ! "${security_bin}" set-key-partition-list \
    -S apple-tool:,apple: \
    -t private \
    -k "${keychain_password}" \
    "${signing_keychain}" >/dev/null; then
    fail_stage "private-key ACL configuration"
fi

if ! "${codesign_bin}" \
    --force \
    --sign "${signing_identity}" \
    --keychain "${signing_keychain}" \
    --identifier "${signing_identifier}" \
    --options runtime \
    --timestamp \
    "${binary_path}"; then
    fail_stage "code signing"
fi
if ! "${codesign_bin}" --verify --strict --verbose=4 "${binary_path}"; then
    fail_stage "signature verification"
fi

if ! signature_details="$(
    "${codesign_bin}" --display --verbose=4 "${binary_path}" 2>&1
)"; then
    fail_stage "signature inspection"
fi
if [[ "${signature_details}" != *"Identifier=${signing_identifier}"* ]]; then
    echo "Signed binary has the wrong signing identifier" >&2
    exit 1
fi
if [[ "${signature_details}" != *"TeamIdentifier=${signing_team_id}"* ]]; then
    echo "Signed binary has the wrong team identifier" >&2
    exit 1
fi
signed_cdhash="$(
    printf '%s\n' "${signature_details}" \
        | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
)"
if [[ -z "${signed_cdhash}" ]]; then
    echo "Signed binary is missing its code-directory hash" >&2
    exit 1
fi

"${ditto_bin}" -c -k "${binary_path}" "${notary_archive_path}"
if ! "${xcrun_bin}" notarytool submit "${notary_archive_path}" \
    --key "${notary_key_path}" \
    --key-id "${APPLE_NOTARY_KEY_ID}" \
    --issuer "${APPLE_NOTARY_ISSUER_ID}" \
    --wait \
    --output-format json >"${notary_result_path}"; then
    fail_stage "notarization submission"
fi

notary_status="$("${jq_bin}" -r '.status' "${notary_result_path}")"
submission_id="$("${jq_bin}" -r '.id' "${notary_result_path}")"
if [[ "${notary_status}" != "Accepted" || -z "${submission_id}" ]]; then
    echo "Apple notarization failed with status: ${notary_status}" >&2
    exit 1
fi

if ! "${xcrun_bin}" notarytool log "${submission_id}" \
    --key "${notary_key_path}" \
    --key-id "${APPLE_NOTARY_KEY_ID}" \
    --issuer "${APPLE_NOTARY_ISSUER_ID}" \
    "${notary_log_path}"; then
    fail_stage "notarization log retrieval"
fi
if ! "${jq_bin}" -e \
    '.status == "Accepted" and ((.issues // []) | length == 0)' \
    "${notary_log_path}" >/dev/null; then
    echo "Apple notarization log contains issues" >&2
    exit 1
fi
if ! "${jq_bin}" -e \
    --arg cdhash "${signed_cdhash}" \
    '.ticketContents // [] | any(.cdhash == $cdhash)' \
    "${notary_log_path}" >/dev/null; then
    echo "Apple notarization ticket does not match the signed binary" >&2
    exit 1
fi
echo "Signed and notarized ${binary_path} (submission ${submission_id})"
