# webOS6-usbrealtek-driver

**Faster wired internet for LG webOS 6 TVs (OLED A1 and other 2021 `lm21u` models) using a cheap USB Ethernet
adapter.**

The Ethernet port built into these TVs is limited to **100 Mbit/s**. Plug a gigabit USB adapter into the TV
instead, install this app from Homebrew Channel, and the TV gets **about 3x faster wired internet**, with lower
latency and no dropped packets in game streaming (Moonlight, Sunshine, Apollo) or high-bitrate movies (Plex,
Jellyfin, Kodi).

The app does everything with the remote: it loads the driver, makes webOS treat the adapter as the TV's normal
cable connection, reloads it every time the TV starts, and can fall back to Wi-Fi if the cable stops working.

## At a glance

Measured on an LG OLED55A1PSA, with a PC on the same gigabit network:

| | TV's own Ethernet port | Adapter with LG's driver as shipped | **Adapter with this project (v0.7)** |
|---|---|---|---|
| Download speed | ~94 Mbit/s | ~152 Mbit/s | **~309 Mbit/s** |
| Game-stream video (bursts of 80–200 Mbit/s) | can't carry it | **~40–45% of packets lost**¹ | **no loss** |
| Response time (ping, median) | — | ~0.35–0.45 ms¹ | **~0.25 ms** |
| CPU used to receive 150 Mbit/s | — | — | ~10% of one core |

¹ Measured with v0.6.2, which only enlarged LG's buffers; the cause is a bug in LG's code (explained
[below](#whats-different-from-lgs-original-driver)).

What this means in practice:

- **4K movies:** even the heaviest 4K Blu-ray rips (peaks around 130–145 Mbit/s) have plenty of headroom.
- **Game streaming:** a 150 Mbit/s Moonlight stream arrives complete; with LG's driver almost half of every
  frame's packets were thrown away, which shows up as stutter, artifacts or the client lowering the quality.
- **Internet:** on a 300 Mbit/s plan the TV downloads at ~180–190 Mbit/s (browser speed tests such as fast.com
  show less because the TV's browser itself is slow).

## What you need

- An **LG TV with webOS 6 on the `lm21u` platform** (for example the OLED A1 from 2021). The app checks this
  itself and will not load the driver on anything else.
- The TV must be **rooted** and have **[Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel)**
  installed (see [webosbrew.org](https://www.webosbrew.org/) for how to root).
- A **USB Ethernet adapter with a Realtek RTL8153 chip** (most cheap "USB 3.0 to gigabit Ethernet" adapters and
  many USB-C docks). RTL8152 (100 Mbit/s) adapters also work, but are no faster than the TV's own port. Full list
  of accepted adapters: [Supported adapters](#supported-adapters).

The TV's USB ports are USB 2.0, which is why the speed tops out at ~300 Mbit/s instead of 1000. That is still
about three times the built-in port.

## Install

### Through Homebrew Channel (recommended)

You add this project's app list to Homebrew Channel once; after that the app installs and updates like any
other homebrew app.

1. On the TV, open **Homebrew Channel** → **Settings** (gear icon) → **Repositories** → **Add repository**.
2. Type this address and confirm with **Add repository**:

   ```
   https://raw.githubusercontent.com/artor410/webOS6-usbrealtek-driver/main/repo/apps.json
   ```

3. Go back to the app list. **USB Ethernet (RTL8153)** now appears. Open it and press **Install**.

Typing the address with the remote is tedious. If you can reach the TV over SSH, this opens Homebrew Channel
with the address already filled in (you only confirm on the TV):

```sh
luna-send -n 1 luna://com.webos.applicationManager/launch '{"id":"org.webosbrew.hbchannel","params":{"launchMode":"addRepository","url":"https://raw.githubusercontent.com/artor410/webOS6-usbrealtek-driver/main/repo/apps.json"}}'
```

### Installing the `.ipk` file by hand

Download `io.github.artor410.lgusbethernet_<version>_all.ipk` from
[Releases](https://github.com/artor410/webOS6-usbrealtek-driver/releases) and install it **one** of these ways:

- **webOS Dev Manager:** open [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop), connect to
  the TV, go to **Apps → Install** and pick the `.ipk`.
- **Over SSH:**

  ```sh
  scp io.github.artor410.lgusbethernet_<version>_all.ipk root@TV_IP:/tmp/app.ipk
  ssh root@TV_IP
  luna-send -n 6 luna://com.webos.appInstallService/dev/install '{"id":"io.github.artor410.lgusbethernet","ipkUrl":"/tmp/app.ipk","subscribe":true}'
  ```

Installed this way, the app does not update by itself; the Homebrew Channel method above is easier.

## First use

1. Plug the adapter into a USB port on the TV, and the network cable into the **adapter** (leave the TV's own
   Ethernet port empty).
2. Open **USB Ethernet (RTL8153)** from the app list.
3. The **Status** column should show the TV as compatible and your adapter as detected.
4. Press **Load driver now**. After a few seconds the adapter shows up with an address.
5. Press **Use adapter as main**. The network drops for a few seconds, then webOS sees the cable as connected
   (the *Cable in webOS* row says `connected`).
6. Once everything works, press **Load at TV startup** so it happens automatically every time the TV turns on.
7. Optional: press **Enable Wi-Fi fallback** if you have a Wi-Fi network saved on the TV.

That's it. From now on the TV comes up with the adapter by itself, about 45 seconds after you turn it on.

### What the buttons do

| Button | What it does |
|---|---|
| **Load driver now** / **Unload driver** | Turns the adapter's driver on or off right now. |
| **Use adapter as main** / **Use TV port as main** | Makes webOS treat the adapter as the TV's wired connection (needed for Settings and for apps that check the connection). The second button gives the role back to the TV's own port. |
| **Load at TV startup** / **Don't load at startup** | Loads the driver (and your other choices) automatically every time the TV starts. |
| **Enable Wi-Fi fallback** / **Disable Wi-Fi fallback** | If the cable has no link for 1 minute (loose cable, router restarting, adapter unplugged), turns Wi-Fi on; turns it off again once the cable has been back for 30 seconds. Needs a saved Wi-Fi network. |
| **Test speed** | Downloads 50 MB from Cloudflare and shows the result under *Last speed*. |

The status refreshes by itself every few seconds while the app is open.

## Tips for game streaming and movies

- Connect the TV and the gaming PC to the **same router or switch**, both with cables.
- Game-streaming hosts send each video frame as a burst at full gigabit speed. The TV asks the router to pause
  for a moment during each burst (Ethernet "flow control"), so the router's buffer catches the excess. Most
  routers do this; if you still see packet loss, try another switch.
- Bitrates **up to ~150 Mbit/s** are comfortable. At the same bitrate, **120 fps is easier than 60 fps** (each
  frame, and so each burst, is half the size). Very large bursts, such as 300 Mbit/s at 60 fps, are too much for
  the router to hold.
- A full-speed download on the TV at the same time (for example an app update) fills the connection and raises
  the latency to a few milliseconds while it lasts.
- For movies, prefer **direct play** over transcoding in Plex/Jellyfin; the adapter has the speed for it.

## What's different from LG's original driver

The driver for these adapters (`r8152`, from Realtek) is in the source code LG publishes for the TV, but the TV
does not come with it, and LG's copy is old. This project builds that same driver for the TV, with fixes:

- **It was throwing packets away.** Most adapters today use the **RTL8153B** version of the chip. LG's driver
  recognizes it but sets it up like the older RTL8153A. One setting (how much data the chip packs into each USB
  transfer) uses a different unit on the B chip, so the chip sent transfers twice as big as the driver's buffers,
  and the driver silently discarded whatever did not fit. With normal downloads TCP resends the lost data and you
  only notice lower speed; with game streaming, which never resends, ~45% of each video frame was lost.
  The setting is now done the way mainline Linux does it.
- **It was waiting too long.** The chip collects packets for a moment before handing them to the TV. On the B chip
  that delay lives in a different register; LG's driver put **250 µs** in the wrong one. It is now **15 µs** in the
  right one (as in mainline Linux), which is where most of the lower ping comes from.
- **Rest of the RTL8153B setup** copied from mainline Linux: a USB power-saving mode that can miss data is turned
  off, and power tables meant only for the older chip are no longer written.
- **More, right-sized buffers:** 32 receive buffers of 16 KB (LG: 10), the size the TV's USB controller handles
  in one piece.
- **Stability fixes** from newer Linux versions (shutdown ordering, error recovery, checksum handling, a false
  "transmit timeout").
- Adapters with the older RTL8152 / RTL8153A chips are programmed exactly as before.

The full change is one patch, [`driver/patches/`](driver/patches/), applied to LG's original
[`driver/r8152.c`](driver/r8152.c). Every step was measured on the TV; the numbers and method are in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

The app also raises a system limit on network receive buffers while the driver is loaded (from 512 KB to 4 MB),
because Moonlight asks for a bigger buffer than webOS normally allows.

## Safety and uninstalling

- The app only loads the driver on the TV model and system version it was built for.
- **If something goes wrong at startup:** if the TV fails to finish starting **twice in a row** right after
  loading the driver, the app stops loading it at startup by itself (and turns Wi-Fi on if Wi-Fi fallback is
  enabled, so the TV is not left offline). Homebrew Channel also has its own failsafe mode.
- **Clock:** if the TV's clock was never set (which breaks every secure website and app), the app sets it from
  the internet. A correct clock is never touched.
- **To uninstall:** in the app press **Don't load at startup** and **Unload driver**, then remove the app. (If
  you remove the app directly, its startup script deletes itself on the next boot.)

> [!WARNING]
> This loads a driver into the TV's system. It is built from the source code LG publishes for this TV and has
> been tested on the model listed below, but other firmware versions may behave differently. In the worst case the
> TV freezes and restarts, and it comes back normally. Use at your own risk.

## Troubleshooting

- **Settings says "Not connected" right after turning the TV on.** Homebrew apps can only start ~35 seconds into
  the boot; the adapter is ready at ~45 seconds. Wait a moment.
- **Slower than expected?** Press **Test speed** in the app. If you test from a PC, check that the PC's own link
  is really at 1 Gbit/s: some network cards come back from sleep stuck at 10 or 100 Mbit/s.
- **Adapter not detected?** Check that it is in the [supported list](#supported-adapters) and try another USB port.
- **Something else?** The app shows its log at the bottom. Please open an
  [issue](https://github.com/artor410/webOS6-usbrealtek-driver/issues) with your TV model, firmware version,
  adapter and the log.

## Tested on

| TV | Firmware / webOS | Adapter | Result |
|---|---|---|---|
| OLED55A1PSA (2021) | 03.53.45 / webOS 6.5.3 | Realtek RTL8153B (`0bda:8153`) | ✅ works |

Tested on that TV: loading at startup, the adapter as main connection, standby and power cycles, unplugging and
replugging the adapter, Wi-Fi fallback, and the speed and game-stream measurements above.

Tried it on another TV? Please open an [issue](https://github.com/artor410/webOS6-usbrealtek-driver/issues)
with the model, firmware and result.

## Supported adapters

Adapters with a Realtek RTL8152 (100 Mbit/s) or RTL8153 (1 Gbit/s) chip. USB IDs the driver accepts:

| VID:PID | Adapter |
|---|---|
| `0bda:8152`, `0bda:8153`, `0bda:8050` | Realtek (generic; most USB 3.0 / USB-C gigabit adapters) |
| `045e:07ab`, `045e:07c6` | Microsoft |
| `04e8:a101` | Samsung |
| `17ef:304f`, `17ef:3062`, `17ef:3069`, `17ef:7205`, `17ef:720c`, `17ef:7214` | Lenovo |
| `13b1:0041` | Linksys USB3GIGV1 |
| `0955:09ff` | NVIDIA |
| `2357:0601` | TP-Link UE300 |

**Not supported:** 2.5 Gbit/s adapters (RTL8156) and adapters with ASIX chips.

To check a TV over SSH:

```sh
nyx-cmd DeviceInfo query device_name   # should print: lm21u
uname -r                               # should start with: 4.4.84-
```

## For advanced users

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

How the main-connection swap works: webOS only treats `eth0` (normally the TV's own port) as the wired
connection, so the app renames the adapter to `eth0` and parks the built-in port as `eth2`. A light watcher redoes
the swap after standby and gives `eth0` back to the built-in port if the adapter is unplugged; if the adapter gets
no address after the swap, it undoes it so the TV is never left offline. This logic is adapted from
[LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0) (MIT, see [`THIRD_PARTY.md`](THIRD_PARTY.md)).

The driver has optional module parameters for experiments (none are needed); they are listed in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). [`tools/netprobe/`](tools/netprobe/) has the measurement tools
used for the numbers in this README.

### Building it yourself

The ready-made module is in [`prebuilt/`](prebuilt/) (SHA-256 in `prebuilt/*.sha256`). To reproduce it:

1. Download LG's GPL package **"webOS 6.0 LMUA 1.0"** from [opensource.lge.com](https://opensource.lge.com)
   (search for an `OLED55A1…` model); only part 2 is used.
2. On Linux (or WSL) with `gcc-9-arm-linux-gnueabihf`, `make`, `flex`, `bison`, `bc`, `patch` and `libssl-dev`:

   ```sh
   bash scripts/extract-source.sh /path/to/downloads
   bash scripts/build-r8152.sh       # builds build/r8152.ko with the TV's config (diagnostics/config.gz)
   bash scripts/package-ipk.sh       # builds dist/*.ipk, dist/*.manifest.json and repo/apps.json
   ```

`scripts/collect-tv-info.sh` writes a report about your TV, which is useful when opening an issue about another
model.

### Project layout

| Folder | Contents |
|---|---|
| `app/` | The Homebrew Channel app (HTML/JS) and its `bin/usbeth.sh` script |
| `driver/` | `r8152.c` exactly as in LG's GPL package, plus `patches/` applied at build time |
| `prebuilt/` | `r8152.ko` built for `4.4.84` / `lm21u` |
| `repo/` | This project's Homebrew Channel app list (`apps.json`) |
| `scripts/` | Diagnostics, build and packaging |
| `tools/netprobe/` | Network measurement tools (TV and PC) |
| `diagnostics/` | The TV's kernel config used for the build |
| `docs/` | Development notes and all measurements |

## Use of AI

The driver changes, the app and the scripts were written by an AI agent (Claude Code) under the maintainer's
direction; the maintainer ran the tests on their own TV (OLED55A1PSA) and is responsible for the project. The
driver changes follow mainline Linux and Realtek's own driver, and each one was measured on the TV before release
(see [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)).

## License and credits

- GPL-2.0 (see [`LICENSE`](LICENSE)). The `r8152` driver is © Realtek Semiconductor, distributed by LG in the
  TV's open source package ([`driver/r8152.c`](driver/r8152.c)); the RTL8153B setup follows the mainline Linux
  `r8152` driver.
- [webOS Homebrew Project](https://github.com/webosbrew) for Homebrew Channel.
- [LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0) for the interface swap and Wi-Fi fallback
  logic (MIT, see [`THIRD_PARTY.md`](THIRD_PARTY.md)).
- [throwaway96/webos-kernel-drivers](https://github.com/throwaway96/webos-kernel-drivers) and
  [DonZoomik/webos-r8152](https://github.com/DonZoomik/webos-r8152) for showing how to build modules for webOS
  TVs.
