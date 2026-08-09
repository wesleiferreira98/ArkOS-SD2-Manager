#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROMS_DIR="${ROMS_ROOT:-/roms}"
TOOLS_DIR="$ROMS_DIR/tools"
TARGET="$TOOLS_DIR/ROM Splitter.sh"
SYSTEM_TARGET="/opt/system/Tools/ROM Splitter.sh"
SERVICE="/etc/systemd/system/roms2-manager.service"

chmod +x "$BASE_DIR/roms2-manager.sh" "$BASE_DIR/boot/roms2-mount.sh" "$BASE_DIR/install.sh"
find "$BASE_DIR/lib" -type f -name '*.sh' -exec chmod +x {} +

cat > /tmp/rom-splitter-launcher.sh <<EOF2
#!/usr/bin/env bash
set -uo pipefail
cd "$BASE_DIR"

# SSH and an interactive shell already provide a usable terminal.
if [[ -t 0 && -t 1 ]]; then
  export TERM="\${TERM:-linux}"
  exec "$BASE_DIR/roms2-manager.sh"
fi

# EmulationStation may launch custom Tools without a controlling TTY. Run the
# terminal UI on VT2, then switch back to the VT normally used by ES.
if command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
  sudo openvt -c 2 -s -f -w -- env TERM=linux "$BASE_DIR/roms2-manager.sh"
  rc=\$?
  sudo chvt 1 || true
  exit "\$rc"
fi

# Compatibility fallback for images without openvt/chvt.
export TERM=linux
exec "$BASE_DIR/roms2-manager.sh" </dev/tty1 >/dev/tty1 2>&1
EOF2
chmod +x /tmp/rom-splitter-launcher.sh
sudo mkdir -p "$TOOLS_DIR" /opt/system/Tools
sudo cp /tmp/rom-splitter-launcher.sh "$TARGET"
sudo cp /tmp/rom-splitter-launcher.sh "$SYSTEM_TARGET"

cat > /tmp/roms2-manager.service <<EOF2
[Unit]
Description=ROM Splitter SD2 bind mount restoration
After=local-fs.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=$BASE_DIR/boot/roms2-mount.sh
RemainAfterExit=no
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF2
sudo cp /tmp/roms2-manager.service "$SERVICE"
sudo systemctl daemon-reload
sudo systemctl enable roms2-manager.service

echo "Installed. ROM launcher: $TARGET"
echo "System launcher: $SYSTEM_TARGET"
echo "Boot service: roms2-manager.service"
