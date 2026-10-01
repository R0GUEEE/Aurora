# Building the Aurora app (and its `.deb`)

The app is a SwiftUI shell around the local SwiftPM package at the repository root
(`AuroraCore`). There is no third-party dependency: everything the app needs is in
this repository.

```
App/
  project.yml           XcodeGen spec (this is the source of truth, not the .xcodeproj)
  Aurora.entitlements   platform entitlements, applied by ldid when packaging
  Resources/Info.plist  bundle metadata
  Sources/              the app itself
Packaging/
  control.template      Debian control file, with @VERSION@ and @ARCH@ placeholders
  build-deb.sh          turns a built .app into a jailbreak .deb
```

## Prerequisites (on a Mac)

```sh
brew install xcodegen ldid dpkg
```

`xcodegen` generates the Xcode project, `ldid` signs the binary with the platform
entitlements an Apple signing identity will not give you, and `dpkg`'s `dpkg-deb`
builds the package.

## 1. Generate the project

```sh
xcodegen generate --spec App/project.yml --project App
```

`App/Aurora.xcodeproj` is generated, never edited by hand, and is not committed.
Regenerate it after adding files (XcodeGen discovers sources by directory).

## 2. Build the app

```sh
xcodebuild \
  -project App/Aurora.xcodeproj \
  -scheme Aurora \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```

The bundle ends up at `build/Build/Products/Release-iphoneos/Aurora.app`.

Signing is disabled on purpose. The entitlements in `App/Aurora.entitlements`
(`platform-application`, `com.apple.private.security.no-container`, …) are
*platform* entitlements; a normal Apple certificate cannot carry them, so the
binary is signed after packaging, on device, by `ldid`.

To work on the UI, `open App/Aurora.xcodeproj` and run on a simulator or a device.
The app degrades cleanly without a jailbreak: it shows a banner, browsing and the
queue still work, and anything that needs `dpkg` is refused with a clear message.

## 3. Build a `.deb`

```sh
Packaging/build-deb.sh build/Build/Products/Release-iphoneos/Aurora.app --rootless
```

That writes `dist/aurora_<version>_<arch>.deb`. Useful flags:

| Flag | Effect |
| --- | --- |
| `--rootless` | install to `/var/jb/Applications/Aurora.app` (default), architecture `iphoneos-arm64` |
| `--rootful` | install to `/Applications/Aurora.app`, architecture `iphoneos-arm` |
| `--print-layout` | print the exact file list the package would contain, then exit |
| `--version <v>` | override the version (default: `CFBundleShortVersionString`) |
| `--output <dir>` | where to write the `.deb` (default: `./dist`) |

Check the result before installing it:

```sh
dpkg-deb -c dist/aurora_1.0.0_iphoneos-arm64.deb   # contents
dpkg-deb -I dist/aurora_1.0.0_iphoneos-arm64.deb   # control fields
```

Then, on the device:

```sh
dpkg -i aurora_1.0.0_iphoneos-arm64.deb && uicache -p /var/jb/Applications/Aurora.app
```

A plain `dpkg -i` does not register the app with LaunchServices; `uicache`
(or a respring) does. Installers such as Sileo, Zebra and Installer.app handle
that themselves, so no `postinst` is needed and `build-deb.sh` does not write one.

## Rootless vs rootful

Jailbreaks come in two filesystem layouts and a package built for one does not
work on the other:

| | Rootless | Rootful |
| --- | --- | --- |
| Jailbreak root | `/var/jb` | `/` |
| App installs to | `/var/jb/Applications/Aurora.app` | `/Applications/Aurora.app` |
| Debian architecture | `iphoneos-arm64` | `iphoneos-arm` |
| `dpkg` | `/var/jb/usr/bin/dpkg` | `/usr/bin/dpkg` |
| Typical jailbreaks | Dopamine, palera1n (rootless), most Theos `ROOTLESS=1` builds | unc0ver, checkra1n, palera1n (rootful) |

The *binary* is identical in both: every path Aurora touches is resolved through
`AuroraCore.JailbreakEnvironment`, which detects the layout at launch. Only the
packaging differs, which is why `build-deb.sh` takes a flag instead of the build
taking a define. Installing the rootless package on a rootful device puts an app
in a directory nothing scans — it installs "successfully" and never appears.

`AuroraCore`'s package index for rootless devices therefore only offers
`iphoneos-arm64` packages by default, and the app's
"Show only rootless-compatible packages" setting hides `iphoneos-arm` ones from a
merged index.

## Continuous integration

`.github/workflows/app-build.yml` does exactly the steps above on `macos-14`,
packages both layouts, asserts that the produced `.deb` really contains
`Applications/Aurora.app/Aurora` (and that its `Architecture:` matches the layout),
and uploads both `.deb` files as artifacts.
