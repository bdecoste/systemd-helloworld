#!/usr/bin/env bash
# Installer for the systemd deployment. Suitable for EC2 user-data
# or hand-running on an Amazon Linux / Ubuntu VM.
set -euo pipefail

APP_USER=helloworld
APP_DIR=/opt/helloworld
ETC_DIR=/etc/helloworld
UNIT_DIR=/etc/systemd/system

# 1. Runtime (python3 is stdlib-only for this app)
if command -v dnf >/dev/null; then
  dnf install -y python3
elif command -v apt-get >/dev/null; then
  apt-get update && apt-get install -y python3
fi

# 2. Service account
id "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"

# 3. App + config
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR" "$ETC_DIR"
install -m 0755 -o "$APP_USER" -g "$APP_USER" "$(dirname "$0")/../app/helloworld.py" "$APP_DIR/helloworld.py"
install -m 0644 "$(dirname "$0")/helloworld.env" "$ETC_DIR/helloworld.env"

# 4. Unit
install -m 0644 "$(dirname "$0")/helloworld.service" "$UNIT_DIR/helloworld.service"

# 5. Start
systemctl daemon-reload
systemctl enable --now helloworld

systemctl --no-pager status helloworld
