#!/usr/bin/env bash
# Compare the emulator versions in .github/emulator-versions.json with the
# newest releases AWS publishes. When they differ, build a replacement version
# list (with per-arch SHA-256 pins), show it in the job summary and, with
# --write, rewrite the file in place.
#
# Usage: check-emulator-updates.sh [--write] [path/to/emulator-versions.json]
#   KEEP: number of newest versions to track (default 2)
#
# Step outputs (when run in Actions):
#   outdated=true|false
#   versions=<space-separated newest versions, newest first>
#
# The hashes are a convenience for pinning. They do not replace signature
# checking: the Docker build still GPG-verifies every package against the
# pinned AWS key, so a tampered package fails the build (and so fails CI on
# the update PR).

set -euo pipefail

WRITE=false
if [ "${1:-}" = "--write" ]; then WRITE=true; shift; fi
VERSIONS_FILE="${1:-.github/emulator-versions.json}"
KEEP="${KEEP:-2}"
BASE_URL="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

dl() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$@"; }

# versions.json lists "1.0.385.1"; packages are named after "1.0.385".
mapfile -t latest < <(
  dl "${BASE_URL}/versions.json" \
    | jq -r '.versions[].version' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | cut -d. -f1-3 | sort -uV | tail -n "${KEEP}" | sort -rV
)
[ "${#latest[@]}" -gt 0 ] || { echo "::error::No versions found in versions.json"; exit 2; }

mapfile -t current < <(jq -r '.include[].emulator_version' "${VERSIONS_FILE}" | sort -rV)

echo "Newest ${KEEP} releases: ${latest[*]}"
echo "Tracked versions:        ${current[*]:-<none>}"
echo "versions=${latest[*]}" >> "${OUTPUT}"

if [ "${latest[*]}" = "${current[*]:-}" ]; then
  echo "outdated=false" >> "${OUTPUT}"
  {
    echo "### Emulator versions up to date"
    echo "Tracking the newest releases: \`${latest[*]}\`."
  } >> "${SUMMARY}"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

hash_of() {
  local f="aws-emulator_${1}-1_${2}.deb"
  dl -o "${tmp}/${f}" "${BASE_URL}/${f}"
  sha256sum "${tmp}/${f}" | cut -d' ' -f1
  rm -f "${tmp}/${f}"
}

# Newest first; only the newest gets latest: true.
first=true
for v in "${latest[@]}"; do
  jq -n --arg v "${v}" --arg amd64 "$(hash_of "${v}" amd64)" \
    --arg arm64 "$(hash_of "${v}" arm64)" --argjson latest "${first}" \
    '{emulator_version: $v, sha256_amd64: $amd64, sha256_arm64: $arm64, latest: $latest}'
  first=false
done | jq -s '{include: .}' > "${tmp}/new.json"

if ${WRITE}; then
  cat "${tmp}/new.json" > "${VERSIONS_FILE}"
fi

{
  echo "### Emulator update available"
  echo
  echo "Tracked: \`${current[*]:-none}\` → newest releases: \`${latest[*]}\`"
  echo
  echo "New \`${VERSIONS_FILE}\`:"
  echo
  echo '```json'
  cat "${tmp}/new.json"
  echo '```'
} >> "${SUMMARY}"

echo "outdated=true" >> "${OUTPUT}"
echo "::notice::Emulator versions are out of date (have: ${current[*]:-none}; newest: ${latest[*]})."
