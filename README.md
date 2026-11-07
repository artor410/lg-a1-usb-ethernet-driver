# webOS6-usbrealtek-driver

The **r8152** driver for **Realtek USB Ethernet adapters (RTL8152/RTL8153)** on **LG webOS 6** TVs with the
**lm21u** platform (e.g. **OLED A1**, 2021), plus a **Homebrew Channel** app to turn it on with the remote.

LG TVs have a 100 Mbit/s Ethernet port. With a gigabit adapter on the TV's USB 2.0 port, the TV goes well past
that: on the local network it measured **~309 Mbit/s receiving** and **~250 Mbit/s sending**, with a round trip of
**~0.22 ms** and no loss on game-stream-like bursts up to 200 Mbit/s, which helps with Plex, Jellyfin, Moonlight,
Sunshine/Apollo and the like.

## Tested on

| TV | Firmware / webOS | Adapter | Result |
|---|---|---|---|
| OLED55A1PSA (2021) | 03.53.45 / webOS 6.5.3 | Realtek RTL8153 (`0bda:8153`) | ✅ works |

- The driver loads cleanly; the TV configures the adapter's network **by itself** (address, route and DNS
  through its own connection manager) and goes online. 1000 Mbit/s link.
- Local network (PC at 1 Gbit/s on the same switch), v0.7.0: **~309 Mbit/s** receiving (TCP) and **~250 Mbit/s**
  sending, versus ~94 Mbit/s on the TV's built-in port and ~152 Mbit/s with LG's unmodified driver.
- Game streaming (v0.7.0): Sunshine/Apollo send each video frame as a burst at gigabit speed. Bursts of
  80–200 Mbit/s at 60–120 fps arrive **without loss** (0.2% at 300 Mbit/s @120 fps); up to v0.6.2, 41–44% of
  such bursts were lost. UDP round trip: **~0.22 ms** idle, **~0.24 ms** while receiving a 100 Mbit/s stream
  (v0.6.2: ~0.35 and ~0.45 ms). Receiving 150 Mbit/s uses ~10% of one CPU core.
  See [What v0.7.0 fixed](#what-v070-fixed-in-the-driver).
- Internet (300 Mbit/s plan, Cloudflare, one 50 MB download): **182–183 Mbit/s** with v0.3.0 and later,
  versus 111–119 Mbit/s with v0.2.0. Browser-based tests such as fast.com come out lower because the TV's
  browser itself is slow.
- **Load at TV startup**, tested with reboots: the driver loads ~33 s after power-on (when Homebrew Channel
  runs its startup hooks), the adapter becomes `eth0` a second later, and the network is ready at ~43–45 s.
  Until then webOS shows the wired connection as not connected; this is the earliest a homebrew hook can run.
- **Adapter as main connection** (v0.4.0): webOS goes from `disconnected` to `connected` (`eth0`,
  `onInternet: yes`); tested turning it on and off, unplugging the adapter, and switching the TV off and on with
  the remote.
- **Wi-Fi fallback** (v0.5.0): adapter gone → Wi-Fi turned on after 60 s and the TV stayed online through it;
  adapter back → swap redone and Wi-Fi turned off after 30 s. **Speed test** in the app: 183 Mbit/s.

## What v0.7.0 fixed in the driver

The common adapters (and the one tested here) use the **RTL8153B** chip. LG's driver recognizes it but programs it
like the older RTL8153A ([`driver/patches/`](driver/patches/) has the full patch and its description):

- **Lost bursts.** The chip's "early size" (how much it packs into one USB transfer) is counted in 8-byte units
  on the RTL8153B; LG's driver wrote 4-byte units, so the chip built transfers up to twice the size of the
  driver's buffers and the driver silently dropped what did not fit. This was invisible in every counter and cost
  ~45% of the packets of a video burst. Now set as in mainline Linux.
- **Latency.** The RTL8153B's receive timer is a different register; LG's driver put a 250 µs delay into a
  secondary timer instead. Now 15 µs, as in mainline Linux, plus the rest of mainline's RTL8153B setup (USB power
  saving that can miss transfers turned off, no RTL8153A-only power tables).
- **Buffers.** 32 receive buffers of 16 KB, the size the TV's USB controller handles in one piece.

Tips for game streaming over this adapter: keep the PC and the TV on the same gigabit switch (the TV uses Ethernet
flow control to pause the switch during bursts, so a switch that honors pause frames helps); prefer 120 fps over
60 fps at the same bitrate (half the burst per frame); bitrates up to ~150 Mbit/s are comfortable.

Tried it on another TV? Please open an [issue](https://github.com/artor410/webOS6-usbrealtek-driver/issues)
with the model, firmware and result.

> [!WARNING]
> This loads a module into the TV's kernel. It is built from the GPL source LG publishes for this TV and tested
> on the model above, but other firmwares may differ. If something goes wrong the TV may freeze and restart; it
> comes back normally, and startup loading turns itself off if the TV does not finish booting. Use at your own
> risk.

## Compatibility

| Item | Required |
|---|---|
| TV | LG with the `lm21u` platform (e.g. OLED A1, 2021) |
| System | webOS 6.x (built and tested against 6.5.3) |
| Kernel | `4.4.84-*`, ARMv7 (`armv7l`) |
| Access | **root** with the [Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel) |

The app checks all of this itself and refuses to load the driver on any other TV. To check over SSH:

```sh
nyx-cmd DeviceInfo query device_name   # should print: lm21u
uname -r                               # should start with: 4.4.84-
```

### Supported adapters

Realtek RTL8152 (100 Mbit/s) or RTL8153 (1 Gbit/s) chips. USB IDs the driver accepts:

| VID:PID | Adapter |
|---|---|
| `0bda:8152`, `0bda:8153`, `0bda:8050` | Realtek (generic; most USB 3.0 / USB-C gigabit adapters) |
| `045e:07ab`, `045e:07c6` | Microsoft |
| `04e8:a101` | Samsung |
| `17ef:304f`, `17ef:3062`, `17ef:3069`, `17ef:7205`, `17ef:720c`, `17ef:7214` | Lenovo |
| `13b1:0041` | Linksys USB3GIGV1 |
| `0955:09ff` | NVIDIA |
| `2357:0601` | TP-Link UE300 |

**RTL8156 (2.5G)** and **ASIX** adapters are not supported by this driver.

## Installation

### Through Homebrew Channel (recommended)

Add this project's repository to Homebrew Channel on the TV. The app then shows up in its list, and updates
arrive there.

1. On the TV, open **Homebrew Channel** → **Settings** (gear) → **Repositories** → **Add repository**.
2. Enter this URL and confirm with **Add repository**:

   ```
   https://raw.githubusercontent.com/artor410/webOS6-usbrealtek-driver/main/repo/apps.json
   ```

3. Go back to the app list: **USB Ethernet (RTL8153)** shows up marked *(from …)*. Open it and press
   **Install**.

Typing the URL with the remote is tedious. Over SSH you can open Homebrew Channel with the URL already filled
in (you only confirm it on the TV):

```sh
luna-send -n 1 luna://com.webos.applicationManager/launch '{"id":"org.webosbrew.hbchannel","params":{"launchMode":"addRepository","url":"https://raw.githubusercontent.com/artor410/webOS6-usbrealtek-driver/main/repo/apps.json"}}'
```

### Installing the `.ipk` by hand

Download `io.github.artor410.lgusbethernet_<version>_all.ipk` from
[Releases](https://github.com/artor410/webOS6-usbrealtek-driver/releases) and install it **one** of these
ways:

- **webOS Dev Manager:** open [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop), connect
  to the TV, go to **Apps → Install** and pick the `.ipk`.
- **Over SSH** (rooted TV):

  ```sh
  scp io.github.artor410.lgusbethernet_<version>_all.ipk root@TV_IP:/tmp/app.ipk
  ssh root@TV_IP
  luna-send -n 6 luna://com.webos.appInstallService/dev/install '{"id":"io.github.artor410.lgusbethernet","ipkUrl":"/tmp/app.ipk","subscribe":true}'
  ```

## How to use it

1. Plug the adapter into a USB port on the TV, and the network cable into the adapter.
2. Open **USB Ethernet (RTL8153)** from the app list.
3. Check the *Status* column: compatibility, detected adapter and driver.
4. Press **Load driver now**. If all goes well, the adapter shows up as a network interface (e.g. `eth1`).
5. Press **Use adapter as main** (see below) so webOS and apps see the cable as connected.
6. Only once it works, press **Load at TV startup** to load the driver every time the TV starts.

Use the cable on the adapter only: the TV's own Ethernet port is left unused.

The status refreshes by itself every few seconds while the app is open.

### Adapter as the main connection (`eth0`)

webOS only treats `eth0`, the TV's built-in port, as the wired connection. With the adapter as `eth1` the
internet works, but webOS reports the wired connection as **disconnected**: Settings may show "Not connected"
and some streaming apps refuse to play.

**Use adapter as main** swaps the names: the adapter becomes `eth0` and the built-in port is parked as `eth2`.
The internet drops for a few seconds during the swap. After that:

- webOS reports the wired connection as connected (the app's *Cable in webOS* row shows `connected`);
- a light watcher checks the names every 5 s: it redoes the swap when the TV comes back from standby, and gives
  `eth0` back to the built-in port if the adapter is unplugged;
- the choice is saved and also applies at startup (with **Load at TV startup**).

If `eth0` gets no address after the swap (and the adapter had one before), the script takes the link down and
up; if that does not help, it undoes the swap until the next boot so the TV is never left offline.

To undo it, press **Use TV port as main**. The swap logic is adapted from
[LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0) (MIT, see [`THIRD_PARTY.md`](THIRD_PARTY.md)).

### Wi-Fi fallback

With **Enable Wi-Fi fallback**, if the adapter's cable has **no link for 1 minute** (loose cable, router
restarting, adapter unplugged), the app turns Wi-Fi on through webOS's own connection manager, the same switch
as in Settings. Once the cable is back with a link for **30 seconds**, Wi-Fi is turned off again. It only
touches Wi-Fi if Wi-Fi was off. The TV needs a saved Wi-Fi network.

### Speed test

**Test speed** downloads 50 MB from `speed.cloudflare.com` and shows the result under *Last speed*. If the
server refuses (it rate-limits back-to-back tests), wait a few minutes.

### Safety

- The app only loads the driver on the platform and kernel it was built for.
- **Boot-loop guard:** if **two boots in a row** end within 30 s of loading the driver at startup, startup
  loading turns itself off (and Wi-Fi is turned on if Wi-Fi fallback is enabled, so the TV is not left offline).
  A single early power-off or restart does not trip it. Homebrew Channel also has its own failsafe mode that
  skips startup scripts after a failure.
- **Clock:** webOS sets its clock from LG's servers once the network is up. If that has not happened 45 s after
  the driver loads (late network, or those servers blocked by a privacy hook), every HTTPS connection on the TV
  fails, so the app sets the clock from a plain HTTP `Date` header through webOS's own time service. A valid
  clock is never touched; the app's *Clock* row shows the state.
- To uninstall: in the app, press **Don't load at startup** and **Unload driver**, then remove the app. (If you
  remove the app directly, its startup script deletes itself on the next boot.)

### Command line

The app uses a script that also works over SSH:

```sh
S=/media/developer/apps/usr/palm/applications/io.github.artor410.lgusbethernet/bin/usbeth.sh
sh $S status          # compatibility, adapter, driver, interface
sh $S load            # load the driver now
sh $S unload          # unload it
sh $S autostart-on    # load it when the TV starts
sh $S autostart-off
sh $S primary-on      # adapter as eth0 (built-in port becomes eth2) + watcher
sh $S primary-off     # built-in port is eth0 again
sh $S wififb-on       # Wi-Fi fallback (turns Wi-Fi on after 60 s without cable link)
sh $S wififb-off
sh $S speedtest       # downloads 50 MB and shows the speed
sh $S log             # log (/var/lib/lg-a1-usb-ethernet/log.txt)
```

Over SSH without a terminal, `luna-send` gives no output on this TV, so the *Cable in webOS* state and the Wi-Fi
fallback only work when run from the app or at startup.

## Building it yourself

The ready-made module is in [`prebuilt/`](prebuilt/) (SHA-256 in `prebuilt/*.sha256`). To reproduce it:

1. Download LG's GPL package **"webOS 6.0 LMUA 1.0"** from [opensource.lge.com](https://opensource.lge.com)
   (search for an `OLED55A1…` model); only part 2 is used.
2. On Linux (or WSL) with `gcc-9-arm-linux-gnueabihf`, `make`, `flex`, `bison`, `bc`, `patch` and `libssl-dev`:

   ```sh
   bash scripts/extract-source.sh /path/to/downloads
   bash scripts/build-r8152.sh       # builds build/r8152.ko with the TV's config (diagnostics/config.gz)
   bash scripts/package-ipk.sh       # builds dist/*.ipk, dist/*.manifest.json and repo/apps.json
   ```

The investigation (TV diagnostics, config differences, measurements, risks) is in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). `scripts/collect-tv-info.sh` writes a report about your TV,
which is useful when opening an issue about another model.

## Layout

| Folder | Contents |
|---|---|
| `app/` | The Homebrew Channel app (HTML/JS) and its `bin/usbeth.sh` script |
| `driver/` | `r8152.c` exactly as in LG's GPL package, plus `patches/` applied at build time |
| `prebuilt/` | `r8152.ko` built for `4.4.84` / `lm21u` |
| `repo/` | This project's Homebrew Channel repository (`apps.json`, written by `scripts/generate-index.sh`) |
| `scripts/` | Diagnostics, build and packaging |
| `diagnostics/` | The TV's kernel config used for the build |

## Use of AI

The driver was built, and the app and scripts were written, by an AI agent (Claude Code) under the
maintainer's direction; the maintainer drove the testing on their own TV (OLED55A1PSA) and is responsible for
the project. The driver code is Realtek's/LG's original `r8152`; the only change is the receive-buffer patch in
`driver/patches/`, with the measurements behind it.

## License and credits

- GPL-2.0 (see [`LICENSE`](LICENSE)). The `r8152` driver is © Realtek Semiconductor, distributed by LG in the
  TV's open source package; the code is in [`driver/r8152.c`](driver/r8152.c).
- [webOS Homebrew Project](https://github.com/webosbrew) for Homebrew Channel.
- [LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0) for the interface swap and Wi-Fi fallback
  logic (MIT, see [`THIRD_PARTY.md`](THIRD_PARTY.md)).
- [throwaway96/webos-kernel-drivers](https://github.com/throwaway96/webos-kernel-drivers) and
  [DonZoomik/webos-r8152](https://github.com/DonZoomik/webos-r8152) for showing how to build modules for webOS
  TVs.
