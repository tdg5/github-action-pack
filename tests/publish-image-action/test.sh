#!/usr/bin/env bash
# Unit tests for actions/docker/publish-image-action/publish-image.sh.
#
# Sources the script (its main is source-guarded) and drives its functions
# directly; the subcommands run against temporary git repo fixtures with stub
# aws, docker and gh executables first on PATH.

set -o nounset -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../../actions/docker/publish-image-action/publish-image.sh"

# shellcheck source=tests/publish-image-action/test-helpers.sh
source "$TEST_DIR/test-helpers.sh"
# shellcheck source=actions/docker/publish-image-action/publish-image.sh
source "$SCRIPT" || exit 1
# The script sets errexit for its own runs; the tests handle failures
# themselves so that every assertion reports.
set +o errexit

# Hermetic git: ignore the user's global config (signing, hooks, templates).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com"

# The two GHCR lookup errors captured in the plan's Operator step 0
# (docker buildx imagetools inspect, authenticated, exit 1), verbatim.
GHCR_MISSING_TAG_REF="ghcr.io/tdg5/ax/ax-task-runner:0.0.0-does-not-exist"
GHCR_MISSING_TAG_STDERR="ERROR: ghcr.io/tdg5/ax/ax-task-runner:0.0.0-does-not-exist: not found"
GHCR_MISSING_PACKAGE_REF="ghcr.io/tdg5/does-not-exist/nope:0.0.0"
GHCR_MISSING_PACKAGE_STDERR="ERROR: ghcr.io/tdg5/does-not-exist/nope:0.0.0: not found"
# The anonymous (rejected token) case, which must stay an error.
GHCR_FORBIDDEN_STDERR="ERROR: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Atdg5%2Fdoes-not-exist%2Fnope%3Apull&service=ghcr.io: 403 Forbidden"

ECR_NOT_FOUND_STDERR="An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageDigest:'null', imageTag:'1.0.0'} does not exist within the repository with name 'tdg5/hello' in the registry with id '123456789012'"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# commit_file <path> <subject>: writes a line to path and commits it.
commit_file() {
  mkdir -p "$(dirname "$1")"
  echo "$2" >> "$1"
  git add "$1"
  git commit -q -m "$2"
}

# make_fixture_repo: creates $TEMP_DIR/repo, cds into it. It has a default
# build config, an ECR image tdg5/hello with no build-config.yaml, and a GHCR
# image tdg5/ghcr-thing with its own build-config.yaml.
make_fixture_repo() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/repo"
  cd "$TEMP_DIR/repo" || return 1
  git init -q -b main
  mkdir -p config images/tdg5/hello images/tdg5/ghcr-thing
  cat > config/default-build-config.yaml <<'YAML'
platforms:
  - linux/amd64
  - linux/arm64
YAML
  echo "FROM scratch" > images/tdg5/hello/Dockerfile
  echo "FROM scratch" > images/tdg5/ghcr-thing/Dockerfile
  cat > images/tdg5/ghcr-thing/build-config.yaml <<'YAML'
platforms:
  - linux/amd64
registry: ghcr
YAML
  git add -A
  git commit -q -m "Initial commit"
}

# make_stubs: puts stub aws, docker and gh executables first on PATH.
# aws: describe-repositories fails when STUB_AWS_REPO_EXISTS=false;
#      describe-images prints STUB_AWS_IMAGES_STDERR and exits STUB_AWS_IMAGES_EXIT.
# docker: prints STUB_DOCKER_STDERR and exits STUB_DOCKER_EXIT.
# gh: appends one line per call to $TEMP_DIR/gh-calls and copies the
#     --notes-file to $TEMP_DIR/gh-notes.
make_stubs() {
  mkdir -p "$TEMP_DIR/bin"
  cat > "$TEMP_DIR/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$STUB_DIR/aws-calls"
case "$2" in
  describe-repositories)
    if [[ "${STUB_AWS_REPO_EXISTS:-true}" != true ]]; then
      echo "An error occurred (RepositoryNotFoundException) when calling the DescribeRepositories operation" >&2
      exit 254
    fi
    ;;
  describe-images)
    printf '%s\n' "${STUB_AWS_IMAGES_STDERR:-}" >&2
    exit "${STUB_AWS_IMAGES_EXIT:-0}"
    ;;
esac
STUB
  cat > "$TEMP_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_DIR/docker-calls"
printf '%s\n' "${STUB_DOCKER_STDERR:-}" >&2
exit "${STUB_DOCKER_EXIT:-0}"
STUB
  cat > "$TEMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh-calls"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--notes-file" ]]; then
    cp "$2" "$STUB_DIR/gh-notes"
  fi
  shift
done
STUB
  chmod +x "$TEMP_DIR/bin/aws" "$TEMP_DIR/bin/docker" "$TEMP_DIR/bin/gh"
  export STUB_DIR="$TEMP_DIR"
  export PATH="$TEMP_DIR/bin:$PATH"
}

# infra_notes: infra publish-image.yaml:192-205, verbatim, for comparison.
# The uppercase names are set by the caller, as infra's job env set them.
# shellcheck disable=SC2153
infra_notes() {
  notes_file="$(mktemp)"
  {
    echo "Image \`$IMAGE\` version \`$VERSION\`."
    echo
    echo "Pushed tags: \`$VERSION\`, \`latest\`, \`$GITHUB_SHA\`."
    echo
    echo "## Changes to $IMAGE_DIR"
    echo
    if [ -n "$PREVIOUS_VERSION" ]; then
      git log --no-merges --pretty='- %s (%h)' "$PREVIOUS_RELEASE_TAG..HEAD" -- "$IMAGE_DIR"
    else
      git log --no-merges --pretty='- %s (%h)' -- "$IMAGE_DIR"
    fi
  } > "$notes_file"
  cat "$notes_file"
  rm -f "$notes_file"
}

# infra_summary: infra publish-image.yaml:226-239, verbatim apart from the
# platforms expression, which reads $PLATFORMS. The caller sets the env.
# shellcheck disable=SC2153
infra_summary() {
  {
    echo "## Published $IMAGE:$VERSION"
    echo
    echo "- Registry: \`$IMAGE_REF\`"
    echo "- Tags: \`$VERSION\`, \`latest\`, \`$GITHUB_SHA\`"
    echo "- Platforms: \`$PLATFORMS\`"
    echo "- Git tag / Release: \`$RELEASE_TAG\`"
    if [ -n "$PREVIOUS_VERSION" ]; then
      echo "- Previous tag: \`$PREVIOUS_RELEASE_TAG\`"
    fi
    if [ "$REGISTRY" = "ghcr" ] && [ "$FIRST_PUBLISH" = "true" ]; then
      echo "- First publish to GHCR: the package was created PRIVATE. Make it public in the package settings (Package settings → Danger zone → Change visibility); this cannot be undone."
    fi
  }
}

# ---------------------------------------------------------------------------
# Image validation (D9)
# ---------------------------------------------------------------------------

test_validate_image_accepts_valid_names() {
  local image
  for image in tdg5/hello jig a.b/c-d; do
    assert_succeeds "validate_image accepts '$image'" validate_image "$image"
  done
}

test_validate_image_rejects_invalid_names() {
  local image
  for image in Tdg5/x x//y /x x/ ../x ""; do
    assert_fails "validate_image rejects '$image'" validate_image "$image"
  done
}

test_dockerfile_path_requires_a_dockerfile() {
  make_fixture_repo
  assert_succeeds "Dockerfile found for tdg5/hello" dockerfile_path images tdg5/hello
  assert_equals "images/tdg5/hello/Dockerfile" "$ASSERT_OUTPUT" "Dockerfile path"
  assert_fails "missing Dockerfile fails" dockerfile_path images tdg5/nope
  assert_contains "$ASSERT_OUTPUT" "images/tdg5/nope/Dockerfile" "error names the path"
  assert_fails "one-segment name has no Dockerfile in a two-level layout" dockerfile_path images tdg5
}

# ---------------------------------------------------------------------------
# Config resolution (D12, D15)
# ---------------------------------------------------------------------------

test_resolve_config_prefers_per_image_file() {
  make_fixture_repo
  assert_equals "images/tdg5/ghcr-thing/build-config.yaml" \
    "$(resolve_config images/tdg5/ghcr-thing config/default-build-config.yaml)" \
    "per-image build-config.yaml wins"
  assert_equals "linux/amd64" "$(config_platforms images/tdg5/ghcr-thing/build-config.yaml)" \
    "per-image config is used wholesale, not merged"
}

test_resolve_config_falls_back_to_default() {
  make_fixture_repo
  assert_equals "config/default-build-config.yaml" \
    "$(resolve_config images/tdg5/hello config/default-build-config.yaml)" \
    "default used when per-image file is absent"
  assert_fails "no per-image file and empty default fails" resolve_config images/tdg5/hello ""
  assert_fails "no per-image file and missing default fails" resolve_config images/tdg5/hello config/nope.yaml
}

test_config_platforms_joins() {
  make_fixture_repo
  assert_equals "linux/amd64,linux/arm64" "$(config_platforms config/default-build-config.yaml)" \
    "platforms joined with commas"
  echo "registry: ecr" > "$TEMP_DIR/no-platforms.yaml"
  assert_fails "missing platforms fails" config_platforms "$TEMP_DIR/no-platforms.yaml"
}

test_config_registry() {
  make_fixture_repo
  assert_equals "ecr" "$(config_registry config/default-build-config.yaml)" "missing registry is ecr"
  assert_equals "ghcr" "$(config_registry images/tdg5/ghcr-thing/build-config.yaml)" "registry ghcr"
  printf 'platforms: [linux/amd64]\nregistry: quay\n' > "$TEMP_DIR/quay.yaml"
  assert_fails "registry quay fails" config_registry "$TEMP_DIR/quay.yaml"
  assert_contains "$ASSERT_OUTPUT" "quay" "error names the bad registry"
}

test_config_notes_paths() {
  make_fixture_repo
  assert_equals "images/tdg5/hello" "$(config_notes_paths config/default-build-config.yaml images/tdg5/hello)" \
    "notes-paths defaults to the image directory"
  printf 'platforms: [linux/amd64]\nnotes-paths:\n  - src\n  - deploy/hello\n' > "$TEMP_DIR/paths.yaml"
  assert_equals $'src\ndeploy/hello' "$(config_notes_paths "$TEMP_DIR/paths.yaml" images/tdg5/hello)" \
    "a two-entry list comes back as two paths"
}

# ---------------------------------------------------------------------------
# Publish history (R6, D13)
# ---------------------------------------------------------------------------

test_require_new_release_tag() {
  make_fixture_repo
  git tag tdg5/hello/v1.0.0
  assert_fails "existing release tag fails" require_new_release_tag tdg5/hello/v1.0.0
  assert_contains "$ASSERT_OUTPUT" "tdg5/hello/v1.0.0" "error names the tag"
  assert_succeeds "new release tag passes" require_new_release_tag tdg5/hello/v1.1.0
}

test_publish_history_first_publish() {
  make_fixture_repo
  git tag tdg5/hello-other/v1.0.0
  assert_equals "true" "$(publish_history tdg5/hello "")" "no <image>/v* tag is a first publish"
}

test_publish_history_requires_previous_version() {
  make_fixture_repo
  git tag tdg5/hello/v1.0.0
  git tag tdg5/hello/v1.1.0
  assert_fails "prior tags with empty previous version fails" publish_history tdg5/hello ""
  assert_contains "$ASSERT_OUTPUT" "tdg5/hello/v1.0.0" "error names the first tag"
  assert_contains "$ASSERT_OUTPUT" "tdg5/hello/v1.1.0" "error names the second tag"
  assert_equals "false" "$(publish_history tdg5/hello 1.1.0)" "with previous version it is not a first publish"
}

test_publish_history_requires_previous_tag() {
  make_fixture_repo
  git tag tdg5/hello/v1.0.0
  assert_fails "missing previous tag fails" publish_history tdg5/hello 0.9.0
  assert_contains "$ASSERT_OUTPUT" "tdg5/hello/v0.9.0" "error names the missing tag"
}

test_require_full_history_rejects_shallow_clone() {
  make_fixture_repo
  commit_file images/tdg5/hello/a "second"
  assert_succeeds "full clone passes" require_full_history
  git clone -q --depth 1 "file://$TEMP_DIR/repo" "$TEMP_DIR/shallow"
  cd "$TEMP_DIR/shallow" || return 1
  assert_fails "shallow clone fails" require_full_history
  assert_contains "$ASSERT_OUTPUT" "fetch-depth: 0" "error says how to fix it"
}

# ---------------------------------------------------------------------------
# Names (D8)
# ---------------------------------------------------------------------------

test_names() {
  assert_equals "tdg5/hello" "$(repository_name "" tdg5/hello)" "empty prefix repository"
  assert_equals "tdg5/hello/v1.0.0" "$(release_tag_for tdg5/hello 1.0.0)" "empty prefix tag"
  assert_equals "jig/jig-verify" "$(repository_name jig/ jig-verify)" "prefixed repository"
  assert_equals "jig-verify/v1.0.0" "$(release_tag_for jig-verify 1.0.0)" "tag ignores the prefix"
  assert_equals "ghcr.io/tdg5/jig/jig-verify" "$(image_ref_for ghcr "" tdg5 jig/jig-verify)" "GHCR ref"
  assert_equals "123.dkr.ecr.us-east-1.amazonaws.com/tdg5/hello" \
    "$(image_ref_for ecr 123.dkr.ecr.us-east-1.amazonaws.com tdg5 tdg5/hello)" "ECR ref"
}

# ---------------------------------------------------------------------------
# Registry lookup classification (R3, D21)
# ---------------------------------------------------------------------------

test_classify_ecr_lookup() {
  assert_equals "present" "$(classify_ecr_lookup 0 "")" "ECR exit 0 is present"
  assert_equals "absent" "$(classify_ecr_lookup 254 "$ECR_NOT_FOUND_STDERR")" "ImageNotFoundException is absent"
  assert_equals "error" "$(classify_ecr_lookup 254 "An error occurred (AccessDeniedException)")" "other failure is error"
  assert_equals "error" "$(classify_ecr_lookup 255 "")" "silent failure is error"
}

test_classify_ghcr_lookup() {
  assert_equals "present" "$(classify_ghcr_lookup 0 "" "$GHCR_MISSING_TAG_REF")" "GHCR exit 0 is present"
  assert_equals "absent" "$(classify_ghcr_lookup 1 "$GHCR_MISSING_TAG_STDERR" "$GHCR_MISSING_TAG_REF")" \
    "captured missing-tag text is absent"
  assert_equals "absent" "$(classify_ghcr_lookup 1 "$GHCR_MISSING_PACKAGE_STDERR" "$GHCR_MISSING_PACKAGE_REF")" \
    "captured missing-package text is absent"
  assert_equals "absent" "$(classify_ghcr_lookup 1 "$GHCR_MISSING_TAG_STDERR"$'\n' "$GHCR_MISSING_TAG_REF")" \
    "trailing newline is tolerated"
  assert_equals "error" "$(classify_ghcr_lookup 1 "$GHCR_FORBIDDEN_STDERR" "$GHCR_MISSING_PACKAGE_REF")" \
    "rejected token (403) is error"
  assert_equals "error" "$(classify_ghcr_lookup 1 "$GHCR_MISSING_TAG_STDERR" "$GHCR_MISSING_PACKAGE_REF")" \
    "not found for a different ref is error"
  assert_equals "error" "$(classify_ghcr_lookup 1 "" "$GHCR_MISSING_TAG_REF")" "silent failure is error"
}

# ---------------------------------------------------------------------------
# preflight subcommand (R3, D10)
# ---------------------------------------------------------------------------

preflight_env() {
  export INPUT_IMAGE="$1" INPUT_REPOSITORY_PREFIX="$2" INPUT_VERSION="1.0.0" REGISTRY="$3"
  export ECR_REGISTRY="123.dkr.ecr.us-east-1.amazonaws.com" OWNER="tdg5"
  export GITHUB_OUTPUT="$TEMP_DIR/github-output"
  : > "$GITHUB_OUTPUT"
}

test_preflight_ecr() {
  setup_temp_dir
  make_stubs
  preflight_env tdg5/hello "" ecr

  export STUB_AWS_IMAGES_EXIT=0 STUB_AWS_IMAGES_STDERR=""
  assert_fails "ECR present fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "1.0.0" "present error names the version"

  export STUB_AWS_IMAGES_EXIT=254 STUB_AWS_IMAGES_STDERR="$ECR_NOT_FOUND_STDERR"
  : > "$GITHUB_OUTPUT"
  assert_succeeds "ECR absent passes" "$SCRIPT" preflight
  assert_equals "image_ref=123.dkr.ecr.us-east-1.amazonaws.com/tdg5/hello" "$(cat "$GITHUB_OUTPUT")" \
    "ECR absent writes image_ref"
  assert_contains "$(cat "$TEMP_DIR/aws-calls")" "--image-ids imageTag=1.0.0" "describe-images asks for the version tag"

  export STUB_AWS_IMAGES_EXIT=254 STUB_AWS_IMAGES_STDERR="An error occurred (AccessDeniedException)"
  assert_fails "ECR error fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "AccessDeniedException" "error shows the lookup's stderr"

  export STUB_AWS_REPO_EXISTS=false STUB_AWS_IMAGES_EXIT=254 STUB_AWS_IMAGES_STDERR="$ECR_NOT_FOUND_STDERR"
  assert_fails "missing ECR repository fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "'tdg5/hello'" "error names the repository"
  assert_not_contains "$ASSERT_OUTPUT" "container-registry" "error does not name infra's Terraform root"
}

test_preflight_ecr_prefixed_repository() {
  setup_temp_dir
  make_stubs
  preflight_env jig-verify jig/ ecr
  export STUB_AWS_REPO_EXISTS=false
  assert_fails "missing prefixed repository fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "'jig/jig-verify'" "error names the prefixed repository"
}

test_preflight_ghcr() {
  setup_temp_dir
  make_stubs
  preflight_env jig-verify jig/ ghcr

  export STUB_DOCKER_EXIT=0 STUB_DOCKER_STDERR=""
  assert_fails "GHCR present fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "1.0.0" "present error names the version"
  assert_contains "$(cat "$TEMP_DIR/docker-calls")" \
    "docker buildx imagetools inspect ghcr.io/tdg5/jig/jig-verify:1.0.0" "inspects <ref>:<version>"

  export STUB_DOCKER_EXIT=1 STUB_DOCKER_STDERR="ERROR: ghcr.io/tdg5/jig/jig-verify:1.0.0: not found"
  : > "$GITHUB_OUTPUT"
  assert_succeeds "GHCR absent passes" "$SCRIPT" preflight
  assert_equals "image_ref=ghcr.io/tdg5/jig/jig-verify" "$(cat "$GITHUB_OUTPUT")" "GHCR absent writes image_ref"

  export STUB_DOCKER_EXIT=1 STUB_DOCKER_STDERR="$GHCR_FORBIDDEN_STDERR"
  assert_fails "GHCR error fails" "$SCRIPT" preflight
  assert_contains "$ASSERT_OUTPUT" "403 Forbidden" "error shows the lookup's stderr"
}

# ---------------------------------------------------------------------------
# Release notes (R4, R8, R11, D18, D22)
# ---------------------------------------------------------------------------

# make_notes_fixture: fixture repo with commits in and out of tdg5/hello and
# a tag tdg5/hello/v1.0.0 between them.
make_notes_fixture() {
  make_fixture_repo
  commit_file images/tdg5/hello/a "hello one"
  commit_file images/tdg5/other/a "other one"
  git tag tdg5/hello/v1.0.0
  commit_file images/tdg5/hello/a "hello two"
  commit_file src/main.c "src one"
  commit_file images/tdg5/other/a "other two"
  commit_file images/tdg5/hello/b "hello three"
}

test_release_notes_match_infra() {
  make_notes_fixture
  local sha
  sha="$(git rev-parse HEAD)"

  local expected actual
  expected="$(IMAGE=tdg5/hello VERSION=1.1.0 GITHUB_SHA=$sha IMAGE_DIR=images/tdg5/hello \
    PREVIOUS_VERSION=1.0.0 PREVIOUS_RELEASE_TAG=tdg5/hello/v1.0.0 infra_notes; echo x)"
  actual="$(release_notes tdg5/hello 1.1.0 "$sha" tdg5/hello/v1.0.0 "" images/tdg5/hello; echo x)"
  assert_equals "$expected" "$actual" "notes with a previous tag are byte-identical to infra's"
  assert_contains "$actual" "- hello two ($(git rev-parse --short HEAD~3))" "line is '- <subject> (<short sha>)'"
  assert_not_contains "$actual" "hello one" "bounded by the previous tag"
  assert_not_contains "$actual" "src one" "only commits touching notes-paths"

  expected="$(IMAGE=tdg5/hello VERSION=1.1.0 GITHUB_SHA=$sha IMAGE_DIR=images/tdg5/hello \
    PREVIOUS_VERSION="" PREVIOUS_RELEASE_TAG=tdg5/hello/v infra_notes; echo x)"
  actual="$(release_notes tdg5/hello 1.1.0 "$sha" "" "" images/tdg5/hello; echo x)"
  assert_equals "$expected" "$actual" "first-publish notes are byte-identical to infra's"
  assert_contains "$actual" "hello one" "no previous tag means full history"
}

test_release_notes_prefix_and_paths() {
  make_notes_fixture
  local actual
  actual="$(release_notes jig/hello 1.1.0 abc tdg5/hello/v1.0.0 "" images/tdg5/hello src)"
  assert_contains "$actual" "Image \`jig/hello\` version \`1.1.0\`." "preamble names the published repository"
  assert_contains "$actual" "## Changes to images/tdg5/hello, src" "heading joins the paths"
  assert_contains "$actual" "- src one (" "commits touching the second path appear"
  assert_contains "$actual" "- hello three (" "commits touching the first path appear"
  assert_not_contains "$actual" "other" "commits outside the paths are left out"
}

test_release_notes_first_publish_limit() {
  make_fixture_repo
  local i
  for i in 1 2 3 4 5; do
    commit_file images/tdg5/hello/a "hello $i"
  done
  local actual lines
  actual="$(release_notes tdg5/hello 1.0.0 abc "" 2 images/tdg5/hello)"
  lines="$(grep -c '^- ' <<<"$actual")"
  assert_equals "2" "$lines" "limit caps the first publish at two lines"
  assert_contains "$actual" "- hello 5 (" "the newest commits are kept"
  assert_not_contains "$actual" "- hello 3 (" "older commits are dropped"
  assert_equals "Showing the last 2 commits." "$(tail -n 1 <<<"$actual")" "notes end with the cap line"

  actual="$(release_notes tdg5/hello 1.0.0 abc "" "" images/tdg5/hello)"
  assert_equals "6" "$(grep -c '^- ' <<<"$actual")" "empty limit means no cap"
  assert_not_contains "$actual" "Showing the last" "no cap line without a limit"

  git tag tdg5/hello/v0.9.0 HEAD~4
  actual="$(release_notes tdg5/hello 1.0.0 abc tdg5/hello/v0.9.0 2 images/tdg5/hello)"
  assert_equals "4" "$(grep -c '^- ' <<<"$actual")" "limit does not apply with a previous version"
  assert_not_contains "$actual" "Showing the last" "no cap line with a previous version"

  assert_fails "a non-numeric limit fails" release_notes tdg5/hello 1.0.0 abc "" two images/tdg5/hello
}

# ---------------------------------------------------------------------------
# prepare subcommand
# ---------------------------------------------------------------------------

prepare_env() {
  export INPUT_IMAGE="$1" INPUT_VERSION="1.1.0" INPUT_PREVIOUS_VERSION="${2:-}"
  export INPUT_IMAGES_ROOT="images" INPUT_DEFAULT_BUILD_CONFIG="config/default-build-config.yaml"
  export INPUT_AWS_ROLE_ARN="arn:aws:iam::123456789012:role/test"
  export INPUT_FIRST_PUBLISH_NOTES_LIMIT=""
  export GITHUB_OUTPUT="$TEMP_DIR/github-output"
  : > "$GITHUB_OUTPUT"
}

test_prepare_ecr() {
  make_fixture_repo
  git tag tdg5/hello/v1.0.0
  prepare_env tdg5/hello 1.0.0
  assert_succeeds "prepare passes for an ECR image" "$SCRIPT" prepare
  assert_equals "config dockerfile first_publish platforms registry release_tag" \
    "$(cut -d= -f1 "$GITHUB_OUTPUT" | sort | tr '\n' ' ' | sed 's/ $//')" "output keys are exactly the contract"
  local expected
  expected="$(printf '%s\n' \
    config=config/default-build-config.yaml \
    dockerfile=images/tdg5/hello/Dockerfile \
    first_publish=false \
    platforms=linux/amd64,linux/arm64 \
    registry=ecr \
    release_tag=tdg5/hello/v1.1.0)"
  assert_equals "$expected" "$(sort "$GITHUB_OUTPUT")" "ECR output values"

  prepare_env tdg5/hello 1.0.0
  export INPUT_AWS_ROLE_ARN=""
  assert_fails "ECR with an empty aws-role-arn fails" "$SCRIPT" prepare
  assert_contains "$ASSERT_OUTPUT" "aws-role-arn" "error names the input"
}

test_prepare_ghcr() {
  make_fixture_repo
  prepare_env tdg5/ghcr-thing
  export INPUT_AWS_ROLE_ARN=""
  assert_succeeds "prepare passes for a GHCR image without a role" "$SCRIPT" prepare
  local expected
  expected="$(printf '%s\n' \
    config=images/tdg5/ghcr-thing/build-config.yaml \
    dockerfile=images/tdg5/ghcr-thing/Dockerfile \
    first_publish=true \
    platforms=linux/amd64 \
    registry=ghcr \
    release_tag=tdg5/ghcr-thing/v1.1.0)"
  assert_equals "$expected" "$(sort "$GITHUB_OUTPUT")" "GHCR output values"
}

test_prepare_guards() {
  make_fixture_repo
  git tag tdg5/hello/v1.1.0
  prepare_env tdg5/hello 1.0.0
  assert_fails "prepare refuses an existing release tag" "$SCRIPT" prepare
  assert_contains "$ASSERT_OUTPUT" "tdg5/hello/v1.1.0" "error names the tag"
  # Drop the tag so the cases below fail on their own guard, not this one.
  git tag -d tdg5/hello/v1.1.0 >/dev/null

  prepare_env Tdg5/hello
  assert_fails "prepare rejects a bad image name" "$SCRIPT" prepare

  prepare_env tdg5/nope
  assert_fails "prepare rejects a missing Dockerfile" "$SCRIPT" prepare

  prepare_env tdg5/hello
  export INPUT_DEFAULT_BUILD_CONFIG=""
  assert_fails "prepare fails with no config at all" "$SCRIPT" prepare
  assert_contains "$ASSERT_OUTPUT" "build-config" "error names the missing config"

  prepare_env tdg5/hello
  assert_succeeds "prepare passes once the guards are satisfied" "$SCRIPT" prepare

  prepare_env tdg5/hello
  export INPUT_FIRST_PUBLISH_NOTES_LIMIT=abc
  assert_fails "prepare rejects a non-numeric notes limit" "$SCRIPT" prepare
  assert_contains "$ASSERT_OUTPUT" "first-publish-notes-limit" "error names the input"
}

# ---------------------------------------------------------------------------
# release subcommand
# ---------------------------------------------------------------------------

test_release_calls_gh() {
  make_notes_fixture
  make_stubs
  export INPUT_IMAGE=tdg5/hello INPUT_REPOSITORY_PREFIX="" INPUT_VERSION=1.1.0
  export INPUT_PREVIOUS_VERSION=1.0.0 INPUT_IMAGES_ROOT=images INPUT_FIRST_PUBLISH_NOTES_LIMIT=""
  export CONFIG=config/default-build-config.yaml RELEASE_TAG=tdg5/hello/v1.1.0
  export GH_TOKEN=token GITHUB_SHA
  GITHUB_SHA="$(git rev-parse HEAD)"

  assert_succeeds "release passes" "$SCRIPT" release
  local calls
  calls="$(cat "$TEMP_DIR/gh-calls")"
  assert_equals "1" "$(wc -l < "$TEMP_DIR/gh-calls" | tr -d ' ')" "gh is called once"
  assert_contains "$calls" \
    "release create tdg5/hello/v1.1.0 --title tdg5/hello/v1.1.0 --target $GITHUB_SHA --notes-file " \
    "gh release create arguments"
  local expected
  expected="$(release_notes tdg5/hello 1.1.0 "$GITHUB_SHA" tdg5/hello/v1.0.0 "" images/tdg5/hello; echo x)"
  assert_equals "$expected" "$(cat "$TEMP_DIR/gh-notes"; echo x)" "notes file holds the expected notes"
}

# ---------------------------------------------------------------------------
# summary subcommand (R8, R12, D19, D22)
# ---------------------------------------------------------------------------

summary_env() {
  export INPUT_IMAGE="$1" INPUT_REPOSITORY_PREFIX="$2" REGISTRY="$3" FIRST_PUBLISH="$4"
  export INPUT_VERSION=1.1.0 INPUT_PREVIOUS_VERSION="${5:-}"
  export IMAGE_REF="$6" PLATFORMS=linux/amd64,linux/arm64
  export RELEASE_TAG="$1/v1.1.0" GITHUB_SHA=0123456789abcdef
  export GITHUB_STEP_SUMMARY="$TEMP_DIR/summary"
  : > "$GITHUB_STEP_SUMMARY"
}

test_summary_ecr_matches_infra() {
  setup_temp_dir
  summary_env tdg5/hello "" ecr false 1.0.0 123.dkr.ecr.us-east-1.amazonaws.com/tdg5/hello
  assert_succeeds "summary passes" "$SCRIPT" summary
  local expected
  expected="$(IMAGE=tdg5/hello VERSION=1.1.0 PREVIOUS_VERSION=1.0.0 PREVIOUS_RELEASE_TAG=tdg5/hello/v1.0.0 \
    infra_summary; echo x)"
  assert_equals "$expected" "$(cat "$GITHUB_STEP_SUMMARY"; echo x)" "ECR summary is byte-identical to infra's"
}

test_summary_prefix_names_repository() {
  setup_temp_dir
  summary_env jig-verify jig/ ecr false "" 123.dkr.ecr.us-east-1.amazonaws.com/jig/jig-verify
  "$SCRIPT" summary
  assert_equals "## Published jig/jig-verify:1.1.0" "$(head -n 1 "$GITHUB_STEP_SUMMARY")" \
    "heading names the published repository"
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "- Git tag / Release: \`jig-verify/v1.1.0\`" "release tag line"
}

test_summary_ghcr_first_publish() {
  setup_temp_dir
  summary_env tdg5/ghcr-thing "" ghcr true "" ghcr.io/tdg5/tdg5/ghcr-thing
  "$SCRIPT" summary
  local expected actual
  expected="$(IMAGE=tdg5/ghcr-thing VERSION=1.1.0 PREVIOUS_VERSION="" PREVIOUS_RELEASE_TAG="" infra_summary)"
  actual="$(cat "$GITHUB_STEP_SUMMARY")"
  assert_equals "$(head -n -1 <<<"$expected")" "$(head -n -1 <<<"$actual")" \
    "every line but the first-publish line matches infra's"
  assert_contains "$(tail -n 1 <<<"$actual")" "if this push created the package" "first-publish line is conditional"
  assert_contains "$(tail -n 1 <<<"$actual")" "PRIVATE" "first-publish line still warns about visibility"
  assert_equals "$(wc -l <<<"$expected")" "$(wc -l <<<"$actual")" "same number of lines as infra's"
}

run_tests
