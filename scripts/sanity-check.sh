#!/usr/bin/env bash

set -e -o pipefail

# From https://stackoverflow.com/a/4774063
REPO_DIR="$( cd -- "$(dirname "$0")/.." >/dev/null 2>&1 ; pwd -P )"
cd "$REPO_DIR"

FAILED=0

# Set up Python virtual environment
VENV_DIR="$REPO_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating Python virtual environment at .venv..."
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install -q -r "$REPO_DIR/requirements.txt"

run_check() {
  local name="$1"
  shift
  echo ""
  echo "=== ${name} ==="
  if "$@"; then
    echo "--- ${name}: PASSED ---"
  else
    echo "--- ${name}: FAILED ---"
    FAILED=1
  fi
}

run_check "TypeScript type check" pnpm exec tsc --noEmit -p packages/toolkit/tsconfig.json
run_check "TypeScript type check (test-toolkit)" pnpm exec tsc --noEmit -p packages/test-toolkit/tsconfig.json
run_check "TypeScript type check (stage-files-and-commit)" pnpm exec tsc --noEmit -p packages/git/stage-files-and-commit-action/tsconfig.json
run_check "TypeScript type check (stage-files-and-commit-and-push)" pnpm exec tsc --noEmit -p packages/git/stage-files-and-commit-and-push-action/tsconfig.json
run_check "TypeScript type check (increment-version-file)" pnpm exec tsc --noEmit -p packages/utils/increment-version-file-action/tsconfig.json

run_check "ESLint" pnpm exec eslint packages/

run_check "Prettier" pnpm exec prettier --check "packages/**/src/**/*.ts"

run_check "Tests" pnpm -r run test

run_check "Build" scripts/build

# Verify that built action.yaml files are in sync with their sources
run_check "action.yaml sync check" bash -c '
  PACKAGES_DIR="packages"
  STATUS=0
  for SOURCE in $(find "$PACKAGES_DIR" -name "action.yaml" -not -path "*/node_modules/*"); do
    RELATIVE="${SOURCE#"$PACKAGES_DIR/"}"
    BUILT="actions/$RELATIVE"
    if [ ! -f "$BUILT" ]; then
      echo "MISSING: $BUILT (expected copy of $SOURCE)"
      STATUS=1
      continue
    fi
    # Strip the comment header (first 3 lines) from the built file before comparing
    if ! diff -q <(cat "$SOURCE") <(tail -n +4 "$BUILT") > /dev/null 2>&1; then
      echo "OUT OF SYNC: $BUILT differs from $SOURCE"
      STATUS=1
    fi
  done
  exit $STATUS
'

run_check "YAML validation" python3 "$REPO_DIR/scripts/validate-yaml.py"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed."
  exit 1
fi
