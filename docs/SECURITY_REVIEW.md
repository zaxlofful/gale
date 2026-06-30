# Adversarial Security Review

Date: 2026-06-30

This review applied the requested **Caveman Mode** (can I break/confuse/replace/race/inject/bypass?) and **Superpowers Mode** (multi-step, patient attacker chaining low-severity weaknesses). The named `caveman` and `superpowers` skills were requested but were not present in the installed skills list or OpenAI curated/experimental catalog under those names; this report explicitly uses those reasoning modes instead.

## Executive Risk Summary

Gale is a Tauri desktop mod manager that intentionally crosses several dangerous trust boundaries: webview JavaScript to privileged Rust IPC, internet package metadata to local filesystem writes, user-selected archives to profile extraction, deep links to import/auth flows, and GitHub release automation to signed updater artifacts. The highest-risk issues are in release/supply-chain hardening and local archive/package handling.

### Prioritized Findings

| ID   | Severity      | Finding                                                                                                                                                         |
| ---- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F-01 | High          | Release workflow relies on unpinned third-party GitHub Actions and broad default token assumptions.                                                             |
| F-02 | High          | Tauri CSP and asset protocol are overly permissive for a privileged desktop app.                                                                                |
| F-03 | High          | OAuth callback accepts bearer tokens from any process able to invoke `gale://auth/callback`, and JWTs are decoded without signature/audience/issuer validation. |
| F-04 | Medium        | Mod/profile archive extraction lacks size/count/depth limits and can be abused for disk exhaustion.                                                             |
| F-05 | Medium        | Archive extraction and install paths are vulnerable to symlink/hardlink race and filesystem pivot risks on hostile local filesystems.                           |
| F-06 | Medium        | Custom launch arguments intentionally allow arbitrary launcher prefix and environment injection.                                                                |
| F-07 | Medium        | Updater endpoint is a mutable GitHub Gist; release integrity depends on secret custody and unsigned workflow provenance.                                        |
| F-08 | Medium        | Cargo/npm dependencies are broadly version-ranged, include build scripts/proc macros/plugins, and lack provenance/SBOM policy.                                  |
| F-09 | Low           | Deep-link file import treats raw command-line argument as a filesystem path and supports broad file-origin import.                                              |
| F-10 | Low           | Several `unwrap`/`expect` paths are reachable from OS/webview/environment state and can cause denial of service.                                                |
| F-11 | Informational | Secrets are mostly not hardcoded, but CI secrets and local tokens form important trust anchors needing documented rotation and least privilege.                 |

## Review Passes

### Pass 1: Surface Review

Observed a Rust/Tauri backend with many IPC commands registered in `src-tauri/src/lib.rs`, a Svelte frontend, package installation/import/export functionality, deep links, updater configuration, and GitHub workflows. The obvious attack surfaces are package downloads, ZIP extraction, profile import, OAuth deep links, updater metadata, GitHub Actions, and privileged Tauri plugins.

### Pass 2: Trust Boundaries

| Boundary                             | What is trusted                                              | Why                                            | Violation/confusion/escalation risk                                                                                                                                           |
| ------------------------------------ | ------------------------------------------------------------ | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Webview JS -> Rust IPC               | Main window frontend code may invoke powerful commands       | Tauri command registration and capability file | If XSS, dependency compromise, or remote script execution occurs, attacker inherits filesystem, install, launch, updater, clipboard, HTTP, dialog, and shell-adjacent powers. |
| Thunderstore/API -> local filesystem | Package metadata, archive names, file contents, dependencies | App purpose requires installing mods           | Malicious mod can write large files, executable scripts, DLLs, config, and influence game launch/runtime.                                                                     |
| Deep links -> auth/import actions    | OS-dispatched `ror2mm://`/`gale://` URLs                     | Desktop integration                            | Any local app/browser can send callbacks/imports; auth tokens can be injected without PKCE/state verification visible in repo.                                                |
| GitHub Actions -> releases/updater   | Workflow dependencies, secrets, tags, Actions runners        | CI builds and publishes release artifacts      | Compromised action, token, tag, maintainer, or dependency can poison signed update metadata/artifacts.                                                                        |
| Updater endpoint -> clients          | GitHub Gist `latest.json`                                    | Tauri updater uses signed metadata             | Gist token compromise can redirect update metadata unless signature validation prevents artifact install; rollback/freeze risks remain.                                       |
| Local filesystem -> profiles/cache   | User-controlled profile directory and archives               | User chooses local paths/mods                  | Symlinks, hardlinks, races, and path aliasing can confuse copy/remove/toggle operations.                                                                                      |
| Environment -> sync API/build        | `GALE_SYNC_URL`, Cargo/npm env, build scripts                | Developer/test flexibility                     | Env poisoning can redirect sync API in developer/runtime contexts; build scripts can execute arbitrary code.                                                                  |

### Pass 3: Supply Chain Review

The repository uses many Cargo and npm dependencies with semver ranges (`^`, major-only Rust versions, and unpinned GitHub Actions). Rust dependencies include Tauri plugins, `zip`, `reqwest`, `rusqlite`, `keyring`, `image`, `serde_yaml`, proc macro crates, and build dependencies. npm dependencies include Svelte/Vite/Tauri APIs, markdown/highlight packages, and plugins. These are normal choices but create a large implicit trust graph.

Major supply-chain concerns:

- GitHub Actions are version-tag pinned, not commit-SHA pinned.
- `andyholmes/flatter@main` follows a mutable branch.
- `pnpm install` is used rather than a frozen lockfile install in CI.
- Cargo versions are mostly ranges rather than exact pins; lockfile protects applications, but malicious lockfile PRs or maintainer compromise remain plausible.
- No visible SBOM/provenance/signing policy beyond Tauri updater signing and Flatpak GPG signing.
- Build scripts and proc macros execute arbitrary code during build; `src-tauri/build.rs` itself is simple, but dependencies can run code.

### Pass 4: Chained Attacks

#### Chain A: Contributor-to-release compromise

Unpinned third-party GitHub Action or mutable `flatter@main`
↓
Action maintainer/token compromise executes in release workflow
↓
Secrets for Tauri signing, Gist, Thunderstore, or GPG are exposed or misused
↓
Malicious release/updater metadata/package is published
↓
Client compromise

#### Chain B: Webview compromise to local system impact

Overly broad CSP/remote script allowance or frontend dependency compromise
↓
Attacker JavaScript runs in the main webview
↓
JavaScript invokes registered IPC commands and allowed plugins
↓
Imports malicious ZIP/profile, changes custom launch args, reads clipboard, opens URLs/files, installs mods
↓
Persistence through game mod loader or launch prefix

#### Chain C: Malicious mod to filesystem/resource exhaustion

Thunderstore/local mod archive is malicious but path-enclosed
↓
Archive contains huge decompressed files, many entries, deep paths, or executable shell files
↓
Extractor writes until disk exhaustion and preserves/sets executable bits
↓
App/game launch fails or executes attacker-controlled mod code in game context

#### Chain D: Local malicious process to account confusion

Victim starts OAuth login
↓
Local process/browser sends `gale://auth/callback?access_token=...&refresh_token=...`
↓
App accepts tokens from callback channel and decodes JWT without local signature/audience/issuer verification
↓
Victim app becomes logged in as attacker-selected account/token context
↓
Profile sync actions operate under confused identity

### Pass 5: Assume Every Assumption Is Wrong

- If a maintainer account is compromised, tag-triggered release workflows can publish updates unless environments/tags/releases require independent approval.
- If CI is compromised, updater signing keys and Thunderstore/Gist/GPG tokens are high-value targets.
- If a dependency becomes malicious, build-time Rust/npm code can exfiltrate secrets during CI and developer builds.
- If a contributor is malicious, lockfile/package updates, workflow edits, and subtle frontend markdown/content rendering changes are high-impact.
- If a local attacker exists, deep links, temp extraction directories under app data, symlinks, hardlinks, and profile paths become abuse primitives.
- If the webview is compromised, the effective sandbox is weak because the main window owns a broad command/plugin surface.

## Detailed Findings

### F-01: Unpinned and mutable GitHub Actions in release workflow

**Severity:** High  
**CWE:** CWE-829, CWE-494, CWE-269

**Description:** Workflows use third-party actions by tag and at least one mutable branch (`andyholmes/flatter@main`). Release jobs receive signing and publishing secrets. Tags can move, action maintainers can be compromised, and mutable branch references can change without repository review.

**Impact:** Release artifact poisoning, secret exfiltration, updater metadata compromise, Thunderstore publishing compromise, Flatpak signing compromise.

**Likelihood:** Medium. Public CI/CD supply-chain compromise is a realistic attacker path for desktop software.

**Prerequisites:** Compromise of action maintainer, action tag/branch, GitHub token, maintainer account, or malicious workflow change.

**Affected files:** `.github/workflows/publish.yaml`, `.github/workflows/check.yaml`.

**Root cause:** Trusting mutable third-party workflow code in privileged jobs.

**Recommended remediation:** Pin every action to immutable commit SHA; replace `andyholmes/flatter@main`; set explicit minimal `permissions:` at workflow/job level; use protected environments for release jobs; require signed/protected tags; separate build and publish with artifact attestations; scope secrets to environments and rotate them after any workflow hardening.

### F-02: Overly permissive Tauri CSP and asset protocol

**Severity:** High  
**CWE:** CWE-79, CWE-346, CWE-942

**Description:** The CSP permits `default-src *`, allows an external script source, and the asset protocol scope is `**`. The main capability grants many APIs and HTTP fetch. In a Tauri app, XSS or content injection is not just browser compromise; it becomes a bridge to privileged IPC.

**Impact:** If attacker-controlled HTML/JS executes in the main window, it can invoke registered commands/plugins to install files, manipulate profiles, access clipboard, initiate updater checks, and influence local game execution.

**Likelihood:** Medium. The app renders remote/package-controlled text and uses markdown/highlighting dependencies; remote script allowlisting increases blast radius.

**Prerequisites:** XSS/content injection, malicious frontend dependency, compromised allowed remote script, or webview bug.

**Affected files:** `src-tauri/tauri.conf.json`, `src-tauri/capabilities/main.json`, `src-tauri/src/lib.rs`.

**Root cause:** Broad webview policy and broad capability surface.

**Recommended remediation:** Change CSP to `default-src 'self'`; remove remote script sources or load them outside the privileged webview; explicitly scope images/connect/font/style; remove `assetProtocol.scope: ["**"]` and restrict to app-owned directories; split windows/capabilities by privilege; deny shell/default APIs unless needed; add automated CSP/capability regression tests.

### F-03: OAuth callback accepts injected tokens and decodes JWT without verification

**Severity:** High  
**CWE:** CWE-287, CWE-345, CWE-346, CWE-347

**Description:** OAuth login opens a browser and waits for a deep-link callback. The callback handler forwards the URL to a broadcast channel. The login path extracts `access_token` and `refresh_token` from the callback and constructs credentials by decoding the JWT payload locally; no local state/nonce/PKCE/audience/issuer/signature validation is visible.

**Impact:** Account confusion, attacker-selected token injection, possible sync-profile actions under an unintended identity, and reliance on server-side rejection for malformed/forged tokens.

**Likelihood:** Medium for local/deep-link injection; higher if malicious browser extension/local app exists.

**Prerequisites:** Ability to invoke a deep link during the login window or control callback content.

**Affected files:** `src-tauri/src/profile/sync/auth.rs`, `src-tauri/src/deep_link.rs`.

**Root cause:** Missing callback state binding and local token validation.

**Recommended remediation:** Implement OAuth Authorization Code + PKCE; include a cryptographically random `state`; reject callbacks without matching state; avoid accepting bearer tokens directly in URI query strings; validate JWT issuer/audience/expiry/signature or treat JWT payload as untrusted display-only until server verification; clear pending login state after first callback.

### F-04: ZIP/profile/local mod extraction has no resource limits

**Severity:** Medium  
**CWE:** CWE-400, CWE-409

**Description:** ZIP extraction checks path enclosure but does not enforce maximum entry count, decompressed size, compression ratio, directory depth, path length, or operation timeout. Profile import, local mod import, and package install can therefore be abused by decompression bombs or many-entry archives.

**Impact:** Disk exhaustion, CPU exhaustion, UI hangs, profile/cache corruption, failed launches, denial of service.

**Likelihood:** Medium. Malicious mods/profile exports are a realistic input source for a mod manager.

**Prerequisites:** User imports/installs a malicious archive or remote package metadata points to a malicious archive.

**Affected files:** `src-tauri/src/util/zip.rs`, `src-tauri/src/profile/install/fs.rs`, `src-tauri/src/profile/import/local.rs`, `src-tauri/src/profile/import/mod.rs`.

**Root cause:** Archive parsing and extraction without quotas.

**Recommended remediation:** Add configurable limits for total decompressed bytes, per-file bytes, entry count, directory depth, path length, and compression ratio; preflight archives before extraction where possible; stream with byte counters; fail closed and clean partial extraction; fuzz archive handling.

### F-05: Symlink/hardlink and TOCTOU risks during extraction/install/remove

**Severity:** Medium  
**CWE:** CWE-22, CWE-59, CWE-367

**Description:** Extraction joins validated relative paths to a destination and then creates files with `File::create`; install/remove/toggle operations follow normal filesystem metadata and remove paths recursively. Path enclosure is lexical and does not protect against destination components replaced with symlinks between checks and writes, preexisting symlinks, hardlinks, or hostile profile/cache directories.

**Impact:** Local attacker or malicious archive/profile path could cause writes/removals outside the intended directory, overwrite user files, or pivot cache/profile operations.

**Likelihood:** Low-to-Medium. Requires local filesystem manipulation or user-controlled profile/data directories, but desktop apps commonly run in user-writable locations.

**Prerequisites:** Ability to influence profile/cache directory contents or race filesystem operations.

**Affected files:** `src-tauri/src/util/zip.rs`, `src-tauri/src/profile/install/fs.rs`, `src-tauri/src/util/fs.rs`, `src-tauri/src/prefs/mod.rs`.

**Root cause:** Lexical path validation and non-atomic filesystem operations over attacker-influenced directories.

**Recommended remediation:** Canonicalize and verify final paths against canonical roots; reject symlinks during extraction/copy/remove; use `openat`-style directory-relative APIs where available; create temp dirs with unpredictable names and correct permissions; use `OpenOptions::create_new` where appropriate; avoid following symlinks in recursive deletion/copy logic.

### F-06: Custom launch arguments enable arbitrary local command prefix and environment injection

**Severity:** Medium  
**CWE:** CWE-78, CWE-15

**Description:** Custom launch arguments support environment assignments and a prefix before `%command%`, replacing the game command with an arbitrary executable name. This is powerful by design, but it becomes dangerous if preferences can be modified by compromised webview JS, malicious imported profile data, or local config tampering.

**Impact:** Persistence or code execution on game launch in the user's context.

**Likelihood:** Medium if combined with webview compromise/import/config tampering; Low as a standalone because the user may intentionally configure it.

**Prerequisites:** Ability to modify custom args or trick user into doing so.

**Affected files:** `src-tauri/src/profile/launch/custom_args.rs`, `src-tauri/src/profile/commands.rs`.

**Root cause:** Dangerous capability exposed as a preference without apparent high-risk confirmation/audit.

**Recommended remediation:** Treat prefix changes as high-risk; add warning/confirmation UI; restrict env var names and optionally prefix executable allowlist; do not import custom launch prefixes without explicit confirmation; log/audit changes; show effective command before launch.

### F-07: Mutable updater endpoint and release integrity assumptions

**Severity:** Medium  
**CWE:** CWE-494, CWE-353

**Description:** The Tauri updater points to a mutable GitHub Gist raw endpoint. Tauri signatures help artifact integrity, but availability, rollback/freeze behavior, endpoint compromise, and signing key custody still matter. The publish workflow updates this Gist using a long-lived secret.

**Impact:** Update denial/freeze, rollback attempts, or malicious update attempts if signing keys and Gist token are compromised together.

**Likelihood:** Medium because updater infrastructure is a primary target.

**Prerequisites:** Gist token compromise, signing-key compromise, release workflow compromise, or maintainer compromise.

**Affected files:** `src-tauri/tauri.conf.json`, `.github/workflows/publish.yaml`.

**Root cause:** Centralized mutable metadata with high-value CI secrets.

**Recommended remediation:** Protect updater metadata behind release environments; rotate keys; document key custody; add version monotonicity/rollback protection; publish checksums/attestations; use GitHub Releases plus signed provenance; monitor Gist changes.

### F-08: Broad dependency trust and missing provenance policy

**Severity:** Medium  
**CWE:** CWE-1104, CWE-829, CWE-494

**Description:** Cargo and npm dependencies are semver-ranged and include transitive build scripts/proc macros. CI does not visibly enforce lockfile freshness, frozen installs, cargo deny, npm audit policy, SBOM generation, license/security allowlists, or source provenance.

**Impact:** Malicious dependency update or lockfile poisoning can execute during build, compromise developer machines/CI, or ship malicious code.

**Likelihood:** Medium. This is a common and high-impact supply-chain path.

**Prerequisites:** Dependency maintainer compromise, typo/confusion package, malicious PR changing lockfiles, or registry compromise.

**Affected files:** `src-tauri/Cargo.toml`, `src-tauri/Cargo.lock`, `package.json`, `pnpm-lock.yaml`, `.github/workflows/*.yaml`.

**Root cause:** No visible dependency governance controls.

**Recommended remediation:** Use `pnpm install --frozen-lockfile`; add `cargo deny`, `cargo audit`, `cargo vet` or equivalent; add npm audit/OSV scanning; generate SBOMs; require review for lockfile/workflow changes; pin critical dependencies where appropriate; use Dependabot/Renovate with grouped security review.

### F-09: Broad deep-link/file import behavior

**Severity:** Low  
**CWE:** CWE-20, CWE-22

**Description:** Deep links route URLs ending in `r2z` into file import by converting the whole argument to a `PathBuf`. There is no explicit scheme parsing or user confirmation visible in the deep-link handler.

**Impact:** Confusing import prompts, local file probing through error/log behavior, or unwanted profile import attempts.

**Likelihood:** Low-to-Medium depending on OS URL handling.

**Prerequisites:** Ability to cause the user/OS to open a crafted deep link or associated file.

**Affected files:** `src-tauri/src/deep_link.rs`, `src-tauri/src/profile/import/mod.rs`.

**Root cause:** Deep-link paths are accepted before strict URL/scheme normalization and confirmation.

**Recommended remediation:** Parse URLs with a URL parser; accept only expected schemes and file association paths; require explicit user confirmation before importing; log sanitized paths; reject remote/network paths unless intentionally supported.

### F-10: Reachable panics can cause denial of service

**Severity:** Low  
**CWE:** CWE-248, CWE-755

**Description:** The codebase contains `unwrap`/`expect` on window lookup, mutex locking, font enumeration, UTF-8 conversion, and path assumptions. Many are probably safe in normal execution, but attacker-influenced OS state, poisoned mutexes, missing main windows, or unusual fonts/files can crash the app.

**Impact:** Denial of service, failed import/launch, possible data loss if crash occurs during install.

**Likelihood:** Low-to-Medium.

**Prerequisites:** Trigger unusual runtime state, malformed local environment, or panic in a locked section.

**Affected files:** `src-tauri/src/lib.rs`, `src-tauri/src/deep_link.rs`, `src-tauri/src/prefs/commands.rs`, `src-tauri/src/config/bepinex/ser.rs`, `src-tauri/src/profile/sync/auth.rs`.

**Root cause:** Panic-based handling in application paths.

**Recommended remediation:** Replace panics with structured errors in command/deep-link/runtime paths; add crash-safe install transactions; fuzz parsers; add panic hooks that avoid sensitive logging.

### F-11: Secrets and token custody need explicit operational controls

**Severity:** Informational  
**CWE:** CWE-522, CWE-798 (not observed as hardcoded), CWE-532

**Description:** No hardcoded private tokens were observed in the reviewed files. Thunderstore API tokens are stored through OS keyring, while sync credentials are saved in the app DB. CI uses high-value secrets for release signing, Gist deployment, Thunderstore publishing, and GPG signing.

**Impact:** Credential compromise enables package publishing, update metadata tampering, or user account/session misuse.

**Likelihood:** Depends on maintainer/dev/CI hygiene.

**Prerequisites:** Local malware, CI compromise, maintainer compromise, log leak, or database/keyring compromise.

**Affected files:** `src-tauri/src/thunderstore/token.rs`, `src-tauri/src/profile/sync/auth.rs`, `.github/workflows/publish.yaml`.

**Root cause:** Necessary secrets exist but custody/rotation/minimization are not documented in repo controls.

**Recommended remediation:** Document secret inventory and rotation; minimize GitHub secret scopes; use environments; avoid storing refresh tokens unencrypted outside OS keyring if currently DB-backed; redact sensitive logs; add secret scanning in CI.

## Positive Security Observations

- ZIP path traversal is not ignored: extraction rejects absolute/root/prefix/parent traversal and null bytes via `is_enclosed`.
- Tauri updater has a configured public key, so artifact signature verification is at least intended.
- Thunderstore API token storage uses the OS keyring abstraction.
- The application avoids shell string execution for normal custom args by using `std::process::Command` arguments, although prefix execution remains powerful by design.
- Release profile aborts panics and strips symbols, reducing some post-crash cleanup complexity and reverse-engineering metadata.

## Action Plan

### Immediate (0-7 days)

1. Pin all GitHub Actions to commit SHAs and replace `@main` usage.
2. Set explicit minimal workflow/job `permissions:` and protected release environments.
3. Tighten Tauri CSP and asset protocol scope.
4. Add OAuth `state` and PKCE; reject callbacks without matching state.
5. Switch CI to `pnpm install --frozen-lockfile`.

### Near Term (1-4 weeks)

1. Add archive extraction quotas and cleanup-on-failure.
2. Harden filesystem operations against symlinks/races.
3. Add `cargo audit`, `cargo deny`, npm/OSV scanning, and dependency review.
4. Generate SBOMs and provenance attestations for releases.
5. Add high-risk confirmation for custom launch prefixes and imported launch settings.

### Longer Term

1. Split Tauri capabilities into least-privilege windows/contexts.
2. Build reproducible release guidance and independent verification steps.
3. Document threat model, secret inventory, release process, and incident response.
4. Add fuzzing for ZIP/YAML/JSON/config parsers and import flows.
5. Consider sandboxing extraction/metadata parsing in a lower-privilege process.
