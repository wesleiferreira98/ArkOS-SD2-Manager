# ROM Splitter — ArkOS/dArkOS Dual Storage Manager

ROM Splitter distributes games between the primary ROM partition (`/roms`) and a second microSD card (`/roms2`) without changing the paths used by EmulationStation or emulators.

Games stored physically on SD2 are bind-mounted back to their original `/roms/<system>/<game>` locations. If SD2 is absent, the console and games remaining on SD1 continue to work normally.

> **Pre-release warning:** version 0.2.0 has automated local tests but still requires validation on real handheld hardware. Test formatting and transfers with expendable media before using an important card. Formatting permanently erases the selected device.

## Features

- Detects candidate secondary storage devices and protects devices containing `/`, `/boot`, or `/roms`.
- Prepares SD2 as exFAT with the `ROMS2` label and mounts it at `/roms2`.
- Reads systems from EmulationStation and shows game size and SD1/SD2 location.
- Transfers one or multiple files/directories with free-space checks, SHA-256 verification and rollback on failure.
- Restores bind mounts automatically after boot using a manifest stored on SD2.
- Groups CUE tracks, M3U multidisc sets and matching PortMaster launcher/directories.
- Discovers games copied directly to SD2 from a computer or over the network.
- Provides diagnostics, mount repair and safe unmount operations.
- Supports built-in handheld controls through `oga_controls`, with keyboard fallback.
- Leaves `gamelist.xml`, artwork and media out of normal game transfers.

## Supported controls

Automatic controller profile detection covers Anbernic RG351/RG353/RG503, R35S, R36S, R36H, RGB10, RK2020, OGA, OGS and GameForce devices.

```text
D-Pad / analog stick  Navigate
A                     Confirm
B                     Previous screen / cancel
X                     Mark or unmark a checklist item
START                 Previous screen
```

B closes only the current screen. On the main menu, exit using the explicit `Exit` option. The active input backend is displayed under `Diagnostics`.

If device detection fails, set `ROMS2_OGA_PROFILE` in the launcher to `anbernic`, `chi`, `oga`, `ogs`, or `rk2020`.

## Requirements

The following commands are expected on ArkOS/dArkOS:

- Bash
- util-linux: `lsblk`, `findmnt`, `mount`, `blkid`
- `unzip`
- `sha256sum`
- `rsync` (recommended; `cp` is the fallback)
- `dialog` or `whiptail` (recommended)
- `oga_controls` (recommended for built-in gamepad input)
- `parted` and `mkfs.exfat` from exfatprogs (required only to format SD2)

Administrative operations use `sudo` when the manager is not running as root.

## Install the release package

The release contains two files:

```text
ROM-Splitter-0.2.0.zip
Install ROM Splitter.sh
```

1. Copy both files to the console's `/roms/tools` directory. This can be done by inserting SD1 into a computer, using SCP/SFTP, or using a file manager on the console.
2. Refresh or restart EmulationStation.
3. Open `Tools` and run `Install ROM Splitter`.
4. Wait for the success message.
5. Refresh or restart EmulationStation again.
6. Open `Tools > ROM Splitter`.

The package installer verifies the ZIP checksum before extraction and installs the application at:

```text
/roms/tools/.rom-splitter
```

It creates launchers at:

```text
/roms/tools/ROM Splitter.sh
/opt/system/Tools/ROM Splitter.sh
```

It also installs the boot restoration service:

```text
/etc/systemd/system/roms2-manager.service
```

## Install from source

Copy or clone the project onto the console, then run:

```bash
chmod +x install.sh
./install.sh
```

The generated launchers point to the source directory, so do not move or delete that directory after installation.

## First safe test

1. Use an empty or expendable microSD card.
2. Start ROM Splitter from EmulationStation's Tools screen.
3. Open `Diagnostics` and confirm that the controller backend and SD1 information look correct.
4. Insert SD2 and open `Storage information`.
5. If SD2 is already exFAT and labeled `ROMS2`, select `Mount SD2`.
6. Move one small, nonessential, single-file game to SD2.
7. Launch the game from EmulationStation.
8. Reboot and launch it again to test boot-time mount restoration.
9. Restore the game to SD1 before testing larger batches.

Do not use `Prepare/format SD2` until device detection has been checked carefully.

## Prepare a new SD2 card

`Prepare/format SD2` performs the following destructive operation:

```text
create GPT partition table
create one exFAT partition
label the partition ROMS2
save its UUID
mount it at /roms2
```

The manager excludes detected system and ROM devices and asks for confirmation. Nevertheless, verify the displayed device name and capacity before confirming. All existing data on the selected device will be lost.

## Move games between cards

1. Open `Manage games`.
2. Select a system.
3. Use X to mark one or more games.
4. Press A to continue.
5. Review the game count, item count, total size and destination.
6. Confirm the operation.

SD1 games are moved to SD2; SD2 games are restored to SD1. A batch must contain games from only one storage location. The source is not removed until copying and verification succeed.

## CUE and multidisc games

A `.cue` file and every local track referenced by its `FILE` statements are treated as one logical game. An `.m3u` playlist and every referenced disc or nested CUE set are also treated as one game.

```text
Final Fantasy VII.m3u
Final Fantasy VII (Disc 1).chd
Final Fantasy VII (Disc 2).chd
Final Fantasy VII (Disc 3).chd
```

Missing references, absolute paths and references escaping the current system directory are rejected before transfer.

## PortMaster games

In `/roms/ports`, a top-level launcher and its matching directory are grouped automatically:

```text
Celeste.sh + celeste/
Stardew Valley.sh + stardewvalley/
Half-Life.sh + half-life/
```

Matching ignores case, spaces, hyphens, underscores and punctuation. If more than one directory matches, ROM Splitter reports an ambiguity instead of guessing. A launcher without a matching directory remains an individual item.

## Games copied directly to SD2

Files may be copied directly to SD2 using a computer, SCP/SFTP or a network share. Keep the same system layout used by SD1:

```text
/roms2/psx/New Game.chd
/roms2/dreamcast/Game.cue
/roms2/ports/Celeste.sh
/roms2/ports/celeste/
```

After inserting and mounting SD2:

1. Open ROM Splitter.
2. Select `Scan SD2 for new games`.
3. Review the number of linked items, conflicts and failures.
4. Refresh the EmulationStation game list if necessary.

New items are added to the SD2 manifest and bind-mounted at their matching `/roms` paths. If a real SD1 item already occupies a path, it is reported as a conflict and neither copy is changed. Hidden files, metadata/media directories and `/roms2/tools` are ignored.

## Diagnostics and repair

Use `Diagnostics` to inspect SD1, SD2, the configured card, manifest entry count and controller backend.

Use `Repair/rebuild bind mounts` when files exist on SD2 but are not visible under `/roms`. The boot restoration script can also be run manually:

```bash
sudo /roms/tools/.rom-splitter/boot/roms2-mount.sh
```

Logs are stored at:

```text
/roms/tools/.rom-splitter/logs/roms2-manager.log
```

## Safely remove SD2

Close any running game stored on SD2, open ROM Splitter, and select `Safely unmount SD2`. Remove the card only after the success message. Games stored on SD2 remain unavailable until the card is reinserted and mounts are rebuilt.

## Update

Copy the new ZIP and its matching `Install ROM Splitter.sh` into `/roms/tools`, then run the installer again. Existing configuration and SD2 data are preserved. Always use the installer distributed with that exact ZIP because it contains the expected package checksum.

## Uninstall

Run:

```bash
/roms/tools/.rom-splitter/uninstall.sh
```

This removes both launchers and the boot service. It does not delete games, the SD2 manifest, or data from either card. The hidden application directory may be removed manually after uninstalling if its logs and configuration are no longer needed.

## Demo mode

On a desktop Linux system, preview the UI and simulated transfers without root access or real storage devices:

```bash
chmod +x roms2-manager.sh
./roms2-manager.sh --demo
```

Demo files are created under `/tmp/roms2-manager-demo`. Formatting is disabled. Delete that directory to reset the demo.

## Build a release

On the development computer:

```bash
chmod +x scripts/build-release.sh
./scripts/build-release.sh
```

The generated files are placed in `dist/`. Update `VERSION` before building a new release.

## Internal storage layout

SD2 stores the persistent bind manifest at:

```text
/roms2/.roms2-manifest.tsv
```

At boot, `roms2-manager.service` mounts the configured SD2 by UUID and recreates every registered bind mount. The absence of SD2 does not prevent normal SD1 startup.
