#!/usr/bin/env bash
# Rebuilds this catalog from the newest signed Frameleaf Manager release and the newest
# stable Frameleaf application release (manual Server and ML templates).
# The listing files come from each release's own commit, so every template matches what
# its signed manifest binds. Screenshots in images/ are maintained by hand.
# MANAGER_TAG=manager-vX.Y.Z / APPLICATION_TAG=frameleaf-vX.Y.Z rebuild specific releases
# even when the catalog is already on them.
set -euo pipefail
source_repo=Frameleaf/frameleaf-app
newest() {
  gh release list -R "$source_repo" --exclude-drafts --exclude-pre-releases --limit 100 \
    --json tagName --jq '.[].tagName' | grep -E "^$1[0-9]+\.[0-9]+\.[0-9]+\$" | sort -V | tail -1
}
tag=${MANAGER_TAG:-$(newest manager-v)}
app_tag=${APPLICATION_TAG:-$(newest frameleaf-v)}
[[ "$tag" =~ ^manager-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No Manager release found" >&2; exit 1; }
[[ "$app_tag" =~ ^frameleaf-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No application release found" >&2; exit 1; }
if [ -z "${MANAGER_TAG:-}${APPLICATION_TAG:-}" ] &&
  [ "$(jq -r .managerRelease catalog-source.json)" = "$tag" ] &&
  [ "$(jq -r '.applicationRelease // ""' catalog-source.json)" = "$app_tag" ]; then
  echo "Catalog is already at $tag and $app_tag"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout() { # commit directory
  git init -q "$2"
  git -C "$2" fetch -q --depth 1 "https://github.com/$source_repo" "$1"
  git -C "$2" checkout -q FETCH_HEAD
  npm ci --prefix "$2/manager" --ignore-scripts --silent
}

gh release download "$tag" -R "$source_repo" -p manager-manifest.json -D "$work"
commit=$(jq -r '.installers.sourceCommit // .sourceCommit' "$work/manager-manifest.json")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]]
checkout "$commit" "$work/source"
# Verifies the cosign signature, attestation, build run and installer checksums before writing.
NODE_PATH="$work/source/manager/node_modules" \
  node "$work/source/packaging/nas/build-manager.cjs" "$work/manager-manifest.json" "$work/out"

mkdir -p "$work/app-release"
gh release download "$app_tag" -R "$source_repo" -D "$work/app-release"
app_commit=$(jq -r .sourceCommit "$work/app-release/release-manifest.json")
[[ "$app_commit" =~ ^[0-9a-f]{40}$ ]]
checkout "$app_commit" "$work/app-source"
# Verifies release and NAS manifests, checksums, every image signature, attestations and the build run.
NODE_PATH="$work/app-source/manager/node_modules" \
  node "$work/app-source/packaging/nas/build.cjs" "$work/app-release" "$app_tag" "$work/app-out"

cp "$work"/out/unraid/{README.md,ca_profile.xml,LICENSE} .
cp "$work/out/unraid/templates/frameleaf-manager.xml" templates/
cp "$work"/app-out/unraid/templates/{frameleaf-server,frameleaf-ml}.xml templates/
cp "$work/out/manager-manifest.json" "$work/app-out/nas-manifest.json" "$work/source/cosign.pub" .
jq -n --arg commit "$commit" --arg tag "$tag" --arg appCommit "$app_commit" --arg appTag "$app_tag" \
  '{repository: "Frameleaf/frameleaf-app", sourceCommit: $commit, sourcePath: "packaging/nas", managerRelease: $tag,
    applicationSourceCommit: $appCommit, applicationRelease: $appTag}' \
  > catalog-source.json
git add -A
git ls-files | grep -Ev '^(SHA256SUMS|\.github/.*|scripts/.*)$' | sort | xargs shasum -a 256 > SHA256SUMS
echo "tag=$tag" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "app_tag=$app_tag" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Catalog rebuilt from $tag ($commit) and $app_tag ($app_commit)"
