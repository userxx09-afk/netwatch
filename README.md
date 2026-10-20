# NetWatch: network and restart logging for kiosk iPads

NetWatch is a lightweight monitor that records **when** a kiosk iPad loses the network, **at which step** it broke, and **why** the device or app restarted.

## The Single App Mode problem, and the three ways around it

iPadOS suspends any app that isn't on screen. A separate "monitor app" therefore can't run beside your kiosk app; whatever is on screen has to do the monitoring. Pick the option that fits your setup:

| Your kiosk is… | Do this |
|---|---|
| **An app you build, or one your vendor can change** | **Option A (best).** Add the `NetWatchKit` Swift package to that app and call `NetWatch.shared.start()`. Nothing in your kiosk or MDM setup changes. |
| **A web page** (Safari, web clip, browser kiosk) | **Option B.** Make the NetWatch app the Single App Mode app and set `kioskURL`. It shows your page full screen, logs everything, and reloads the page when the network returns. |
| **A third-party app you can't change** | **Option C.** Put one or two "canary" iPads, the same model and in the same spots, into Single App Mode with NetWatch. Use the no-app method (section 6) on the real kiosks. |

How to read the canary results: if the canary drops at the same times as the kiosks, the cause is the network (access point, DHCP, upstream link). If the canary stays up while the kiosks drop, the cause is on the device (sleep or auto-lock, the kiosk app, the private Wi-Fi address, Low Power Mode).

---

## 1. What gets logged

Each event is one JSON line in `Documents/NetWatchLogs/*.jsonl`. Events are also written to the iOS unified log (subsystem `NetWatch`), so they appear in a sysdiagnose.

| Event | Meaning |
|---|---|
| `network_change` | iOS network path changed: satisfied or unsatisfied, interfaces, **gateway**, and **unsatisfied reason** (e.g. `wifi_denied_by_settings`, `local_network_permission_denied`) |
| `wifi_joined` / `wifi_lost` / `wifi_roam` / `wifi_network_changed` | Wi-Fi association changes, with SSID and **access point BSSID**. Roams expose a flaky AP or bad roaming between APs. |
| `outage_start` / `outage_update` / `outage_end` | The connectivity check failed or recovered, with a **verdict** (below) and the outage duration |
| `device_rebooted` | The device restarted since the last run, with **clues**: iOS update, battery ran flat, overheating, sudden reboot (panic, forced restart, MDM), or long silence before boot |
| `app_relaunched_unexpectedly` | The app died while on screen but the device did not reboot (crash, memory kill, watchdog) |
| `metrickit_crash` / `metrickit_hang` / `metrickit_daily` | iOS's own report of *why* the app exited. It arrives on the next launch, plus a daily summary. |
| `monitor_gap` | The app went quiet, which means the device slept or the app was suspended. A gap followed by an outage points to sleep. |
| `app_background`, `device_locked`, `battery_*`, `low_power_mode`, `thermal_state`, `memory_warning` | Context that explains most "mystery" drops |
| `kiosk_load_failed`, `kiosk_webcontent_crashed` | Option B only: the web page failed to load, or a blank-screen crash |
| `status` | Snapshot every 10 minutes: battery, uptime, IPs, memory, idle-timer state |

### Connectivity verdicts (the "why it can't get on the network" part)

Every check runs these steps in order and reports the **first one that fails**:

| Verdict | What it means | Usual culprit |
|---|---|---|
| `no_ip_address` | No IPv4 address at all | Not joined to Wi-Fi: out of range, AP rejected it, Wi-Fi profile or password/cert issue |
| `dhcp_failure` | Joined the AP but got a 169.254.x.x address | DHCP scope full, wrong VLAN, NAC or MAC filtering, **private Wi-Fi address rotated** |
| `dns_failure` | Has an IP, but name lookups fail | DNS server down or unreachable, or the upstream link is down |
| `internet_unreachable` | DNS works, but nothing outside answers | Firewall, upstream outage, routing |
| `captive_portal_or_proxy` | Got an answer, but not the expected page | Guest captive portal, web filter, or proxy intercepting traffic |
| `target_unreachable` | Internet works, but **your** server doesn't | Your backend, a firewall rule, or a local server |

## 2. Build it

### On GitHub (no Mac needed)

`.github/workflows/ios.yml` builds the app on GitHub's macOS machines.

- **`compile` job.** Runs on every push and proves the code builds. It needs no Apple account. If it fails, open the run and look at **Show errors**, or download the `build-log` artifact.
- **`signed` job.** Run it manually: **Actions → iOS build → Run workflow**, then pick `ad-hoc`. It produces a signed `NetWatch.ipa` as a downloadable artifact, ready to upload to your MDM as an in-house app.

Cost: macOS minutes are free on public repos. On private repos they use your Actions minutes at a higher rate than Linux (check your plan). One build takes roughly 5–10 minutes.

**What you need for the signed build:** an Apple Developer Program membership. Everything else can be done from Windows or Linux.

1. **App ID.** At developer.apple.com → Certificates, IDs & Profiles → Identifiers → +, create an App ID such as `com.yourorg.netwatch`. Enable **Access Wi-Fi Information**.
2. **Distribution certificate**, created with OpenSSL (Git Bash or WSL on Windows):
   ```bash
   openssl genrsa -out dist.key 2048
   openssl req -new -key dist.key -out dist.csr -subj "/emailAddress=you@yourorg.com/CN=Your Org/C=US"
   # Portal: Certificates -> + -> "Apple Distribution" -> upload dist.csr -> download distribution.cer
   openssl x509 -inform DER -in distribution.cer -out dist.pem
   openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12   # choose a password
   ```
   Keep `dist.key` and `dist.p12` somewhere safe and **never commit them**.
3. **Devices (Ad Hoc only).** Register the iPads' UDIDs under Devices. Your MDM lists each device's UDID. The limit is 100 iPads per year, which is plenty for canaries.
4. **Provisioning profile.** Profiles → + → **Ad Hoc**. Choose the App ID, the certificate, and the devices, then download the `.mobileprovision` file.
5. **GitHub repo settings** → Secrets and variables → Actions:

   | Type | Name | Value |
   |---|---|---|
   | Secret | `BUILD_CERTIFICATE_BASE64` | `base64 -w0 dist.p12` |
   | Secret | `P12_PASSWORD` | the password from step 2 |
   | Secret | `BUILD_PROVISION_PROFILE_BASE64` | `base64 -w0 NetWatch_AdHoc.mobileprovision` |
   | Secret | `KEYCHAIN_PASSWORD` | any random string |
   | Variable | `TEAM_ID` | your 10-character Team ID (shown under Membership) |
   | Variable | `BUNDLE_ID` | the App ID from step 1 |

   On Windows PowerShell, base64-encode with `[Convert]::ToBase64String([IO.File]::ReadAllBytes("dist.p12"))`.

Other distribution routes: an **Enterprise** account uses an In-House profile and `enterprise`. A **Custom App** through Apple Business Manager uses an App Store profile and `app-store`; you upload the .ipa with Transporter, and Apple reviews it. Ad Hoc is the quickest for a few canary iPads.

### On a Mac

```bash
brew install xcodegen
cd NetWatch
# edit Config/Signing.xcconfig: PRODUCT_BUNDLE_IDENTIFIER and DEVELOPMENT_TEAM
xcodegen
open NetWatch.xcodeproj
```

Either way, the App ID must have **Access WiFi Information** enabled. Without it the logs still work, but they won't include the Wi-Fi name or access point.

### Option A: embed in your own kiosk app

1. In Xcode, go to File → Add Package Dependencies → Add Local… and select the `NetWatchKit` folder (or host it in a git repo).
2. In your app delegate:
   ```swift
   import NetWatchKit
   func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
       NetWatch.shared.start()
       return true
   }
   ```
3. Copy these settings from `project.yml` into your app: the `com.apple.developer.networking.wifi-info` entitlement, `NSLocationWhenInUseUsageDescription`, `NSLocalNetworkUsageDescription`, `UIFileSharingEnabled`, and the `captive.apple.com` ATS exception. Alternatively, skip the ATS exception and set `probeURL` to an https URL of your own.
4. Optional: log your app's own events into the same file with `NetWatch.shared.log("my_event", "message")`.

## 3. Deploy in Single App Mode

1. Install the app on the supervised iPad through MDM.
2. **Before turning on App Lock**, open the app once and tap **Allow While Using App** on the location prompt (needed for the Wi-Fi name) and **Allow** on the local network prompt. Single App Mode can hide these prompts later.
3. Push the managed app configuration (`mdm/managed-app-config.plist`). Set `deviceLabel` from your MDM's device-name or serial-number variable.
4. Push App Lock (`mdm/AppLock-NetWatch.mobileconfig`), or use your MDM's Single App Mode screen with the bundle ID. **Set `DisableAutoLock`.**
5. Option B: to reach the diagnostics screen, hold **three fingers on the screen for 3 seconds**.

## 4. Get the logs off

- **Automatic (recommended):** run the collector on any always-on machine the iPads can reach:
  ```bash
  python3 collector/collector.py serve --port 8080 --token change-me
  ```
  Set `collectorURL` = `http://<host>:8080/ingest`. Logs written during an outage are uploaded once the device is back online. Open `http://<host>:8080/` for a dashboard of outages per device, causes, reboots, sleep gaps, and roams.
- **Cable:** connect the iPad to a Mac and open it in Finder → Files → NetWatch → drag out `NetWatchLogs`. Apple Configurator works too.
- **On device:** use Export logs on the diagnostics screen.

Summarize pulled files: `python3 collector/collector.py summarize NetWatchLogs/*.jsonl`

## 5. Common causes to check while you collect data

- **Auto-Lock or sleep.** When the screen sleeps, Wi-Fi powers down and the app is suspended. Look for `monitor_gap` → `outage_start` pairs. Fix it with App Lock `DisableAutoLock` or `keepAwake=true`.
- **Private Wi-Fi Address.** iPadOS rotates it, which breaks MAC allow-lists, DHCP reservations, and NAC rules. Look for `dhcp_failure`. Fix it by setting `DisableAssociationMACRandomization` = true in the MDM Wi-Fi payload.
- **Power.** Look for a `device_rebooted` clue that says the battery ran flat, or for `battery_state: unplugged`. Kiosk chargers and cables often fail quietly.
- **Roaming or a weak AP.** Look for many `wifi_roam` events, or drops that always happen on the same BSSID. Check the Wi-Fi controller for deauth reasons for the device's MAC.
- **802.1X or certificate expiry.** `wifi_lost` and `no_ip_address` start on a specific date across all devices.
- **Low Power Mode or overheating.** See the `low_power_mode` and `thermal_state` events.

## 6. Deeper Wi-Fi detail without any app (works on the real kiosks)

iOS doesn't give apps signal strength (RSSI) or deauth reasons. The OS does log them:

1. Install Apple's **Wi-Fi logging profile** (developer.apple.com/bug-reporting/profiles-and-logs → "Wi-Fi") through MDM. It turns on verbose Wi-Fi logging.
2. After a drop, connect the iPad to a Mac and run:
   ```bash
   sudo log collect --device-name "<iPad name>" --last 6h --output kiosk.logarchive
   log show kiosk.logarchive --predicate 'process == "wifid" OR subsystem == "com.apple.wifi" OR subsystem == "NetWatch"' > wifi.txt
   ```
   This shows RSSI, roam decisions, deauth/disassoc reason codes, DHCP, and (with NetWatch) our events on the same timeline.
3. For reboots, take a sysdiagnose: press both volume buttons and the top button for about 1 second, then sync it to the Mac. Look in `crashes_and_spins/` for `panic-full-*.ips`.
4. Also check your Wi-Fi controller and DHCP server logs for the iPad's MAC address, and the MDM's command history (an unexpected Restart or Wi-Fi profile push).

## 7. Testing the "72-hour restart" theory

Since iOS/iPadOS 18.1, a device that stays **locked for 72 hours without an unlock** restarts itself (the "inactivity reboot"). After any restart, a device **with a passcode** sits in *Before First Unlock* (BFU). In BFU, saved Wi-Fi credentials are unavailable, the Single App Mode app can't launch, and MDM can't reach the device. It stays offline until someone types in the passcode. A device with no passcode, or one whose screen never locks, shouldn't be affected.

**Step 1: no app needed, takes a day.** When a device is reported offline, have someone photograph the screen *before touching it*.
- A passcode screen saying the passcode is required after a restart means BFU, which supports the theory.
- If the device rejoins Wi-Fi as soon as the passcode is entered, the theory is confirmed for that device.
- If the kiosk app is on screen but the device is offline, it's a different problem (Wi-Fi, DHCP, MAC rotation). The canary plus NetWatch is the right tool for that.

**Step 2: reproduce it on purpose instead of waiting for a random failure.** Take a test iPad with the **exact same profiles** as the fleet (passcode policy, App Lock options, Wi-Fi profile) and NetWatch as the App Lock app. Lock it and leave it for about 3.5 days. On the next launch, NetWatch's `device_rebooted` event reports:
- how long the device was locked before it restarted, flagging about 72 hours as an inactivity reboot
- how long the device sat at the passcode screen before the app could run

Then repeat the test with the fix (see below) to show that the problem goes away.

**Fixes, if it's confirmed:** remove the passcode requirement from the kiosk devices (most Single App Mode kiosks don't use one), and/or make sure the screen never locks (App Lock `DisableAutoLock`, plus no auto-lock restriction in other profiles). With a passcode **and** an auto-lock, every restart, for any reason (iOS update, power blip, inactivity reboot), takes the device offline until someone visits it.

## Limits (iOS, not NetWatch)

- No signal strength, Wi-Fi channel, or deauth reason codes for normal apps (use section 6).
- iOS doesn't record a reboot reason that apps can read. NetWatch infers it from boot time, the last heartbeat, battery, OS version, and thermal state.
- Nothing runs while the device is asleep or the app is suspended. Those periods appear as `monitor_gap`.
- The Wi-Fi name and access point need the entitlement plus location permission.
