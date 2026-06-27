# Gale Wine Homebrew Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and launch Gale's existing x64 Windows MSI on Apple Silicon macOS through a dedicated Wine prefix managed by a Homebrew formula.

**Architecture:** A testable POSIX launcher owns prerequisite checks, Wine-tool discovery, prefix initialization, versioned MSI installation, and Gale startup. A Homebrew formula pins the upstream MSI and installs both the MSI and launcher; the launcher discovers Wine at runtime so the package is not permanently coupled to the deprecated `wine-stable` Cask.

**Tech Stack:** POSIX shell, Wine/WineHQ, Homebrew Formula DSL, ShellCheck, GitHub Actions macOS runners.

---

## File Structure

- Create `packaging/macos/gale-wine`: canonical POSIX launcher.
- Create `packaging/macos/test-gale-wine.sh`: dependency-free launcher regression tests using temporary fake Wine tools.
- Create `Formula/gale-wine.rb`: Homebrew formula pinning Gale 1.16.1's MSI and installing the launcher.
- Create `packaging/macos/check-formula-launcher.sh`: verifies the formula installs the canonical launcher from the tap checkout.
- Modify `.github/workflows/publish.yaml`: add a non-publishing macOS wrapper validation job.
- Modify `README.md`: document the experimental Apple Silicon installation path and its limitations.

### Task 1: Platform and Rosetta Prerequisites

**Files:**
- Create: `packaging/macos/gale-wine`
- Create: `packaging/macos/test-gale-wine.sh`

- [ ] **Step 1: Write failing platform tests**

Create `packaging/macos/test-gale-wine.sh` with a temporary sandbox, an `assert_status` helper, and these cases:

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LAUNCHER="$ROOT/packaging/macos/gale-wine"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

assert_status() {
  expected=$1
  shift
  set +e
  "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    printf 'expected status %s, got %s\n' "$expected" "$actual" >&2
    cat "$TMP_ROOT/stderr" >&2
    exit 1
  fi
}

assert_stderr_contains() {
  if ! grep -F "$1" "$TMP_ROOT/stderr" >/dev/null; then
    printf 'stderr did not contain: %s\n' "$1" >&2
    cat "$TMP_ROOT/stderr" >&2
    exit 1
  fi
}

assert_status 64 env GALE_WINE_OS=Linux GALE_WINE_ARCH=arm64 "$LAUNCHER"
assert_stderr_contains "requires macOS"

assert_status 64 env GALE_WINE_OS=Darwin GALE_WINE_ARCH=x86_64 "$LAUNCHER"
assert_stderr_contains "requires Apple Silicon"

assert_status 69 env \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=false \
  "$LAUNCHER"
assert_stderr_contains "Rosetta 2"
```

- [ ] **Step 2: Run tests and verify the launcher is missing**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: failure because `packaging/macos/gale-wine` does not exist.

- [ ] **Step 3: Implement prerequisite checks**

Create `packaging/macos/gale-wine`:

```sh
#!/bin/sh
set -eu

die() {
  status=$1
  shift
  printf 'gale-wine: %s\n' "$*" >&2
  exit "$status"
}

host_os=${GALE_WINE_OS:-$(uname -s)}
host_arch=${GALE_WINE_ARCH:-$(uname -m)}

[ "$host_os" = Darwin ] || die 64 "requires macOS"
[ "$host_arch" = arm64 ] || die 64 "requires Apple Silicon"

if [ "${GALE_WINE_ROSETTA_CHECK:-true}" = true; then
  /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1 ||
    die 69 "Rosetta 2 is required; install it with: softwareupdate --install-rosetta --agree-to-license"
else
  die 69 "Rosetta 2 is required; install it with: softwareupdate --install-rosetta --agree-to-license"
fi

die 69 "no compatible Wine runtime was found"
```

- [ ] **Step 4: Run tests and verify all three prerequisite cases pass**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: exit 0.

- [ ] **Step 5: Commit prerequisite checks**

```bash
git add packaging/macos/gale-wine packaging/macos/test-gale-wine.sh
git commit -m "feat: validate Gale Wine host prerequisites"
```

### Task 2: Wine Tool Discovery

**Files:**
- Modify: `packaging/macos/gale-wine`
- Modify: `packaging/macos/test-gale-wine.sh`

- [ ] **Step 1: Add failing Wine-discovery tests**

Append test setup that creates executable fake tools under a path containing spaces:

```sh
FAKE_BIN="$TMP_ROOT/fake wine/bin"
mkdir -p "$FAKE_BIN"
for tool in wine wineboot winepath; do
  printf '#!/bin/sh\nexit 0\n' >"$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
done

assert_status 66 env \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=true \
  GALE_WINE_BIN="$FAKE_BIN/wine" \
  GALE_WINE_MSI="$TMP_ROOT/missing.msi" \
  "$LAUNCHER"
assert_stderr_contains "MSI payload is missing"
```

Also add:

```sh
assert_status 69 env \
  PATH=/usr/bin:/bin \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=true \
  GALE_WINE_MSI="$TMP_ROOT/missing.msi" \
  "$LAUNCHER"
assert_stderr_contains "no compatible Wine runtime"
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: the override case reports the old no-Wine error instead of the missing-MSI error.

- [ ] **Step 3: Implement runtime discovery**

Replace the terminal error in `gale-wine` with:

```sh
find_wine() {
  if [ -n "${GALE_WINE_BIN:-}" ] && [ -x "$GALE_WINE_BIN" ]; then
    printf '%s\n' "$GALE_WINE_BIN"
    return
  fi

  for candidate in \
    "$(command -v wine64 2>/dev/null || true)" \
    "$(command -v wine 2>/dev/null || true)" \
    "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64" \
    "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine64" \
    "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine64"
  do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  return 1
}

wine_bin=$(find_wine) ||
  die 69 "no compatible Wine runtime was found; install a supported WineHQ package first"
wine_dir=$(dirname -- "$wine_bin")
wineboot_bin="$wine_dir/wineboot"
winepath_bin="$wine_dir/winepath"

[ -x "$wineboot_bin" ] || die 69 "Wine runtime is missing wineboot: $wineboot_bin"
[ -x "$winepath_bin" ] || die 69 "Wine runtime is missing winepath: $winepath_bin"

msi=${GALE_WINE_MSI:-$(CDPATH= cd -- "$(dirname -- "$0")/../libexec/gale-wine" && pwd)/Gale.msi}
[ -f "$msi" ] || die 66 "MSI payload is missing: $msi"
```

- [ ] **Step 4: Run tests**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: exit 0.

- [ ] **Step 5: Commit Wine discovery**

```bash
git add packaging/macos/gale-wine packaging/macos/test-gale-wine.sh
git commit -m "feat: discover Wine runtime for Gale"
```

### Task 3: Prefix Initialization and Versioned MSI Installation

**Files:**
- Modify: `packaging/macos/gale-wine`
- Modify: `packaging/macos/test-gale-wine.sh`

- [ ] **Step 1: Add failing installation-state tests**

Replace the simple fake tools with a dispatcher that appends every invocation to `$GALE_WINE_TEST_LOG`. Add tests that set:

```sh
PREFIX="$TMP_ROOT/Application Support/GaleWine"
MSI="$TMP_ROOT/Gale 1.16.1.msi"
LOG="$TMP_ROOT/wine.log"
touch "$MSI"
```

The fake `winepath` prints `Z:\\Gale 1.16.1.msi`. Run the launcher with:

```sh
GALE_WINE_VERSION=1.16.1
GALE_WINE_PREFIX="$PREFIX"
GALE_WINE_MSI="$MSI"
GALE_WINE_TEST_LOG="$LOG"
```

Assert that first launch logs `wineboot -u`, logs `msiexec /i`, and creates:

```text
$PREFIX/.gale-wrapper-version
```

with exactly `1.16.1`. Run it again and assert that `msiexec /i` occurs only once. Change `GALE_WINE_VERSION` to `1.16.2`, run again, and assert that installation occurs a second time and the marker becomes `1.16.2`.

- [ ] **Step 2: Run tests and verify installation assertions fail**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: failure because no prefix, installer invocation, or marker exists.

- [ ] **Step 3: Implement prefix initialization and installation**

Add:

```sh
version=${GALE_WINE_VERSION:-1.16.1}
prefix=${GALE_WINE_PREFIX:-"$HOME/Library/Application Support/GaleWine"}
marker="$prefix/.gale-wrapper-version"
export WINEPREFIX=$prefix

if [ ! -d "$prefix" ]; then
  printf 'Initializing Gale Wine prefix...\n'
  "$wineboot_bin" -u || die 70 "Wine prefix initialization failed"
fi

installed_version=
if [ -f "$marker" ]; then
  IFS= read -r installed_version <"$marker" || true
fi

if [ "$installed_version" != "$version" ]; then
  printf 'Installing Gale %s...\n' "$version"
  windows_msi=$("$winepath_bin" -w "$msi") ||
    die 70 "Wine could not translate the MSI path"
  "$wine_bin" msiexec /i "$windows_msi" /qn ||
    die 70 "Gale MSI installation failed"
  printf '%s\n' "$version" >"$marker"
fi
```

- [ ] **Step 4: Run tests**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: installation-state tests progress to the missing-Gale-executable failure.

- [ ] **Step 5: Add and verify installer-failure coverage**

Make the fake Wine dispatcher return 1 for `msiexec` when `GALE_WINE_TEST_INSTALL_FAIL=1`. Assert status 70 and assert the marker retains its prior value.

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: exit 0 after accounting for the later missing-executable condition in the test fixture.

- [ ] **Step 6: Commit prefix installation**

```bash
git add packaging/macos/gale-wine packaging/macos/test-gale-wine.sh
git commit -m "feat: install Gale into a private Wine prefix"
```

### Task 4: Gale Executable Discovery and Launch

**Files:**
- Modify: `packaging/macos/gale-wine`
- Modify: `packaging/macos/test-gale-wine.sh`

- [ ] **Step 1: Add failing launch tests**

Create this fake installed executable:

```sh
GALE_EXE="$PREFIX/drive_c/Program Files/Gale/gale.exe"
mkdir -p "$(dirname -- "$GALE_EXE")"
touch "$GALE_EXE"
```

Assert that the final fake Wine log entry contains the complete executable path. Add a second case using:

```text
$PREFIX/drive_c/Program Files/Gale/Gale.exe
```

to cover MSI filename capitalization.

- [ ] **Step 2: Run tests and verify launch assertion fails**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
```

Expected: failure because the launcher never starts Gale.

- [ ] **Step 3: Implement executable discovery and launch**

Append:

```sh
find_gale_exe() {
  for candidate in \
    "$prefix/drive_c/Program Files/Gale/gale.exe" \
    "$prefix/drive_c/Program Files/Gale/Gale.exe" \
    "$prefix/drive_c/users/$USER/AppData/Local/Gale/gale.exe" \
    "$prefix/drive_c/users/$USER/AppData/Local/Gale/Gale.exe"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

gale_exe=$(find_gale_exe) ||
  die 70 "Gale was installed but gale.exe could not be found in the Wine prefix"

exec "$wine_bin" "$gale_exe" "$@"
```

- [ ] **Step 4: Run launcher tests and ShellCheck**

Run:

```sh
sh packaging/macos/test-gale-wine.sh
shellcheck packaging/macos/gale-wine packaging/macos/test-gale-wine.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit launch behavior**

```bash
git add packaging/macos/gale-wine packaging/macos/test-gale-wine.sh
git commit -m "feat: launch installed Gale through Wine"
```

### Task 5: Homebrew Formula

**Files:**
- Create: `Formula/gale-wine.rb`
- Create: `packaging/macos/check-formula-launcher.sh`
- Modify: `packaging/macos/gale-wine`

- [ ] **Step 1: Add formula metadata constants to the launcher**

Add default environment-backed constants near the top:

```sh
version=${GALE_WINE_VERSION:-1.16.1}
msi=${GALE_WINE_MSI:-@GALE_WINE_MSI@}
```

Remove the later duplicate `version` and `msi` assignments. The installed formula substitutes `@GALE_WINE_MSI@`; repository tests continue to pass `GALE_WINE_MSI`.

- [ ] **Step 2: Write a failing launcher-drift check**

Create `packaging/macos/check-formula-launcher.sh`:

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
formula="$ROOT/Formula/gale-wine.rb"

[ -f "$formula" ] || {
  echo "missing Formula/gale-wine.rb" >&2
  exit 1
}

grep -F 'Pathname(__dir__).parent/"packaging/macos/gale-wine"' "$formula" >/dev/null || {
  echo "formula does not install the canonical launcher" >&2
  exit 1
}
```

- [ ] **Step 3: Run the drift check and verify failure**

Run:

```sh
sh packaging/macos/check-formula-launcher.sh
```

Expected: failure because the formula does not exist.

- [ ] **Step 4: Create the formula**

Create `Formula/gale-wine.rb` with:

```ruby
class GaleWine < Formula
  desc "Unofficial Wine wrapper for the Gale Thunderstore mod manager"
  homepage "https://github.com/Kesomannen/gale"
  url "https://github.com/Kesomannen/gale/releases/download/1.16.1/Gale_1.16.1_x64_en-US.msi",
      using: :nounzip
  version "1.16.1"
  sha256 "0e276537392210cab27ae6c3024c80a1c06d03379059200e542e9d175db896a4"
  license "GPL-3.0-only"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    libexec.install Dir["*.msi"].first => "Gale.msi"

    launcher_path = Pathname(__dir__).parent/"packaging/macos/gale-wine"
    launcher = launcher_path.read
    launcher.sub!("@GALE_WINE_MSI@", libexec/"Gale.msi")
    (bin/"gale-wine").write launcher
    chmod 0755, bin/"gale-wine"
  end

  def caveats
    <<~EOS
      This is an unofficial compatibility wrapper.
      Install Rosetta 2 and a supported WineHQ runtime before running gale-wine.
      Gale game discovery and launching are not supported by this initial wrapper.
    EOS
  end

  test do
    assert_match "requires macOS",
      shell_output("GALE_WINE_OS=Linux #{bin}/gale-wine 2>&1", 64)
  end
end
```

The formula reads the canonical launcher from the tap checkout. The tap must therefore retain both `Formula/gale-wine.rb` and `packaging/macos/gale-wine`; launcher logic is not duplicated inside Ruby.

- [ ] **Step 5: Run formula checks**

Run on macOS with Homebrew:

```sh
sh packaging/macos/check-formula-launcher.sh
brew style Formula/gale-wine.rb
brew audit --strict Formula/gale-wine.rb
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit formula packaging**

```bash
git add Formula/gale-wine.rb packaging/macos/gale-wine packaging/macos/check-formula-launcher.sh
git commit -m "feat: package Gale Wine wrapper for Homebrew"
```

### Task 6: macOS CI Validation

**Files:**
- Modify: `.github/workflows/publish.yaml`

- [ ] **Step 1: Add a validation job that initially fails before dependencies are configured**

Add:

```yaml
  validate-gale-wine:
    name: Validate Gale Wine wrapper
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v6

      - name: Install validation tools
        run: brew install shellcheck

      - name: Test launcher
        run: sh packaging/macos/test-gale-wine.sh

      - name: Lint shell
        run: shellcheck packaging/macos/gale-wine packaging/macos/test-gale-wine.sh packaging/macos/check-formula-launcher.sh

      - name: Check formula launcher
        run: sh packaging/macos/check-formula-launcher.sh

      - name: Validate formula
        run: |
          brew style Formula/gale-wine.rb
          brew audit --strict Formula/gale-wine.rb
```

- [ ] **Step 2: Run the equivalent local checks**

Run on macOS:

```sh
sh packaging/macos/test-gale-wine.sh
shellcheck packaging/macos/gale-wine packaging/macos/test-gale-wine.sh packaging/macos/check-formula-launcher.sh
sh packaging/macos/check-formula-launcher.sh
brew style Formula/gale-wine.rb
brew audit --strict Formula/gale-wine.rb
```

Expected: exit 0 for every command.

- [ ] **Step 3: Commit CI validation**

```bash
git add .github/workflows/publish.yaml
git commit -m "ci: validate Gale Wine Homebrew wrapper"
```

### Task 7: User Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add experimental macOS instructions**

Add a macOS section that states:

```markdown
### macOS (experimental)

The `gale-wine` package runs Gale's existing Windows build through Wine on
Apple Silicon Macs. It is an unofficial compatibility wrapper, not a native
macOS build.

Requirements:

- Apple Silicon
- macOS Sonoma or newer
- Rosetta 2
- A compatible WineHQ runtime

After adding the Gale Homebrew tap:

```sh
brew install gale-wine
gale-wine
```

The first launch creates a Wine prefix under
`~/Library/Application Support/GaleWine` and installs Gale there.

Game discovery and launching are not yet supported. This milestone only covers
launching Gale itself.
```

- [ ] **Step 2: Verify Markdown formatting and repository checks**

Run:

```sh
pnpm lint
sh packaging/macos/test-gale-wine.sh
shellcheck packaging/macos/gale-wine packaging/macos/test-gale-wine.sh packaging/macos/check-formula-launcher.sh
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe experimental Gale Wine package"
```

### Task 8: M1 Smoke Test

**Files:**
- No repository changes unless the smoke test exposes a defect.

- [ ] **Step 1: Install prerequisites on the M1 test machine**

```sh
softwareupdate --install-rosetta --agree-to-license
brew install --cask wine-stable
```

If Homebrew has disabled `wine-stable` by test time, install a current WineHQ package and confirm `wine64`, `wineboot`, and `winepath` are available together.

- [ ] **Step 2: Install the local formula**

From the repository checkout:

```sh
brew install --formula ./Formula/gale-wine.rb
```

Expected: Homebrew installs the pinned MSI and `gale-wine` launcher.

- [ ] **Step 3: Launch Gale**

```sh
gale-wine
```

Expected: the wrapper initializes `~/Library/Application Support/GaleWine`, installs Gale 1.16.1, and opens Gale's main Windows UI.

- [ ] **Step 4: Verify idempotence**

Quit Gale and run:

```sh
gale-wine
```

Expected: Gale opens without rerunning the MSI installer.

- [ ] **Step 5: Record actual Wine provider and installation path**

Capture:

```sh
command -v wine64 || command -v wine
find "$HOME/Library/Application Support/GaleWine/drive_c" -iname 'gale.exe' -print
```

Use these results to replace or extend executable candidates only if the installed path differs from the tested candidates.

## Final Verification

Run fresh:

```sh
sh packaging/macos/test-gale-wine.sh
shellcheck packaging/macos/gale-wine packaging/macos/test-gale-wine.sh packaging/macos/check-formula-launcher.sh
sh packaging/macos/check-formula-launcher.sh
pnpm lint
git diff --check
```

On the M1 machine also run:

```sh
brew style Formula/gale-wine.rb
brew audit --strict Formula/gale-wine.rb
brew test gale-wine
gale-wine
```

Completion requires all automated checks to exit 0 and Gale's main UI to open on the M1 machine.
