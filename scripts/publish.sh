#!/usr/bin/env bash
# Rebuilds this catalog from the newest signed Frameleaf Manager release.
# The listing files come from the release's own commit, so the template always matches
# the checksum the signed manifest binds. Screenshots in images/ are maintained by hand.
# MANAGER_TAG=manager-vX.Y.Z rebuilds a specific release even when the catalog is already on it.
set -euo pipefail
source_repo=Frameleaf/frameleaf-app
tag=${MANAGER_TAG:-$(gh release list -R "$source_repo" --exclude-drafts --exclude-pre-releases --limit 100 \
  --json tagName --jq '.[].tagName' | grep -E '^manager-v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}
[[ "$tag" =~ ^manager-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No Manager release found" >&2; exit 1; }
if [ -z "${MANAGER_TAG:-}" ] && [ "$(jq -r .managerRelease catalog-source.json)" = "$tag" ]; then
  echo "Catalog is already at $tag"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$tag" -R "$source_repo" -p manager-manifest.json -D "$work"
commit=$(jq -r '.installers.sourceCommit // .sourceCommit' "$work/manager-manifest.json")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]]
git init -q "$work/source"
git -C "$work/source" fetch -q --depth 1 "https://github.com/$source_repo" "$commit"
git -C "$work/source" checkout -q FETCH_HEAD
npm ci --prefix "$work/source/manager" --ignore-scripts --silent
# Verifies the cosign signature, attestation, build run and installer checksums before writing.
NODE_PATH="$work/source/manager/node_modules" \
  node "$work/source/packaging/nas/build-manager.cjs" "$work/manager-manifest.json" "$work/out"

cp "$work"/out/unraid/{README.md,ca_profile.xml,LICENSE} .
cp "$work/out/unraid/templates/frameleaf-manager.xml" templates/
cp "$work/out/manager-manifest.json" "$work/source/cosign.pub" .
jq -n --arg commit "$commit" --arg tag "$tag" \
  '{repository: "Frameleaf/frameleaf-app", sourceCommit: $commit, sourcePath: "packaging/nas", managerRelease: $tag}' \
  > catalog-source.json
git ls-files | grep -Ev '^(SHA256SUMS|\.github/.*|scripts/.*)$' | sort | xargs shasum -a 256 > SHA256SUMS
echo "tag=$tag" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Catalog rebuilt from $tag ($commit)"
