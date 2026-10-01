# Aurora

[![Engine](https://github.com/R0GUEEE/Aurora/actions/workflows/ci.yml/badge.svg)](https://github.com/R0GUEEE/Aurora/actions/workflows/ci.yml)
[![App Build](https://github.com/R0GUEEE/Aurora/actions/workflows/app-build.yml/badge.svg)](https://github.com/R0GUEEE/Aurora/actions/workflows/app-build.yml)

A package manager for jailbroken iOS — rootless and rootful, with its own
dependency resolver instead of a wrapper around `apt`.

This repository contains the **engine** (`AuroraCore`), a **command-line front
end** (`aurora`), and the **app** (`App/`, SwiftUI). The engine is the part that
decides what installing a package actually means; it is usable on its own and is
what the test suite covers.

```sh
swift build
swift test
.build/debug/aurora env
.build/debug/aurora plan install com.example.tweak
```

## Why another one

Existing clients either shell out to `apt` and show you its output, or reimplement
a subset of it and hope. Aurora does the second thing deliberately, and is explicit
about where the line is:

| Decision | Why |
| --- | --- |
| Own resolver, `dpkg` for the files | Dependency resolution is the part that has to be *good* to be better than what exists. Unpacking, conffile handling and maintainer-script bookkeeping are the part that must be *identical* to what every package on the device was built against, so that stays with `dpkg`. |
| Verify, then install | Every archive's control file is compared against the index record the plan was computed from. A repository that serves a different version than its index advertises is stopped before `dpkg` sees it. |
| Signature state is visible, not fatal | Most jailbreak repositories are unsigned. Requiring signatures by default empties the store; pretending everything is signed is dishonest. Every source shows `Signed` / `Unsigned` / `Signature rejected`, and a policy switch makes signatures mandatory for users who want that. |
| Nothing is vendored | gzip via the system zlib, xz via Apple's `Compression`, hashing via CryptoKit. The only C dependency is `libz`, which is part of iOS. |
| Rootless first | `/var/jb` is where a modern jailbreak lives; rootful is supported but not assumed. |

## What works today

**Engine**
- `DebianVersion` ordering that matches `dpkg` exactly, including the `~` rule,
  validated against real `dpkg` on 1332 pairs (`Tools/fuzz_version_order.py`, the
  vectors are the test fixture).
- Control-field parsing with lossless round-tripping — the dpkg status file is
  read and written without dropping fields Aurora does not understand.
- Dependency, conflict, provides/replaces and multi-architecture-aware index
  handling.
- Greedy-with-repair resolver producing an ordered, verified `TransactionPlan`:
  removals first, then unpack in dependency order, then one configure pass.
- Repository refresh against both layouts (flat and `dists`), with the `Release`
  hash chain enforced, on-disk index caching and conditional requests.
- `.deb` reading (ar + tar, GNU long names, pax, base-256 sizes): control
  metadata, maintainer scripts, payload summary.
- `dpkg` execution through `posix_spawn` with a controlled environment, atomic
  status-file writes and a backup.

**App** — Browse / Search / Sources / queue / transaction log / settings, iOS 16+.

## Layout

```
Sources/AuroraCore/
  Version/      DebianVersion, constraints, dpkg-compatible ordering
  Index/        control stanzas, package records, package index, Release files
  Resolve/      queue model, dependency resolver, transaction plans
  Repo/         repository sources, HTTP transport, refresh, signature checking
  Database/     the installed-package database (dpkg status)
  Install/      .deb reader, dpkg client, transaction executor
  Compression/  container detection and decompression
  Environment/  rootless/rootful detection, source persistence
Sources/AuroraCLI/  the `aurora` command
App/                the SwiftUI app
Tests/              XCTest suite and fixtures (real .deb, real gzip/xz indexes)
Tools/              fixture generation and the dpkg fuzz harness
```

## Building the app and the .deb

See [`App/README.md`](App/README.md). Short version, on a Mac:

```sh
brew install xcodegen ldid dpkg
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/Aurora.xcodeproj -scheme Aurora -configuration Release \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
Packaging/build-deb.sh build/Release-iphoneos/Aurora.app --rootless
```

## What is verified, and how

| Check | How |
| --- | --- |
| Version ordering | 1332 pairs fuzzed against a real `dpkg --compare-versions`; the resulting table is a test fixture, so the Swift transcription is checked against dpkg, not against itself. |
| Fixtures | Built by real `dpkg-deb`, `gzip` and `xz`, and byte-reproducible (`SOURCE_DATE_EPOCH`); CI regenerates them and diffs. |
| Parser | Round-trip and idempotency checked over the real `status`/`Packages`/`Release` fixtures (`Tools/parser_mirror.py`), which is the property the dpkg status writer depends on. |
| Engine | 112 XCTest cases on the macOS runner, including gz and xz indexes decompressing to the same bytes as the plain one. |
| App | `xcodegen` + `xcodebuild` on a real device SDK, then packaged into both `.deb` layouts and checked for `Applications/Aurora.app/Aurora`. |
| Binary | Inspected directly: 64-bit arm64 Mach-O with an `LC_CODE_SIGNATURE` carrying `platform-application` and `com.apple.private.security.no-container`. |

Not verified: installation on a physical device. Nothing here has been run
against a live jailbreak.

## Status and limits

Honest list, because a package manager that lies about its coverage is dangerous:

- **Not implemented:** source packages, `apt`-style pinning/preferences,
  `Multi-Arch: foreign` promotion, debconf, `.list`-format sources interop,
  progress-percentage reporting for `dpkg` (output is streamed, not parsed).
- **Resolver:** greedy with a repair loop. It is not a SAT solver, so a
  pathological set of alternatives can produce a plan apt would have resolved
  differently — but it never emits a plan whose dependency clauses do not all
  check out.
- **zstd indexes** need a helper binary; there is no zstd decoder on iOS and one
  is deliberately not vendored. Every major repository also publishes xz or gzip.
- **OpenPGP verification** uses the device's `gpgv`/`sqv` and keyrings. Where
  neither exists, sources report `Signature not checked` rather than `Signed`.
- The app does not yet do background refreshes, and it has never been installed
  on a physical device.

## License

MIT — see [LICENSE](LICENSE).
