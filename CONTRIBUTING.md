# Contributing to MiddleAI

Thank you for helping improve MiddleAI.

## Development setup

MiddleAI requires an Apple Silicon Mac, macOS 14 or newer, and Swift 6 Command Line Tools or Xcode.

```sh
swift build -c debug
swift run -c debug middleai-tests
```

Use `./scripts/build-app.sh` to create the local application bundle under `dist/`. Generated applications, binaries, local configuration, credentials and downloaded models must not be committed.

## Pull requests

1. Create a focused branch from `main`.
2. Keep changes limited to one coherent concern.
3. Add or update tests when behavior changes.
4. Run the complete test suite before opening the pull request.
5. Document user-visible behavior and privacy implications.

By intentionally submitting a contribution, you agree that it is licensed under the Apache License 2.0 as described in [LICENSE](LICENSE).

## Security and privacy

Do not include credentials, private OpenWebUI URLs, user transcripts, model caches or generated databases. Report vulnerabilities according to [SECURITY.md](SECURITY.md).
