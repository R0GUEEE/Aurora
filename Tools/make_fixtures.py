#!/usr/bin/env python3
"""Builds the fixtures the AuroraCore test suite parses.

Everything here is produced by the real tools (dpkg-deb, gzip, xz, sha256sum) so
the tests exercise the on-disk formats rather than a convenient approximation of
them. Re-running the script is expected to be byte-identical.

    python3 Tools/make_fixtures.py
"""
import gzip
import hashlib
import lzma
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Tests", "AuroraCoreTests", "Fixtures")
PACKAGES_DIR = os.path.join(FIXTURES, "packages")

# ---------------------------------------------------------------- Packages index
#
# Deliberately awkward: a dependency with alternatives, a virtual package with a
# versioned Provides, a conflict, an uninstallable dependency, a dependency cycle,
# a package with no version constraint, and both architectures.
PACKAGES = [
    {
        "Package": "bash",
        "Version": "5.2.15-2",
        "Architecture": "iphoneos-arm64",
        "Essential": "yes",
        "Section": "shells",
        "Installed-Size": "1580",
        "Maintainer": "Procursus Team <team@procursus.org>",
        "Description": "The GNU Bourne Again SHell\n A shell that everything else assumes is present.",
    },
    {
        "Package": "coreutils",
        "Version": "9.1-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "4200",
        "Maintainer": "Procursus Team <team@procursus.org>",
        "Depends": "bash (>= 5.0)",
        "Description": "Core utilities",
    },
    {
        "Package": "libfoo1",
        "Version": "1.4.2-3",
        "Architecture": "iphoneos-arm64",
        "Section": "libs",
        "Installed-Size": "312",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Shared library used by the test fixtures",
    },
    {
        "Package": "foo-app",
        "Version": "2.0.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "2048",
        "Depends": "libfoo1 (>= 1.4), bash",
        "Suggests": "foo-extras",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Fixture application\n Upgradable, and needs libfoo1.",
    },
    {
        "Package": "foo-app",
        "Version": "1.9.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "2000",
        "Depends": "libfoo1 (>= 1.0), bash",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Fixture application (older version)",
    },
    {
        "Package": "newapp",
        "Version": "0.5-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "120",
        "Depends": "libfoo1 (>= 1.0) | libbar1",
        "Conflicts": "oldapp",
        "Replaces": "oldapp",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Takes over files from oldapp",
    },
    {
        "Package": "oldapp",
        "Version": "1.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "100",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Obsolete package",
    },
    {
        "Package": "plugin",
        "Version": "3.1-1",
        "Architecture": "iphoneos-arm64",
        "Section": "tweaks",
        "Installed-Size": "64",
        "Depends": "foo-app (>= 2.0)",
        "Recommends": "coreutils",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Depends on the newest foo-app",
    },
    {
        "Package": "plugin",
        "Version": "3.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "tweaks",
        "Installed-Size": "60",
        "Depends": "foo-app (>= 1.0)",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Older plugin",
    },
    {
        "Package": "mailserver",
        "Version": "7.2-1",
        "Architecture": "iphoneos-arm64",
        "Section": "mail",
        "Installed-Size": "500",
        "Provides": "mail-transport-agent (= 7.2)",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Provides the mail-transport-agent virtual name",
    },
    {
        "Package": "mailclient",
        "Version": "1.1-1",
        "Architecture": "iphoneos-arm64",
        "Section": "mail",
        "Installed-Size": "900",
        "Depends": "mail-transport-agent",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Needs a mail transport agent",
    },
    {
        "Package": "brokenapp",
        "Version": "1.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "10",
        "Depends": "does-not-exist (>= 1)",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Cannot be installed",
    },
    {
        "Package": "cyc-a",
        "Version": "1.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "10",
        "Depends": "cyc-b",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Half of a dependency cycle",
    },
    {
        "Package": "cyc-b",
        "Version": "1.0-1",
        "Architecture": "iphoneos-arm64",
        "Section": "utils",
        "Installed-Size": "10",
        "Depends": "cyc-a",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "The other half",
    },
    {
        "Package": "arch-all-tool",
        "Version": "1.0-1",
        "Architecture": "all",
        "Section": "utils",
        "Installed-Size": "20",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Architecture-independent package",
    },
    {
        "Package": "legacy-tweak",
        "Version": "0.9-1",
        "Architecture": "iphoneos-arm",
        "Section": "tweaks",
        "Installed-Size": "40",
        "Maintainer": "Aurora Test <test@example.invalid>",
        "Description": "Rootful-era architecture",
    },
]

# Installed state: bash + coreutils + libfoo1 + foo-app 1.9 + oldapp.
STATUS = [
    {
        "Package": "bash",
        "Status": "install ok installed",
        "Version": "5.2.15-2",
        "Architecture": "iphoneos-arm64",
        "Essential": "yes",
        "Installed-Size": "1580",
        "Description": "The GNU Bourne Again SHell",
    },
    {
        "Package": "coreutils",
        "Status": "install ok installed",
        "Version": "9.1-1",
        "Architecture": "iphoneos-arm64",
        "Depends": "bash (>= 5.0)",
        "Installed-Size": "4200",
        "Description": "Core utilities",
    },
    {
        "Package": "libfoo1",
        "Status": "install ok installed",
        "Version": "1.4.2-3",
        "Architecture": "iphoneos-arm64",
        "Installed-Size": "312",
        "Description": "Shared library used by the test fixtures",
    },
    {
        "Package": "foo-app",
        "Status": "install ok installed",
        "Version": "1.9.0-1",
        "Architecture": "iphoneos-arm64",
        "Depends": "libfoo1 (>= 1.0), bash",
        "Installed-Size": "2000",
        "Description": "Fixture application",
    },
    {
        "Package": "oldapp",
        "Status": "install ok installed",
        "Version": "1.0-1",
        "Architecture": "iphoneos-arm64",
        "Installed-Size": "100",
        "Description": "Obsolete package",
    },
    {
        "Package": "halfbroken",
        "Status": "install ok half-configured",
        "Version": "0.1-1",
        "Architecture": "iphoneos-arm64",
        "Installed-Size": "12",
        "Conffiles": "\n /etc/halfbroken.conf deadbeef",
        "Description": "Installed but never configured",
    },
    {
        "Package": "goneconf",
        "Status": "deinstall ok config-files",
        "Version": "0.2-1",
        "Architecture": "iphoneos-arm64",
        "Installed-Size": "8",
        "Description": "Removed, configuration files kept",
    },
]


# Download metadata. Invented, but well formed: the resolver adds `Size` values
# into a plan's download total and `RepositoryClient.packageURL` builds a URL from
# `Filename`, so both need something real to work on.
def add_download_metadata(entries):
    for entry in entries:
        key = "%s_%s_%s" % (entry["Package"], entry["Version"], entry["Architecture"])
        entry["Filename"] = "pool/main/%s/%s.deb" % (entry["Package"][0], key)
        entry["Size"] = str(4096 + int(entry["Installed-Size"]) * 300)
        entry["SHA256"] = hashlib.sha256(key.encode()).hexdigest()
        entry["MD5sum"] = hashlib.md5(key.encode()).hexdigest()
    return entries


def render(entries):
    """Serialises entries to control-file format, fields in insertion order."""
    out = []
    for entry in entries:
        for name, value in entry.items():
            lines = value.split("\n")
            out.append("%s: %s" % (name, lines[0]))
            for extra in lines[1:]:
                out.append(" ." if extra == "" else " " + extra)
        out.append("")
    return "\n".join(out)


def main():
    # Only the generated tree is cleared: Fixtures/version-vectors.tsv is the
    # dpkg-derived table produced by Tools/fuzz_version_order.py and must survive
    # a fixture regeneration, or CI's reproducibility check would see it vanish.
    if os.path.isdir(PACKAGES_DIR):
        shutil.rmtree(PACKAGES_DIR)
    os.makedirs(PACKAGES_DIR)

    packages = render(add_download_metadata(PACKAGES)).encode()
    status = render(STATUS).encode()

    with open(os.path.join(PACKAGES_DIR, "Packages"), "wb") as handle:
        handle.write(packages)
    with open(os.path.join(PACKAGES_DIR, "Packages.gz"), "wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as handle:
            handle.write(packages)
    with lzma.open(os.path.join(PACKAGES_DIR, "Packages.xz"), "wb") as handle:
        handle.write(packages)
    with open(os.path.join(PACKAGES_DIR, "status"), "wb") as handle:
        handle.write(status)

    # Release file, hashed the way a repository would: sha256 for the compressed
    # forms (what a client actually downloads) and md5 for the plain one.
    release_lines = [
        "Origin: Aurora Test Fixtures",
        "Label: Aurora",
        "Suite: stable",
        "Version: 1.0",
        "Codename: stable",
        "Architectures: iphoneos-arm64 iphoneos-arm",
        "Components: main",
        "Description: Fixtures for the AuroraCore test suite",
        "Date: Fri, 26 Sep 2026 12:00:00 UTC",
        "Valid-Until: Fri, 26 Sep 2031 12:00:00 UTC",
    ]
    sha256_lines = []
    md5_lines = []
    for name in ["Packages", "Packages.gz", "Packages.xz"]:
        path = os.path.join(PACKAGES_DIR, name)
        with open(path, "rb") as handle:
            data = handle.read()
        sha256_lines.append(" %s %d main/binary-iphoneos-arm64/%s"
                            % (hashlib.sha256(data).hexdigest(), len(data), name))
        md5_lines.append(" %s %d main/binary-iphoneos-arm64/%s"
                         % (hashlib.md5(data).hexdigest(), len(data), name))
    release_lines.append("SHA256:")
    release_lines.extend(sha256_lines)
    release_lines.append("MD5Sum:")
    release_lines.extend(md5_lines)
    with open(os.path.join(PACKAGES_DIR, "Release"), "w") as handle:
        handle.write("\n".join(release_lines) + "\n")

    # A hand-written clearsigned document: the parser (and its dash-unescaping)
    # can be tested without a signature being valid.
    inrelease = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

Origin: Aurora Test Fixtures
Label: Aurora
Suite: stable
- - this line was dash-escaped by the signer
SHA256:
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100 main/binary-iphoneos-arm64/Packages
-----BEGIN PGP SIGNATURE-----

iQIzBAEBCgAdFiEEfakesignaturefakesignaturefakesignatureFAs=
=fake
-----END PGP SIGNATURE-----
"""
    with open(os.path.join(PACKAGES_DIR, "InRelease-sample"), "w") as handle:
        handle.write(inrelease)

    build_test_deb()
    print("fixtures written to %s" % FIXTURES)
    for root, _, files in os.walk(FIXTURES):
        for name in sorted(files):
            path = os.path.join(root, name)
            print("  %-52s %6d bytes" % (os.path.relpath(path, FIXTURES), os.path.getsize(path)))
    return 0


def build_test_deb():
    """Real .deb, built by dpkg-deb, with a maintainer script and a payload.

    The working tree is built under the system temporary directory: the shared
    Minis filesystem does not keep permission bits, and dpkg-deb refuses a
    maintainer script that is not executable.
    """
    work = os.path.join(tempfile.mkdtemp(prefix="aurora-deb-"))
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(os.path.join(work, "DEBIAN"))
    os.makedirs(os.path.join(work, "usr", "bin"))
    os.makedirs(os.path.join(work, "usr", "share", "aurora"))

    with open(os.path.join(work, "DEBIAN", "control"), "w") as handle:
        handle.write(
            "Package: aurora-fixture\n"
            "Version: 1.2.3-1\n"
            "Architecture: iphoneos-arm64\n"
            "Maintainer: Aurora Test <test@example.invalid>\n"
            "Section: utils\n"
            "Priority: optional\n"
            "Installed-Size: 12\n"
            "Depends: bash\n"
            "Description: A tiny package used to test the .deb reader\n"
            " It has a payload, a maintainer script and a conffile.\n"
        )
    with open(os.path.join(work, "DEBIAN", "postinst"), "w") as handle:
        handle.write("#!/bin/sh\nset -e\necho aurora-fixture configured\n")
    os.chmod(os.path.join(work, "DEBIAN", "postinst"), 0o755)
    with open(os.path.join(work, "DEBIAN", "conffiles"), "w") as handle:
        handle.write("/etc/aurora-fixture.conf\n")

    with open(os.path.join(work, "usr", "bin", "aurora-fixture"), "w") as handle:
        handle.write("#!/bin/sh\necho aurora\n")
    os.chmod(os.path.join(work, "usr", "bin", "aurora-fixture"), 0o755)
    with open(os.path.join(work, "usr", "share", "aurora", "data.txt"), "w") as handle:
        handle.write("payload data\n" * 20)
    os.makedirs(os.path.join(work, "etc"))
    with open(os.path.join(work, "etc", "aurora-fixture.conf"), "w") as handle:
        handle.write("# managed by dpkg; conffile\n")

    output = os.path.join(PACKAGES_DIR, "aurora-fixture_1.2.3-1_iphoneos-arm64.deb")
    # SOURCE_DATE_EPOCH makes dpkg-deb stamp every tar member with the same time,
    # so regenerating the fixture produces the same bytes and CI can assert it.
    environment = dict(os.environ)
    environment["SOURCE_DATE_EPOCH"] = "1758897600"
    result = subprocess.run(
        ["dpkg-deb", "--build", "--root-owner-group", work, output],
        capture_output=True,
        env=environment,
    )
    shutil.rmtree(work)
    if result.returncode != 0:
        sys.stderr.write(result.stdout.decode() + result.stderr.decode())
        raise SystemExit("dpkg-deb failed")


if __name__ == "__main__":
    sys.exit(main())
