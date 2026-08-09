#!/usr/bin/env bash
set -Eeuo pipefail

# A logical game is its selected entry plus every local file referenced by a
# CUE or M3U descriptor. Results are emitted as paths relative to /roms.

declare -A SYSTEM_ITEM_SIZE_CACHE=()
declare -A SYSTEM_ITEM_LOCATION_CACHE=()
declare -a PORT_DIRECTORY_CACHE=()
CACHED_SYSTEM=""

prepare_port_directory_cache() {
  mapfile -t PORT_DIRECTORY_CACHE < <(
    {
      [[ -d "$ROMS_ROOT/ports" ]] && find "$ROMS_ROOT/ports" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
      [[ -d "$ROMS2_ROOT/ports" ]] && find "$ROMS2_ROOT/ports" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
    } | sort -u
  )
}

prepare_system_inventory_cache() {
  local system="$1" name size type rel source_path
  local -A managed=()
  SYSTEM_ITEM_SIZE_CACHE=()
  SYSTEM_ITEM_LOCATION_CACHE=()
  CACHED_SYSTEM="$system"
  [[ "$system" == ports ]] && prepare_port_directory_cache

  while IFS=$'\t' read -r rel _; do
    [[ "$rel" == "$system/"* ]] || continue
    name="${rel#"$system/"}"
    [[ "$name" != */* ]] && managed["$name"]=1
  done < <(manifest_list)

  [[ -d "$ROMS_ROOT/$system" ]] || return 0
  while IFS=$'\t' read -r name size type; do
    [[ -n "$name" ]] || continue
    rel="$system/$name"
    source_path="$ROMS_ROOT/$rel"

    if [[ -n "${managed[$name]+x}" ]]; then
      if [[ -e "$ROMS2_ROOT/$rel" ]]; then
        SYSTEM_ITEM_LOCATION_CACHE["$name"]="SD2"
        source_path="$ROMS2_ROOT/$rel"
      else
        SYSTEM_ITEM_LOCATION_CACHE["$name"]="SD2-unmounted"
      fi
    else
      SYSTEM_ITEM_LOCATION_CACHE["$name"]="SD1"
    fi

    if [[ "$type" == d || -d "$source_path" ]]; then
      if [[ "$system" == ports ]]; then
        # Port directories can contain thousands of files. Their exact size is
        # calculated only after selection, not while opening the list.
        size=0
      else
        size="$(file_size_bytes "$source_path" 2>/dev/null || printf 0)"
      fi
    elif [[ "$source_path" == "$ROMS2_ROOT/"* && -f "$source_path" ]]; then
      size="$(stat -c '%s' -- "$source_path" 2>/dev/null || printf '%s' "$size")"
    fi
    SYSTEM_ITEM_SIZE_CACHE["$name"]="${size:-0}"
  done < <(find "$ROMS_ROOT/$system" -mindepth 1 -maxdepth 1 \
    ! -name 'gamelist.xml' ! -name 'gamelist.xml.old' \
    ! -name 'images' ! -name 'media' ! -name '*.backup' ! -name '.*' \
    -printf '%f\t%s\t%y\n')
}

cached_group_size() {
  local primary="$1" rel name total=0 path
  [[ "${primary%%/*}" == "$CACHED_SYSTEM" ]] || prepare_system_inventory_cache "${primary%%/*}"
  while IFS= read -r rel; do
    name="${rel#*/}"
    if [[ -n "${SYSTEM_ITEM_SIZE_CACHE[$name]+x}" ]]; then
      total=$((total + SYSTEM_ITEM_SIZE_CACHE[$name]))
    else
      path="$(game_existing_path "$rel")" || return 1
      total=$((total + $(file_size_bytes "$path")))
    fi
  done < <(resolve_game_group "$primary")
  printf '%s\n' "$total"
}

cached_group_location() {
  local primary="$1" rel name loc first=""
  [[ "${primary%%/*}" == "$CACHED_SYSTEM" ]] || prepare_system_inventory_cache "${primary%%/*}"
  while IFS= read -r rel; do
    name="${rel#*/}"
    loc="${SYSTEM_ITEM_LOCATION_CACHE[$name]:-missing}"
    [[ -z "$first" ]] && first="$loc"
    [[ "$loc" == "$first" ]] || { printf 'mixed\n'; return; }
  done < <(resolve_game_group "$primary")
  printf '%s\n' "${first:-missing}"
}

game_existing_path() {
  local rel="$1"
  if [[ -e "$ROMS_ROOT/$rel" ]]; then
    printf '%s\n' "$ROMS_ROOT/$rel"
  elif [[ -e "$ROMS2_ROOT/$rel" ]]; then
    printf '%s\n' "$ROMS2_ROOT/$rel"
  else
    return 1
  fi
}

normalized_port_name() {
  local name="${1##*/}"
  name="${name%.sh}"
  printf '%s' "${name,,}" | tr -cd '[:alnum:]'
}

port_companion_directory() {
  local rel="$1" launcher_name candidate candidate_name match="" count=0 launcher_path launcher_lines
  [[ "$rel" == ports/*.sh && "$rel" != ports/*/*.sh ]] || return 0
  launcher_name="$(normalized_port_name "$rel")"
  [[ -n "$launcher_name" ]] || return 0

  ((${#PORT_DIRECTORY_CACHE[@]})) || prepare_port_directory_cache
  for candidate in "${PORT_DIRECTORY_CACHE[@]}"; do
    candidate_name="$(normalized_port_name "$candidate")"
    if [[ "$candidate_name" == "$launcher_name" ]]; then
      match="ports/$candidate"
      count=$((count+1))
    fi
  done

  if (( count == 1 )); then
    printf '%s\n' "$match"
    return 0
  fi

  # Some PortMaster launchers and data directories intentionally use different
  # names. Inspect only path-related assignment/cd lines; never source or run
  # an untrusted launcher.
  launcher_path="$(game_existing_path "$rel")" || return 1
  launcher_lines="$(port_launcher_path_lines "$launcher_path")"
  match=""
  count=0
  for candidate in "${PORT_DIRECTORY_CACHE[@]}"; do
    if launcher_lines_reference_directory "$launcher_lines" "$candidate"; then
      match="ports/$candidate"
      count=$((count+1))
    fi
  done

  (( count <= 1 )) || { fail "Ambiguous directory references inside $rel"; return 1; }
  [[ -n "$match" ]] && printf '%s\n' "$match"
  return 0
}

port_launcher_path_lines() {
  local launcher="$1"
  awk '
    /^[[:space:]]*#/ { next }
    /(^|[[:space:]])cd[[:space:]]/ ||
    /GAMEDIR|GAME_DIR|PORTDIR|PORT_DIR|BASEDIR|BASE_DIR|INSTALLDIR|INSTALL_DIR/ { print }
  ' "$launcher"
}

launcher_lines_reference_directory() {
  local launcher_lines="$1" directory="$2" line
  while IFS= read -r line; do
    case "$line" in
      *"/$directory/"*|*"/$directory\""*|*"/$directory'"*|*"/$directory "*|*"/$directory") return 0 ;;
    esac
  done <<< "$launcher_lines"
  return 1
}

normalize_game_reference() {
  local owner_rel="$1" reference="$2" system candidate system_root
  reference="${reference%$'\r'}"
  [[ -n "$reference" && "$reference" != /* && "$reference" != *$'\t'* && "$reference" != *$'\n'* ]] || return 1
  system="${owner_rel%%/*}"
  # Use lexical normalization here: an existing demo/bind symlink legitimately
  # resolves into /roms2 and must still retain its logical /roms path.
  system_root="$(realpath -ms -- "$ROMS_ROOT/$system")"
  candidate="$(realpath -ms -- "$ROMS_ROOT/$(dirname "$owner_rel")/$reference")"
  [[ "$candidate" == "$system_root" || "$candidate" == "$system_root"/* ]] || return 1
  printf '%s\n' "${candidate#"$ROMS_ROOT/"}"
}

descriptor_references() {
  local rel="$1" path line ref lower
  path="$(game_existing_path "$rel")" || return 1
  lower="${rel,,}"

  if [[ "$lower" == *.m3u ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -n "$line" && "$line" != \#* ]] || continue
      normalize_game_reference "$rel" "$line" || { fail "Invalid M3U reference in $rel: $line"; return 1; }
    done < "$path"
  elif [[ "$lower" == *.cue ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*[Ff][Ii][Ll][Ee][[:space:]]+\"([^\"]+)\" ]] && ref="${BASH_REMATCH[1]}" || {
        [[ "$line" =~ ^[[:space:]]*[Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]] || continue
        ref="${BASH_REMATCH[1]}"
      }
      normalize_game_reference "$rel" "$ref" || { fail "Invalid CUE reference in $rel: $ref"; return 1; }
    done < "$path"
  elif [[ "$rel" == ports/*.sh && "$rel" != ports/*/*.sh ]]; then
    port_companion_directory "$rel"
  fi
  return 0
}

resolve_game_group() {
  local primary="$1" current ref references
  local -a queue=("$primary")
  local -A seen=()
  validate_manifest_rel "$primary" || { fail "Invalid game path: $primary"; return 1; }

  while ((${#queue[@]})); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -z "${seen[$current]+x}" ]] || continue
    game_existing_path "$current" >/dev/null || { fail "Referenced game file is missing: $current"; return 1; }
    seen["$current"]=1
    printf '%s\n' "$current"
    references="$(descriptor_references "$current")" || return 1
    while IFS= read -r ref; do
      [[ -n "$ref" && -z "${seen[$ref]+x}" ]] && queue+=("$ref")
    done <<< "$references"
  done
  return 0
}

game_group_size() {
  local primary="$1" rel path total=0
  while IFS= read -r rel; do
    path="$(game_existing_path "$rel")" || return 1
    total=$((total + $(file_size_bytes "$path")))
  done < <(resolve_game_group "$primary")
  printf '%s\n' "$total"
}

game_group_location() {
  local primary="$1" rel loc first=""
  while IFS= read -r rel; do
    loc="$(item_location "$rel")"
    [[ -z "$first" ]] && first="$loc"
    [[ "$loc" == "$first" ]] || { printf 'mixed\n'; return; }
  done < <(resolve_game_group "$primary")
  printf '%s\n' "${first:-missing}"
}

referenced_members_for_system() {
  local system="$1" item rel member
  while IFS= read -r item; do
    rel="$system/$item"
    case "${item,,}" in
      *.cue|*.m3u) ;;
      *.sh) [[ "$system" == ports ]] || continue ;;
      *) continue ;;
    esac
    while IFS= read -r member; do
      [[ "$member" != "$rel" ]] && printf '%s\n' "${member#"$system/"}"
    done < <(resolve_game_group "$rel" 2>/dev/null)
  done < <(list_items_for_system "$system")
  return 0
}

inventory_progress() {
  local fd="${1:-}" percentage="$2" message="$3"
  [[ -n "$fd" ]] || return 0
  printf 'XXX\n%s\n%s\nXXX\n' "$percentage" "$message" >&"$fd"
}

list_logical_games_for_system() {
  local system="$1" progress_fd="${2:-}" item rel member index=0 total
  local -A referenced=()
  local -a items=()
  mapfile -t items < <(list_items_for_system "$system")
  total=${#items[@]}

  for item in "${items[@]}"; do
    index=$((index+1))
    inventory_progress "$progress_fd" $((10 + index * 45 / (total > 0 ? total : 1))) \
      "Resolving game groups: $index/$total"
    rel="$system/$item"
    case "${item,,}" in
      *.cue|*.m3u) ;;
      *.sh) [[ "$system" == ports ]] || continue ;;
      *) continue ;;
    esac
    while IFS= read -r member; do
      [[ "$member" != "$rel" ]] && referenced["${member#"$system/"}"]=1
    done < <(resolve_game_group "$rel" 2>/dev/null)
  done

  for item in "${items[@]}"; do
    [[ -z "${referenced[$item]+x}" ]] && printf '%s\n' "$item"
  done
  return 0
}
