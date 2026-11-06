# Development notes

How the driver was investigated, built and tested for the **LG OLED A1 (webOS 6)**.

## Starting point (diagnostics, 2026-11-05)
- TV: webOS 6.5.3, kernel `4.4.84-899.19.koli.1`, ARMv7 (32-bit), built with GCC 8.2.0, platform `lm21u`.
- Access: `ssh -i ~/.ssh/lg_tv_ed25519 root@TV_IP` (key authorized with `scripts/authorize-key.ps1`).
- Adapter: **Realtek RTL8153** (`0bda:8153`), seen on the USB 2.0 port, **with no driver**.
- Kernel: accepts modules (`CONFIG_MODULES=y`), **no signature requirement** and no `MODVERSIONS`.
  `CONFIG_MII=y` is built in; only the `r8152` driver is missing (`CONFIG_USB_RTL8152` is off).
- The TV already loads modules with different vermagic strings (`4.4.84 ...` and `4.4.84-899.kcl4tv.17 ...`),
  so the version check is lenient. Target: `4.4.84 SMP preempt mod_unload ARMv7`.
- **Chosen path:** build only `r8152.ko` (it does not depend on `usbnet`).
- The TV's USB port is 2.0, so the practical ceiling is around 300 Mbit/s (still above the built-in
  100 Mbit/s port).
- `diagnostics/config.gz` is the TV's kernel config, used for the build.

## Build (2026-11-05)
- Environment: WSL Ubuntu 24.04, `arm-linux-gnueabihf-gcc-9` (9.5; the TV's kernel used 8.2).
- Source: `bsp_open/kernel` from `common/bsp_open3.tar.gz` (part 2 of the package), kernel 4.4.84.
  Extraction: `bash scripts/extract-source.sh /path/to/downloads` (creates `~/lg/bsp_open/kernel`).
- Build: `bash scripts/build-r8152.sh` → `build/r8152.ko` (the `r8152` driver from LG's own tree).
- Checked: vermagic `4.4.84 SMP preempt mod_unload ARMv7`, and all 94 symbols the module uses are exported
  by the TV's kernel.
- Differences between the TV's config and this source: `CPU_SW_DOMAIN_PAN` (the older source disables it on
  MStar; r8152 does not access user memory, so it does not matter) and `MFB_GC` (an LG option missing from the
  source, effect unknown). In other words, the TV's kernel (2025) is newer than the source (2021).
  Risk: if an internal structure changed, the module could freeze the TV; it restarts and comes back, since the
  module is not loaded automatically unless the user enables it.

## Procedure

### 1. Access to the TV
- The TV needs **root** and **SSH** (Homebrew Channel).
- The rooting method depends on the firmware version: check it under *Settings → General → About this TV*
  and see <https://www.webosbrew.org/rooting/>.
- Without root the diagnostics run with limited access, and no driver can be loaded.

### 2. Diagnostics (adapter plugged into the TV)
Copy and run on the TV:

```sh
scp scripts/collect-tv-info.sh root@TV_IP:/tmp/
ssh root@TV_IP sh /tmp/collect-tv-info.sh
scp root@TV_IP:/tmp/tv-info.txt diagnostics/
```

The report shows:
- the adapter's **VID:PID** and **chip** (and whether a driver already claimed it);
- the kernel and webOS versions;
- whether the kernel accepts modules (`CONFIG_MODULES`) and requires signatures (`CONFIG_MODULE_SIG*`);
- which USB network drivers the TV already has;
- the `vermagic` a module we build has to match.

With the adapter plugged into a Windows PC, its chip can be identified with:

```powershell
pwsh -File scripts\identify-adapter.ps1
```

### 3. Deciding the path
| What the report shows | What to do |
|---|---|
| The chip's driver exists as a `.ko` but is not loaded | Just `insmod`/`modprobe` it and configure the interface |
| No driver, and the kernel accepts unsigned modules | Build the module (step 4) |
| The kernel requires signed modules | No custom module possible; use an adapter whose chip is already supported |
| Unknown chip | Look up the VID:PID; if it is CDC-ECM/NCM, try `cdc_ether`/`cdc_ncm` |

### 4. Building the module
1. Download the TV's GPL kernel source from <https://opensource.lge.com> (search for the model, e.g. `OLED55A1`).
   Package found: **"webOS 6.0 LMUA 1.0"** (model `OLED55A1PSA`), in 3 parts:
   `webOS 6.0 LMUA_1.0_1.tar.gz`, `_2.tar.gz`, `_3.tar.gz`. It is from the original 6.0 release; the TV runs
   6.5.3, so the TV's own `.config` is used (`diagnostics/config.gz`).
   Prior work: `github.com/throwaway96/webos-kernel-drivers` (ready-made modules for `armv7l-4.4.84-lm21u`, but
   no `r8152`) and `github.com/DonZoomik/webos-r8152` (r8152 for another TV; scatter-gather off avoids USB hangs
   with Realtek's newer driver on xHCI).
2. Use a toolchain close to the GCC version shown in `/proc/version`.
3. Use the TV's `.config` (`/proc/config.gz`), with `LOCALVERSION` set so the `vermagic` matches.
4. Build only what is needed as a module: here just `r8152` (`mii` is built in).

### 5. Loading it and making it permanent
- `insmod r8152.ko`; check with `dmesg` and `ip link`.
- The TV's connection manager brings the interface up with DHCP by itself.
- To load at boot: a script in `/var/lib/webosbrew/init.d/`.

## Risks
- An incompatible module can freeze the TV; it normally comes back after a restart.
- Rooting and modifications may affect the warranty.

## First test on the TV (2026-11-05, OLED55A1PSA, firmware 03.53.45, webOS 6.5.3)
- `insmod` without errors: `r8152 1-1:1.0 eth1: v1.08.2`. The driver switches the adapter from USB
  configuration 2 (generic CDC) to 1 (vendor), as expected.
- With the cable in the adapter, the TV's connman creates the `ethernet_<mac>_cable` service by itself, gets an
  address over DHCP, and sets the default route and DNS; `connmanctl state` = `online`. Nothing else needed.
- 1000 Mbit/s link. Download (Cloudflare, 50 MB): 111 Mbit/s with one stream; 98 Mbit/s with 4 streams.
  TV → PC on the LAN: 94 Mbit/s, but the PC's NIC had negotiated 100 Mbit/s at the time.
  Over SSH ~90 Mbit/s (limited by encryption on the TV's CPU).
- `rx_dropped` grows over time (packets the TV discards, such as multicast/IPv6); `rx_errors` = 0.
- Startup loading: hook in `/var/lib/webosbrew/init.d/60-lg-a1-usb-ethernet`; after `reboot`, the driver
  loaded ~40 s after power-on and the network came back by itself. The `boot-pending` guard file was removed
  ~2 min later, as designed.
- `.ipk` package: LG's verifier rejects the GNU binutils `ar` format (member names ending in `/`);
  `scripts/package-ipk.sh` writes the classic `dpkg-deb` format, which installs fine.
- Updating from the first package (0.1.0, file dates set to 1970) failed in the installer; packages since
  0.2.0 use real dates and update normally.

## Speed and receive buffers (2026-11-05, v0.3.0)
Measured with `scripts/speed-test.sh` and LAN tests (PC at 1 Gbit/s, HTTP server on the PC):
- No TV CPU core goes above ~36% during downloads: the CPU is not the bottleneck. RPS barely helped.
- Sending (TV → PC, `nc`): ~251 Mbit/s. Receiving (PC → TV, HTTP): ~152 Mbit/s with the original driver, with
  ~17,700 out-of-order TCP segments per 300 MB: loss inside the adapter, before the kernel (the driver's
  `rx_dropped` barely moves).
- Variants tested (module swapped live, falling back to the original if the network did not come back):
  32 × 16 KB: 155–159 Mbit/s; 10 × 32 KB: 202–212; **32 × 32 KB: 214–215** (out-of-order ~600).
  The gain comes from the buffer size; 32 KB is what mainline Linux's r8152 uses for the RTL8153.
- This became `driver/patches/0001-rx-buffers-32x32k.patch`, applied by `scripts/build-r8152.sh`.
- `speed.cloudflare.com` starts refusing (HTTP 429) after many back-to-back downloads from the same IP.
- After installing v0.3.0 through Homebrew Channel's service (from the manifest) and reloading the driver:
  LAN 216 Mbit/s (out-of-order 594); internet (Cloudflare, 50 MB) 182 Mbit/s, versus 111–119 before.

## Adapter as eth0 (2026-11-06, v0.4.0)
- With the adapter as `eth1`, `connectionmanager/getStatus` returns
  `"wired":{"plugged":false,"state":"disconnected"}` even with internet (`isInternetConnectionAvailable: true`):
  webOS only looks at `eth0`.
- On the A1's MStar SoC the built-in port is `/sys/devices/virtual/net/eth0` (no `device` link), so it is
  recognized as "wired, `eth*`, not USB, not Wi-Fi/bridge/tunnel"; on the first swap its MAC is saved to
  `/var/lib/lg-a1-usb-ethernet/builtin_mac`, and from then on the MAC decides.
- Swap (adapter → `eth0`, built-in → `eth2`): ~12 s until the network is back; connman keeps the service
  (`ethernet_<mac>_cable`) and the address; `getStatus` turns `connected`, `interfaceName: eth0`,
  `onInternet: yes`.
- Watcher (`usbeth.sh watch`, every 5 s): adapter disabled in software (`authorized` 0/1) → eth0 goes back to
  the built-in port; adapter back → swap redone. Switching the TV off and on with the remote did a full boot:
  driver at ~42 s, swap 0.4 s later, `connected`; the `boot-pending` guard cleared on time.
- `luna-send` only prints output in the Homebrew Channel context (exec/boot); over SSH without a terminal it
  prints nothing.

## v0.5.0 (2026-11-06): recovery, Wi-Fi fallback, speed test, background boot
- `wifi/getstatus` on webOS 6 returns `"status":"serviceDisabled"` with Wi-Fi off (same format as
  webOS 24/25); `connectionmanager/setstate {"wifi":"enabled|disabled"}` turns it on and off.
- The watcher has to be started from the Homebrew Channel context (app/boot) for `luna-send` to answer; a
  watcher started over SSH cannot read the Wi-Fi state and simply never triggers the fallback.
- Test (adapter disabled in software for 110 s): eth0 back on the built-in port in ~16 s; Wi-Fi on at ~72 s and
  the TV online through `wlan0`; adapter back → swap redone; Wi-Fi off 31 s later.
- Boot: `usbeth.sh boot` sets the guard and returns at once; `boot-worker` loads the driver in the background
  (driver ~37 s, swap ~42 s, guard cleared ~160 s).
- Recovery after the swap (link down/up, and undo if eth0 gets no address): only the normal path was
  exercised; the failure itself was not simulated.
- Speed test in the app (50 MB, Cloudflare): 183 Mbit/s.

## v0.6.x (2026-11-06): rename, English, automatic status refresh
- The app refreshes its status every 10 s while it is visible and idle (the Refresh button is gone).
  Measured through the app's own path (Homebrew Channel exec): one status run took ~0.9 s, ~0.35 s of it in
  three `nyx-cmd` calls whose answers never change until a reboot. v0.6.1 caches those facts in `/tmp`
  (`/tmp/lg-a1-usb-ethernet.static`): ~0.6 s per run, about 35% less. The watcher uses ~30 ms of CPU per minute.
- Checked on the TV with a screen capture (`luna://com.webos.service.capture/executeOneShot`): the TV's
  Chromium 79 ignores `gap` in flex layouts (the icon touched the title), and long log lines wrapped so the
  newest line was hidden. v0.6.1 uses a margin instead of `gap` and scrolls the log to the newest line.
- Speed after the rename and translation (no driver change): 189 Mbit/s (Cloudflare, 50 MB), versus 183 before.

## v0.6.2 (2026-11-06): faster startup, boot-loop guard fix, clock fix
- Reported: right after switching the TV on, Settings showed the wired connection as "Not connected". The swap
  worked; it just happened ~43 s after power-on. Boot milestones on this TV (bootd/initctl logs): core boot ~13 s,
  adapter enumerated ~16 s, `webos-rbd` ~29 s, `webos-bd` ~41 s; Homebrew Channel runs `init.d` hooks at ~33–41 s.
- Hook renamed from `60-` to `05-` (migrated automatically at boot) so `run-parts` starts it before the other
  homebrew hooks: it now starts at ~32.5 s instead of ~38–41 s.
- The watcher starts right after `insmod` (it used to start after a 3 s wait and the dmesg logging) and checks
  every second for its first 30 s: the swap happens ~1 s after the driver loads instead of ~4 s.
- Result: driver 32.7 s, swap 33.8 s, address on eth0 43.1 s (v0.6.1: swap ~43 s, address ~51 s).
- Boot-loop guard: a reboot ~60 s after power-on (inside the old 120 s window) disabled startup loading, leaving
  the TV without a network (cable on the adapter only, Wi-Fi off). Now the window is 30 s after the driver loads,
  and it takes 2 such boots in a row; tested by rebooting 52 s after power-on: the next boot logged "strike 1 of 2",
  loaded the driver and had the network at 45 s.
- Clock: after that boot the TV kept its factory time (2021) because the network came up late (the driver was only
  loaded by hand) and the `lifesgoodwithoutspying` hook blocks LG's SDP servers (which webOS uses to set the
  clock) 60 s after it starts. Every HTTPS request failed with "certificate is not yet valid". The app now sets an
  invalid clock (year < 2025) from the `Date` header of `http://connectivitycheck.gstatic.com/generate_204` via
  `luna://com.webos.service.systemservice/time/setSystemTime`, 45 s after the driver loads; this also writes the
  RTC. Tested by forcing the clock to 2021: HTTPS 000 → clock set from the network → HTTPS 200. The TV's
  `autoClock` setting was already off and is not changed.
