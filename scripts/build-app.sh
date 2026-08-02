#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
mkdir -p .build/module-cache dist/MiddleAI.app/Contents/MacOS dist/MiddleAI.app/Contents/Resources dist/bin

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"

build_args=(-c release)
if [[ -n "${MIDDLEAI_BUILD_ARCH:-}" ]]; then
  build_args+=(--arch "$MIDDLEAI_BUILD_ARCH")
fi

swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
cp "$bin_dir/MiddleAI" dist/MiddleAI.app/Contents/MacOS/MiddleAI
cp "$bin_dir/middleai-cli" dist/bin/middleai
rm -f dist/bin/middleai-ask
cp Resources/Info.plist dist/MiddleAI.app/Contents/Info.plist
cp THIRD_PARTY_NOTICES.md dist/MiddleAI.app/Contents/Resources/THIRD_PARTY_NOTICES.md
for resource_bundle in "$bin_dir"/*.bundle(N); do
  bundle_name=${resource_bundle:t}
  rm -rf "dist/MiddleAI.app/Contents/Resources/$bundle_name"
  cp -R "$resource_bundle" "dist/MiddleAI.app/Contents/Resources/$bundle_name"
done
codesign --force --sign - \
  --requirements '=designated => identifier "de.middleai.app"' \
  dist/MiddleAI.app >/dev/null
codesign --force --sign - dist/bin/middleai >/dev/null

echo "Built: $PROJECT_DIR/dist/MiddleAI.app"
echo "CLI:   $PROJECT_DIR/dist/bin/middleai"
echo "Voice: built into MiddleAI.app"
