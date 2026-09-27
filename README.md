# github-action-pack

A pack of GitHub actions and utilities for working with GitHub actions.

## Getting Started

```bash
# Install dependencies
npm i
```

## publish-image-action

`tdg5/github-action-pack/actions/docker/publish-image-action` builds one
image from the caller's checkout and pushes it to AWS ECR or GHCR with the
tags `:<version>`, `:latest` and `:<git-sha>`. It then creates the git tag
`<image>/v<version>` and a GitHub Release whose notes list the commits
since the previous version that touch the image's notes paths.

Before building, it refuses to publish when:

- there is no Dockerfile at `<images-root>/<image>/Dockerfile`;
- the git tag `<image>/v<version>` already exists;
- the image has a `<image>/v*` tag and `previous-version` is empty, or the
  previous version's tag is missing;
- the checkout is shallow;
- for ECR, the repository does not exist;
- the `:<version>` tag already exists in the registry, or the lookup fails
  for any reason other than "not found".

### The caller's obligations

- Trigger the workflow with `workflow_dispatch`.
- Grant `permissions`: `contents: write` (tag and Release), `id-token:
  write` (AWS OIDC) and `packages: write` (GHCR).
- Check out with `fetch-depth: 0`, so tags and history are present.
- Serialize publishes per image with `concurrency`, so two dispatches can't
  race on the same tags.
- Own any branch guard, such as a `Require main` step. The action has none.

### Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `aws-region` | no | `us-east-1` | Region of the ECR registry. |
| `aws-role-arn` | no (required for ECR) | `''` | Role assumed via GitHub OIDC. |
| `context` | no | `.` | Docker build context. |
| `default-build-config` | no | `''` | Build config used when the image has no `build-config.yaml`. |
| `first-publish-notes-limit` | no | `''` | Caps a first publish's notes at this many commits; empty is no cap. |
| `image` | yes | — | One or more `/`-separated lowercase segments. |
| `images-root` | yes | — | Directory holding `<image>/Dockerfile`. |
| `previous-version` | no | `''` | Required once the image has a `<image>/v*` tag. |
| `repository-prefix` | no | `''` | Prefix of the published repository name. |
| `source-token` | no | `''` | Mounted only as the BuildKit secret `source_token`; empty passes no secret. |
| `token` | no | `${{ github.token }}` | Used for the GHCR login and the Release. |
| `version` | yes | — | Version to publish, with no leading `v`. |

The action has no outputs.

### Naming

The published repository is `<repository-prefix><image>`: the ECR
repository `<registry>/<repository-prefix><image>`, or
`ghcr.io/<owner>/<repository-prefix><image>`. The git tag and Release are
`<image>/v<version>`, without the prefix. For example, with the prefix
`jig/` and the image `jig-verify`, the image is published as
`jig/jig-verify` and tagged `jig-verify/v1.0.0`.

### Build config

The image's `<images-root>/<image>/build-config.yaml` is used if it
exists, *wholesale*; otherwise `default-build-config` is used, and it is an
error when neither exists. Keys:

- `platforms` (required): a list, e.g. `[linux/amd64, linux/arm64]`.
- `registry` (optional): `ecr` (the default) or `ghcr`.
- `notes-paths` (optional): repo-relative paths whose commits make up the
  release notes. The default is the image's directory.

A first push to GHCR creates the package private; make it public in the
package settings if it should be pullable anonymously.

### Example

```yaml
name: publish-image
run-name: publish-image ${{ inputs.image }}:${{ inputs.version }}

on:
  workflow_dispatch:
    inputs:
      image:
        required: true
        type: string
      version:
        required: true
        type: string
      previous-version:
        required: false
        type: string

concurrency:
  cancel-in-progress: false
  group: publish-image-${{ inputs.image }}

permissions:
  contents: write
  id-token: write
  packages: write

jobs:
  publish-image:
    runs-on: ubuntu-latest
    steps:
      - name: Require main
        env:
          REF: ${{ github.ref }}
        run: |
          if [ "$REF" != "refs/heads/main" ]; then
            echo "publish-image must be dispatched from main; got $REF." >&2
            exit 1
          fi
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tdg5/github-action-pack/actions/docker/publish-image-action@v0.0.8
        with:
          aws-role-arn: arn:aws:iam::123456789012:role/my-publish-role
          image: ${{ inputs.image }}
          images-root: images
          previous-version: ${{ inputs.previous-version }}
          version: ${{ inputs.version }}
```
