#!/usr/bin/env bash
set -Eeuo pipefail

UI_BIN=""
if command -v dialog >/dev/null 2>&1; then UI_BIN="dialog"; elif command -v whiptail >/dev/null 2>&1; then UI_BIN="whiptail"; fi

ui_prompt_with_controls() {
  local prompt="$1"
  if declare -F controller_help_text >/dev/null 2>&1; then
    printf '%s\n\n%s' "$prompt" "$(controller_help_text)"
  else
    printf '%s' "$prompt"
  fi
}

ui_msg() {
  local title="$1" text="$2"
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --title "$title" --msgbox "$(ui_prompt_with_controls "$text")" 14 72 || true
  else
    printf '\n[%s]\n%s\n' "$title" "$text"
  fi
}

ui_infobox() {
  local title="$1" text="$2"
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --title "$title" --infobox "$text" 8 72 || true
  else
    printf '\n[%s]\n%s\n' "$title" "$text"
  fi
}

ui_yesno() {
  local title="$1" text="$2"
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --title "$title" --yesno "$(ui_prompt_with_controls "$text")" 16 72
  else
    read -r -p "$text [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
  fi
}

ui_menu() {
  local title="$1" prompt="$2"; shift 2
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --clear --title "$title" --menu "$(ui_prompt_with_controls "$prompt")" 22 78 12 "$@" 3>&1 1>&2 2>&3
  else
    local args=("$@") i=0
    printf '\n%s\n%s\n' "$title" "$prompt" >&2
    while (( i < ${#args[@]} )); do printf '%s) %s\n' "${args[i]}" "${args[i+1]}" >&2; i=$((i+2)); done
    read -r -p '> ' choice || return 1
    printf '%s\n' "$choice"
  fi
}

ui_checklist() {
  local title="$1" prompt="$2"; shift 2
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --separate-output --title "$title" --checklist "$(ui_prompt_with_controls "$prompt")" 24 78 15 "$@" 3>&1 1>&2 2>&3
  else
    local args=("$@") i=0 answer token
    printf '\n%s\n%s\n' "$title" "$prompt" >&2
    while (( i < ${#args[@]} )); do
      printf '%s) %s\n' "${args[i]}" "${args[i+1]}" >&2
      i=$((i+3))
    done
    read -r -p 'Numbers separated by spaces: ' answer || return 1
    for token in $answer; do printf '%s\n' "$token"; done
  fi
}

ui_gauge() {
  local title="$1" prompt="$2"
  if [[ -n "$UI_BIN" ]]; then
    "$UI_BIN" --title "$title" --gauge "$prompt" 10 72 0
  else
    # Keep noninteractive/keyboard-only execution quiet while consuming input.
    while IFS= read -r _; do :; done
  fi
}

build_system_menu_cache() {
  local system="$1" output_file="$2" item loc size rel index=0 total
  local -a logical_items=()

  inventory_progress 3 2 "Scanning $system storage..."
  prepare_system_inventory_cache "$system"
  inventory_progress 3 10 "Reading game entries..."
  mapfile -t logical_items < <(list_logical_games_for_system "$system" 3)
  total=${#logical_items[@]}

  : > "$output_file"
  for item in "${logical_items[@]}"; do
    index=$((index+1))
    rel="$system/$item"
    loc="$(cached_group_location "$rel")"
    if [[ "$system" == ports ]]; then
      size="size calculated after selection"
    else
      size="$(human_size "$(cached_group_size "$rel" 2>/dev/null || echo 0)")"
    fi
    printf '%s\0%s\0%s\0' "$item" "$loc" "$size" >> "$output_file"
    inventory_progress 3 $((55 + index * 44 / (total > 0 ? total : 1))) \
      "Preparing game list: $index/$total"
  done
  inventory_progress 3 100 "Game list ready: $total game(s)"
}

show_storage_info() {
  local s1 s2
  s1="$(df -h "$ROMS_ROOT" | tail -n1 | awk '{print "SD1: " $3 " used / " $2 ", " $4 " free"}')"
  if findmnt -rn "$ROMS2_ROOT" >/dev/null 2>&1; then
    s2="$(df -h "$ROMS2_ROOT" | tail -n1 | awk '{print "SD2: " $3 " used / " $2 ", " $4 " free"}')"
  else
    s2="SD2: not mounted"
  fi
  ui_msg "Storage" "$s1\n$s2\n\n$(sd2_info)"
}

choose_system() {
  local opts=() s
  while read -r s; do [[ -n "$s" ]] && opts+=("$s" "$s"); done < <(systems_from_es)
  ((${#opts[@]})) || return 1
  ui_menu "ROM Splitter" "Choose a system" "${opts[@]}"
}

manage_system() {
  local system="$1" item loc size rel id selected_output scan_file scan_rc gauge_rc needs_refresh=1
  local -a scan_pipeline_status opts=() games=()
  while true; do
    if ((needs_refresh)); then
      opts=()
      games=()
      id=0
      scan_file="$(mktemp "$STATE_DIR/system-scan.XXXXXX")"
      set +e
      build_system_menu_cache "$system" "$scan_file" 3>&1 | ui_gauge "Scanning games" "Scanning $system..."
      scan_pipeline_status=("${PIPESTATUS[@]}")
      scan_rc=${scan_pipeline_status[0]:-1}
      gauge_rc=${scan_pipeline_status[1]:-1}
      set -e
      if ((scan_rc != 0 || gauge_rc != 0)); then
        rm -f -- "$scan_file"
        ui_msg "Scan error" "Could not scan games for $system. Check the log for details."
        return 0
      fi

      while IFS= read -r -d '' item && IFS= read -r -d '' loc && IFS= read -r -d '' size; do
        id=$((id+1))
        games[id]="$item"
        opts+=("$id" "$item | $loc | $size" "off")
      done < "$scan_file"
      rm -f -- "$scan_file"
      needs_refresh=0
    fi

    ((${#opts[@]})) || { ui_msg "ROM Splitter" "No items found in $system."; return; }
    local -a selected=()
    if ! selected_output="$(ui_checklist "$system" "Select one or more games" "${opts[@]}")"; then
      # B/Escape returns to the system list.
      return 0
    fi
    mapfile -t selected <<< "$selected_output"
    if [[ -z "$selected_output" || ${#selected[@]} -eq 0 ]]; then
      ui_msg "Selection required" "Select at least one game with X before pressing A."
      continue
    fi

    local selected_id first_loc="" total=0 member_count=0 group_size group_members_count
    for selected_id in "${selected[@]}"; do
      item="${games[selected_id]:-}"
      [[ -n "$item" ]] || continue
      rel="$system/$item"
      loc="$(game_group_location "$rel")"
      [[ -z "$first_loc" ]] && first_loc="$loc"
      if [[ "$loc" != "$first_loc" ]]; then
        ui_msg "Selection" "Select games from only one storage location at a time."
        continue 2
      fi
      group_size="$(game_group_size "$rel")"
      group_members_count="$(resolve_game_group "$rel" | wc -l)"
      total=$((total + group_size))
      member_count=$((member_count + group_members_count))
    done

    local destination move_action chosen_action
    case "$first_loc" in
      SD1) destination="SD2"; move_action="move_group_to_sd2" ;;
      SD2|SD2-unmounted) destination="SD1"; move_action="move_group_to_sd1" ;;
      *) ui_msg "Error" "Unsupported selection state: $first_loc"; continue ;;
    esac

    chosen_action="$(ui_menu "Game action" \
      "${#selected[@]} game(s) selected | $member_count file(s)/item(s) | $(human_size "$total")" \
      "move" "Move to $destination" \
      "delete" "Permanently delete")" || continue

    local action result_title
    case "$chosen_action" in
      move)
        action="$move_action"
        result_title="Move result"
        ui_yesno "Confirm move" "Move ${#selected[@]} game(s) to $destination?\n\nTotal: $(human_size "$total")" || continue
        ;;
      delete)
        action="delete_game_group"
        result_title="Delete result"
        ui_yesno "PERMANENT DELETE" \
          "Permanently delete ${#selected[@]} game(s)?\n\n$member_count file(s)/item(s)\nTotal: $(human_size "$total")\n\nThis cannot be undone." || continue
        ;;
      *) continue ;;
    esac

    local completed=0 failed=0
    for selected_id in "${selected[@]}"; do
      item="${games[selected_id]:-}"
      [[ -n "$item" ]] || continue
      if "$action" "$system/$item"; then completed=$((completed+1)); else failed=$((failed+1)); fi
    done
    ui_msg "$result_title" "Completed: $completed\nFailed: $failed\n\nSee the log for details."
    # A real storage mutation invalidates locations and item membership. Simple
    # navigation, empty selection and cancelled dialogs keep the current cache.
    needs_refresh=1
  done
}

manage_games() {
  mount_sd2 || { ui_msg "SD2" "No configured ROMS2 card was found."; return; }
  local sys
  while sys="$(choose_system)"; do
    manage_system "$sys"
  done
}

format_sd2_ui() {
  if [[ "${ROMS2_DEMO:-0}" == 1 ]]; then
    ui_msg "Demo mode" "Formatting is disabled in demo mode."
    return
  fi
  local opts=() dev size model chosen
  while IFS='|' read -r dev size model; do opts+=("$dev" "$size $model"); done < <(list_candidate_sd2_devices)
  ((${#opts[@]})) || { ui_msg "Prepare SD2" "No safe candidate device was detected."; return; }
  chosen="$(ui_menu "Prepare SD2" "Select the SECONDARY card. The selected device will be ERASED." "${opts[@]}")" || return
  ui_yesno "DANGER" "ALL DATA on $chosen will be erased.\n\nThe system disk and /roms disk are protected, but verify the device before continuing.\n\nFormat as exFAT and label ROMS2?" || return
  if prepare_sd2_device "$chosen"; then
    mount_sd2
    ui_msg "Prepare SD2" "Card prepared successfully as ROMS2."
  else
    ui_msg "Error" "Formatting failed. Check logs."
  fi
}

show_diagnostics() {
  mount_sd2 || true
  local text=""
  text+="ROMS mount: $(findmnt -n -o SOURCE,FSTYPE "$ROMS_ROOT" 2>/dev/null || echo missing)\n"
  text+="ROMS2 mount: $(findmnt -n -o SOURCE,FSTYPE "$ROMS2_ROOT" 2>/dev/null || echo not-mounted)\n"
  text+="Configured SD2: $(sd2_info)\n"
  text+="Manifest entries: $(manifest_list 2>/dev/null | wc -l)\n"
  text+="Controls: ${CONTROLS_BACKEND:-keyboard}\n"
  ui_msg "Diagnostics" "$text"
}

scan_sd2_for_new_games() {
  if import_new_sd2_items; then
    ui_msg "Scan SD2" "New items linked: $IMPORT_ADDED\nConflicts skipped: $IMPORT_CONFLICTS\nFailures: $IMPORT_FAILED\n\nNew games are now available under /roms."
  else
    ui_msg "Scan SD2" "New items linked: $IMPORT_ADDED\nConflicts skipped: $IMPORT_CONFLICTS\nFailures: $IMPORT_FAILED\n\nCheck the log for failed items."
  fi
}

main_menu() {
  while true; do
    local choice
    if ! choice="$(ui_menu "ROM Splitter" "ArkOS Dual Storage Manager" \
      "1" "Manage games" \
      "2" "Storage information" \
      "3" "Prepare/format SD2" \
      "4" "Repair/rebuild bind mounts" \
      "5" "Mount SD2" \
      "6" "Safely unmount SD2" \
      "7" "Diagnostics" \
      "8" "Scan SD2 for new games" \
      "0" "Exit")"; then
      # B/Escape at the root keeps the application open. Exit is explicit.
      continue
    fi

    case "$choice" in
      1) manage_games ;;
      2) show_storage_info ;;
      3) format_sd2_ui ;;
      4) repair_storage && ui_msg "Repair" "Bind mounts rebuilt." || ui_msg "Repair" "Repair failed. Check logs." ;;
      5) mount_sd2 && ui_msg "SD2" "Mounted at $ROMS2_ROOT." || ui_msg "SD2" "Mount failed." ;;
      6) unmount_sd2 && ui_msg "SD2" "Unmounted safely." || ui_msg "SD2" "Unmount failed." ;;
      7) show_diagnostics ;;
      8) scan_sd2_for_new_games ;;
      0) break ;;
    esac
  done
}
