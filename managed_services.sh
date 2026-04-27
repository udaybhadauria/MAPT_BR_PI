#!/bin/bash
set -e

BASE_DIR="/root/NAT_PI_2"
VENV="$BASE_DIR/ui_venv"

APP_PY="$BASE_DIR/app.py"
WATCHDOG_SH="$BASE_DIR/watchdog_routers.sh"

APP_SERVICE="/etc/systemd/system/app-mqtt.service"
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
  echo "❌ ERROR: mqtt_agent.py not found"
  exit 1
fi

if [[ ! -f "$WATCHDOG_SH" ]]; then
  echo "❌ ERROR: watchdog_routers.sh not found"
  exit 1
fi

chmod +x "$WATCHDOG_SH"

# -----------------------------
# Ensure Flask is installed
# -----------------------------
echo "📦 Checking Flask dependency..."
if ! "$PYTHON" -c "import flask" 2>/dev/null; then
  echo "⚠️ Flask not found in ui_venv — installing..."
  "$PIP" install flask
else
  echo "✅ Flask already installed in ui_venv"
fi

# -----------------------------
# Create app.py systemd service
# -----------------------------
if [[ ! -f "$APP_SERVICE" ]]; then
  echo "🛠 Creating app-mqtt.service..."

  cat > "$APP_SERVICE" <<EOF
[Unit]
Description=PI Python Application (Flask)
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
  echo "✅ app-mqtt.service already exists"
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
systemctl enable app-pi.service watchdog-routers.service

echo "🚀 Restarting services..."
systemctl restart app-pi.service watchdog-routers.service

# -----------------------------
# Status summary
# -----------------------------
echo
echo "📊 Service status:"
systemctl --no-pager --full status mqtt-pi.service watchdog-routers.service

