#!/usr/bin/env bash
set -Eeuo pipefail

root_parent_device() {
  local src pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
  [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk"
}

roms_parent_device() {
  local src pk
  src="$(findmnt -n -o SOURCE "$ROMS_ROOT" 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
  [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk"
}

list_candidate_sd2_devices() {
  local rootdev romsdev
  rootdev="$(root_parent_device || true)"
  romsdev="$(roms_parent_device || true)"

  lsblk -dpno NAME,TYPE,RM,SIZE,MODEL | while read -r name type rm size model; do
    [[ "$type" == "disk" ]] || continue
    [[ "$name" == "$rootdev" ]] && continue
    [[ "$name" == "$romsdev" ]] && continue
    case "$name" in
      /dev/mmcblk*|/dev/sd*|/dev/nvme*) ;;
      *) continue ;;
    esac
    printf '%s|%s|%s\n' "$name" "$size" "${model:-Unknown}"
  done
}

find_sd2_partition() {
  load_config
  if [[ -n "${ROMS2_UUID:-}" ]]; then
    local byuuid
    byuuid="$(blkid -U "$ROMS2_UUID" 2>/dev/null || true)"
    [[ -b "$byuuid" ]] && { printf '%s\n' "$byuuid"; return 0; }
  fi

  local dev
  while IFS='|' read -r dev _ _; do
    lsblk -lnpo NAME,TYPE,LABEL "$dev" | awk '$2=="part" && $3=="ROMS2"{print $1; exit}'
  done < <(list_candidate_sd2_devices)
}

validate_not_system_device() {
  local dev="$1" rootdev romsdev
  rootdev="$(root_parent_device || true)"
  romsdev="$(roms_parent_device || true)"
  [[ "$dev" != "$rootdev" && "$dev" != "$romsdev" ]] || return 1

  if findmnt -rn -S "${dev}"* -o TARGET 2>/dev/null | grep -Eq '^/$|^/boot$|^/roms$'; then
    return 1
  fi
  return 0
}

sd2_info() {
  local part
  part="$(find_sd2_partition || true)"
  if [[ -z "$part" ]]; then
    printf 'not-configured\n'
    return 0
  fi
  lsblk -no NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$part"
}
