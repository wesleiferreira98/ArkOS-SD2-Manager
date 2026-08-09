# ROM Splitter — dArkOS Dual Storage Manager

A proof-of-concept and usable first implementation for distributing ROMs between the dArkOS primary ROM partition (`/roms`) and a second microSD card (`/roms2`) while keeping EmulationStation paths unchanged.

## Core idea

A ROM physically stored on SD2 is bind-mounted back to its original `/roms/<system>/<game>` path. EmulationStation and emulators continue to see the normal `/roms` tree.

## Features implemented

- Detects candidate secondary storage devices dynamically.
- Refuses to format devices containing `/`, `/boot`, or `/roms`.
- Prepares the second card as exFAT with label `ROMS2`.
- Mounts SD2 at `/roms2`.
- Reads systems from `/etc/emulationstation/es_systems.cfg`.
- Lists games/items and shows SD1/SD2 location.
- Moves individual files, directories or multiple selected games SD1 -> SD2 and SD2 -> SD1.
- Groups `.cue` files with their referenced tracks and `.m3u` playlists with all referenced discs.
- Checks free space before transfers.
- Verifies copied size before deleting the source.
- Uses bind mounts so EmulationStation still sees `/roms`.
- Stores a manifest on SD2 and rebuilds binds after boot.
- Includes repair/diagnostics and safe unmount.
- Uses `dialog` when available, with terminal fallback.
- Preserves `gamelist.xml`, images and media by excluding them from normal game selection.

## Important safety status

This is an early version. The bind-mount concept has been validated manually on dArkOS, but the formatting and automated migration paths should still be tested on expendable media first.

The formatter contains multiple safeguards, but any partitioning/formatting feature deserves extra caution. Test with the 64 GB card before using a new 128/256 GB card.

## Dependencies

Expected on dArkOS or installable:

- bash
- util-linux (`lsblk`, `findmnt`, `mount`, `blkid`)
- exfatprogs (`mkfs.exfat`)
- parted
- rsync (recommended)
- dialog or whiptail (recommended)
- `oga_controls` (recommended on ArkOS/dArkOS for built-in gamepad navigation)

## Handheld controls

When launched on a supported ArkOS/dArkOS handheld, ROM Splitter looks for the existing `oga_controls` mapper and translates the built-in controls for the terminal UI:

Automatic profile detection covers Anbernic RG351/RG353/RG503, R35S, R36S, R36H, RGB10, RK2020, OGA, OGS and GameForce devices.

```text
D-Pad / analog stick  Navigate
A                     Confirm
B                     Previous screen / cancel
X                     Mark an item in a checklist
START                 Previous screen
```

Pressing B closes only the current screen. On the main menu it keeps the application open; use the explicit `Exit` option to close ROM Splitter.

Keyboard navigation remains available as a fallback. The active input backend is shown on the Diagnostics screen. If automatic device detection fails, a launcher may set `ROMS2_OGA_PROFILE` to one of `anbernic`, `chi`, `oga`, `ogs`, or `rk2020`.

## Install

Copy the entire `roms2-manager` folder onto the console, for example:

```bash
scp -r roms2-manager ark@CONSOLE_IP:/home/ark/
```

Then:

```bash
ssh ark@CONSOLE_IP
cd ~/roms2-manager
chmod +x install.sh
./install.sh
```

The installer creates:

```text
/roms/tools/ROM Splitter.sh
/opt/system/Tools/ROM Splitter.sh
/etc/systemd/system/roms2-manager.service
```

The `/roms/tools` launcher allows EmulationStation to discover and start ROM Splitter from its Tools interface. The `/opt/system/Tools` launcher is retained for ArkOS/dArkOS variants that use the system tools directory. After refreshing or restarting EmulationStation, `ROM Splitter` should be available in Tools.

## First test

1. Insert the expendable 64 GB card.
2. Start ROM Splitter.
3. Use `Mount SD2` if the card is already exFAT/ROMS2.
4. Choose `Manage games`.
5. Select Atari 2600 -> Enduro.
6. Move it to SD2.
7. Exit and run Enduro from EmulationStation.
8. Reboot the console and verify Enduro still launches; this validates the boot restoration service.

## Safe demo mode

To preview the interface, grouped games and batch transfers without a real SD card or root access:

```bash
chmod +x roms2-manager.sh
./roms2-manager.sh --demo
```

Demo data is created under `/tmp/roms2-manager-demo`. Formatting is disabled in this mode. Remove that directory to reset the demo.

## Manifest

The second card stores:

```text
/roms2/.roms2-manifest.tsv
```

Example:

```text
atari2600/Enduro (USA).zip\tfile
psx/Some Game.chd\tfile
ports/SomePort\tdir
```

The boot script uses this list to recreate bind mounts.

## Multi-file games

The manager treats `.cue` and `.m3u` entries as logical games. Referenced tracks, discs and nested CUE descriptors are transferred and verified together. Missing references and paths that escape the system directory are rejected before a transfer starts.

## PortMaster games

In `/roms/ports`, a top-level launcher and its matching directory are treated as one logical game:

```text
Celeste.sh + celeste/               -> Celeste
Stardew Valley.sh + stardewvalley/ -> Stardew Valley
```

Matching ignores case, spaces, hyphens and other punctuation. The launcher remains the visible item and the companion directory is transferred, verified and restored with it. An ambiguous directory match is rejected instead of guessing.

## Recovery

If a bind is missing:

```bash
cd ~/roms2-manager
sudo ./boot/roms2-mount.sh
```

Or use `Repair/rebuild bind mounts` from the interface.

If SD2 is removed, SD1 remains bootable. Items physically stored on SD2 are unavailable until SD2 is inserted and mounts are rebuilt.

## Uninstall

```bash
cd ~/roms2-manager
chmod +x uninstall.sh
./uninstall.sh
```

This removes only the launcher and boot service. It does not delete ROMs from either card.
