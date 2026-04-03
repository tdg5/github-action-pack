#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# --- Helpers ---

dry_run_enabled() {
  [[ "${INPUT_DRY_RUN:-false}" == "true" ]]
}

# --- Plugin Discovery ---

discover_plugins() {
  local plugins_dir="$1"
  find "$plugins_dir" -name "plugin.json" -path "*/.claude-plugin/plugin.json" -print0 |
    while IFS= read -r -d '' plugin_json; do
      dirname "$(dirname "$plugin_json")"
    done | sort
}

# --- Version Extraction ---

get_plugin_name() {
  local plugin_json="$1"
  jq -r '.name' "$plugin_json"
}

get_plugin_version() {
  local plugin_json="$1"
  jq -r '.version' "$plugin_json"
}

get_latest_tag_for_plugin() {
  local plugin_name="$1"
  git tag -l "${plugin_name}-v*" --sort=-v:refname | head -n 1
}

has_version_changed() {
  local plugin_name="$1"
  local current_version="$2"
  local latest_tag
  latest_tag=$(get_latest_tag_for_plugin "$plugin_name")

  if [[ -z "$latest_tag" ]]; then
    # No prior tag — first release
    return 0
  fi

  local tag_version="${latest_tag#"${plugin_name}-v"}"
  if [[ "$current_version" = "$tag_version" ]]; then
    return 1
  fi
  return 0
}

# --- Validation ---

validate_plugin() {
  local plugin_dir="$1"
  local plugin_json="$plugin_dir/.claude-plugin/plugin.json"
  local errors=0

  # Check plugin.json is valid JSON
  if ! jq empty "$plugin_json" 2>/dev/null; then
    echo "ERROR: $plugin_json is not valid JSON" >&2
    return 1
  fi

  # Check required fields
  local name version
  name=$(jq -r '.name // empty' "$plugin_json")
  version=$(jq -r '.version // empty' "$plugin_json")

  if [[ -z "$name" ]]; then
    echo "ERROR: $plugin_json missing required 'name' field" >&2
    errors=$((errors + 1))
  fi
  if [[ -z "$version" ]]; then
    echo "ERROR: $plugin_json missing required 'version' field" >&2
    errors=$((errors + 1))
  fi

  # Validate skills
  if [[ -d "$plugin_dir/skills" ]]; then
    for skill_dir in "$plugin_dir/skills"/*/; do
      [[ ! -d "$skill_dir" ]] && continue
      local skill_md="${skill_dir}SKILL.md"
      if [[ ! -f "$skill_md" ]]; then
        echo "ERROR: Skill directory $skill_dir missing SKILL.md" >&2
        errors=$((errors + 1))
        continue
      fi
      # Check frontmatter exists (starts with ---)
      if ! head -n 1 "$skill_md" | grep -q '^---$'; then
        echo "ERROR: $skill_md missing YAML frontmatter" >&2
        errors=$((errors + 1))
        continue
      fi
      # Extract frontmatter and check for name and description
      local frontmatter
      frontmatter=$(sed -n '2,/^---$/p' "$skill_md" | sed '$d')
      if ! echo "$frontmatter" | grep -q '^name:'; then
        echo "ERROR: $skill_md frontmatter missing 'name'" >&2
        errors=$((errors + 1))
      fi
      if ! echo "$frontmatter" | grep -q '^description:'; then
        echo "ERROR: $skill_md frontmatter missing 'description'" >&2
        errors=$((errors + 1))
      fi
    done
  fi

  # Validate hooks.json if present
  if [[ -f "$plugin_dir/hooks/hooks.json" ]]; then
    if ! jq empty "$plugin_dir/hooks/hooks.json" 2>/dev/null; then
      echo "ERROR: $plugin_dir/hooks/hooks.json is not valid JSON" >&2
      errors=$((errors + 1))
    fi
  fi

  # Validate .mcp.json if present
  if [[ -f "$plugin_dir/.mcp.json" ]]; then
    if ! jq empty "$plugin_dir/.mcp.json" 2>/dev/null; then
      echo "ERROR: $plugin_dir/.mcp.json is not valid JSON" >&2
      errors=$((errors + 1))
    fi
  fi

  if [[ $errors -gt 0 ]]; then
    return 1
  fi
  return 0
}

# --- Tag & Release ---

create_tag_and_release() {
  local plugin_name="$1"
  local version="$2"
  local mark_as_latest="$3"
  local tag="${plugin_name}-v${version}"

  # Idempotent: skip if tag already exists
  if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag $tag already exists, skipping."
    return 0
  fi

  if dry_run_enabled; then
    echo "[DRY RUN] Would create tag $tag"
    echo "[DRY RUN] Would create GitHub Release for $tag"
    return 0
  fi

  echo "Creating tag $tag..."
  git tag "$tag"
  git push origin "$tag"

  echo "Creating GitHub Release for $tag..."
  local args=(create "$tag" --title "$tag" --generate-notes)
  if [[ "$mark_as_latest" = "false" ]]; then
    args+=(--latest=false)
  fi
  gh release "${args[@]}"
}

# --- Marketplace Assembly ---

assemble_marketplace_json() {
  local plugins_dir="$1"
  local marketplace_json=".claude-plugin/marketplace.json"

  # Read base marketplace metadata (strip any existing plugins array)
  local base_marketplace
  base_marketplace=$(jq 'del(.plugins)' "$marketplace_json")

  # Build plugins array from discovered plugins
  local plugins_array="[]"
  while IFS= read -r plugin_dir; do
    [[ -z "$plugin_dir" ]] && continue
    local pjson="$plugin_dir/.claude-plugin/plugin.json"
    local entry
    entry=$(jq --arg source "./$plugin_dir" '{
      name: .name,
      source: $source,
      description: (.description // ""),
      version: (.version // ""),
      keywords: (.keywords // [])
    }' "$pjson")
    plugins_array=$(echo "$plugins_array" | jq --argjson entry "$entry" '. + [$entry]')
  done < <(discover_plugins "$plugins_dir")

  # Assemble final marketplace.json
  echo "$base_marketplace" | jq --argjson plugins "$plugins_array" '. + {plugins: $plugins}'
}

push_to_release_branch() {
  local plugins_dir="$1"
  local release_branch="$2"
  local assembled_json="$3"

  if dry_run_enabled; then
    echo "[DRY RUN] Assembled marketplace.json:"
    echo "$assembled_json" | jq .
    echo "[DRY RUN] Would push to release branch '$release_branch'"
    return 0
  fi

  # Create a temp directory for assembling the release branch content
  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Copy assembled marketplace.json
  mkdir -p "$tmp_dir/.claude-plugin"
  echo "$assembled_json" > "$tmp_dir/.claude-plugin/marketplace.json"

  # Copy all plugin directories
  while IFS= read -r plugin_dir; do
    [[ -z "$plugin_dir" ]] && continue
    mkdir -p "$tmp_dir/$plugin_dir"
    cp -r "$plugin_dir"/* "$tmp_dir/$plugin_dir/" 2>/dev/null || true
    # Also copy hidden dirs like .claude-plugin
    cp -r "$plugin_dir"/.* "$tmp_dir/$plugin_dir/" 2>/dev/null || true
  done < <(discover_plugins "$plugins_dir")

  # Save current branch to return to
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  # Create or update the release branch
  if git ls-remote --exit-code --heads origin "$release_branch" >/dev/null 2>&1; then
    git fetch origin "$release_branch" >/dev/null 2>&1
    git checkout "$release_branch" >/dev/null 2>&1
    git rm -rf . >/dev/null 2>&1 || true
  else
    git checkout --orphan "$release_branch" >/dev/null 2>&1
    git rm -rf . >/dev/null 2>&1 || true
  fi

  # Copy assembled content into the working tree
  cp -r "$tmp_dir"/.claude-plugin .
  # Copy plugin dirs if they exist in tmp
  if compgen -G "$tmp_dir"/*/  > /dev/null 2>&1; then
    for dir in "$tmp_dir"/*/; do
      local dirname
      dirname=$(basename "$dir")
      [[ "$dirname" == ".claude-plugin" ]] && continue
      cp -r "$dir" "./$dirname"
    done
  fi

  git add -A
  git commit --quiet -m "Release plugins ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  git push origin "$release_branch"

  # Return to original branch
  git checkout "$current_branch" >/dev/null 2>&1
  rm -rf "$tmp_dir"
}

# --- Main ---

main() {
  local plugins_dir="${INPUT_PLUGINS_DIR:-claude-plugins}"
  local release_branch="${INPUT_RELEASE_BRANCH:-latest}"
  local mark_as_latest="${INPUT_MARK_AS_LATEST:-true}"

  : "${GITHUB_REPOSITORY:?Environment variable GITHUB_REPOSITORY must be set}"
  local owner repo
  owner=$(cut -d '/' -f 1 <<< "$GITHUB_REPOSITORY")
  repo=$(cut -d '/' -f 2 <<< "$GITHUB_REPOSITORY")

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)
  pushd "$repo_root" >/dev/null

  # Configure git for CI
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  if ! dry_run_enabled; then
    git remote set-url origin "https://x-access-token:${INPUT_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
    export GH_TOKEN="${INPUT_TOKEN}"
  fi

  git fetch --tags >/dev/null 2>&1

  local released_any=false

  while IFS= read -r plugin_dir; do
    [[ -z "$plugin_dir" ]] && continue
    local plugin_json="$plugin_dir/.claude-plugin/plugin.json"
    local plugin_name plugin_version

    plugin_name=$(get_plugin_name "$plugin_json")
    plugin_version=$(get_plugin_version "$plugin_json")

    if ! has_version_changed "$plugin_name" "$plugin_version"; then
      echo "Plugin '$plugin_name' version $plugin_version unchanged, skipping."
      continue
    fi

    echo "Plugin '$plugin_name' has new version $plugin_version"

    echo "Validating plugin '$plugin_name'..."
    validate_plugin "$plugin_dir"

    echo "Creating tag and release for '$plugin_name' v$plugin_version..."
    create_tag_and_release "$plugin_name" "$plugin_version" "$mark_as_latest"

    released_any=true
  done < <(discover_plugins "$plugins_dir")

  if [[ "$released_any" = true ]]; then
    echo "Assembling marketplace.json and pushing to $release_branch..."
    local assembled_json
    assembled_json=$(assemble_marketplace_json "$plugins_dir")
    push_to_release_branch "$plugins_dir" "$release_branch" "$assembled_json"
  else
    echo "No plugin releases detected."
  fi

  popd >/dev/null
}

# Source guard: only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
