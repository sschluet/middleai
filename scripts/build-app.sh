#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
mkdir -p .build/module-cache dist dist/bin
staging_root=$(mktemp -d "$PROJECT_DIR/.build/middleai-app.XXXXXX")
staging_app="$staging_root/MiddleAI.app"
trap 'rm -rf "$staging_root"' EXIT
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"

build_args=(-c release)
if [[ -n "${MIDDLEAI_BUILD_ARCH:-}" ]]; then
  build_args+=(--arch "$MIDDLEAI_BUILD_ARCH")
fi

swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
cp "$bin_dir/MiddleAI" "$staging_app/Contents/MacOS/MiddleAI"
cp "$bin_dir/middleai-cli" dist/bin/middleai
rm -f dist/bin/middleai-ask
cp Resources/Info.plist "$staging_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staging_app/Contents/Resources/AppIcon.icns"
cp Resources/Brand/MiddleAI-AppIcon.png "$staging_app/Contents/Resources/MiddleAI-AppIcon.png"
cp LICENSE "$staging_app/Contents/Resources/LICENSE"
cp NOTICE "$staging_app/Contents/Resources/NOTICE"
cp THIRD_PARTY_NOTICES.md "$staging_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
for resource_bundle in "$bin_dir"/*.bundle(N); do
  bundle_name=${resource_bundle:t}
  cp -R "$resource_bundle" "$staging_app/Contents/Resources/$bundle_name"
done
chmod 755 "$staging_app/Contents/MacOS/MiddleAI"
find "$staging_app/Contents/Resources" -type d -exec chmod 755 {} +
find "$staging_app/Contents/Resources" -type f -exec chmod 644 {} +
codesign --force --sign - \
  --requirements '=designated => identifier "de.middleai.app"' \
  "$staging_app" >/dev/null
codesign --force --sign - dist/bin/middleai >/dev/null

rm -rf "$PROJECT_DIR/dist/MiddleAI.app"
mv "$staging_app" "$PROJECT_DIR/dist/MiddleAI.app"

echo "Built: $PROJECT_DIR/dist/MiddleAI.app"
echo "CLI:   $PROJECT_DIR/dist/bin/middleai"
echo "Voice: built into MiddleAI.app"
