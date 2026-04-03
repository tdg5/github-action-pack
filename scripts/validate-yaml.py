#!/usr/bin/env python3

import glob
import sys

import yaml

errors = []
patterns = ["actions/**/action.yaml", "packages/**/action.yaml", ".github/workflows/*.yaml"]
files = [f for p in patterns for f in glob.glob(p, recursive=True)]

if not files:
    print("WARNING: No YAML files found")
    sys.exit(1)

for path in sorted(files):
    try:
        with open(path) as f:
            yaml.safe_load(f)
    except yaml.YAMLError as e:
        errors.append(f"{path}: {e}")

print(f"Validated {len(files)} YAML files")
if errors:
    for err in errors:
        print(f"  ERROR: {err}")
    sys.exit(1)
