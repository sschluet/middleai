.PHONY: setup build test run clean

setup:
	./setup.sh

build:
	./scripts/build-app.sh

test:
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/module-cache" swift run middleai-tests

run: build
	open dist/MiddleAI.app

clean:
	swift package clean
