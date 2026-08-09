#!/usr/bin/env bash
set -Eeuo pipefail

free_bytes() {
  df -B1 --output=avail "$1" | tail -n1 | tr -d ' '
}

copy_with_progress() {
  local src="$1" dst="$2" gauge_title="${3:-Copying}"
  mkdir -p "$(dirname "$dst")"

  if command -v rsync >/dev/null 2>&1; then
    # rsync progress2 emits percentage; feed it to dialog gauge if available.
    if command -v dialog >/dev/null 2>&1; then
      local rsync_rc dialog_rc
      local -a pipeline_status
      set +e
      rsync -a --info=progress2 -- "$src" "$dst" 2>&1 | \
        stdbuf -oL tr '\r' '\n' | \
        awk 'match($0,/([0-9]{1,3})%/,m){print m[1]}' | \
        dialog --title "$gauge_title" --gauge "$(basename "$src")" 8 70 0
      pipeline_status=("${PIPESTATUS[@]}")
      rsync_rc=${pipeline_status[0]}
      dialog_rc=${pipeline_status[3]:-0}
      set -e
      (( rsync_rc == 0 && dialog_rc == 0 ))
    else
      rsync -a --info=progress2 -- "$src" "$dst"
    fi
  else
    cp -a -- "$src" "$dst"
  fi
}

verify_copy() {
  local src="$1" dst="$2"
  [[ -e "$src" && -e "$dst" ]] || return 1
  local a b
  a="$(file_size_bytes "$src")"
  b="$(file_size_bytes "$dst")"
  [[ "$a" == "$b" ]] || return 1

  command -v sha256sum >/dev/null 2>&1 || return 0
  if [[ -f "$src" && -f "$dst" ]]; then
    [[ "$(sha256sum -- "$src" | awk '{print $1}')" == "$(sha256sum -- "$dst" | awk '{print $1}')" ]]
  elif [[ -d "$src" && -d "$dst" ]]; then
    verify_directory_checksums "$src" "$dst"
  else
    return 1
  fi
}

directory_digest() {
  local root="$1"
  (
    cd "$root"
    find . -type f -print0 | sort -z | while IFS= read -r -d '' path; do
      printf 'F\0%s\0' "$path"
      sha256sum -- "$path" | awk '{printf "%s\\0", $1}'
    done
    find . -type d -print0 | sort -z | while IFS= read -r -d '' path; do printf 'D\0%s\0' "$path"; done
    find . -type l -print0 | sort -z | while IFS= read -r -d '' path; do printf 'L\0%s\0%s\0' "$path" "$(readlink -- "$path")"; done
  ) | sha256sum | awk '{print $1}'
}

verify_directory_checksums() {
  [[ "$(directory_digest "$1")" == "$(directory_digest "$2")" ]]
}

move_to_sd2() {
  local rel="$1"
  validate_manifest_rel "$rel" || { fail "Invalid or unsupported item path: $rel"; return 1; }
  mount_sd2 || return 1
  local src="$ROMS_ROOT/$rel" dst="$ROMS2_ROOT/$rel"
  [[ -e "$src" ]] || { fail "Source not found: $src"; return 1; }
  [[ ! -e "$dst" ]] || { fail "Destination already exists: $dst"; return 1; }
  if mountpoint -q "$src" 2>/dev/null; then fail "Item is already mounted from SD2: $rel"; return 1; fi

  local size free kind
  size="$(file_size_bytes "$src")"
  free="$(free_bytes "$ROMS2_ROOT")"
  (( free > size + 10485760 )) || { fail "Not enough free space on SD2."; return 1; }
  kind="file"; [[ -d "$src" ]] && kind="dir"

  copy_with_progress "$src" "$dst" "Moving to SD2" || {
    rm -rf -- "$dst"
    fail "Copy was cancelled or failed. Original was preserved."
    return 1
  }
  verify_copy "$src" "$dst" || { rm -rf -- "$dst"; fail "Copy verification failed. Original was preserved."; return 1; }

  local backup="${src}.roms2-tmp-backup"
  mv -- "$src" "$backup"
  if [[ "$kind" == "dir" ]]; then mkdir -p "$src"; else : > "$src"; fi

  if ! bind_item "$dst" "$src"; then
    rm -rf -- "$src" 2>/dev/null || true
    mv -- "$backup" "$src"
    rm -rf -- "$dst"
    fail "Bind mount failed. Original was restored."
    return 1
  fi

  rm -rf -- "$backup"
  manifest_add "$rel" "$kind"
  log "Moved to SD2: $rel"
}

move_to_sd1() {
  local rel="$1"
  validate_manifest_rel "$rel" || { fail "Invalid or unsupported item path: $rel"; return 1; }
  mount_sd2 || return 1
  local src="$ROMS2_ROOT/$rel" dst="$ROMS_ROOT/$rel"
  [[ -e "$src" ]] || { fail "SD2 source not found: $src"; return 1; }

  local size free kind
  size="$(file_size_bytes "$src")"
  free="$(free_bytes "$ROMS_ROOT")"
  (( free > size + 10485760 )) || { fail "Not enough free space on SD1."; return 1; }
  kind="file"; [[ -d "$src" ]] && kind="dir"

  unbind_one "$dst"
  rm -rf -- "$dst"
  mkdir -p "$(dirname "$dst")"

  copy_with_progress "$src" "$dst" "Moving to SD1" || {
    rm -rf -- "$dst"
    bind_item "$src" "$dst" || true
    fail "Copy was cancelled or failed. SD2 copy was preserved."
    return 1
  }
  if ! verify_copy "$src" "$dst"; then
    rm -rf -- "$dst"
    bind_item "$src" "$dst" || true
    fail "Copy verification failed. SD2 copy was preserved."
    return 1
  fi

  rm -rf -- "$src"
  manifest_remove "$rel"
  log "Moved to SD1: $rel"
}

move_group_to_sd2() {
  local primary="$1" rel resolved
  local -a members moved=()
  resolved="$(resolve_game_group "$primary")" || return 1
  mapfile -t members <<< "$resolved"
  ((${#members[@]})) || { fail "No files found for game: $primary"; return 1; }

  for rel in "${members[@]}"; do
    case "$(item_location "$rel")" in
      SD1)
        if move_to_sd2 "$rel"; then
          moved+=("$rel")
        else
          local rollback
          for ((rollback=${#moved[@]}-1; rollback>=0; rollback--)); do
            move_to_sd1 "${moved[rollback]}" || log "Group rollback failed: ${moved[rollback]}"
          done
          fail "Game group transfer failed and completed items were rolled back: $primary"
          return 1
        fi
        ;;
      SD2|SD2-unmounted) ;;
      *) fail "Invalid member state in game group: $rel"; return 1 ;;
    esac
  done
  log "Moved game group to SD2: $primary (${#members[@]} items)"
}

move_group_to_sd1() {
  local primary="$1" rel resolved
  mount_sd2 || return 1
  local -a members moved=()
  resolved="$(resolve_game_group "$primary")" || return 1
  mapfile -t members <<< "$resolved"
  ((${#members[@]})) || { fail "No files found for game: $primary"; return 1; }

  for rel in "${members[@]}"; do
    case "$(item_location "$rel")" in
      SD2)
        if move_to_sd1 "$rel"; then
          moved+=("$rel")
        else
          local rollback
          for ((rollback=${#moved[@]}-1; rollback>=0; rollback--)); do
            move_to_sd2 "${moved[rollback]}" || log "Group rollback failed: ${moved[rollback]}"
          done
          fail "Game group restore failed and completed items were rolled back: $primary"
          return 1
        fi
        ;;
      SD1) ;;
      *) fail "Invalid member state in game group: $rel"; return 1 ;;
    esac
  done
  log "Moved game group to SD1: $primary (${#members[@]} items)"
}

repair_storage() {
  mount_sd2
  rebuild_binds

  local manifest="$ROMS2_ROOT/.roms2-manifest.tsv"
  [[ -f "$manifest" ]] || return 0
  while IFS=$'\t' read -r rel kind; do
    [[ -n "$rel" ]] || continue
    local src="$ROMS2_ROOT/$rel" dst="$ROMS_ROOT/$rel"
    if [[ ! -e "$src" ]]; then
      log "Manifest orphan: $rel"
      continue
    fi
    if ! mountpoint -q "$dst" 2>/dev/null; then
      bind_item "$src" "$dst" || true
    fi
  done < "$manifest"
}

IMPORT_ADDED=0
IMPORT_CONFLICTS=0
IMPORT_FAILED=0

import_new_sd2_items() {
  mount_sd2 || return 1
  IMPORT_ADDED=0
  IMPORT_CONFLICTS=0
  IMPORT_FAILED=0

  local rel src dst kind
  while IFS= read -r -d '' rel; do
    src="$ROMS2_ROOT/$rel"
    dst="$ROMS_ROOT/$rel"
    kind=file; [[ -d "$src" ]] && kind=dir

    if [[ -e "$dst" || -L "$dst" ]]; then
      log "SD2 import conflict, SD1 path already exists: $rel"
      IMPORT_CONFLICTS=$((IMPORT_CONFLICTS+1))
      continue
    fi

    if bind_item "$src" "$dst"; then
      manifest_add "$rel" "$kind"
      IMPORT_ADDED=$((IMPORT_ADDED+1))
      log "Imported new SD2 item: $rel"
    else
      IMPORT_FAILED=$((IMPORT_FAILED+1))
      log "Failed to import SD2 item: $rel"
    fi
  done < <(discover_unmanaged_sd2_items)

  (( IMPORT_FAILED == 0 ))
}
