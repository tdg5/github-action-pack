#!/usr/bin/env python3
"""Structural check of actions/docker/publish-image-action/action.yaml.

The YAML validator only parses action.yaml; this asserts its content: the
input contract, the subcommand wiring, the pinned third-party steps and
their order, and that the source token reaches only build-push's secrets.
"""

import os
import re
import sys

import yaml

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ACTION = os.path.join(REPO_DIR, "actions", "docker", "publish-image-action", "action.yaml")

EXPECTED_INPUTS = {
    # name: (required, default); None means no default key.
    "aws-region": (False, "us-east-1"),
    "aws-role-arn": (False, ""),
    "context": (False, "."),
    "default-build-config": (False, ""),
    "first-publish-notes-limit": (False, ""),
    "image": (True, None),
    "images-root": (True, None),
    "previous-version": (False, ""),
    "repository-prefix": (False, ""),
    "source-token": (False, ""),
    "token": (False, "${{ github.token }}"),
    "version": (True, None),
}

EXPECTED_USES = [
    "aws-actions/configure-aws-credentials@v6",
    "aws-actions/amazon-ecr-login@v2",
    "docker/login-action@v4",
    "docker/setup-qemu-action@v3",
    "docker/setup-buildx-action@v3",
    "docker/build-push-action@v6",
]

SUBCOMMANDS = ("prepare", "preflight", "release", "summary")
RUN_PATTERN = re.compile(
    r"^\$\{\{ github\.action_path \}\}/publish-image\.sh (" + "|".join(SUBCOMMANDS) + r")$"
)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def main():
    if not os.path.isfile(ACTION):
        print(f"FAIL: {ACTION} does not exist")
        return 1

    with open(ACTION) as f:
        text = f.read()
    action = yaml.safe_load(text)

    check(action.get("runs", {}).get("using") == "composite", "runs.using must be 'composite'")

    # --- Inputs ---
    inputs = action.get("inputs") or {}
    check(
        list(inputs) == sorted(inputs),
        f"inputs must be in alphabetical order; got {list(inputs)}",
    )
    check(
        set(inputs) == set(EXPECTED_INPUTS),
        f"input set differs: missing {sorted(set(EXPECTED_INPUTS) - set(inputs))}, "
        f"extra {sorted(set(inputs) - set(EXPECTED_INPUTS))}",
    )
    for name, (required, default) in EXPECTED_INPUTS.items():
        spec = inputs.get(name)
        if not check(isinstance(spec, dict), f"input {name} must be a mapping"):
            continue
        check(spec.get("required") is required, f"input {name}: required must be {required}")
        check(bool(spec.get("description")), f"input {name}: needs a description")
        if default is None:
            check("default" not in spec, f"input {name}: must have no default")
        else:
            check(
                spec.get("default") == default,
                f"input {name}: default must be {default!r}; got {spec.get('default')!r}",
            )
    check("outputs" not in action, "the action must have no outputs")

    # --- Steps ---
    steps = action.get("runs", {}).get("steps") or []
    order = {}  # label -> index
    uses_seen = []
    for index, step in enumerate(steps):
        if "run" in step:
            check(step.get("shell") == "bash", f"step {index}: run steps need shell: bash")
            match = RUN_PATTERN.match(str(step["run"]).strip())
            if check(match, f"step {index}: run must invoke publish-image.sh <subcommand>; got {step['run']!r}"):
                sub = match.group(1)
                check(sub not in order, f"subcommand {sub} runs more than once")
                order[sub] = index
        elif "uses" in step:
            uses_seen.append(step["uses"])
            order.setdefault(step["uses"], index)
        else:
            failures.append(f"step {index}: neither run nor uses")

    check(uses_seen == EXPECTED_USES, f"uses steps must be exactly {EXPECTED_USES}; got {uses_seen}")
    for sub in SUBCOMMANDS:
        check(sub in order, f"no step runs the {sub} subcommand")

    def idx(label):
        return order.get(label, -1)

    logins = EXPECTED_USES[:3]
    build_push = "docker/build-push-action@v6"
    if all(label in order for label in (*SUBCOMMANDS, *logins, build_push)):
        for login in logins:
            check(idx("prepare") < idx(login) < idx("preflight"), f"{login} must run between prepare and preflight")
        check(idx("preflight") < idx(build_push), "preflight must run before build-push")
        check(idx(build_push) < idx("release"), "build-push must run before release")
        check(idx("release") < idx("summary"), "release must run before summary")

    # The prepare and preflight steps' ids, for output references.
    ids = {}
    for sub in SUBCOMMANDS:
        if sub in order:
            ids[sub] = steps[order[sub]].get("id")
    check(bool(ids.get("prepare")), "the prepare step needs an id")
    check(bool(ids.get("preflight")), "the preflight step needs an id")

    # D24: both prepare and release get the notes limit.
    for sub in ("prepare", "release"):
        if sub in order:
            env = steps[order[sub]].get("env") or {}
            check(
                env.get("INPUT_FIRST_PUBLISH_NOTES_LIMIT") == "${{ inputs.first-publish-notes-limit }}",
                f"{sub} must receive INPUT_FIRST_PUBLISH_NOTES_LIMIT",
            )

    # --- build-push ---
    if build_push in order:
        with_ = steps[order[build_push]].get("with") or {}
        prepare_id = ids.get("prepare")
        preflight_id = ids.get("preflight")
        check(with_.get("context") == "${{ inputs.context }}", "build-push context must be ${{ inputs.context }}")
        check(with_.get("push") is True, "build-push push must be true")
        check(
            with_.get("file") == f"${{{{ steps.{prepare_id}.outputs.dockerfile }}}}",
            "build-push file must come from the prepare step's dockerfile output",
        )
        check(
            with_.get("platforms") == f"${{{{ steps.{prepare_id}.outputs.platforms }}}}",
            "build-push platforms must come from the prepare step's platforms output",
        )
        ref = f"${{{{ steps.{preflight_id}.outputs.image_ref }}}}"
        tags = [t.strip() for t in str(with_.get("tags", "")).splitlines() if t.strip()]
        expected_tags = [
            f"{ref}:${{{{ inputs.version }}}}",
            f"{ref}:latest",
            f"{ref}:${{{{ github.sha }}}}",
        ]
        check(tags == expected_tags, f"build-push tags must be {expected_tags}; got {tags}")
        secrets = str(with_.get("secrets", ""))
        check("inputs.source-token" in secrets, "build-push secrets must reference inputs.source-token")
        check("source_token" in secrets.replace("inputs.source-token", ""), "build-push secrets must use the id source_token")
        check("build-args" not in with_, "build-push must have no build-args")

    check("secrets." not in text, "the text 'secrets.' must not appear in action.yaml")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("action.yaml structural check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
