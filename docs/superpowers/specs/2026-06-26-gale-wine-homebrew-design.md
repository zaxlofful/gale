# Gale Wine Homebrew Wrapper Design

## Goal

Make the existing x64 Windows release of Gale launchable on Apple Silicon Macs through a Homebrew-managed Wine wrapper, without requiring a native macOS build or an Apple Developer account.

## Scope

The first milestone supports macOS Sonoma or newer on Apple Silicon. A successful installation provides a `gale-wine` command that initializes a private Wine prefix, installs Gale from its upstream Windows MSI, and launches Gale's Windows user interface.

This milestone does not promise Steam discovery, automatic game discovery, native macOS game support, or reliable game launching. Those features require separate Wine-prefix and game-path integration.

## Packaging Architecture

A custom Homebrew tap contains a `gale-wine` Cask and its launcher. The Cask downloads the unmodified Gale x64 Windows MSI and installs the launcher into Homebrew's binary directory.

The Cask checks these host requirements:

- Apple Silicon CPU.
- macOS Sonoma or newer.
- Rosetta 2, because Gale and its Windows dependencies are x64.
- A compatible Wine executable.

The wrapper locates Wine at runtime rather than embedding a versioned Homebrew path. This keeps the package replaceable when Homebrew disables the currently deprecated `wine-stable` Cask. Whisky and Bottles are not supported runtime providers: Whisky is discontinued, and Bottles is a Linux application.

The initial implementation may recommend `wine-stable` while it remains available, but runtime discovery and diagnostics must not assume that provider is permanent.

## Wine Prefix and Installation

The wrapper owns this prefix:

```text
~/Library/Application Support/GaleWine
```

It sets `WINEPREFIX` to that directory for every initialization, installation, and launch command. On first launch, it initializes the prefix and installs Gale's MSI silently. A marker containing the packaged Gale version records successful installation.

When the packaged Gale version changes, the wrapper runs the newer MSI in the existing prefix and updates the marker only after the installer exits successfully. A failed installation leaves the previous marker untouched and prints an actionable error.

The wrapper launches Gale from the installed Windows path inside the prefix. It never deletes or recreates an existing prefix automatically.

## User Data Lifecycle

Normal Cask upgrades and uninstall operations preserve the Wine prefix. This protects Gale settings, profiles, cached data, and installed state.

The Cask's `zap` operation removes:

```text
~/Library/Application Support/GaleWine
```

The launcher and packaged MSI are removed by an ordinary Cask uninstall.

## Errors and Diagnostics

The launcher exits before modifying the prefix when:

- it is run on an unsupported CPU or macOS version;
- Rosetta 2 is unavailable;
- no compatible Wine executable can be found; or
- the packaged MSI is missing.

Errors identify the failed prerequisite and show a concrete remediation command where one is stable. Installer and launch failures include the command's exit status. Diagnostic messages go to standard error; successful first-run progress goes to standard output.

## Testing

Shell-level tests run with stub executables and temporary directories. They verify:

- platform and architecture rejection;
- Wine discovery precedence;
- missing-Wine diagnostics;
- first-run prefix initialization and MSI installation;
- no reinstall when the version marker matches;
- upgrade when the marker is older;
- marker preservation after an installer failure;
- correct Gale executable launch;
- paths containing spaces.

Homebrew validation checks Cask syntax and audit output where the local Homebrew tooling is available.

A macOS CI job performs installation and non-GUI prefix initialization when GitHub's runner permits Rosetta and Wine. The definitive GUI smoke test is manual on an Apple M1 machine:

```bash
brew install --cask gale-wine
gale-wine
```

The milestone is accepted when Gale's main Windows UI opens through the dedicated prefix. Game-management compatibility remains outside this acceptance criterion.

## Distribution and Security

The wrapper uses Gale's existing published Windows MSI and pins its SHA-256 checksum in the Cask. It does not re-sign or modify Gale. The Wine runtime remains separately installed and independently updatable.

Because this is intended initially for a project tap, the package must clearly state that it is an unofficial compatibility wrapper rather than an upstream native macOS release.
