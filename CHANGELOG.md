# Unreleased

- Add a read-only privacy check to System Settings with system locale, time
  zone, DNS configuration, on-demand exit lookup, a local desktop browser
  check, and copyable AI follow-up prompts.

- Ask users to sign in again only after the Accounts session endpoint confirms
  rejection. Temporary workspace sync failures keep valid cached access.

- Add Smart routing and Global proxy modes for standard System VPN profiles on macOS,
  iOS, Android, Windows, and Linux. Smart routing directs LAN and Chinese mainland
  domain traffic directly while routing other public traffic through the node;
  Global proxy routes public traffic through the node while preserving LAN direct access.
  The preference applies on the next app connection.

- Show server-reported month-to-date usage and allowance on the connector page.

- Connector sync silently retries rejected reads, falls back to a valid saved
  session cookie, and uses a saved refresh token when the server provides one.
  Recovery stays on the connector page without a login form. Login/MFA and
  native tunnel stop requests have bounded timeouts.
- Background synchronization authentication failures no longer sign users out.
  Saved credentials and profiles persist until explicit logout or connector
  change; unauthorized managed access remains suspended until reauthorized.
- Managed connections retain their last successful local snapshot through
  transient sync failures and same-account restarts. Offline authorization is
  limited to 24 hours or team expiry, whichever comes first; logout, explicit
  denial, scope changes, and authoritative empty lists still withdraw access.
- Separate managed access suspension from file deletion. Login expiry, logout,
  ordinary authorization failures and empty responses retain saved profiles
  while disabling their use. Successful login automatically refreshes them;
  a complete new-account snapshot replaces the previous account's profiles.
  Only explicit server quota-stop, traffic-stop or blacklist codes purge the
  affected account's managed profiles, never independently imported profiles.

- Manually imported connections now use independent files and unique display names,
  preventing same-prefix imports or managed sync from overwriting user profiles.
- All platforms share an in-app notification bell, unread badge, quota status banner,
  and Settings > Notifications. Remaining included allowance below 10% triggers a
  deduplicated reminder; explicit server quota rejection explains paused sync.
- Quota reminders and read state persist locally, are isolated by account, honor
  unlimited plans/temporary overrides, and clear when the condition recovers.

- Windows MSI now opens the standard interactive welcome, install-location, progress, and completion dialogs.
- CI build naming now follows the shared release policy: production refs use the package version, main uses `latest`, and feature builds include a run ID and short commit.

- CI release builds now inject the source commit ID and build date into the
  Linux and Windows apps, so About identifies the packaged revision instead of
  showing the development fallback.

- Preserve LF line endings for dependency patches on Windows checkouts, fixing
  the adapter patch application failure in Windows CI and release builds.

- Windows MSI uses a three-field version including the increasing build number,
  so build-only releases upgrade correctly. Rebuilt packages at the same product
  version replace the existing installation instead of installing side by side.

- About displays the packaged source Git short commit ID instead of a moving
  branch label; builds without revision metadata are marked dev.

- Windows adapter startup reuses an existing interface and recovers from a
  stale GUID collision with a system-assigned identity, retaining the interface
  name. Isolated dependency builds apply the reviewed adapter patch.

- Windows native tunnels now receive explicit interface addresses and selected
  DNS resolvers. Core startup waits for acknowledgement, keeps the UI responsive
  during authorization, and verifies recovered process identity before stopping.

- Save imported connections without loading the native runtime, and replace the
  complete node snapshot without duplicates. Windows configuration uses the
  current user application data directory instead of the installation directory.

- Prioritize custom imported connections for Free, Plus and Team accounts.
  Managed account sync preserves custom configuration and active selections;
  team authorization continues to isolate all account-managed connections.

- Fix custom connection imports remaining disabled after saving and personal
  connections disappearing while account sync is pending. Failed saves no
  longer publish an imported connection to the home screen.

- Apple builds locate Go in Xcode environments, and macOS archives use a
  project-local lipo compatibility adapter for Xcode 27. Universal archives
  include both arm64 and x86_64 Xray bridge slices targeting macOS 12.0.

- The control plane can now tune XHTTP upload and connection-reuse settings
  and the DoH upstream timeout through
  `GET /api/agent-server/v1/client-tuning`, fetched after each node sync and
  applied on the next connect. Values are range-checked, and settings the
  user changed keep precedence. See `docs/architecture/client-tuning.md`.
- Apple Packet Tunnels accept a tuned Go memory limit and GC percentage
  through the typed tunnel profile and a new explicit bridge entry; `0`
  now truly removes the Go soft limit. Persisted profiles are refreshed when
  tuning changes, and metrics report the footprint peak and Go pacing.
- Production connects run Xray at the `warning` log level; profiles saved
  at `debug` or `info` are lowered when they connect.

- The existing DoH switch now routes application A queries through
  Packet Tunnel → Xray DNS → proxy → existing DoH resolvers. Node
  domains, direct-domain exceptions, and other DNS record types retain the
  established forwarding path. Each DoH upstream has a 1.5-second timeout;
  if both fail, queries use the primary Base DNS through the same tunnel.
  Disable DoH and reconnect to
  restore the previous tunnel DNS routing.

- Add managed team connections with server-owned access, account-scoped sync, cached-node cleanup on withdrawal, and no public-node fallback in dedicated mode.
- Pin connectivity_plus to 7.0.0 so existing macOS CI does not resolve APIs requiring the macOS 26 SDK.

- Android home now reports live Packet Tunnel traffic, CPU, and memory metrics; node sync and local-node migration remove the legacy compatibility node `tky-proxy.svc.plus`.

- Linux uses one GTK event loop for tray and window operations, scopes single
  instance activation to each desktop display, and keeps windows recoverable
  when no tray host is available. Wayland retains native minimization. Closing
  the window-manager button now hides to the tray, or iconifies without a tray
  host, while keeping the process and network runtime alive; only the tray
  Quit action exits.
- Linux builds and PR verification check the clean, pinned libXray gitlink;
  desktop integrations remain in XConnect so upstream updates do not require
  carrying a libXray patch.

- Android release builds now use the Vault-backed upload keystore contract and
  publish both the APK and a Play Console-ready App Bundle. Verification builds
  retain an explicit debug-signing fallback.

- Android Packet Tunnel now excludes the XConnect UID and pinned node IPs from
  its own VPN route so Xray node and DNS connections stay on the underlying
  network. It also falls back to literal IPv4 DNS servers when a profile has
  none. IPv6 is disabled by default until an IPv6 tunnel address is configured,
  preventing IPv6-only applications from being sent into an unusable route.
- Added verified Ubuntu 26.04 Linux builds, including native GNOME Wayland
  minimize behavior and X11-only legacy tray integration.
- Linux DEB/RPM packages now include the privileged network helper, PolicyKit
  policy, capability setup hook, and complete runtime dependencies required by
  System Tunnel mode.
- Linux Flutter bundles now always install the Go native bridge library instead
  of relying on a best-effort Makefile copy.
- Linux release bridges now omit Go debug symbols and local source paths to
  reduce installed and downloadable artifact size.
- Linux now loads SQLite through its stable `libsqlite3.so.0` runtime SONAME,
  so end users do not need the SQLite development package.
- Linux capability-marked packages retain a secure origin-relative native
  library path so System Tunnel binaries can load their bundled bridge.
- Linux native packages register their bundled bridge directory with the
  system loader cache, allowing capability-marked binaries to start securely.
- Windows System Tunnel now waits for the named `XConnect` interface and its
  default route before reporting a successful connection.
- Linux System Tunnel now uses the named `xconnect-tun0` interface with
  automatic routing, GNOME/KDE package capability setup, and matching runtime
  status checks.
- iOS and macOS Packet Tunnel configuration and behavior are unchanged.

# XConnect v1.0.0

_Release Date: 2026-08-14 — tag `v2026.08.14-1938`, merge commit `27a312d`, branch `main`_

This entry records the changes between the previous daily release tag `v2026.8.14` and `v2026.08.14-1938`.

## Before this tag

- iOS Packet Tunnel data-plane probing, persisted App logs, Xray engine logs, egress-family diagnostics, and bounded Go runtime metrics were already available from PRs #48 and #49.
- PR #50 had identified the cellular DNS deadlock and introduced the first endpoint-pinning direction.
- The remaining risk was stale DNS UI/state, an iOS bootstrap path that could still be confused by an old Packet Tunnel session, and redundant server-domain resolution configuration.

## ✨ Features and fixes in this tag

- Resolve the iOS outbound server before starting Packet Tunnel, with system DNS followed by literal-IP UDP DNS and literal-IP DoH fallback.
- Write a runtime config with the resolved IP, preserve TLS SNI/XHTTP Host as the original domain, and add the IP as a `/32` excluded route.
- Fail closed when iOS cannot resolve the outbound endpoint instead of starting a tunnel that will fall back to a domain and deadlock.
- Wait for a previous Packet Tunnel to settle to `disconnected` before resolving the next endpoint.
- Remove the retired “server-domain direct resolution” setting and its stale iOS preference path.
- Keep Desktop/macOS Base DNS and tunnel-DNS controls while renaming the ambiguous “Direct DNS” label to “Base DNS / 基础 DNS”.
- Keep proxy DNS resolvers IP-literal and built in; remove obsolete DNS control-plane forwarding and Darwin dead branches.
- Make iOS DNS schema migration independent from the desktop tunnel-DNS preference migration.
- Keep the data-plane probe bounded, backoff-aware, and suspension-aware; a suspended iOS probe is inconclusive rather than a false network failure.
- Preserve XHTTP advanced configuration, QUIC/TUN routing behavior, and existing macOS DNS behavior.

## ✅ Validation for this tag

- `flutter analyze lib test`: no issues.
- `flutter test`: 103 tests passed.
- iOS Release `xcodebuild` and strict code-sign verification passed.
- Clean-installed on iPhone 16e, Wi-Fi off, real 5G active, Tky selected.
- `tky-proxy.svc.plus` fixed to `43.207.194.92` over `pdp_ip0`; Xray repeatedly dialed the literal IP with the domain retained for SNI/Host.
- Successful session had no `no such host`, `仍按域名连接`, or `No route to host` bootstrap failure.
- macOS Desktop Release built as universal `arm64`/`x86_64` and passed strict code-sign verification.
- Official Packet Tunnel soak smoke run reported zero restarts and zero reported errors; a full 120-minute traffic soak remains a follow-up.

## 📚 Documentation added after the tag

The following documentation commit is intentionally after the release tag and records the investigation without changing the released binary:

- `docs/ios-cellular-dns-deadlock-handoff.md`: reorganized historical handoff and final status.
- `docs/ios-cellular-dns-deadlock-debug-record-2026-08-14.md`: complete timeline, root cause, stale-build diagnosis, code changes, device evidence, soak results, and release record.

## Earlier v1.0.0 notes

- Tunnel Mode verifies the data plane after connecting, with a settle delay and bounded retries. The check is advisory: a failed probe reports the problem and leaves the tunnel running.
- iOS app logs are mirrored to a bounded, rotating file under `Library/Caches`, so a problem reported from a physical device can be diagnosed after the fact.
- The data-plane check no longer overruns its time budget on a weak link, and backs off between attempts instead of retrying a refused route dozens of times.
- Bounded the in-memory log buffers, which previously grew for the lifetime of a Packet Tunnel session.
- Reduced the iOS Packet Tunnel extension's memory footprint by tightening Go GC pacing and returning idle heap to the system while a tunnel is up.

## Earlier Unreleased notes

- Reframed the primary connection flow around self-managed connections and optional workspace connectors.
- Removed the standalone node configuration navigation tab; connection import remains available from the global connector action.
- Updated user-facing copy toward neutral Secure Tunnel and connection terminology for international store distribution.
- Added an XHTTP advanced `XMUX maxConcurrency` setting, persisted by the app and emitted as `xhttpSettings.extra.xmux.maxConcurrency` for controlled connection reuse.
- Applied XHTTP advanced settings to legacy node files before Packet Tunnel startup and rewrote the active node configuration on save, with a reconnect prompt when runtime settings changed.

_Release Date: 2026-03-27_

## 🐛 Fixes
- Fixed TUN mode DNS resolution failure in CN: default DoH DNS changed from blocked 1.1.1.1/8.8.8.8 to domestic-safe DNSPod and AliDNS

## ✨ Features
- Added DNS preset quick-select chips in proxy DNS settings (DNSPod, AliDNS, 360, Cloudflare, Google)
- Added "Tunnel DNS via Proxy" toggle: forces all TUN DNS queries through proxy resolver via Xray routing rules (solves GFW DoH blocking at the config level)

# XConnect v1.0.4

_Release Date: 2026-04-12_

## ✅ Changes
- Fixed Windows MSI packaging so the installer tree generator accepts the root directory entry during packaging

# XConnect v0.3.5

_Release Date: 2026-03-07_

## ✅ Changes
- Updated project license from GNU GPLv3 to Apache 2.0
- Realigned documentation and legal notices with Apache 2.0 terms

# XConnect v0.3.4

_Release Date: 2026-03-02_

## ✨ Features
- Added a reusable global breadcrumb navigation component for app-level and subpage navigation context
- Added breadcrumb headers for Logs, Help, and About pages, including Settings-driven navigation paths

## ✅ Changes
- Fine-tuned Logs page readability on iPhone and desktop with controlled text scaling, wrapped action buttons, and horizontal scroll support for long log lines
- Kept log display in monospaced style and improved visual consistency of the log container
- Bumped app version to `1.0.3+5` for macOS/iOS build metadata alignment

# XConnect v0.3.0 - Preview Release

_Release Date: 2026-02-28_

## ✨ Features
- iOS platform support with System VPN integration
- Apple Packet Tunnel support for System VPN mode on macOS and iOS
- iOS Packet Tunnel data plane now uses a statically linked `libxray.a` bridge inside the extension process

## ✅ Changes

- Added a unified DNS control-plane model that now generates resolver policy, domain sets, DNS routing, and Darwin system DNS capture behavior from one source instead of maintaining separate DNS fragments
- Kept Darwin Packet Tunnel full DNS capture with `matchDomains = [""]` while aligning the shipping default to the stable resolver-IP path validated by `release/v0.3.0`
- Enabled tun inbound sniffing in route-only mode so domain-aware routing can stay aligned with the same Direct Resolver policy used by Secure DNS decisions
- Added a default-off FakeDNS policy slot to the DNS control plane, including guarded config generation and operator-facing warning text for future explicit fake-domain use
- Fixed the About page and update checks to read the real app version and build number from platform package metadata instead of only showing build-label strings
- Tightened Home monitoring gating so Packet Tunnel metrics and latency now depend on the real connected status of the System VPN session, preventing stale or split monitoring cards during disconnected or transitional states
- Aligned iOS Packet Tunnel build settings with Flutter build-name/build-number variables through dedicated extension xcconfig files so `Runner.app` and `PacketTunnel.appex` archives now materialize matching bundle versions
- Unified DNS configuration into a single control model shared by Xray config generation and Darwin Packet Tunnel bootstrap DNS
- Kept the Darwin tunnel-local DNS endpoint path as a staged follow-up instead of the default shipping route, after comparing behavior with `release/v0.3.0`
- Removed hardcoded runtime DNS fallback resolvers so Xray DNS and Packet Tunnel bootstrap DNS now derive from the same user-managed configuration
- Replaced the inactive `DNS over TLS` settings switch with a real `DNS over HTTPS` control path and aligned Settings copy with actual Secure DNS behavior
- Added `docs/dns-secure-tunnel-design.md` to document current DNS flow, target Secure Tunnel DNS architecture, and the staged DoH rollout plan
- Reworked the Home monitoring cards for iOS and macOS with a quieter Material 3 layout: a primary download/upload card, a latency card, a CPU card, and a thin memory strip without changing page flow or connection actions
- Added a Darwin `PacketTunnelProvider -> App Group -> DarwinHostApi -> Home` monitoring snapshot path so the Home page can show live download/upload and memory data from the System VPN extension on iOS and macOS while CPU stays optional
- Added macOS Packet Tunnel CPU sampling and Home-side millisecond latency probing for the active connection, so the Apple monitoring cards no longer rely on placeholder values during active sessions
- Added iOS Packet Tunnel CPU sampling to the existing Home-side millisecond latency probing path so the iPhone monitoring cards can show CPU, throughput, memory, and active connection latency from the System VPN runtime
- Tightened the iOS monitoring snapshot cadence and Home polling interval so rate and memory cards feel more responsive during active Secure Tunnel sessions
- Stripped local SOCKS and HTTP inbounds from iOS Packet Tunnel runtime configs and stop any lingering iOS app-process engine before System VPN startup, avoiding local port conflicts inside the Packet Tunnel extension
- Switched the iOS Packet Tunnel target to statically link `libxray.a` and call the Go bridge exports directly from the Swift provider, while keeping the macOS bridge path unchanged
- Reduced iOS System VPN profile churn by saving Packet Tunnel configuration only when the profile changes, while keeping macOS Packet Tunnel save/start behavior unchanged
- Realigned the iOS Packet Tunnel extension to use the standard Swift principal-class entry path and removed the temporary Objective-C startup probe
- Moved iOS Packet Tunnel runtime config into the App Group shared container so the host app and Packet Tunnel extension use the same System VPN runtime path
- Added iOS startup bootstrap to register the System VPN profile even before the first node import, so `XConnect` can appear in the system VPN list earlier
- Updated iOS Packet Tunnel profile save flow to register `XConnect` in the system VPN list during profile save, and pre-register the VPN profile after iOS node import without auto-connecting
- Fixed iOS Packet Tunnel provider build by replacing unavailable iPhoneOS SDK `utun` macros with stable Darwin fallback constants
- Added repo-local `xconnect-ios-real-device-smoke` skill with executable iPhone smoke script, baseline, test cases, and latest report
- Added iOS `RunnerTests` Packet Tunnel start/stop smoke coverage and test-host fixes for real-device execution
- Updated the iOS host app startup to use Flutter's implicit engine registration path so Release builds can register plugins and native Packet Tunnel channels without crashing at launch
- Simplified iPhone navigation to `Home / Proxy / Account / Settings` and moved `Logs`, `Help`, and `About` into Settings so support and release information remain reachable without expanding the bottom bar
- Changed iOS and macOS Packet Tunnel CPU monitoring to publish the average of the most recent 10 seconds instead of a single instantaneous sample, reducing jitter in Home monitoring cards
- Allowed iOS node import to generate sandbox config files without requiring a desktop sudo password, while keeping desktop service generation rules unchanged
- Improved iOS Packet Tunnel diagnostics to clear stale session timestamps before new starts and surface the system VPN's last disconnect error during status checks
- Recorded current iPhone Packet Tunnel smoke blocker and next-step checklist in `docs/ios-packet-tunnel-real-device-followup.md`
- Removed tun2socks-based system-wide path; Packet Tunnel is now the only TUN/VPN entry on macOS
- Cleaned tun2socks scripts/resources/docs and related native/Dart APIs
- Added iOS/macOS `PacketTunnel` app extension targets with embedded `.appex` wiring in both Xcode projects
- Added Darwin Pigeon channel (`pigeons/darwin.dart`) and generated bridge code for Flutter and Swift
- Added `DarwinHostApiImpl` native implementation and startup registration in iOS/macOS app entry points
- Migrated Packet Tunnel provider implementation pattern to options-driven network settings on iOS/macOS
- Unified Darwin Packet Tunnel control to Pigeon single entry and removed Runner `NativeBridge+PacketTunnel` legacy channel wiring
- Added xray tunnel bridge symbols (`StartXrayTunnel`, `SubmitInboundPacket`, `StopXrayTunnel`, `FreeXrayTunnel`) in Go/C bridge layer
- Added Android Packet Tunnel native bridge (`StartXrayTunnelWithFd`) and connected `VpnService` TUN fd to xray-core tun inbound session
- Added Android JNI tunnel adapter (`packet_tunnel_jni`) and wired Packet Tunnel lifecycle to native xray tunnel start/stop
- Upgraded `go_core` xray dependency to xray-core `v1.260206.0` for native tun inbound support on mobile Packet Tunnel path
- Added Packet Tunnel startup rollback path in iOS/macOS providers and documented startup/failure sequence in `docs/system-vpn-packet-tunnel-xray26.md`
- Added client-side `vless://` URI support for node import and outbound generation, including `tcp` and `xhttp` transport parameters

# XConnect v0.2.0 - Windows Release

_Release Date: 2025-06-10_

## ✨ Features
- Windows platform support with service-based deployment
- Packaging includes automatic service registration for background running
- Integrated Bridge Windows module for one-click start and recovery

## ✅ Changes
- Verified config.json and Task Scheduler deployment
- Passed multi-region switch and proxy tests on Windows

# XConnect v0.1.4 - macOS Tray Support

_Release Date: 2025-06-09_

## ✨ Features
- macOS system tray status icon with window toggle
- Icon generation script for automated build

## ✅ Changes
- Improved minimize behavior on macOS
- Cleaned plugin registration

# XConnect v0.1.3 - Linux Runner

_Release Date: 2025-06-08_

## ✨ Features
- Go-based Linux native bridge with systemd support
- Updated CI workflow for Linux builds

## ✅ Changes
- Fixed cross-platform build scripts
- Added Linux systemd documentation

# XConnect v0.1.2 - Beta Update

_Release Date: 2025-06-08_

## ✨ Features
- Static `index.json` based update check
- Modular update system with persistent settings
- Injects build metadata into About dialog
- Xray config generation via Dart templates
- Inlined reset script for macOS reliability
- Revised license attributions

## ✅ Changes
- Fixed duplicate network service start
- Resolved logConsoleKey import
- Improved CI and BuildContext usage

# XConnect v0.1.1 - Minor Improvements

_Release Date: 2025-06-07_

## ✨ Features
- "Reset All Configuration" option in settings
- Updated icons and asset handling without Git LFS

## ✅ Changes
- Fixed macOS reset script quoting issues
- Updated Windows app icon generation



# XConnect v0.1.0 - First Public Preview

_Release Date: 2025-06-06_

## ✨ Features

- 🎯 **Cross-platform network acceleration engine powered by XTLS / VLESS**
- 💻 macOS native integration via Swift + LaunchAgent + Xray
- 🛠️ Integrated `xray` binaries for both `arm64` and `x86_64` architectures
- 📂 Per-user config persistence in `ApplicationSupport` directory
- 📡 Built-in Flutter UI for node selection and management
- 📤 One-click sync to write config and generate launchd service

## ✅ Changes

- Migrated `xray` binaries into `macos/Resources/xray/` (unified resource location)
- Implemented Swift-side logic to:
  - Detect platform architecture (`arm64` / `x86_64`)
  - Copy correct binary into `/opt/homebrew/bin/xray`
  - Set execution permissions
- Added `url_launcher` plugin support with macOS integration (`url_launcher_macos`)
- Simplified `project.pbxproj` to remove unused `inputPaths` / `outputPaths`
- Removed old `macos/xray/` location and binaries

## 🔧 Dev & Build

- Updated `Makefile` to support both `arm64` and `x86_64` macOS targets
- Rebuilt `Podfile.lock` to include new plugins (`url_launcher_macos`)
- Optimized Swift AppleScript command formatting for stability and shell-escaping
- Code cleanup and refactor in `NativeBridge+XrayInit.swift`

## 🧪 Known Limitations

- Current version supports only **basic node config** – advanced Xray routing not yet exposed
- No system tray or background daemon control UI yet
- Tested only on macOS 12+ (Apple Silicon and Intel)

## 🔜 Roadmap

- [ ] GUI for custom route / rule editing
- [ ] Windows and Linux GUI support
- [ ] Built-in diagnostics and log viewer
