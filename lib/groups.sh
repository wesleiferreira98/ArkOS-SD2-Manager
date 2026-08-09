#!/usr/bin/env bash
set -Eeuo pipefail

# A logical game is its selected entry plus every local file referenced by a
# CUE or M3U descriptor. Results are emitted as paths relative to /roms.

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
  local rel="$1" launcher_name candidate candidate_name match="" count=0
  [[ "$rel" == ports/*.sh && "$rel" != ports/*/*.sh ]] || return 0
  launcher_name="$(normalized_port_name "$rel")"
  [[ -n "$launcher_name" ]] || return 0

  while IFS= read -r candidate; do
    candidate_name="$(normalized_port_name "$candidate")"
    if [[ "$candidate_name" == "$launcher_name" ]]; then
      match="ports/$candidate"
      count=$((count+1))
    fi
  done < <(
    {
      [[ -d "$ROMS_ROOT/ports" ]] && find "$ROMS_ROOT/ports" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
      [[ -d "$ROMS2_ROOT/ports" ]] && find "$ROMS2_ROOT/ports" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
    } | sort -u
  )

  (( count <= 1 )) || { fail "Ambiguous PortMaster directory for $rel"; return 1; }
  [[ -n "$match" ]] && printf '%s\n' "$match"
  return 0
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
    done < <(resolve_game_group "$rel")
  done < <(list_items_for_system "$system")
  return 0
}

list_logical_games_for_system() {
  local system="$1" item
  local -A referenced=()
  while IFS= read -r item; do [[ -n "$item" ]] && referenced["$item"]=1; done < <(referenced_members_for_system "$system")
  while IFS= read -r item; do
    [[ -z "${referenced[$item]+x}" ]] && printf '%s\n' "$item"
  done < <(list_items_for_system "$system")
  return 0
}
