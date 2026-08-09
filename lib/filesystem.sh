#!/usr/bin/env bash
set -Eeuo pipefail

prepare_sd2_device() {
  local dev="$1"
  [[ -b "$dev" ]] || fail "Invalid block device: $dev"
  validate_not_system_device "$dev" || fail "Refusing to format system/storage device: $dev"

  # Extra fail-safe: refuse any disk with mounted child partitions.
  if lsblk -nrpo MOUNTPOINT "$dev" | grep -qE '^/|^/boot$|^/roms$'; then
    fail "Refusing to format a device containing a protected mount."
  fi

  run_root umount "${dev}"p* 2>/dev/null || run_root umount "${dev}"[0-9]* 2>/dev/null || true

  command -v parted >/dev/null 2>&1 || fail "parted is required to format a card."
  command -v mkfs.exfat >/dev/null 2>&1 || fail "mkfs.exfat is required to format a card."

  run_root parted -s "$dev" mklabel gpt
  run_root parted -s "$dev" mkpart primary exfat 1MiB 100%
  run_root partprobe "$dev" || true
  sleep 1

  local part
  if [[ "$dev" == /dev/mmcblk* || "$dev" == /dev/nvme* ]]; then
    part="${dev}p1"
  else
    part="${dev}1"
  fi
  [[ -b "$part" ]] || { sleep 2; [[ -b "$part" ]] || fail "Partition was not created: $part"; }

  run_root mkfs.exfat -n ROMS2 "$part"
  local uuid
  uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
  save_config_value ROMS2_UUID "$uuid"
  save_config_value ROMS2_PARTITION "$part"
  log "Prepared SD2 device $dev ($part, UUID=$uuid)"
}
