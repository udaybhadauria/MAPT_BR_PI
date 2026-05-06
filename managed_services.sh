#!/bin/bash
set -e

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
VENV="$BASE_DIR/ui_venv"

APP_PY="$BASE_DIR/mqtt_agent.py"
WATCHDOG_SH="$BASE_DIR/watchdog_routers.sh"

APP_SERVICE="/etc/systemd/system/mqtt-agent.service"
WATCHDOG_SERVICE="/etc/systemd/system/watchdog-routers.service"

PYTHON="$VENV/bin/python"
PIP="$VENV/bin/pip"

echo "🔍 Validating environment..."

# -----------------------------
# Sanity checks
# -----------------------------
if [[ ! -d "$VENV" ]]; then
  echo "❌ ERROR: Virtualenv not found: $VENV"
  exit 1
fi

if [[ ! -x "$PYTHON" ]]; then
  echo "❌ ERROR: Python not found in venv: $PYTHON"
  exit 1
fi

if [[ ! -f "$APP_PY" ]]; then
  echo "❌ ERROR: mqtt_agent.py not found at $APP_PY"
  exit 1
fi

if [[ ! -f "$WATCHDOG_SH" ]]; then
  echo "❌ ERROR: watchdog_routers.sh not found"
  exit 1
fi

chmod +x "$WATCHDOG_SH"

# -----------------------------
# Ensure Python dependencies are installed
# -----------------------------
echo "📦 Checking MQTT/Flask dependencies..."
if ! "$PYTHON" -c "import paho.mqtt.client, flask" 2>/dev/null; then
  echo "⚠️ Dependencies missing in ui_venv — installing..."
  "$PIP" install paho-mqtt flask
else
  echo "✅ Dependencies already installed in ui_venv"
fi

# -----------------------------
# Create mqtt-agent systemd service
# -----------------------------
if [[ ! -f "$APP_SERVICE" ]]; then
  echo "🛠 Creating mqtt-agent.service..."

  cat > "$APP_SERVICE" <<EOF
[Unit]
Description=BR PI MQTT Agent (Python)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$PYTHON $APP_PY
Restart=always
RestartSec=5

StandardOutput=journal
StandardError=journal

KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
else
  echo "✅ mqtt-agent.service already exists"
fi

# -----------------------------
# Create watchdog systemd service
# -----------------------------
if [[ ! -f "$WATCHDOG_SERVICE" ]]; then
  echo "🛠 Creating watchdog-routers.service..."

  cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=BR PI Watchdog (continuous)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG_SH
Restart=always
RestartSec=5

StandardOutput=journal
StandardError=journal

KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
else
  echo "✅ watchdog-routers.service already exists"
fi

# -----------------------------
# Reload & manage services
# -----------------------------
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reload

echo "✅ Enabling services..."
systemctl enable mqtt-agent.service watchdog-routers.service

echo "🚀 Restarting services..."
systemctl restart mqtt-agent.service watchdog-routers.service

# -----------------------------
# Status summary
# -----------------------------
echo
echo "📊 Service status:"
systemctl --no-pager --full status mqtt-agent.service watchdog-routers.service

