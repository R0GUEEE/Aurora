# Architecture

## The one decision that shapes everything

Aurora resolves dependencies itself and hands `dpkg` a list of archives.

```
queue → resolver → plan → verify → dpkg --unpack → dpkg --configure -a
```

The split is not arbitrary. Dependency resolution is where existing clients are
weak, so that is where the work went. Everything else — conffile prompts, script
ordering, file ownership, trigger bookkeeping — is where `dpkg` is strong and
where every package on the device was built expecting `dpkg`'s exact behaviour.
Reimplementing that would be the fastest way to produce a package manager that
breaks devices.

## Layers

```
AuroraCore
├── Version      DebianVersion, version constraints
├── Index        ControlStanza → PackageRecord → PackageIndex, ReleaseFile
├── Resolve      PackageQueue → DependencyResolver → TransactionPlan
├── Repo         RepositorySource → RepositoryClient (HTTP, cache, signatures)
├── Database     InstalledPackageDatabase (dpkg status)
├── Install      DebArchive, DpkgClient, InstallEngine
├── Compression  CompressionFormat + Decompressor
└── Environment  JailbreakEnvironment, SourceStore
```

Each layer depends only on the ones above it. `Version` and `Index` are pure: no
I/O, no Foundation networking, no process spawning — which is why they are the
most heavily tested part.

## Data flow for a refresh

1. `RepositoryClient.refresh(source)` fetches `InRelease` (clearsigned) or
   `Release` + `Release.gpg`/`.asc`.
2. The signature is checked with the device's `gpgv` or `sqv`.
3. For each architecture and component, the `Release` file's `SHA256` block
   decides which `Packages.*` file may be fetched. **A path the Release file does
   not list is never requested.** Preference order is xz → gzip → zstd → bzip2 →
   plain.
4. Size and digest are checked before the bytes are parsed.
5. Conditionally-cached indexes answer `304` and are reused, so a refresh with a
   warm cache costs one round trip per source.
6. Stanzas become `PackageRecord`s tagged with their `RepositoryID`.

## Data flow for a transaction

1. The user stages `PackageAction`s (`.install`, `.remove(name:purge:)`, …).
2. `DependencyResolver` builds a target set:
   - seed it with the installed packages, then apply the queue;
   - walk `Pre-Depends` and `Depends` depth-first, preferring what is already
     installed, then the highest version that satisfies the constraint, honouring
     versioned `Provides`;
   - remove whatever the target set conflicts with, then re-walk the packages that
     depended on the losers;
   - verify every clause of every package *in the transaction*.
3. The plan is ordered: removals → unpacks (topological) → one configure pass.
4. `InstallEngine` downloads and **verifies the control file of every archive
   against the record the plan was built from**, then runs `dpkg`.
5. Failures stop the transaction, and a configure pass is attempted so the device
   is left in a state `dpkg --configure -a` can finish.

## Invariants worth preserving

- **A plan is all-or-nothing.** Nothing is emitted unless every clause in the
  transaction checks out. Partial plans are how devices break.
- **The status file is never truncated in place.** Write beside it, then rename.
- **An index record is not trusted until its hash matched the signed Release
  file.** An archive is not trusted until its control file matched the record.
- **`--force-*` is not used** except `--force-confold`, which is what makes a
  non-interactive client safe. The resolver is what is supposed to make the
  transaction consistent, not a force flag.
- **Untouched installed packages are not validated.** Jailbreaks accumulate
  packages whose dependencies disappeared from the internet years ago; refusing to
  install anything until the whole device is pristine would make the client
  useless.

## Where the risk is

Ordered by how bad the failure would be:

1. **Writing `/var/lib/dpkg/status`** — mitigated by atomic writes plus a backup,
   and by the fact that `dpkg` itself maintains the file during normal operation.
2. **The resolver removing something it should not** — mitigated by protecting
   essential/required packages, by refusing to remove a package whose dependents
   cannot also be removed, and by the verification pass.
3. **Decompression** — bounded: index size limits, bounded decode attempts, and a
   hard cap on decompressed size.
4. **Signature policy** — the default trusts unsigned repositories (because that
   is the ecosystem) but reports it per source, and `requireSignature` turns the
   reporting into enforcement.
