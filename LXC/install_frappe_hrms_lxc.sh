#!/usr/bin/env bash
set -euo pipefail

#################################################
# CONFIGURATION (CHANGE THESE)
#################################################
FRAPPE_USER="frappe"
FRAPPE_HOME="/home/frappe"
BENCH_DIR="$FRAPPE_HOME/frappe-bench"

SITE_NAME="hrms.anthenagroup.com"
ADMIN_PASSWORD="Admin@123"

DB_HOST="192.168.0.162"          
DB_ROOT_PASSWORD="P00sw00rd!!!!"

FRAPPE_BRANCH="version-15"
NODE_VERSION="18"

LOG_FILE="/var/log/frappe-hrms-install.log"

#################################################
# LOGGING
#################################################
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo " Frappe HRMS LXC Installation Started"
echo " Time: $(date)"
echo "========================================"

#################################################
# ROOT CHECK
#################################################
if [[ $EUID -ne 0 ]]; then
  echo "❌ ERROR: Run this script as root"
  exit 1
fi

#################################################
# BASE SYSTEM
#################################################
apt update
apt upgrade -y

apt install -y \
  sudo curl git ca-certificates gnupg \
  build-essential software-properties-common \
  nginx supervisor redis-server \
  mariadb-client \
  xvfb wkhtmltopdf \
  libmysqlclient-dev \
  libjpeg-dev zlib1g-dev \
  libffi-dev libssl-dev

#################################################
# PYTHON 3.11 (OFFICIAL METHOD)
#################################################
add-apt-repository -y ppa:deadsnakes/ppa
apt update

apt install -y \
  python3.11 \
  python3.11-dev \
  python3.11-venv \
  python3-pip

#################################################
# NODE.JS 18
#################################################
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt install -y nodejs
npm install -g yarn

#################################################
# CREATE FRAPPE USER (IDEMPOTENT)
#################################################
if ! id "$FRAPPE_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$FRAPPE_USER"
  usermod -aG sudo "$FRAPPE_USER"
fi

#################################################
# FIX PERMISSIONS
#################################################
mkdir -p "$FRAPPE_HOME"
chown -R "$FRAPPE_USER:$FRAPPE_USER" "$FRAPPE_HOME"

#################################################
# INSTALL BENCH AS FRAPPE USER
#################################################
sudo -u "$FRAPPE_USER" bash <<EOF
set -e

python3.11 -m pip install --upgrade pip setuptools wheel
pip install frappe-bench

if [ ! -d "$BENCH_DIR" ]; then
  bench init "$BENCH_DIR" \
    --frappe-branch "$FRAPPE_BRANCH" \
    --python python3.11
fi

cd "$BENCH_DIR"

bench get-app erpnext --branch "$FRAPPE_BRANCH" || true
bench get-app hrms --branch "$FRAPPE_BRANCH" || true

if [ ! -d "sites/$SITE_NAME" ]; then
  bench new-site "$SITE_NAME" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --db-host "$DB_HOST"
fi

bench --site "$SITE_NAME" install-app erpnext || true
bench --site "$SITE_NAME" install-app hrms || true
EOF

#################################################
# PRODUCTION SETUP (CRITICAL ORDER)
#################################################
bench setup production "$FRAPPE_USER"

#################################################
# START & VERIFY SERVICES
#################################################
systemctl restart redis-server
systemctl restart nginx
supervisorctl reread
supervisorctl update
supervisorctl restart all

#################################################
# FINAL OUTPUT
#################################################
echo "========================================"
echo " ✅ Frappe HRMS Installation COMPLETE"
echo "----------------------------------------"
echo " URL:        http://<LXC-IP>"
echo " Site:       $SITE_NAME"
echo " Username:   Administrator"
echo " Password:   $ADMIN_PASSWORD"
echo "----------------------------------------"
echo " Logs: $LOG_FILE"
echo "========================================"
