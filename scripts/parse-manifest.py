#!/usr/bin/env python3
"""
Parse demos/manifest.yaml and output filtered tests.

Usage:
    python3 scripts/parse-manifest.py [tag1,tag2,...|all]

Output format (one per line, in manifest order):
    path|name|type|requires
"""

import sys
from pathlib import Path

import yaml


def main():
    # Get filter tags from the command line (comma-separated or "all")
    filter_tags = sys.argv[1] if len(sys.argv) > 1 else "all"

    manifest_path = Path(__file__).parent.parent / "demos" / "manifest.yaml"
    with open(manifest_path) as f:
        manifest = yaml.safe_load(f)

    for entry in manifest.get("tests", []):
        tags = entry.get("tags", [])
        if should_run(tags, filter_tags):
            print("|".join((
                entry.get("path", ""),
                entry.get("name", ""),
                entry.get("type", "shell"),
                entry.get("requires", ""),
            )))


def should_run(entry_tags, filter_tags):
    """Check if an entry should run based on its tags (OR logic)."""
    if filter_tags == "all":
        return True
    return any(tag in entry_tags for tag in filter_tags.split(","))


if __name__ == "__main__":
    main()
