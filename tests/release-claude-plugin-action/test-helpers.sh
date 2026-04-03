#!/usr/bin/env bash
set -o nounset -o pipefail

# ---------------------------------------------------------------------------
# Test counters
# ---------------------------------------------------------------------------
TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Result reporters
# ---------------------------------------------------------------------------
pass() {
  local message="${1:-(no message)}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '\033[32m✓\033[0m %s\n' "$message"
}

fail() {
  local message="${1:-(no message)}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '\033[31m✗\033[0m %s\n' "$message"
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-assert_equals}"
  if [[ "$expected" == "$actual" ]]; then
    pass "$message"
  else
    fail "$message (expected: '$expected', actual: '$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-assert_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (expected '$haystack' to contain '$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-assert_not_contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (expected '$haystack' NOT to contain '$needle')"
  fi
}

assert_file_exists() {
  local path="$1"
  local message="${2:-assert_file_exists}"
  if [[ -f "$path" ]]; then
    pass "$message"
  else
    fail "$message (file does not exist: '$path')"
  fi
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local message="${3:-assert_file_contains}"
  if [[ ! -f "$path" ]]; then
    fail "$message (file does not exist: '$path')"
    return
  fi
  local contents
  contents="$(cat "$path")"
  if [[ "$contents" == *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (file '$path' does not contain '$needle')"
  fi
}

assert_exit_code() {
  local expected_code="$1"
  local message="$2"
  shift 2
  local actual_code=0
  "$@" || actual_code=$?
  if [[ "$actual_code" -eq "$expected_code" ]]; then
    pass "$message"
  else
    fail "$message (expected exit code $expected_code, got $actual_code)"
  fi
}

# ---------------------------------------------------------------------------
# Temp directory management
# ---------------------------------------------------------------------------
setup_temp_dir() {
  TEMP_DIR="$(mktemp -d)"
  echo "$TEMP_DIR"
}

cleanup_temp_dir() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
    unset TEMP_DIR
  fi
}

# ---------------------------------------------------------------------------
# Temp git repo utilities
# ---------------------------------------------------------------------------
setup_temp_repo() {
  TEMP_REPO="$(mktemp -d)"
  git -C "$TEMP_REPO" init --quiet
  git -C "$TEMP_REPO" config user.name "Test User"
  git -C "$TEMP_REPO" config user.email "test@example.com"
  touch "$TEMP_REPO/.gitkeep"
  git -C "$TEMP_REPO" add .gitkeep
  git -C "$TEMP_REPO" commit --quiet -m "Initial commit"
  echo "$TEMP_REPO"
}

setup_temp_repo_with_remote() {
  TEMP_REMOTE="$(mktemp -d)"
  git -C "$TEMP_REMOTE" init --quiet --bare

  TEMP_REPO="$(mktemp -d)"
  git clone --quiet "$TEMP_REMOTE" "$TEMP_REPO"
  git -C "$TEMP_REPO" config user.name "Test User"
  git -C "$TEMP_REPO" config user.email "test@example.com"
  touch "$TEMP_REPO/.gitkeep"
  git -C "$TEMP_REPO" add .gitkeep
  git -C "$TEMP_REPO" commit --quiet -m "Initial commit"
  git -C "$TEMP_REPO" push --quiet origin HEAD
  echo "$TEMP_REPO"
}

cleanup_temp_repo() {
  if [[ -n "${TEMP_REPO:-}" && -d "$TEMP_REPO" ]]; then
    rm -rf "$TEMP_REPO"
    unset TEMP_REPO
  fi
  if [[ -n "${TEMP_REMOTE:-}" && -d "$TEMP_REMOTE" ]]; then
    rm -rf "$TEMP_REMOTE"
    unset TEMP_REMOTE
  fi
}

# ---------------------------------------------------------------------------
# Fixture creators
# ---------------------------------------------------------------------------
create_plugin_fixture() {
  local dir="$1"
  local name="$2"
  local version="$3"

  mkdir -p "$dir/.claude-plugin"
  cat > "$dir/.claude-plugin/plugin.json" <<PLUGIN_JSON
{"name": "$name", "version": "$version", "description": "Test plugin", "keywords": ["test"]}
PLUGIN_JSON

  mkdir -p "$dir/skills/test-skill"
  cat > "$dir/skills/test-skill/SKILL.md" <<'SKILL_MD'
---
name: test-skill
description: A test skill
---
# Test Skill
Content here.
SKILL_MD
}

create_marketplace_fixture() {
  local dir="$1"

  mkdir -p "$dir/.claude-plugin"
  cat > "$dir/.claude-plugin/marketplace.json" <<'MARKETPLACE_JSON'
{"name": "test-marketplace", "owner": {"name": "Test", "url": "https://example.com"}, "metadata": {"description": "Test marketplace", "repository": "https://example.com/repo"}}
MARKETPLACE_JSON
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
run_tests() {
  local test_functions
  test_functions="$(declare -F | awk '{print $3}' | grep '^test_' || true)"

  if [[ -z "$test_functions" ]]; then
    echo ""
    echo "=============================="
    printf 'Tests run: 0 | \033[32mPassed: 0\033[0m | \033[31mFailed: 0\033[0m\n'
    echo "=============================="
    exit 0
  fi

  local total=0
  TESTS_PASSED=0
  TESTS_FAILED=0
  for test_fn in $test_functions; do
    total=$((total + 1))
    echo "--- $test_fn ---"
    # Run in subshell to isolate side effects; capture output and exit code
    local output=""
    local subshell_exit=0
    output=$("$test_fn" 2>&1) || subshell_exit=$?
    echo "$output"
    # Count pass/fail based on whether the test function succeeded
    if [[ $subshell_exit -eq 0 ]]; then
      TESTS_PASSED=$((TESTS_PASSED + 1))
    else
      TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    # Always clean up
    cleanup_temp_dir 2>/dev/null || true
    cleanup_temp_repo 2>/dev/null || true
  done

  echo ""
  echo "=============================="
  printf 'Tests run: %d | \033[32mPassed: %d\033[0m | \033[31mFailed: %d\033[0m\n' \
    "$total" "$TESTS_PASSED" "$TESTS_FAILED"
  echo "=============================="

  if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
