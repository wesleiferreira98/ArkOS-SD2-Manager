#!/usr/bin/env bash
set -Eeuo pipefail

systems_from_es() {
  local cfg="/etc/emulationstation/es_systems.cfg"
  if [[ -r "$cfg" ]]; then
    awk -F'[<>]' '/<path>\/roms\// {gsub("/roms/","",$3); gsub("/","",$3); if($3!="" && $3!="tools") print $3}' "$cfg" | sort -u
  else
    find "$ROMS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name tools -printf '%f\n' | sort
  fi
}

item_location() {
  local rel="$1"
  if [[ "${ROMS2_DEMO:-0}" == 1 && -L "$ROMS_ROOT/$rel" ]]; then
    printf 'SD2\n'
  elif mountpoint -q "$ROMS_ROOT/$rel" 2>/dev/null; then
    printf 'SD2\n'
  elif manifest_contains "$rel"; then
    printf 'SD2-unmounted\n'
  elif [[ -e "$ROMS_ROOT/$rel" ]]; then
    printf 'SD1\n'
  elif [[ -e "$ROMS2_ROOT/$rel" ]]; then
    printf 'SD2-unmounted\n'
  else
    printf 'missing\n'
  fi
}

manifest_cache_file() {
  printf '%s/roms2-manifest.tsv\n' "$STATE_DIR"
}

validate_manifest_rel() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *$'\t'* && "$rel" != *$'\n'* ]] || return 1
  [[ "/$rel/" != *"/../"* && "/$rel/" != *"/./"* ]]
}

sync_manifest_cache() {
  local manifest="$ROMS2_ROOT/.roms2-manifest.tsv" cache
  cache="$(manifest_cache_file)"
  mkdir -p "$STATE_DIR"
  [[ -f "$manifest" ]] && cp -f -- "$manifest" "$cache"
}

manifest_contains() {
  local rel="$1" cache
  cache="$(manifest_cache_file)"
  [[ -f "$cache" ]] && awk -F '\t' -v r="$rel" '$1 == r { found=1; exit } END { exit !found }' "$cache"
}

list_items_for_system() {
  local system="$1" base="$ROMS_ROOT/$system"
  [[ -d "$base" ]] || return 0
  find "$base" -mindepth 1 -maxdepth 1 \
    ! -name 'gamelist.xml' ! -name 'gamelist.xml.old' \
    ! -name 'images' ! -name 'media' ! -name '*.backup' \
    ! -name '.*' \
    -printf '%f\n' | sort -f
}

is_auxiliary_file() {
  local name="${1,,}"
  [[ "$name" == "gamelist.xml" || "$name" == "gamelist.xml.old" || "$name" == "images" || "$name" == "media" ]]
}

manifest_add() {
  local rel="$1" kind="$2" manifest="$ROMS2_ROOT/.roms2-manifest.tsv"
  validate_manifest_rel "$rel" || fail "Unsupported item name for manifest: $rel"
  touch "$manifest"
  grep -Fqx "$rel"$'\t'"$kind" "$manifest" 2>/dev/null || printf '%s\t%s\n' "$rel" "$kind" >> "$manifest"
  sync_manifest_cache
}

manifest_remove() {
  local rel="$1" manifest="$ROMS2_ROOT/.roms2-manifest.tsv"
  [[ -f "$manifest" ]] || return 0
  awk -F '\t' -v r="$rel" '$1 != r' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  sync_manifest_cache
}

manifest_list() {
  local manifest="$ROMS2_ROOT/.roms2-manifest.tsv" cache
  cache="$(manifest_cache_file)"
  if [[ -f "$manifest" ]]; then cat "$manifest"; elif [[ -f "$cache" ]]; then cat "$cache"; fi
}

discover_unmanaged_sd2_items() {
  local system_dir item rel
  [[ -d "$ROMS2_ROOT" ]] || return 0

  while IFS= read -r -d '' system_dir; do
    [[ "$(basename "$system_dir")" != tools ]] || continue
    while IFS= read -r -d '' item; do
      rel="${item#"$ROMS2_ROOT/"}"
      validate_manifest_rel "$rel" || { log "Skipped unsupported SD2 path: $rel"; continue; }
      is_auxiliary_file "$(basename "$item")" && continue
      manifest_contains "$rel" || printf '%s\0' "$rel"
    done < <(find "$system_dir" -mindepth 1 -maxdepth 1 ! -name '.*' -print0)
  done < <(find "$ROMS2_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
}
