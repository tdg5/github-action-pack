#!/usr/bin/env bash
# Setup sops binary. Can be invoked standalone or from the GitHub Action.
#
# Environment variables:
#   INPUT_VERSION     - Desired sops version ("latest", "v3.12.2", "3.12.2", etc.)
#   GITHUB_TOKEN      - (optional) GitHub token for authenticated API requests
#   GITHUB_OUTPUT     - (optional) GitHub Actions output file
#   GITHUB_PATH       - (optional) GitHub Actions PATH file
#   FORCE_INSTALL     - (optional) Set to "true" to install even if a newer sops exists
#   RUNNER_TOOL_CACHE - (optional) Tool cache directory (defaults to ~/.sops)

set -euo pipefail

STABLE_VERSION="v3.12.2"
TARGET_VERSION="${INPUT_VERSION:-latest}"
VERSION_LOWER="$(echo "$TARGET_VERSION" | tr '[:upper:]' '[:lower:]')"

# Resolve 'latest' to actual latest version
if [[ "$VERSION_LOWER" == "latest" ]]; then
  if ! command -v jq &>/dev/null; then
    echo "::warning::jq not found; cannot resolve latest version. Using default ${STABLE_VERSION}."
    TARGET_VERSION="$STABLE_VERSION"
  else
    CURL_ARGS=(-s)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    RELEASES_JSON=$(mktemp)
    HTTP_CODE=$(curl "${CURL_ARGS[@]}" -o "$RELEASES_JSON" -w "%{http_code}" \
      https://api.github.com/repos/getsops/sops/releases)

    if [[ "$HTTP_CODE" != "200" ]]; then
      echo "::warning::GitHub API returned HTTP ${HTTP_CODE}. Using default ${STABLE_VERSION}."
      TARGET_VERSION="$STABLE_VERSION"
    else
      LATEST=$(jq -r '
        [.[] | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))]
        | sort_by(.tag_name | ltrimstr("v") | split(".") | map(tonumber))
        | last
        | .tag_name
      ' "$RELEASES_JSON")

      if [[ -n "$LATEST" && "$LATEST" != "null" ]]; then
        TARGET_VERSION="$LATEST"
      else
        echo "::warning::Cannot determine latest sops version. Using default ${STABLE_VERSION}."
        TARGET_VERSION="$STABLE_VERSION"
      fi
    fi

    rm -f "$RELEASES_JSON"
  fi
elif [[ ! "$VERSION_LOWER" =~ ^v ]]; then
  TARGET_VERSION="v${TARGET_VERSION}"
fi

# Helper to compare semver strings (returns 0 if $1 >= $2)
version_gte() {
  local IFS=.
  local i
  # shellcheck disable=SC2206
  local a=($1)
  # shellcheck disable=SC2206
  local b=($2)
  for ((i=0; i<3; i++)); do
    if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
    if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
  done
  return 0
}

DESIRED_VERSION="${TARGET_VERSION#v}"

# Check for an existing sops installation
if [[ "${FORCE_INSTALL:-}" != "true" ]] && command -v sops &>/dev/null; then
  EXISTING_VERSION=$(sops --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [[ -n "$EXISTING_VERSION" ]] && version_gte "$EXISTING_VERSION" "$DESIRED_VERSION"; then
    EXISTING_PATH="$(command -v sops)"
    echo "Existing sops ${EXISTING_VERSION} >= requested ${TARGET_VERSION}; skipping install."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "sops-path=${EXISTING_PATH}" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi
fi

echo "Installing sops ${TARGET_VERSION}..."

# Determine OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)  SUFFIX="linux.amd64" ;;
      aarch64) SUFFIX="linux.arm64" ;;
      *)       SUFFIX="linux.amd64" ;;
    esac
    ;;
  Darwin)
    case "$ARCH" in
      x86_64)  SUFFIX="darwin.amd64" ;;
      arm64)   SUFFIX="darwin.arm64" ;;
      *)       SUFFIX="darwin.amd64" ;;
    esac
    ;;
  *)
    echo "::error::Unsupported OS: ${OS}"
    exit 1
    ;;
esac

DOWNLOAD_URL="https://github.com/getsops/sops/releases/download/${TARGET_VERSION}/sops-${TARGET_VERSION}.${SUFFIX}"

# Set up install directory
INSTALL_DIR="${RUNNER_TOOL_CACHE:-${HOME}/.sops}/sops/${TARGET_VERSION}"
mkdir -p "$INSTALL_DIR"

SOPS_PATH="${INSTALL_DIR}/sops"

# Download if not already cached
if [[ ! -f "$SOPS_PATH" ]]; then
  echo "Downloading sops from ${DOWNLOAD_URL}..."
  if ! curl -sfL -o "$SOPS_PATH" "$DOWNLOAD_URL"; then
    rm -f "$SOPS_PATH"
    echo "::error::Failed to download sops from ${DOWNLOAD_URL}"
    exit 1
  fi
  chmod +x "$SOPS_PATH"
fi

# Add to PATH and set output
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${INSTALL_DIR}" >> "$GITHUB_PATH"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "sops-path=${SOPS_PATH}" >> "$GITHUB_OUTPUT"
fi
echo "Sops tool version: '${TARGET_VERSION}' has been cached at ${SOPS_PATH}"
