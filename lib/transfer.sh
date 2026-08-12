#!/usr/bin/env bash
set -Eeuo pipefail

free_bytes() {
  df -B1 --output=avail "$1" | tail -n1 | tr -d ' '
}

copy_with_progress() {
  local src="$1" dst="$2" gauge_title="${3:-Copying}"
  local total_files=1
  local -a rsync_args=(-a --info=progress2 --out-format=ROMFILE:%n --)
  mkdir -p "$(dirname "$dst")"

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    total_files="$(find "$src" \( -type f -o -type l \) -printf . | wc -c)"
    rsync_args+=("$src/" "$dst/")
  else
    rsync_args+=("$src" "$dst")
  fi

  if command -v rsync >/dev/null 2>&1; then
    # rsync progress2 emits percentage; feed it to dialog gauge if available.
    if command -v dialog >/dev/null 2>&1; then
      local rsync_rc dialog_rc
      local -a pipeline_status
      set +e
      rsync "${rsync_args[@]}" 2>&1 | \
        stdbuf -oL tr '\r' '\n' | \
        stdbuf -oL awk -v total_files="$total_files" -v fallback_name="$(basename "$src")" -v log_file="$LOG_FILE" '
          BEGIN { current_file = fallback_name; copied = 0 }
          /^ROMFILE:/ {
            current_file = substr($0, 9)
            if (current_file !~ /\/$/) copied++
            next
          }
          match($0, /[0-9][0-9]*%/) {
            percentage = substr($0, RSTART, RLENGTH - 1) + 0
            if (percentage < 100 && percentage != previous) {
              print "XXX"
              print percentage
              print current_file "\n\nFiles copied: " copied "/" total_files
              print "XXX"
              previous = percentage
            }
            next
          }
          NF { print "RSYNC: " $0 >> log_file; fflush(log_file) }
          END {
            print "XXX"
            print 100
            print current_file "\n\nFiles copied: " total_files "/" total_files
            print "XXX"
          }
        ' | \
        dialog --title "$gauge_title" --gauge "$(basename "$src")" 9 68 0
      pipeline_status=("${PIPESTATUS[@]}")
      rsync_rc=${pipeline_status[0]}
      dialog_rc=${pipeline_status[3]:-0}
      set -e
      (( rsync_rc == 0 && dialog_rc == 0 ))
    else
      rsync "${rsync_args[@]}"
    fi
  else
    if [[ -d "$src" ]]; then
      cp -a -- "$src/." "$dst/"
    else
      cp -a -- "$src" "$dst"
    fi
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

verification_progress() {
  local fd="${1:-}" percentage="$2" message="$3"
  [[ -n "$fd" ]] || return 0
  printf 'XXX\n%s\n%s\nXXX\n' "$percentage" "$message" >&"$fd"
}

directory_digest_with_progress() {
  local root="$1" progress_fd="$2" offset="$3" span="$4" total_files="$5" phase="$6"
  local path index=0 percentage status_text
  (
    cd "$root"
    while IFS= read -r -d '' path; do
      index=$((index+1))
      percentage=$((offset + index * span / (total_files > 0 ? total_files : 1)))
      printf -v status_text '%s: %s\n\nFiles checked: %s/%s' \
        "$phase" "${path#./}" "$index" "$total_files"
      verification_progress "$progress_fd" "$percentage" "$status_text"
      printf 'F\0%s\0' "$path"
      sha256sum -- "$path" | awk '{printf "%s\\0", $1}'
    done < <(find . -type f -print0 | sort -z)
    find . -type d -print0 | sort -z | while IFS= read -r -d '' path; do printf 'D\0%s\0' "$path"; done
    find . -type l -print0 | sort -z | while IFS= read -r -d '' path; do printf 'L\0%s\0%s\0' "$path" "$(readlink -- "$path")"; done
  ) | sha256sum | awk '{print $1}'
}

verify_copy_progress_stream() {
  local src="$1" dst="$2" src_hash dst_hash src_files dst_files
  [[ -e "$src" && -e "$dst" ]] || return 1

  verification_progress 3 2 "Checking copied size..."
  if [[ -f "$src" && -f "$dst" ]]; then
    [[ "$(file_size_bytes "$src")" == "$(file_size_bytes "$dst")" ]] || return 1
    verification_progress 3 10 "Verifying source: $(basename "$src")"
    src_hash="$(sha256sum -- "$src" | awk '{print $1}')"
    verification_progress 3 55 "Verifying destination: $(basename "$dst")"
    dst_hash="$(sha256sum -- "$dst" | awk '{print $1}')"
  elif [[ -d "$src" && -d "$dst" ]]; then
    src_files="$(find "$src" -type f -printf . | wc -c)"
    dst_files="$(find "$dst" -type f -printf . | wc -c)"
    verification_progress 3 5 "Preparing verification for $src_files file(s)..."
    src_hash="$(directory_digest_with_progress "$src" 3 5 45 "$src_files" "Checking source")"
    dst_hash="$(directory_digest_with_progress "$dst" 3 50 45 "$dst_files" "Checking copy")"
  else
    return 1
  fi

  [[ "$src_hash" == "$dst_hash" ]] || return 1
  verification_progress 3 100 "Copy verified successfully."
}

verify_copy_with_progress() {
  local src="$1" dst="$2" title="${3:-Verifying copy}"
  local verify_rc gauge_rc
  local -a pipeline_status

  if declare -F ui_gauge >/dev/null 2>&1 && [[ -n "${UI_BIN:-}" ]]; then
    set +e
    verify_copy_progress_stream "$src" "$dst" 3>&1 | ui_gauge "$title" "Checking copied data..."
    pipeline_status=("${PIPESTATUS[@]}")
    verify_rc=${pipeline_status[0]:-1}
    gauge_rc=${pipeline_status[1]:-1}
    set -e
    ((verify_rc == 0 && gauge_rc == 0))
  else
    verify_copy "$src" "$dst"
  fi
}

show_finalizing_transfer() {
  local message="$1"
  if declare -F ui_infobox >/dev/null 2>&1; then
    ui_infobox "Finalizing transfer" "$message\n\nDo not turn off the device."
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
  verify_copy_with_progress "$src" "$dst" "Verifying SD2 copy" || {
    rm -rf -- "$dst"
    fail "Copy verification failed. Original was preserved."
    return 1
  }

  show_finalizing_transfer "Creating the SD2 link and safely removing the SD1 source..."
  local backup="${src}.roms2-tmp-backup"
  mv -- "$src" "$backup"

  if ! bind_item "$dst" "$src" "$rel"; then
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
    bind_item "$src" "$dst" "$rel" || true
    fail "Copy was cancelled or failed. SD2 copy was preserved."
    return 1
  }
  if ! verify_copy_with_progress "$src" "$dst" "Verifying SD1 copy"; then
    rm -rf -- "$dst"
    bind_item "$src" "$dst" "$rel" || true
    fail "Copy verification failed. SD2 copy was preserved."
    return 1
  fi

  show_finalizing_transfer "Removing the SD2 source and updating storage records..."
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

delete_item_permanently() {
  local rel="$1" location src_sd1="$ROMS_ROOT/$rel" src_sd2="$ROMS2_ROOT/$rel"
  validate_manifest_rel "$rel" || { fail "Invalid or unsupported item path: $rel"; return 1; }
  location="$(item_location "$rel")"

  case "$location" in
    SD1)
      rm -rf -- "$src_sd1" || { fail "Could not delete from SD1: $rel"; return 1; }
      ;;
    SD2)
      unbind_one "$src_sd1" || { fail "Could not unmount before deleting: $rel"; return 1; }
      rm -rf -- "$src_sd1"
      rm -rf -- "$src_sd2" || { fail "Could not delete from SD2: $rel"; return 1; }
      manifest_remove "$rel"
      ;;
    SD2-unmounted)
      rm -rf -- "$src_sd2" || { fail "Could not delete from SD2: $rel"; return 1; }
      rm -rf -- "$src_sd1"
      manifest_remove "$rel"
      ;;
    *) fail "Game item was not found for deletion: $rel"; return 1 ;;
  esac
  log "Permanently deleted: $rel ($location)"
}

delete_game_group() {
  local primary="$1" rel resolved deleted=0
  local -a members
  resolved="$(resolve_game_group "$primary")" || return 1
  mapfile -t members <<< "$resolved"
  ((${#members[@]})) || { fail "No files found for game: $primary"; return 1; }

  for rel in "${members[@]}"; do
    if delete_item_permanently "$rel"; then
      deleted=$((deleted+1))
    else
      fail "Game group deletion stopped after $deleted of ${#members[@]} items: $primary"
      return 1
    fi
  done
  log "Permanently deleted game group: $primary (${#members[@]} items)"
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
  local progress_fd="${1:-}" status_file="${2:-}" inventory_file total=0 processed=0 percentage status_text
  mount_sd2 || return 1
  IMPORT_ADDED=0
  IMPORT_CONFLICTS=0
  IMPORT_FAILED=0

  inventory_file="$(mktemp "$STATE_DIR/sd2-import.XXXXXX")"
  discover_unmanaged_sd2_items > "$inventory_file"
  while IFS= read -r -d '' rel; do total=$((total+1)); done < "$inventory_file"
  verification_progress "$progress_fd" 5 "Found $total new item(s) to inspect."

  local rel src dst kind
  while IFS= read -r -d '' rel; do
    processed=$((processed+1))
    percentage=$((5 + processed * 94 / (total > 0 ? total : 1)))
    src="$ROMS2_ROOT/$rel"
    dst="$ROMS_ROOT/$rel"
    kind=file; [[ -d "$src" ]] && kind=dir

    if [[ -e "$dst" || -L "$dst" ]]; then
      log "SD2 import conflict, SD1 path already exists: $rel"
      IMPORT_CONFLICTS=$((IMPORT_CONFLICTS+1))
    elif bind_item "$src" "$dst"; then
      manifest_add "$rel" "$kind"
      IMPORT_ADDED=$((IMPORT_ADDED+1))
      log "Imported new SD2 item: $rel"
    else
      IMPORT_FAILED=$((IMPORT_FAILED+1))
      log "Failed to import SD2 item: $rel"
    fi
    printf -v status_text 'Inspected: %s\n\nProcessed: %s/%s | Linked: %s | Conflicts: %s | Failed: %s' \
      "$rel" "$processed" "$total" "$IMPORT_ADDED" "$IMPORT_CONFLICTS" "$IMPORT_FAILED"
    verification_progress "$progress_fd" "$percentage" "$status_text"
  done < "$inventory_file"
  rm -f -- "$inventory_file"

  if [[ -n "$status_file" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$IMPORT_ADDED" "$IMPORT_CONFLICTS" "$IMPORT_FAILED" "$total" > "$status_file"
  fi
  printf -v status_text 'Scan complete.\n\nInspected: %s | Linked: %s | Conflicts: %s | Failed: %s' \
    "$total" "$IMPORT_ADDED" "$IMPORT_CONFLICTS" "$IMPORT_FAILED"
  verification_progress "$progress_fd" 99 "$status_text"

  (( IMPORT_FAILED == 0 ))
}
