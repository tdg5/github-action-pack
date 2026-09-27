#!/usr/bin/env bash
# publish-image-action's logic, extracted from tdg5/infrastructure's
# publish-image workflow. Run from the caller's checkout root as
#
#   publish-image.sh <prepare|preflight|release|summary>
#
# Each subcommand reads INPUT_* and step env and writes $GITHUB_OUTPUT or
# $GITHUB_STEP_SUMMARY. The functions below are pure enough to be sourced
# and tested on their own; main runs only when the script is executed.
#
# Every yq expression here works with both mikefarah yq v4 (the runner's) and
# the Python jq-wrapper yq, and always uses -r.

set -o errexit
set -o nounset
set -o pipefail

# --- Helpers ---

die() {
  echo "$*" >&2
  exit 1
}

# write_output <key> <value>: appends key=value to $GITHUB_OUTPUT.
write_output() {
  echo "$1=$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
}

# --- Names ---

# validate_image <image>: one or more /-separated lowercase segments, each
# alphanumeric with single . _ - separators.
validate_image() {
  local image="$1"
  local segment='[a-z0-9]+([._-][a-z0-9]+)*'
  if ! printf '%s' "$image" | grep -Eq "^${segment}(/${segment})*\$"; then
    echo "image must be one or more '/'-separated segments (lowercase alphanumeric with . _ - separators); got '$image'." >&2
    return 1
  fi
}

# release_tag_for <image> <version>: the git tag and Release name.
release_tag_for() {
  printf '%s/v%s\n' "$1" "$2"
}

# repository_name <prefix> <image>: the published repository name.
repository_name() {
  printf '%s%s\n' "$1" "$2"
}

# image_ref_for <registry> <ecr_registry> <owner> <repository>
image_ref_for() {
  local registry="$1" ecr_registry="$2" owner="$3" repository="$4"
  case "$registry" in
    ecr) printf '%s/%s\n' "$ecr_registry" "$repository" ;;
    ghcr) printf 'ghcr.io/%s/%s\n' "$owner" "$repository" ;;
    *)
      echo "registry must be 'ecr' or 'ghcr'; got '$registry'." >&2
      return 1
      ;;
  esac
}

# --- Checkout and history guards ---

require_full_history() {
  local shallow
  shallow="$(git rev-parse --is-shallow-repository)" || return 1
  if [[ "$shallow" == "true" ]]; then
    echo "The checkout is shallow; the publish-history guard and release notes need full history and tags. Check out with fetch-depth: 0." >&2
    return 1
  fi
}

# dockerfile_path <images_root> <image>: prints the Dockerfile's path.
dockerfile_path() {
  local dockerfile="${1%/}/$2/Dockerfile"
  if [[ ! -f "$dockerfile" ]]; then
    echo "No Dockerfile at $dockerfile — is the image name correct?" >&2
    return 1
  fi
  printf '%s\n' "$dockerfile"
}

require_new_release_tag() {
  local release_tag="$1"
  if git rev-parse -q --verify "refs/tags/$release_tag" >/dev/null; then
    echo "Tag $release_tag already exists; refusing to republish this version." >&2
    return 1
  fi
}

# publish_history <image> <previous_version>: prints first_publish
# (true|false). Fails when the image was published before and no previous
# version is given, or when the previous version's tag is missing.
publish_history() {
  local image="$1" previous_version="$2"
  local published_before previous_release_tag
  published_before="$(git tag --list "$image/v*")" || return 1
  if [[ -n "$published_before" && -z "$previous_version" ]]; then
    {
      echo "$image has been published before (tags exist); previous-version is required to generate release notes."
      echo "Existing tags:"
      echo "$published_before"
    } >&2
    return 1
  fi
  if [[ -n "$previous_version" ]]; then
    previous_release_tag="$(release_tag_for "$image" "$previous_version")"
    if ! git rev-parse -q --verify "refs/tags/$previous_release_tag" >/dev/null; then
      echo "Previous tag $previous_release_tag was not found in this repository." >&2
      return 1
    fi
  fi
  if [[ -z "$published_before" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# --- Build config ---

# resolve_config <image_dir> <default_config>: prints the build config path.
# The image's own build-config.yaml wins wholesale over the default.
resolve_config() {
  local image_dir="$1" default_config="$2"
  local cfg="$image_dir/build-config.yaml"
  if [[ -f "$cfg" ]]; then
    printf '%s\n' "$cfg"
    return 0
  fi
  if [[ -z "$default_config" ]]; then
    echo "No build config: $cfg does not exist and no default-build-config was given." >&2
    return 1
  fi
  if [[ ! -f "$default_config" ]]; then
    echo "No build config: $cfg does not exist and the default $default_config was not found." >&2
    return 1
  fi
  printf '%s\n' "$default_config"
}

config_platforms() {
  local cfg="$1" platforms
  if ! platforms="$(yq -r '.platforms | join(",")' "$cfg")" || [[ -z "$platforms" || "$platforms" == "null" ]]; then
    echo "No platforms found in $cfg" >&2
    return 1
  fi
  printf '%s\n' "$platforms"
}

config_registry() {
  local cfg="$1" registry
  registry="$(yq -r '.registry // "ecr"' "$cfg")" || return 1
  if [[ "$registry" != "ecr" && "$registry" != "ghcr" ]]; then
    echo "registry must be 'ecr' or 'ghcr' in $cfg; got '$registry'." >&2
    return 1
  fi
  printf '%s\n' "$registry"
}

# config_notes_paths <cfg> <image_dir>: prints the release-notes paths, one
# per line; the image directory when notes-paths is absent or empty.
config_notes_paths() {
  local cfg="$1" image_dir="$2" paths
  if ! paths="$(yq -r '.["notes-paths"] // [] | .[]' "$cfg")"; then
    echo "notes-paths in $cfg must be a list of paths." >&2
    return 1
  fi
  if [[ -z "$paths" ]]; then
    paths="$image_dir"
  fi
  printf '%s\n' "$paths"
}

# --- Registry lookups ---

# classify_ecr_lookup <exit_status> <stderr>: present|absent|error
classify_ecr_lookup() {
  local status="$1" stderr="$2"
  if [[ "$status" -eq 0 ]]; then
    echo "present"
  elif [[ "$stderr" == *ImageNotFoundException* ]]; then
    echo "absent"
  else
    echo "error"
  fi
}

# classify_ghcr_lookup <exit_status> <stderr> <ref>: present|absent|error.
# `docker buildx imagetools inspect` reports both a missing tag and a missing
# package (when logged in) as "ERROR: <ref>: not found"; anything else,
# including a rejected token, is an error.
classify_ghcr_lookup() {
  local status="$1" stderr="$2" ref="$3"
  while [[ "$stderr" == *$'\n' ]]; do
    stderr="${stderr%$'\n'}"
  done
  if [[ "$status" -eq 0 ]]; then
    echo "present"
  elif [[ -n "$ref" && "$stderr" == *"$ref: not found" ]]; then
    echo "absent"
  else
    echo "error"
  fi
}

# --- Release notes ---

# validate_notes_limit <limit>
# Succeeds for an empty limit (no cap) or a positive integer.
validate_notes_limit() {
  local limit="$1"
  if [[ -n "$limit" && ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
    echo "first-publish-notes-limit must be a positive integer; got '$limit'." >&2
    return 1
  fi
}

# release_notes <repository> <version> <sha> <previous_tag> <limit> <path>...
# Prints the release notes. With no previous tag and a non-empty limit, the
# commit list is capped at <limit> and says so when it was cut short.
release_notes() {
  local repository="$1" version="$2" sha="$3" previous_tag="$4" limit="$5"
  shift 5
  local paths=("$@")
  local joined
  joined="$(printf '%s, ' "${paths[@]}")"
  joined="${joined%, }"

  validate_notes_limit "$limit" || return 1

  local range=()
  local cap=()
  local capped=false
  if [[ -n "$previous_tag" ]]; then
    range=("$previous_tag..HEAD")
  elif [[ -n "$limit" ]]; then
    local total
    total="$(git rev-list --count --no-merges HEAD -- "${paths[@]}")" || return 1
    cap=(-n "$limit")
    if [[ "$total" -gt "$limit" ]]; then
      capped=true
    fi
  fi

  echo "Image \`$repository\` version \`$version\`."
  echo
  echo "Pushed tags: \`$version\`, \`latest\`, \`$sha\`."
  echo
  echo "## Changes to $joined"
  echo
  git log --no-merges "${cap[@]}" --pretty='- %s (%h)' "${range[@]}" -- "${paths[@]}" || return 1
  if [[ "$capped" == true ]]; then
    echo
    echo "Showing the last $limit commits."
  fi
}

# --- Summary ---

# publish_summary: prints the step summary from the summary subcommand's env.
publish_summary() {
  local image="${INPUT_IMAGE:?INPUT_IMAGE must be set}"
  local version="${INPUT_VERSION:?INPUT_VERSION must be set}"
  local previous_version="${INPUT_PREVIOUS_VERSION:-}"
  local image_ref="${IMAGE_REF:?IMAGE_REF must be set}"
  local registry="${REGISTRY:?REGISTRY must be set}"
  local first_publish="${FIRST_PUBLISH:?FIRST_PUBLISH must be set}"
  local platforms="${PLATFORMS:?PLATFORMS must be set}"
  local release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
  local sha="${GITHUB_SHA:?GITHUB_SHA must be set}"
  local repository
  repository="$(repository_name "${INPUT_REPOSITORY_PREFIX:-}" "$image")"

  echo "## Published $repository:$version"
  echo
  echo "- Registry: \`$image_ref\`"
  echo "- Tags: \`$version\`, \`latest\`, \`$sha\`"
  echo "- Platforms: \`$platforms\`"
  echo "- Git tag / Release: \`$release_tag\`"
  if [[ -n "$previous_version" ]]; then
    echo "- Previous tag: \`$(release_tag_for "$image" "$previous_version")\`"
  fi
  if [[ "$registry" == "ghcr" && "$first_publish" == "true" ]]; then
    echo "- First publish to GHCR: if this push created the package, it is PRIVATE. Make it public in the package settings (Package settings → Danger zone → Change visibility); this cannot be undone."
  fi
}

# --- Subcommands ---

cmd_prepare() {
  local image="${INPUT_IMAGE:-}" version="${INPUT_VERSION:-}"
  local previous_version="${INPUT_PREVIOUS_VERSION:-}"
  local images_root="${INPUT_IMAGES_ROOT:-}"
  local default_config="${INPUT_DEFAULT_BUILD_CONFIG:-}"
  local role_arn="${INPUT_AWS_ROLE_ARN:-}"

  [[ -n "$version" ]] || die "version is required."
  [[ -n "$images_root" ]] || die "images-root is required."
  validate_image "$image" || exit 1
  require_full_history || exit 1

  local dockerfile release_tag first_publish image_dir cfg platforms registry
  dockerfile="$(dockerfile_path "$images_root" "$image")" || exit 1
  release_tag="$(release_tag_for "$image" "$version")"
  require_new_release_tag "$release_tag" || exit 1
  first_publish="$(publish_history "$image" "$previous_version")" || exit 1

  image_dir="${images_root%/}/$image"
  cfg="$(resolve_config "$image_dir" "$default_config")" || exit 1
  echo "Using build config: $cfg"
  platforms="$(config_platforms "$cfg")" || exit 1
  registry="$(config_registry "$cfg")" || exit 1
  # Fail before the build, not at release time, on a malformed notes-paths
  # or notes limit: after the push, a re-run would trip the registry
  # pre-flight.
  config_notes_paths "$cfg" "$image_dir" >/dev/null || exit 1
  validate_notes_limit "${INPUT_FIRST_PUBLISH_NOTES_LIMIT:-}" || exit 1
  if [[ "$registry" == "ecr" && -z "$role_arn" ]]; then
    die "aws-role-arn is required for an ECR image (registry: ecr in $cfg)."
  fi

  write_output config "$cfg"
  write_output dockerfile "$dockerfile"
  write_output first_publish "$first_publish"
  write_output platforms "$platforms"
  write_output registry "$registry"
  write_output release_tag "$release_tag"
}

cmd_preflight() {
  local image="${INPUT_IMAGE:?INPUT_IMAGE must be set}"
  local version="${INPUT_VERSION:?INPUT_VERSION must be set}"
  local registry="${REGISTRY:?REGISTRY must be set}"
  local repository image_ref
  repository="$(repository_name "${INPUT_REPOSITORY_PREFIX:-}" "$image")"
  image_ref="$(image_ref_for "$registry" "${ECR_REGISTRY:-}" "${OWNER:-}" "$repository")" || exit 1

  local status=0 stderr result
  case "$registry" in
    ecr)
      stderr="$(aws ecr describe-repositories --repository-names "$repository" 2>&1 >/dev/null)" || status=$?
      if [[ "$status" -ne 0 ]]; then
        echo "ECR repository '$repository' does not exist (or could not be read):" >&2
        echo "$stderr" >&2
        die "Create the ECR repository '$repository', then re-run."
      fi
      stderr="$(aws ecr describe-images --repository-name "$repository" \
        --image-ids "imageTag=$version" 2>&1 >/dev/null)" || status=$?
      result="$(classify_ecr_lookup "$status" "$stderr")"
      ;;
    ghcr)
      stderr="$(docker buildx imagetools inspect "$image_ref:$version" 2>&1 >/dev/null)" || status=$?
      result="$(classify_ghcr_lookup "$status" "$stderr" "$image_ref:$version")"
      ;;
  esac

  case "$result" in
    present)
      die "Version $version is already published as $image_ref:$version; refusing to overwrite it."
      ;;
    absent)
      echo "$image_ref:$version is not yet published."
      ;;
    *)
      echo "Could not tell whether $image_ref:$version already exists:" >&2
      die "$stderr"
      ;;
  esac

  write_output image_ref "$image_ref"
}

cmd_release() {
  local image="${INPUT_IMAGE:?INPUT_IMAGE must be set}"
  local version="${INPUT_VERSION:?INPUT_VERSION must be set}"
  local previous_version="${INPUT_PREVIOUS_VERSION:-}"
  local images_root="${INPUT_IMAGES_ROOT:?INPUT_IMAGES_ROOT must be set}"
  local limit="${INPUT_FIRST_PUBLISH_NOTES_LIMIT:-}"
  local cfg="${CONFIG:?CONFIG must be set}"
  local release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
  local sha="${GITHUB_SHA:?GITHUB_SHA must be set}"

  local repository previous_release_tag="" notes_file
  local paths=()
  repository="$(repository_name "${INPUT_REPOSITORY_PREFIX:-}" "$image")"
  if [[ -n "$previous_version" ]]; then
    previous_release_tag="$(release_tag_for "$image" "$previous_version")"
  fi
  mapfile -t paths < <(config_notes_paths "$cfg" "${images_root%/}/$image")
  [[ "${#paths[@]}" -gt 0 ]] || die "Could not resolve notes-paths from $cfg."

  notes_file="$(mktemp)"
  release_notes "$repository" "$version" "$sha" "$previous_release_tag" "$limit" "${paths[@]}" \
    > "$notes_file" || exit 1

  # `gh release create` creates the tag on --target if it doesn't already
  # exist, so a separate git tag/push step would race.
  gh release create "$release_tag" \
    --title "$release_tag" \
    --target "$sha" \
    --notes-file "$notes_file"
}

cmd_summary() {
  local summary
  summary="$(publish_summary)" || exit 1
  printf '%s\n' "$summary" >> "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY must be set}"
}

main() {
  local subcommand="${1:-}"
  case "$subcommand" in
    prepare) cmd_prepare ;;
    preflight) cmd_preflight ;;
    release) cmd_release ;;
    summary) cmd_summary ;;
    *) die "usage: $(basename "$0") <prepare|preflight|release|summary>" ;;
  esac
}

# Source guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
