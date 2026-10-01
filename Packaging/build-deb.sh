#!/bin/sh
#
# build-deb.sh — package an already-built Aurora.app into a jailbreak .deb.
#
# Usage:
#   Packaging/build-deb.sh /path/to/Aurora.app [--rootless|--rootful]
#   APP_PATH=/path/to/Aurora.app Packaging/build-deb.sh --rootful
#   Packaging/build-deb.sh /path/to/Aurora.app --print-layout
#
# Options:
#   --rootless        install to /var/jb/Applications (default; iphoneos-arm64)
#   --rootful         install to /Applications      (iphoneos-arm; iphoneos-arm)
#   --print-layout    print the resulting file list and exit without building
#   --version <v>     override the version (default: CFBundleShortVersionString)
#   --output <dir>    where to write the .deb (default: ./dist)
#   -h, --help        this text
#
# The script never builds the app: it takes a bundle that `xcodebuild` already
# produced (see App/README.md) and turns it into something Installer.app, Sileo
# or `dpkg -i` can install.
#
set -eu

PROG_NAME=$(basename -- "$0")

die() {
    printf '%s: error: %s\n' "$PROG_NAME" "$1" >&2
    exit 1
}

note() {
    printf '%s: %s\n' "$PROG_NAME" "$1" >&2
}

usage() {
    cat <<'USAGE'
Usage: build-deb.sh <Aurora.app> [--rootless|--rootful] [options]

  --rootless        install to /var/jb/Applications (default, iphoneos-arm64)
  --rootful         install to /Applications (iphoneos-arm)
  --print-layout    print the file list the package would contain, then exit
  --version <v>     version to put in the control file (default: from Info.plist)
  --output <dir>    output directory for the .deb (default: ./dist)
  -h, --help        show this text

The app path may also be given through the APP_PATH environment variable.
USAGE
}

# ---------------------------------------------------------------- arguments --

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

APP_PATH=${APP_PATH:-}
LAYOUT=rootless
PRINT_LAYOUT=0
VERSION=
OUTPUT_DIR=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rootless)     LAYOUT=rootless ;;
        --rootful)      LAYOUT=rootful ;;
        --print-layout) PRINT_LAYOUT=1 ;;
        --version)      [ "$#" -ge 2 ] || die "--version needs a value"
                        VERSION=$2; shift ;;
        --version=*)    VERSION=${1#--version=} ;;
        --output)       [ "$#" -ge 2 ] || die "--output needs a value"
                        OUTPUT_DIR=$2; shift ;;
        --output=*)     OUTPUT_DIR=${1#--output=} ;;
        -h|--help)      usage; exit 0 ;;
        -*)             die "unknown option: $1 (try --help)" ;;
        *)              if [ -z "$APP_PATH" ]; then
                            APP_PATH=$1
                        else
                            die "unexpected argument: $1 (the app path is already set)"
                        fi ;;
    esac
    shift
done

[ -n "$APP_PATH" ] || die "no app bundle given; pass it as the first argument or set APP_PATH"

# ------------------------------------------------------------- layout setup --

case "$LAYOUT" in
    rootless)
        DEB_ARCH=iphoneos-arm64
        # Debian-absolute install root, without a leading slash so it can be
        # joined onto the staging directory.
        INSTALL_PREFIX=var/jb
        ;;
    rootful)
        DEB_ARCH=iphoneos-arm
        INSTALL_PREFIX=
        ;;
    *)
        die "internal error: unknown layout '$LAYOUT'"
        ;;
esac

APP_REL="${INSTALL_PREFIX:+$INSTALL_PREFIX/}Applications/Aurora.app"

# ----------------------------------------------------------------- checks ----

[ -d "$APP_PATH" ] || die "app bundle not found at '$APP_PATH' (build it first: see App/README.md)"
[ -f "$APP_PATH/Info.plist" ] || die "'$APP_PATH' does not look like an app bundle (no Info.plist)"
[ -f "$APP_PATH/Aurora" ] || die "'$APP_PATH/Aurora' is missing; the package must contain Applications/Aurora.app/Aurora"
[ -x "$APP_PATH/Aurora" ] || die "'$APP_PATH/Aurora' is not executable; check the build output"

CONTROL_TEMPLATE="$REPO_ROOT/Packaging/control.template"
[ -f "$CONTROL_TEMPLATE" ] || die "control template not found at '$CONTROL_TEMPLATE'"

# ------------------------------------------------------------------ version --

if [ -z "$VERSION" ]; then
    VERSION=1.0.0
    if command -v plutil >/dev/null 2>&1; then
        # `plutil -extract ... raw` exists on macOS 12+; anything older or a
        # broken plist simply falls back to the default above.
        from_plist=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)
        if [ -n "$from_plist" ]; then
            VERSION=$from_plist
        fi
    fi
fi

# Keep the file name safe for shells and URLs while preserving the epoch colon's
# meaning-less-ness: `1:2.0` becomes `1-2.0`.
VERSION_SAFE=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9.+~' '-')
[ -n "$VERSION_SAFE" ] || die "could not derive a file-name-safe version from '$VERSION'"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$REPO_ROOT/dist"
fi
DEB_NAME="aurora_${VERSION_SAFE}_${DEB_ARCH}.deb"

# -------------------------------------------------------------- print layout -

if [ "$PRINT_LAYOUT" != "0" ]; then
    # No dpkg-deb, no copy, no signing: this mode only answers "what would the
    # package contain?", which is what CI asserts on.
    printf './DEBIAN/control\n'
    if [ "$LAYOUT" = "rootless" ]; then
        printf './var/jb\n'
        printf './var/jb/Applications\n'
        printf './var/jb/Applications/Aurora.app\n'
    else
        printf './Applications\n'
        printf './Applications/Aurora.app\n'
    fi
    (
        cd "$APP_PATH" || exit 1
        find . ! -name . -print
    ) | sed -e 's|^\./||' -e "s|^|./$APP_REL/|"
    printf '\n# layout: %s   architecture: %s   version: %s\n' "$LAYOUT" "$DEB_ARCH" "$VERSION" >&2
    printf '# target: %s\n' "$DEB_NAME" >&2
    exit 0
fi

# --------------------------------------------------------------- toolchain ---

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is not installed; on macOS: brew install dpkg (Debian/Ubuntu: apt install dpkg-dev)"

supports_flag() {
    # Looks for a literal option name in `dpkg-deb --help` output. Done with a
    # shell `case` rather than `grep` so that the check has no early-exit pipe
    # to trip over (and works the same on busybox, BSD and GNU userlands).
    help_text=$(dpkg-deb --help 2>&1 || true)
    case "$help_text" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------ staging --

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/aurora-deb.XXXXXX") || die "could not create a temporary directory"
# shellcheck disable=SC2064 # we want STAGE expanded now, not when the trap runs
trap "rm -rf '$STAGE'" EXIT INT TERM

mkdir -p "$STAGE/DEBIAN"
mkdir -p "$STAGE/$APP_REL"

note "staging $LAYOUT app in $STAGE"

# `cp -R` copies symbolic links as links on both BSD and GNU cp, which matters:
# app bundles can contain framework symlinks and dereferencing them would
# duplicate megabytes.
cp -R "$APP_PATH/." "$STAGE/$APP_REL/"

# macOS sets quarantine/com.apple.* xattrs and AppleDouble `._*` files on files
# it did not create; both would end up inside the package and confuse dpkg.
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGE/$APP_REL" 2>/dev/null || note "could not clear extended attributes (continuing)"
fi
find "$STAGE/$APP_REL" -name '._*' -type f -exec rm -f {} \; 2>/dev/null || true

# ------------------------------------------------------------------ control --

control_version=$(printf '%s' "$VERSION" | sed -e 's/[\\&|]/\\&/g')
control_arch=$(printf '%s' "$DEB_ARCH" | sed -e 's/[\\&|]/\\&/g')
sed -e "s|@VERSION@|$control_version|g" -e "s|@ARCH@|$control_arch|g" \
    "$CONTROL_TEMPLATE" > "$STAGE/DEBIAN/control"

modified_control=$(cat "$STAGE/DEBIAN/control")
case "$modified_control" in
    *@VERSION@*|*@ARCH@*)
        die "control template still contains @VERSION@ or @ARCH@ placeholders" ;;
esac

# Installed-Size is what Installer.app uses to show the download footprint; it
# is in kibibytes, exactly like `du -sk`.
installed_size=$(du -sk "$STAGE/$APP_REL" | awk '{ print $1 }')
has_installed_size=0
while IFS= read -r control_line || [ -n "$control_line" ]; do
    case "$control_line" in
        [Ii]nstalled-[Ss]ize:*) has_installed_size=1; break ;;
    esac
done < "$STAGE/DEBIAN/control"
if [ "$has_installed_size" = "0" ]; then
    printf 'Installed-Size: %s\n' "$installed_size" >> "$STAGE/DEBIAN/control"
fi

# ------------------------------------------------------------------ signing --

# Order matters. The signature covers the whole Mach-O, so it must be written
# after every byte of the binary is final: after the copy, after the xattr
# cleanup, and after the permissions below. Nothing may touch the app after this
# block. If you change anything, re-sign (that is what the comment below means
# by "re-sign after any change").
ENTITLEMENTS="$REPO_ROOT/App/Aurora.entitlements"
if command -v ldid >/dev/null 2>&1; then
    # An old signature is invalid the moment the file is copied, and some ldid
    # builds refuse to overwrite one, so drop it first.
    rm -rf "$STAGE/$APP_REL/_CodeSignature"
    if [ -f "$ENTITLEMENTS" ]; then
        ldid -S"$ENTITLEMENTS" "$STAGE/$APP_REL/Aurora" \
            || die "ldid failed to sign with $ENTITLEMENTS"
        note "signed Aurora with $(basename -- "$ENTITLEMENTS")"
    else
        note "warning: $ENTITLEMENTS not found; signing without entitlements"
        ldid -S "$STAGE/$APP_REL/Aurora" || die "ldid failed to sign the binary"
    fi
else
    note "warning: ldid not found; shipping an unsigned binary (install it: brew install ldid)"
fi

# -------------------------------------------------------------- permissions --

# Directories and things that were already executable become 0755, everything
# else becomes 0644. Doing it by permission rather than by name keeps helper
# binaries and frameworks inside the bundle working.
find "$STAGE/$APP_REL" -type d -exec chmod 0755 {} \;
find "$STAGE/$APP_REL" -type f -perm -u+x -exec chmod 0755 {} \;
find "$STAGE/$APP_REL" -type f ! -perm -u+x -exec chmod 0644 {} \;
chmod 0755 "$STAGE/$APP_REL"
chmod 0755 "$STAGE"
chmod 0755 "$STAGE/DEBIAN"
chmod 0644 "$STAGE/DEBIAN/control"

# root:wheel is what MobileSubstrate/Installer expect for an app bundle, and
# `--root-owner-group` reproduces it when the build is not running as root (CI).
if [ "$(id -u)" = "0" ]; then
    chown -R 0:0 "$STAGE" || note "warning: chown failed; the package may carry the wrong owner"
else
    note "not running as root: relying on dpkg-deb --root-owner-group for root:wheel"
fi

# ui-tools/uicache layout note: because the bundle lands in the *standard*
# Applications directory of the jailbreak root (/var/jb/Applications or
# /Applications), nothing else is needed. Installer.app and Sileo register the
# app themselves, and `uicache -a` (run at respring) picks it up for the ones
# that do not. There is deliberately no postinst: a package manager should not
# run a shell script after installation when the layout is already correct.
# Running `uicache -p <path>/Aurora.app` by hand is only needed when you install
# with a plain `dpkg -i` and do not respring.

# ------------------------------------------------------------------- build ---

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH='' cd -- "$OUTPUT_DIR" && pwd)
DEB_PATH="$OUTPUT_DIR/$DEB_NAME"

set -- --build
if supports_flag 'root-owner-group'; then
    set -- "$@" --root-owner-group
fi
if supports_flag -Z; then
    # gzip is the compressor every jailbreak dpkg can read; xz is not always
    # available on older iOS versions and zstd almost never is.
    set -- "$@" -Zgzip
fi

note "building $DEB_PATH"
# shellcheck disable=SC2086 # `set --` above deliberately word-splits
dpkg-deb "$@" "$STAGE" "$DEB_PATH" || die "dpkg-deb failed"

[ -s "$DEB_PATH" ] || die "dpkg-deb produced no package at $DEB_PATH"

printf '%s\n' "$DEB_PATH"
note "done: $(du -h "$DEB_PATH" | awk '{ print $1 }') $DEB_NAME"
note "verify with: dpkg-deb -c '$DEB_PATH'"
