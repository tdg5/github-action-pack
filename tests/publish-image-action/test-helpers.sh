#!/usr/bin/env bash
# Minimal assertion helpers and a test runner for tests/publish-image-action.
#
# Each test_* function runs in its own subshell; an assertion failure marks
# the test failed without aborting it, so every assertion reports.

TEST_FAILURES=0
TEMP_DIR=""

pass() {
  printf '  ok   %s\n' "$1"
}

fail() {
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf '  FAIL %s\n' "$1"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-assert_equals}"
  if [[ "$expected" == "$actual" ]]; then
    pass "$message"
  else
    fail "$message"
    printf '       expected: %q\n       actual:   %q\n' "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-assert_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message"
    printf '       expected %q to contain %q\n' "$haystack" "$needle"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-assert_not_contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message"
    printf '       expected %q not to contain %q\n' "$haystack" "$needle"
  fi
}

# assert_fails <message> <command...>
# Passes when the command exits non-zero. The command's combined output is
# left in ASSERT_OUTPUT so callers can check the error message.
assert_fails() {
  local message="$1"
  shift
  local status=0
  ASSERT_OUTPUT="$("$@" 2>&1)" || status=$?
  if [[ "$status" -ne 0 ]]; then
    pass "$message"
  else
    fail "$message (expected a non-zero exit, got 0)"
    printf '       output: %q\n' "$ASSERT_OUTPUT"
  fi
}

# assert_succeeds <message> <command...>
# Passes when the command exits zero; its combined output is in ASSERT_OUTPUT.
assert_succeeds() {
  local message="$1"
  shift
  local status=0
  ASSERT_OUTPUT="$("$@" 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    pass "$message"
  else
    fail "$message (exit $status)"
    printf '       output: %q\n' "$ASSERT_OUTPUT"
  fi
}

# setup_temp_dir: sets TEMP_DIR to a fresh directory, removed by the runner.
setup_temp_dir() {
  TEMP_DIR="$(mktemp -d)"
}

# run_tests: runs every test_* function in a subshell and reports failures.
run_tests() {
  local test_fn status
  local total=0
  local failed=()
  while IFS= read -r test_fn; do
    total=$((total + 1))
    echo "--- $test_fn"
    status=0
    (
      TEST_FAILURES=0
      "$test_fn"
      fn_status=$?
      if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
      fi
      if [[ "$fn_status" -ne 0 && "$TEST_FAILURES" -eq 0 ]]; then
        printf '  FAIL %s returned %d\n' "$test_fn" "$fn_status"
        exit 1
      fi
      [[ "$TEST_FAILURES" -eq 0 ]]
    ) || status=$?
    if [[ "$status" -ne 0 ]]; then
      failed+=("$test_fn")
    fi
  done < <(declare -F | awk '{print $3}' | grep '^test_')

  echo ""
  echo "Tests run: $total, failed: ${#failed[@]}"
  if [[ "${#failed[@]}" -gt 0 ]]; then
    printf '  %s\n' "${failed[@]}"
    return 1
  fi
  return 0
}
