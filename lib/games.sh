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

card_profiles_dir() {
  printf '%s/cards\n' "$STATE_DIR"
}

safe_card_id() {
  local card_id="$1"
  printf '%s' "$card_id" | tr -cd '[:alnum:]._-'
}

card_profile_manifest() {
  local card_id
  card_id="$(safe_card_id "$1")"
  [[ -n "$card_id" ]] || return 1
  printf '%s/%s.manifest.tsv\n' "$(card_profiles_dir)" "$card_id"
}

active_card_file() {
  printf '%s/active-card\n' "$STATE_DIR"
}

active_binds_file() {
  printf '%s/active-binds.tsv\n' "$STATE_DIR"
}

active_card_id() {
  local file
  file="$(active_card_file)"
  [[ -s "$file" ]] && head -n1 "$file"
}

known_card_profiles_count() {
  local profiles
  profiles="$(card_profiles_dir)"
  [[ -d "$profiles" ]] || { printf '0\n'; return; }
  find "$profiles" -maxdepth 1 -type f -name '*.manifest.tsv' -printf . | wc -c
}

set_active_card_id() {
  local card_id="$1" file
  file="$(active_card_file)"
  mkdir -p "$STATE_DIR" "$(card_profiles_dir)"
  printf '%s\n' "$card_id" > "$file"
}

clear_active_card_id() {
  rm -f -- "$(active_card_file)"
}

active_bind_add() {
  local card_id="$1" rel="$2" kind="$3" registry
  registry="$(active_binds_file)"
  validate_manifest_rel "$rel" || return 1
  mkdir -p "$STATE_DIR"
  touch "$registry"
  awk -F '\t' -v r="$rel" '$2 != r' "$registry" > "$registry.tmp"
  printf '%s\t%s\t%s\n' "$card_id" "$rel" "$kind" >> "$registry.tmp"
  mv "$registry.tmp" "$registry"
}

active_bind_remove() {
  local rel="$1" registry
  registry="$(active_binds_file)"
  [[ -f "$registry" ]] || return 0
  awk -F '\t' -v r="$rel" '$2 != r' "$registry" > "$registry.tmp"
  mv "$registry.tmp" "$registry"
}

active_bind_contains() {
  local rel="$1" registry
  registry="$(active_binds_file)"
  [[ -f "$registry" ]] && awk -F '\t' -v r="$rel" '$2 == r { found=1; exit } END { exit !found }' "$registry"
}

validate_manifest_rel() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *$'\t'* && "$rel" != *$'\n'* ]] || return 1
  [[ "/$rel/" != *"/../"* && "/$rel/" != *"/./"* ]]
}

sync_manifest_cache() {
  local manifest="$ROMS2_ROOT/.roms2-manifest.tsv" cache card_id profile
  cache="$(manifest_cache_file)"
  mkdir -p "$STATE_DIR" "$(card_profiles_dir)"
  if [[ -f "$manifest" ]]; then
    cp -f -- "$manifest" "$cache"
    card_id="$(active_card_id || true)"
    if [[ -n "$card_id" ]]; then
      profile="$(card_profile_manifest "$card_id")"
      cp -f -- "$manifest" "$profile"
    fi
  fi
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
  active_bind_remove "$rel"
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
