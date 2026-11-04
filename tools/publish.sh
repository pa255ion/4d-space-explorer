#!/bin/sh
# Build the browser version and copy it into a static site checkout:
#   tools/publish.sh SITE_DIR [SUBDIR]     (SUBDIR defaults to 4d-space-explorer)
# The commit hash is stamped into the script URL so caches never mix
# versions (see VERSION in web/app.js). Then commit and push the site.
set -eu
site=${1:?usage: tools/publish.sh SITE_DIR [SUBDIR]}
sub=${2:-4d-space-explorer}
cd "$(dirname "$0")/.."
zig build web
version=$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- src web || echo "-dirty")
dest="$site/$sub"
mkdir -p "$dest"
for f in index.html app.js gpu.js shaders.wgsl space4d.wasm; do
  cp zig-out/web/$f "$dest/$f"
done
sed -i "s|src=\"app.js\"|src=\"app.js?v=$version\"|" "$dest/index.html"
echo "published $version to $dest"
