#!/usr/bin/env bash
# ==============================================================================
# generate-topic.sh
#
# Generates a unique NTFY topic composed of two parts:
#   1. Local usable name (required: provided as argument 1)
#   2. Random alphanumeric suffix (optional: defaults to 16 characters)
#
# Format: <local-usable-name>-<random-suffix>
# Example: ./generate-topic.sh pw-lake-updates
#          -> pw-lake-updates-8861344083d8c97d
# ==============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Error: Missing required local name argument." >&2
    echo "Usage: $0 <local-usable-name> [suffix-length]" >&2
    echo "Example: $0 pw-lake-updates 16" >&2
    exit 1
fi

LOCAL_NAME="$1"
SUFFIX_LEN="${2:-16}"

# Generate cryptographically random alphanumeric suffix
generate_suffix() {
    local len="$1"
    if command -v openssl >/dev/null 2>&1 && (( len % 2 == 0 )); then
        openssl rand -hex "$(( len / 2 ))"
    else
        LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c "${len}"
    fi
}

SUFFIX="$(generate_suffix "${SUFFIX_LEN}")"
TOPIC="${LOCAL_NAME}-${SUFFIX}"

echo "${TOPIC}"
