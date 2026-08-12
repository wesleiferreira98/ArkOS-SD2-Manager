#!/usr/bin/env bash
set -Eeuo pipefail

UI_BIN=""
if command -v dialog >/dev/null 2>&1; then UI_BIN="dialog"; elif command -v whiptail >/dev/null 2>&1; then UI_BIN="whiptail"; fi

UI_HEIGHT=10
UI_WIDTH=60

ui_size_for_text() {
  local text="$1" extra_rows="${2:-5}" min_height="${3:-8}" max_height="${4:-20}"
  local content_width=52 lines=0 line length
  while IFS= read -r line || [[ -n "$line" ]]; do
    length=${#line}
    lines=$((lines + (length > 0 ? (length + content_width - 1) / content_width : 1)))
  done <<< "$text"
  UI_HEIGHT=$((lines + extra_rows))
  ((UI_HEIGHT < min_height)) && UI_HEIGHT=$min_height
  ((UI_HEIGHT > max_height)) && UI_HEIGHT=$max_height
  UI_WIDTH=60
  ((lines > 8)) && UI_WIDTH=68
  # Arithmetic tests return 1 when false; never leak that status to callers
  # because the application runs with set -e.
  return 0
}

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
    local display_text
    display_text="$(ui_prompt_with_controls "$text")"
    ui_size_for_text "$display_text" 4 8 18
    "$UI_BIN" --title "$title" --msgbox "$display_text" "$UI_HEIGHT" "$UI_WIDTH" || true
  else
    printf '\n[%s]\n%s\n' "$title" "$text"
  fi
}

ui_infobox() {
  local title="$1" text="$2"
  if [[ -n "$UI_BIN" ]]; then
    ui_size_for_text "$text" 3 6 12
    "$UI_BIN" --title "$title" --infobox "$text" "$UI_HEIGHT" "$UI_WIDTH" || true
  else
    printf '\n[%s]\n%s\n' "$title" "$text"
  fi
}

ui_yesno() {
  local title="$1" text="$2"
  if [[ -n "$UI_BIN" ]]; then
    local display_text
    display_text="$(ui_prompt_with_controls "$text")"
    ui_size_for_text "$display_text" 5 9 20
    "$UI_BIN" --title "$title" --yesno "$display_text" "$UI_HEIGHT" "$UI_WIDTH"
  else
    read -r -p "$text [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
  fi
}

ui_menu() {
  local title="$1" prompt="$2"; shift 2
  if [[ -n "$UI_BIN" ]]; then
    local item_count=$(( $# / 2 )) menu_height height width menu_prompt
    menu_height=$item_count
    ((menu_height > 12)) && menu_height=12
    # Menus do not use X/checklist controls, so keep their help on one compact
    # line and reserve the detailed help text for checklist screens.
    menu_prompt="$prompt\n\nD-Pad: Navigate | A: Confirm | B: Back"
    height=$((menu_height + 7))
    ((height < 9)) && height=9
    ((height > 22)) && height=22
    width=72
    ((item_count <= 4)) && width=60
    "$UI_BIN" --clear --title "$title" --menu "$menu_prompt" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
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
    local item_count=$(( $# / 3 )) list_height height
    list_height=$item_count
    ((list_height < 3)) && list_height=3
    ((list_height > 12)) && list_height=12
    height=$((list_height + 9))
    ((height > 22)) && height=22
    "$UI_BIN" --separate-output --title "$title" --checklist "$(ui_prompt_with_controls "$prompt")" "$height" 72 "$list_height" "$@" 3>&1 1>&2 2>&3
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
    "$UI_BIN" --title "$title" --gauge "$prompt" 9 68 0
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
  local storage_filter="${1:-}" supplied_systems="${2:-}" opts=() s prompt="Choose a system"
  [[ -n "$storage_filter" ]] && prompt="Choose a system on $storage_filter"
  if [[ -n "$storage_filter" ]]; then
    if [[ -n "$supplied_systems" ]]; then
      while read -r s; do [[ -n "$s" ]] && opts+=("$s" "$s"); done <<< "$supplied_systems"
    else
      while read -r s; do [[ -n "$s" ]] && opts+=("$s" "$s"); done < <(systems_for_storage "$storage_filter")
    fi
  else
    while read -r s; do [[ -n "$s" ]] && opts+=("$s" "$s"); done < <(systems_from_es)
  fi
  ((${#opts[@]})) || return 1
  ui_menu "ROM Splitter" "$prompt" "${opts[@]}"
}

choose_storage() {
  ui_menu "Browse by storage" "Choose which card to view" \
    "SD1" "Primary ROM storage" \
    "SD2" "Secondary ROM storage"
}

location_matches_storage() {
  local location="$1" storage="$2"
  case "$storage:$location" in
    SD1:SD1|SD2:SD2|SD2:SD2-unmounted) return 0 ;;
    *) return 1 ;;
  esac
}

manage_system() {
  local system="$1" storage_filter="${2:-}" item loc size rel id selected_output scan_file scan_rc gauge_rc needs_refresh=1
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
        if [[ -n "$storage_filter" ]] && ! location_matches_storage "$loc" "$storage_filter"; then
          continue
        fi
        id=$((id+1))
        games[id]="$item"
        opts+=("$id" "$item | $loc | $size" "off")
      done < "$scan_file"
      rm -f -- "$scan_file"
      needs_refresh=0
    fi

    ((${#opts[@]})) || {
      ui_msg "ROM Splitter" "No items found in $system${storage_filter:+ on $storage_filter}."
      return
    }
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

manage_games_by_storage() {
  local storage sys available_systems systems_file scan_rc gauge_rc
  local -a pipeline_status
  while storage="$(choose_storage)"; do
    if [[ "$storage" == SD2 ]] && ! mount_sd2; then
      ui_msg "SD2" "No configured ROMS2 card was found."
      continue
    fi

    while true; do
      systems_file="$(mktemp "$STATE_DIR/storage-systems.XXXXXX")"
      set +e
      # Duplicate the pipeline into fd 3 first, then redirect normal output to
      # the cache file. Reversing this order mixes gauge protocol into systems.
      systems_for_storage "$storage" 3 3>&1 > "$systems_file" | \
        ui_gauge "Scanning $storage" "Looking for systems with games..."
      pipeline_status=("${PIPESTATUS[@]}")
      scan_rc=${pipeline_status[0]:-1}
      gauge_rc=${pipeline_status[1]:-1}
      set -e
      available_systems="$(<"$systems_file")"
      rm -f -- "$systems_file"

      if ((scan_rc != 0 || gauge_rc != 0)); then
        ui_msg "Browse by storage" "Could not scan systems on $storage. Check the log."
        break
      fi
      if [[ -z "$available_systems" ]]; then
        ui_msg "Browse by storage" "No managed games were found on $storage."
        break
      fi
      sys="$(choose_system "$storage" "$available_systems")" || break
      manage_system "$sys" "$storage"
    done
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
  text+="Active card profile: $(active_card_id 2>/dev/null || echo none)\n"
  text+="Known card profiles: $(known_card_profiles_count)\n"
  text+="Manifest entries: $(manifest_list 2>/dev/null | wc -l)\n"
  text+="Controls: ${CONTROLS_BACKEND:-keyboard}\n"
  ui_msg "Diagnostics" "$text"
}

scan_sd2_for_new_games() {
  local status_file import_rc gauge_rc total=0
  local -a pipeline_status
  status_file="$(mktemp "$STATE_DIR/sd2-scan-status.XXXXXX")"

  set +e
  import_new_sd2_items 3 "$status_file" 3>&1 | ui_gauge "Scanning SD2" "Looking for new games..."
  pipeline_status=("${PIPESTATUS[@]}")
  import_rc=${pipeline_status[0]:-1}
  gauge_rc=${pipeline_status[1]:-1}
  set -e

  if [[ -s "$status_file" ]]; then
    IFS=$'\t' read -r IMPORT_ADDED IMPORT_CONFLICTS IMPORT_FAILED total < "$status_file"
  fi
  rm -f -- "$status_file"

  if ((import_rc == 0 && gauge_rc == 0)); then
    ui_msg "Scan SD2" "New items linked: $IMPORT_ADDED\nConflicts skipped: $IMPORT_CONFLICTS\nFailures: $IMPORT_FAILED\n\nNew games are now available under /roms."
  else
    ui_msg "Scan SD2" "New items linked: $IMPORT_ADDED\nConflicts skipped: $IMPORT_CONFLICTS\nFailures: $IMPORT_FAILED\n\nCheck the log for failed items."
  fi
  return 0
}

switch_sd2_ui() {
  local old_card new_card
  old_card="$(active_card_id || true)"

  if findmnt -rn "$ROMS2_ROOT" >/dev/null 2>&1 || [[ -n "$old_card" ]]; then
    if ! unmount_sd2; then
      ui_msg "Switch SD2" "The current card could not be safely deactivated. Check the log and do not remove it."
      return 1
    fi
  fi

  ui_yesno "Switch SD2" \
    "The previous SD2 is safely deactivated.\n\nRemove it, insert the desired ROMS2 card, then choose Yes to activate its profile.\n\nChoose No to leave SD2 disconnected." || return 0

  ui_infobox "Switch SD2" "Detecting the inserted card and rebuilding its game links..."
  if activate_inserted_sd2; then
    new_card="$(active_card_id || true)"
    ui_msg "Switch SD2" \
      "Active card: ${new_card:-unknown}\nLinks created: $SWITCH_BOUND\nConflicts skipped: $SWITCH_CONFLICTS\nMissing items: $SWITCH_MISSING"
  else
    ui_msg "Switch SD2" "The inserted ROMS2 card could not be activated. No SD1 game was overwritten. Check the log."
    return 1
  fi
}

main_menu() {
  while true; do
    local choice
    if ! choice="$(ui_menu "ROM Splitter" "ArkOS Dual Storage Manager" \
      "1" "Manage games" \
      "2" "Manage games by storage" \
      "3" "Storage information" \
      "4" "Prepare/format SD2" \
      "5" "Repair/rebuild bind mounts" \
      "6" "Activate/switch SD2 card" \
      "7" "Safely unmount SD2" \
      "8" "Diagnostics" \
      "9" "Scan SD2 for new games" \
      "0" "Exit")"; then
      # B/Escape at the root keeps the application open. Exit is explicit.
      continue
    fi

    case "$choice" in
      1) manage_games ;;
      2) manage_games_by_storage ;;
      3) show_storage_info ;;
      4) format_sd2_ui ;;
      5) repair_storage && ui_msg "Repair" "Bind mounts rebuilt." || ui_msg "Repair" "Repair failed. Check logs." ;;
      6) switch_sd2_ui ;;
      7) unmount_sd2 && ui_msg "SD2" "Unmounted safely." || ui_msg "SD2" "Unmount failed." ;;
      8) show_diagnostics ;;
      9) scan_sd2_for_new_games ;;
      0) break ;;
    esac
  done
}
