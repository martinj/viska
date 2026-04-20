#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"

if [ -z "$tag" ]; then
  echo "Usage: $0 v0.1.0"
  exit 1
fi

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a semver tag like v0.1.0"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean"
  git status --short
  exit 1
fi

git fetch origin --tags

if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "Tag already exists: $tag"
  exit 1
fi

git tag -a "$tag" -m "Release $tag"
git push origin "$tag"
