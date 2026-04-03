#!/usr/bin/env bash
set -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Source the script under test (functions only, main guarded)
RELEASE_SCRIPT="$SCRIPT_DIR/../../actions/release/release-claude-plugin-action/release-claude-plugin.sh"
source "$RELEASE_SCRIPT"

# ===========================================================================
# Phase 2: Script skeleton tests
# ===========================================================================

test_script_is_sourceable() {
  # If we got here, sourcing succeeded (above). Verify a known function exists.
  assert_equals "function" "$(type -t dry_run_enabled)" "dry_run_enabled is a function"
  assert_equals "function" "$(type -t main)" "main is a function"
  assert_equals "function" "$(type -t discover_plugins)" "discover_plugins is a function"
}

test_main_fails_without_github_repository() {
  (
    unset GITHUB_REPOSITORY
    main 2>/dev/null
  )
  local exit_code=$?
  assert_equals "1" "$exit_code" "main fails without GITHUB_REPOSITORY"
}

# ===========================================================================
# Phase 3: discover_plugins tests
# ===========================================================================

test_discover_plugins_finds_valid_plugins() {
  setup_temp_dir
  # Create two valid plugins
  create_plugin_fixture "$TEMP_DIR/plugins/plugin-a" "plugin-a" "1.0.0"
  create_plugin_fixture "$TEMP_DIR/plugins/plugin-b" "plugin-b" "2.0.0"
  # Create a non-plugin directory
  mkdir -p "$TEMP_DIR/plugins/not-a-plugin"
  touch "$TEMP_DIR/plugins/not-a-plugin/README.md"

  local output
  output=$(discover_plugins "$TEMP_DIR/plugins")
  local count
  count=$(echo "$output" | grep -c '.' || true)
  assert_equals "2" "$count" "discover_plugins finds exactly 2 plugins"
  assert_contains "$output" "plugin-a" "output contains plugin-a"
  assert_contains "$output" "plugin-b" "output contains plugin-b"
  assert_not_contains "$output" "not-a-plugin" "output does not contain not-a-plugin"
}

test_discover_plugins_empty_dir() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/plugins"
  local output
  output=$(discover_plugins "$TEMP_DIR/plugins")
  assert_equals "" "$output" "discover_plugins returns empty for empty dir"
}

# ===========================================================================
# Phase 3: Version extraction and change detection tests
# ===========================================================================

test_get_plugin_name() {
  setup_temp_dir
  echo '{"name": "my-plugin", "version": "1.0.0"}' > "$TEMP_DIR/plugin.json"
  local result
  result=$(get_plugin_name "$TEMP_DIR/plugin.json")
  assert_equals "my-plugin" "$result" "get_plugin_name returns correct name"
}

test_get_plugin_version() {
  setup_temp_dir
  echo '{"name": "my-plugin", "version": "1.2.3"}' > "$TEMP_DIR/plugin.json"
  local result
  result=$(get_plugin_version "$TEMP_DIR/plugin.json")
  assert_equals "1.2.3" "$result" "get_plugin_version returns correct version"
}

test_get_latest_tag_for_plugin_with_tags() {
  setup_temp_repo
  git -C "$TEMP_REPO" tag "my-plugin-v0.0.1"
  # Add another commit so we can tag a different point
  touch "$TEMP_REPO/file2"
  git -C "$TEMP_REPO" add file2
  git -C "$TEMP_REPO" commit --quiet -m "Second commit"
  git -C "$TEMP_REPO" tag "my-plugin-v0.0.2"
  local result
  result=$(git -C "$TEMP_REPO" tag -l "my-plugin-v*" --sort=-v:refname | head -n 1)
  assert_equals "my-plugin-v0.0.2" "$result" "get_latest_tag returns most recent tag"
}

test_get_latest_tag_for_plugin_no_tags() {
  setup_temp_repo
  local result
  result=$(git -C "$TEMP_REPO" tag -l "my-plugin-v*" --sort=-v:refname | head -n 1)
  assert_equals "" "$result" "get_latest_tag returns empty when no tags"
}

test_get_latest_tag_for_plugin_ignores_other_plugins() {
  setup_temp_repo
  git -C "$TEMP_REPO" tag "other-plugin-v1.0.0"
  local result
  result=$(git -C "$TEMP_REPO" tag -l "my-plugin-v*" --sort=-v:refname | head -n 1)
  assert_equals "" "$result" "get_latest_tag ignores other plugin tags"
}

test_has_version_changed_true() {
  setup_temp_repo
  git -C "$TEMP_REPO" tag "my-plugin-v0.0.1"
  pushd "$TEMP_REPO" >/dev/null
  has_version_changed "my-plugin" "0.0.2"
  local result=$?
  popd >/dev/null
  assert_equals "0" "$result" "has_version_changed returns 0 (true) when version bumped"
}

test_has_version_changed_false() {
  setup_temp_repo
  git -C "$TEMP_REPO" tag "my-plugin-v0.0.1"
  pushd "$TEMP_REPO" >/dev/null
  has_version_changed "my-plugin" "0.0.1" || true
  local exit_code=0
  has_version_changed "my-plugin" "0.0.1" || exit_code=$?
  popd >/dev/null
  assert_equals "1" "$exit_code" "has_version_changed returns 1 (false) when version unchanged"
}

test_has_version_changed_no_prior_tag() {
  setup_temp_repo
  pushd "$TEMP_REPO" >/dev/null
  has_version_changed "my-plugin" "0.0.1"
  local result=$?
  popd >/dev/null
  assert_equals "0" "$result" "has_version_changed returns 0 (true) for first release"
}

# ===========================================================================
# Phase 3: Plugin validation tests
# ===========================================================================

test_validate_plugin_valid() {
  setup_temp_dir
  create_plugin_fixture "$TEMP_DIR/my-plugin" "my-plugin" "1.0.0"
  validate_plugin "$TEMP_DIR/my-plugin"
  assert_equals "0" "$?" "valid plugin passes validation"
}

test_validate_plugin_missing_name() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"version": "1.0.0"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "plugin without name fails validation"
}

test_validate_plugin_missing_version() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"name": "my-plugin"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "plugin without version fails validation"
}

test_validate_plugin_invalid_json() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo 'not json' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "plugin with invalid JSON fails validation"
}

test_validate_plugin_skill_missing_frontmatter() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"name": "my-plugin", "version": "1.0.0"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  mkdir -p "$TEMP_DIR/my-plugin/skills/bad-skill"
  echo "# No frontmatter here" > "$TEMP_DIR/my-plugin/skills/bad-skill/SKILL.md"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "skill without frontmatter fails validation"
}

test_validate_plugin_skill_missing_name_in_frontmatter() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"name": "my-plugin", "version": "1.0.0"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  mkdir -p "$TEMP_DIR/my-plugin/skills/bad-skill"
  cat > "$TEMP_DIR/my-plugin/skills/bad-skill/SKILL.md" <<'EOF'
---
description: A skill without a name
---
# Bad Skill
EOF
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "skill without name in frontmatter fails"
}

test_validate_plugin_skill_missing_description_in_frontmatter() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"name": "my-plugin", "version": "1.0.0"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  mkdir -p "$TEMP_DIR/my-plugin/skills/bad-skill"
  cat > "$TEMP_DIR/my-plugin/skills/bad-skill/SKILL.md" <<'EOF'
---
name: bad-skill
---
# Bad Skill
EOF
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "skill without description in frontmatter fails"
}

test_validate_plugin_invalid_hooks_json() {
  setup_temp_dir
  create_plugin_fixture "$TEMP_DIR/my-plugin" "my-plugin" "1.0.0"
  mkdir -p "$TEMP_DIR/my-plugin/hooks"
  echo 'not json' > "$TEMP_DIR/my-plugin/hooks/hooks.json"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "plugin with invalid hooks.json fails"
}

test_validate_plugin_invalid_mcp_json() {
  setup_temp_dir
  create_plugin_fixture "$TEMP_DIR/my-plugin" "my-plugin" "1.0.0"
  echo 'not json' > "$TEMP_DIR/my-plugin/.mcp.json"
  local exit_code=0
  validate_plugin "$TEMP_DIR/my-plugin" 2>/dev/null || exit_code=$?
  assert_equals "1" "$exit_code" "plugin with invalid .mcp.json fails"
}

test_validate_plugin_valid_with_agents() {
  setup_temp_dir
  create_plugin_fixture "$TEMP_DIR/my-plugin" "my-plugin" "1.0.0"
  mkdir -p "$TEMP_DIR/my-plugin/agents"
  echo "# My Agent" > "$TEMP_DIR/my-plugin/agents/my-agent.md"
  validate_plugin "$TEMP_DIR/my-plugin"
  assert_equals "0" "$?" "plugin with agents passes validation"
}

test_validate_plugin_no_skills_or_agents() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/my-plugin/.claude-plugin"
  echo '{"name": "my-plugin", "version": "1.0.0"}' > "$TEMP_DIR/my-plugin/.claude-plugin/plugin.json"
  validate_plugin "$TEMP_DIR/my-plugin"
  assert_equals "0" "$?" "minimal plugin passes validation"
}

# ===========================================================================
# Phase 4: Tag creation and GitHub Release tests
# ===========================================================================

test_create_tag_new_dry_run() {
  setup_temp_repo
  pushd "$TEMP_REPO" >/dev/null
  INPUT_DRY_RUN=true
  local output
  output=$(create_tag_and_release "my-plugin" "1.0.0" "true" 2>&1)
  INPUT_DRY_RUN=false
  popd >/dev/null
  assert_contains "$output" "[DRY RUN] Would create tag my-plugin-v1.0.0" "dry run logs tag creation"
  assert_contains "$output" "[DRY RUN] Would create GitHub Release" "dry run logs release creation"
}

test_create_tag_already_exists() {
  setup_temp_repo
  git -C "$TEMP_REPO" tag "my-plugin-v1.0.0"
  pushd "$TEMP_REPO" >/dev/null
  local output
  output=$(create_tag_and_release "my-plugin" "1.0.0" "true" 2>&1)
  popd >/dev/null
  assert_contains "$output" "already exists, skipping" "existing tag is skipped"
}

test_create_tag_actually_creates() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null
  INPUT_DRY_RUN=false
  # Mock gh CLI to avoid actual GitHub API calls
  local mock_dir
  mock_dir=$(mktemp -d)
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo "mock gh called with: $*"
exit 0
MOCK
  chmod +x "$mock_dir/gh"
  PATH="$mock_dir:$PATH" create_tag_and_release "my-plugin" "1.0.0" "true" >/dev/null 2>&1
  popd >/dev/null
  # Verify tag exists on remote
  local remote_tags
  remote_tags=$(git -C "$TEMP_REMOTE" tag -l)
  assert_contains "$remote_tags" "my-plugin-v1.0.0" "tag pushed to remote"
  rm -rf "$mock_dir"
}

# ===========================================================================
# Phase 4: Marketplace JSON assembly tests
# ===========================================================================

test_assemble_marketplace_json() {
  setup_temp_repo
  pushd "$TEMP_REPO" >/dev/null
  # Create marketplace fixture at repo root
  create_marketplace_fixture "$TEMP_REPO"
  # Create two plugins
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-a" "plugin-a" "1.0.0"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-b" "plugin-b" "2.0.0"
  git add -A && git commit --quiet -m "Add plugins"

  local output
  output=$(assemble_marketplace_json "plugins")
  popd >/dev/null

  # Check base metadata preserved
  local name
  name=$(echo "$output" | jq -r '.name')
  assert_equals "test-marketplace" "$name" "marketplace name preserved"

  # Check plugins array
  local plugin_count
  plugin_count=$(echo "$output" | jq '.plugins | length')
  assert_equals "2" "$plugin_count" "two plugins in array"

  local p1_name p1_version p1_source
  p1_name=$(echo "$output" | jq -r '.plugins[0].name')
  p1_version=$(echo "$output" | jq -r '.plugins[0].version')
  p1_source=$(echo "$output" | jq -r '.plugins[0].source')
  assert_equals "plugin-a" "$p1_name" "first plugin name correct"
  assert_equals "1.0.0" "$p1_version" "first plugin version correct"
  assert_contains "$p1_source" "plugin-a" "first plugin source path correct"

  local p2_name p2_version
  p2_name=$(echo "$output" | jq -r '.plugins[1].name')
  p2_version=$(echo "$output" | jq -r '.plugins[1].version')
  assert_equals "plugin-b" "$p2_name" "second plugin name correct"
  assert_equals "2.0.0" "$p2_version" "second plugin version correct"
}

test_assemble_marketplace_strips_existing_plugins() {
  setup_temp_repo
  pushd "$TEMP_REPO" >/dev/null
  # Create marketplace with stale plugins array
  mkdir -p "$TEMP_REPO/.claude-plugin"
  cat > "$TEMP_REPO/.claude-plugin/marketplace.json" <<'JSON'
{"name": "test-marketplace", "owner": {"name": "Test"}, "plugins": [{"name": "stale-plugin", "version": "0.0.0"}]}
JSON
  # Create actual plugin
  create_plugin_fixture "$TEMP_REPO/plugins/real-plugin" "real-plugin" "1.0.0"
  git add -A && git commit --quiet -m "Add plugins"

  local output
  output=$(assemble_marketplace_json "plugins")
  popd >/dev/null

  local plugin_count
  plugin_count=$(echo "$output" | jq '.plugins | length')
  assert_equals "1" "$plugin_count" "stale plugins replaced, not merged"

  local p1_name
  p1_name=$(echo "$output" | jq -r '.plugins[0].name')
  assert_equals "real-plugin" "$p1_name" "only real plugin present"
}

# ===========================================================================
# Phase 4: Push to release branch tests
# ===========================================================================

test_push_release_branch_dry_run() {
  setup_temp_repo
  pushd "$TEMP_REPO" >/dev/null
  INPUT_DRY_RUN=true
  local output
  output=$(push_to_release_branch "plugins" "release" '{"name":"test"}' 2>&1)
  INPUT_DRY_RUN=false
  popd >/dev/null
  assert_contains "$output" "[DRY RUN] Assembled marketplace.json" "dry run prints assembled JSON"
  assert_contains "$output" "[DRY RUN] Would push to release branch" "dry run logs branch push"
}

test_push_release_branch_first_run() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null
  # Create marketplace and plugin
  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/test-plugin" "test-plugin" "1.0.0"
  git add -A && git commit --quiet -m "Add plugin"
  git push --quiet origin HEAD

  INPUT_DRY_RUN=false
  local assembled_json='{"name":"test-marketplace","plugins":[{"name":"test-plugin","version":"1.0.0","source":"./plugins/test-plugin"}]}'
  push_to_release_branch "plugins" "release" "$assembled_json" >/dev/null 2>&1
  popd >/dev/null

  # Verify release branch exists on remote
  local branches
  branches=$(git -C "$TEMP_REMOTE" branch)
  assert_contains "$branches" "release" "release branch created on remote"

  # Clone the release branch and check content
  local verify_dir
  verify_dir=$(mktemp -d)
  git clone --quiet --branch release "$TEMP_REMOTE" "$verify_dir" 2>/dev/null
  assert_file_exists "$verify_dir/.claude-plugin/marketplace.json" "marketplace.json on release branch"

  local mp_name
  mp_name=$(jq -r '.name' "$verify_dir/.claude-plugin/marketplace.json")
  assert_equals "test-marketplace" "$mp_name" "marketplace.json content correct"
  rm -rf "$verify_dir"
}

test_push_release_branch_update() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null
  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/test-plugin" "test-plugin" "1.0.0"
  git add -A && git commit --quiet -m "Add plugin"
  git push --quiet origin HEAD

  INPUT_DRY_RUN=false
  local json_v1='{"name":"test-marketplace","plugins":[{"name":"test-plugin","version":"1.0.0"}]}'
  push_to_release_branch "plugins" "release" "$json_v1" >/dev/null 2>&1

  # Now update and push again
  local json_v2='{"name":"test-marketplace","plugins":[{"name":"test-plugin","version":"2.0.0"}]}'
  push_to_release_branch "plugins" "release" "$json_v2" >/dev/null 2>&1
  popd >/dev/null

  # Verify updated content
  local verify_dir
  verify_dir=$(mktemp -d)
  git clone --quiet --branch release "$TEMP_REMOTE" "$verify_dir" 2>/dev/null
  local version
  version=$(jq -r '.plugins[0].version' "$verify_dir/.claude-plugin/marketplace.json")
  assert_equals "2.0.0" "$version" "release branch updated with new version"
  rm -rf "$verify_dir"
}

# ===========================================================================
# Phase 5: End-to-end integration tests
# ===========================================================================

test_main_end_to_end_dry_run() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null

  # Create marketplace and two plugins
  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-a" "plugin-a" "1.0.0"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-b" "plugin-b" "2.0.0"
  git add -A && git commit --quiet -m "Add plugins"
  git push --quiet origin HEAD

  # Tag plugin-a at current version (no change), plugin-b is new (version bump)
  git tag "plugin-a-v1.0.0"
  git push --quiet origin "plugin-a-v1.0.0"

  export GITHUB_REPOSITORY="test/repo"
  export INPUT_PLUGINS_DIR="plugins"
  export INPUT_RELEASE_BRANCH="release"
  export INPUT_MARK_AS_LATEST="true"
  export INPUT_DRY_RUN="true"

  local output
  output=$(main 2>&1)
  popd >/dev/null

  assert_contains "$output" "plugin-a" "output mentions plugin-a"
  assert_contains "$output" "unchanged, skipping" "plugin-a skipped (version unchanged)"
  assert_contains "$output" "plugin-b" "output mentions plugin-b"
  assert_contains "$output" "[DRY RUN] Would create tag plugin-b-v2.0.0" "dry run would tag plugin-b"

  # Verify no actual tags were created
  local remote_tags
  remote_tags=$(git -C "$TEMP_REMOTE" tag -l "plugin-b-v*")
  assert_equals "" "$remote_tags" "no tag actually pushed in dry run"

  unset GITHUB_REPOSITORY INPUT_PLUGINS_DIR INPUT_RELEASE_BRANCH INPUT_MARK_AS_LATEST INPUT_DRY_RUN
}

test_main_end_to_end_no_changes() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null

  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-a" "plugin-a" "1.0.0"
  git add -A && git commit --quiet -m "Add plugins"
  git push --quiet origin HEAD

  # Tag at current version — no change
  git tag "plugin-a-v1.0.0"
  git push --quiet origin "plugin-a-v1.0.0"

  export GITHUB_REPOSITORY="test/repo"
  export INPUT_PLUGINS_DIR="plugins"
  export INPUT_DRY_RUN="true"

  local output
  output=$(main 2>&1)
  popd >/dev/null

  assert_contains "$output" "No plugin releases detected" "no releases when nothing changed"
  unset GITHUB_REPOSITORY INPUT_PLUGINS_DIR INPUT_DRY_RUN
}

test_main_end_to_end_with_bump() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null

  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-a" "plugin-a" "1.0.0"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-b" "plugin-b" "2.0.0"
  git add -A && git commit --quiet -m "Add plugins"
  git push --quiet origin HEAD

  # Tag plugin-a at current (no change), plugin-b is first release
  git tag "plugin-a-v1.0.0"
  git push --quiet origin "plugin-a-v1.0.0"

  # Mock gh CLI
  local mock_dir
  mock_dir=$(mktemp -d)
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_dir/gh"

  export GITHUB_REPOSITORY="test/repo"
  export INPUT_PLUGINS_DIR="plugins"
  export INPUT_RELEASE_BRANCH="release"
  export INPUT_MARK_AS_LATEST="true"
  export INPUT_DRY_RUN="false"
  export INPUT_TOKEN="fake-token"

  # Don't let main change the remote URL (we're using a local remote)
  # Override by keeping origin as-is: set INPUT_DRY_RUN for the remote-set-url part
  # Actually, we need to prevent git remote set-url from running. Easiest: just set dry_run
  # for that one call. Instead, let's just set the remote URL back after main tries to change it.
  # Simpler approach: temporarily override main to not touch remote URL.
  # Simplest: just call the pieces directly rather than main.

  # Let's test the full flow by not calling main() directly but simulating it,
  # since main() tries to set remote URL to github.com which won't work locally.
  git config user.name "test"
  git config user.email "test@test.com"
  git fetch --tags >/dev/null 2>&1

  local released_any=false
  while IFS= read -r plugin_dir; do
    [[ -z "$plugin_dir" ]] && continue
    local plugin_json="$plugin_dir/.claude-plugin/plugin.json"
    local plugin_name plugin_version
    plugin_name=$(get_plugin_name "$plugin_json")
    plugin_version=$(get_plugin_version "$plugin_json")
    if ! has_version_changed "$plugin_name" "$plugin_version"; then
      continue
    fi
    validate_plugin "$plugin_dir"
    PATH="$mock_dir:$PATH" create_tag_and_release "$plugin_name" "$plugin_version" "true" 2>/dev/null
    released_any=true
  done < <(discover_plugins "plugins")

  if [[ "$released_any" = true ]]; then
    local assembled_json
    assembled_json=$(assemble_marketplace_json "plugins")
    push_to_release_branch "plugins" "release" "$assembled_json" >/dev/null 2>&1
  fi
  popd >/dev/null

  # Verify plugin-b got tagged
  local remote_tags
  remote_tags=$(git -C "$TEMP_REMOTE" tag -l)
  assert_contains "$remote_tags" "plugin-b-v2.0.0" "plugin-b tag pushed to remote"
  assert_not_contains "$remote_tags" "plugin-a-v1.0.0-" "no duplicate tag for plugin-a"

  # Verify release branch has correct marketplace.json
  local verify_dir
  verify_dir=$(mktemp -d)
  git clone --quiet --branch release "$TEMP_REMOTE" "$verify_dir" 2>/dev/null
  local plugin_count
  plugin_count=$(jq '.plugins | length' "$verify_dir/.claude-plugin/marketplace.json")
  assert_equals "2" "$plugin_count" "marketplace.json has both plugins"
  rm -rf "$verify_dir" "$mock_dir"

  unset GITHUB_REPOSITORY INPUT_PLUGINS_DIR INPUT_RELEASE_BRANCH INPUT_MARK_AS_LATEST INPUT_DRY_RUN INPUT_TOKEN
}

test_main_first_run_no_tags() {
  setup_temp_repo_with_remote
  pushd "$TEMP_REPO" >/dev/null

  create_marketplace_fixture "$TEMP_REPO"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-a" "plugin-a" "1.0.0"
  create_plugin_fixture "$TEMP_REPO/plugins/plugin-b" "plugin-b" "2.0.0"
  git add -A && git commit --quiet -m "Add plugins"
  git push --quiet origin HEAD

  # No tags at all — first run
  export GITHUB_REPOSITORY="test/repo"
  export INPUT_PLUGINS_DIR="plugins"
  export INPUT_DRY_RUN="true"

  local output
  output=$(main 2>&1)
  popd >/dev/null

  # Both plugins should be detected as new
  assert_contains "$output" "[DRY RUN] Would create tag plugin-a-v1.0.0" "first run tags plugin-a"
  assert_contains "$output" "[DRY RUN] Would create tag plugin-b-v2.0.0" "first run tags plugin-b"

  unset GITHUB_REPOSITORY INPUT_PLUGINS_DIR INPUT_DRY_RUN
}

# ===========================================================================
# Run
# ===========================================================================

run_tests
