#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Frappe v15 + ERPNext + HRMS on Ubuntu 22.04 LXC (External MariaDB)
# - Self-healing against broken global bench installs (python3.12)
# - Step-by-step echo logs
# - Preflight checks: OS, disk, DB connectivity
# - Runs bench actions as "frappe" user; production setup as root from bench dir
###############################################################################

########################################
# USER CONFIG (EDIT THESE)
########################################
FRAPPE_USER="frappe"
SITE_NAME="hrms.anthenagroup.com"
ADMIN_PASSWORD="Admin@123"

# External MariaDB (REQUIRED)
DB_HOST="192.168.0.162"
DB_PORT="3306"
DB_ROOT_USER="admin"
DB_ROOT_PASSWORD="P00sw00rd!!!!"

# Branches
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"

########################################
# INTERNAL CONFIG (DON'T CHANGE)
########################################
FRAPPE_HOME="/home/${FRAPPE_USER}"
BENCH_DIR="${FRAPPE_HOME}/frappe-bench"
LOG_FILE="/var/log/frappe-hrms-install.log"
MIN_FREE_GB=40

###############################################################################
# LOGGING
###############################################################################
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

step() { echo -e "\n=================================================================\n$1\n================================================================="; }
ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
die()  { echo "❌ ERROR: $1"; exit 1; }

###############################################################################
# PRE-CHECKS
###############################################################################
step "STEP 0: Starting install"
date

if [[ $EUID -ne 0 ]]; then
  die "Run this script as root (sudo)."
fi

step "STEP 1: Checking OS (must be Ubuntu 22.04 Jammy)"
if [[ ! -f /etc/os-release ]]; then
  die "/etc/os-release not found."
fi
. /etc/os-release
echo "Detected: ${PRETTY_NAME:-unknown}"
if [[ "${ID:-}" != "ubuntu" ]] || [[ "${VERSION_CODENAME:-}" != "jammy" ]]; then
  die "This script is designed for Ubuntu 22.04 (jammy) inside LXC."
fi
ok "OS check passed"

step "STEP 2: Checking disk space (min ${MIN_FREE_GB}GB free on /)"
avail_kb="$(df --output=avail / | tail -1 | tr -d ' ')"
required_kb="$((MIN_FREE_GB * 1024 * 1024))"
echo "Available KB: $avail_kb"
echo "Required  KB: $required_kb"
if [[ "$avail_kb" -lt "$required_kb" ]]; then
  die "Not enough disk space. Increase LXC rootfs size; aim for 50–60GB total."
fi
ok "Disk space check passed"

step "STEP 3: Ensuring dpkg/apt is in good state"
dpkg --configure -a || true
apt -f install -y || true
apt update
ok "apt/dpkg looks OK"

###############################################################################
# REMOVE BROKEN GLOBAL BENCH (PYTHON 3.12 TRAP)
###############################################################################
step "STEP 4: Removing any broken global bench installs (prevents python3.12 issues)"
# Remove bench/frappe-bench installed via pip/pip3 globally
pip uninstall -y frappe-bench bench >/dev/null 2>&1 || true
pip3 uninstall -y frappe-bench bench >/dev/null 2>&1 || true
# Remove stale bench binary commonly installed under /usr/local/bin
rm -f /usr/local/bin/bench || true
# Remove python3.12 dist-packages bench if present (safe; only deletes that tree)
rm -rf /usr/local/lib/python3.12/dist-packages/bench* || true
rm -rf /usr/local/lib/python3.12/dist-packages/frappe_bench* || true
ok "Global bench cleanup done (if anything existed)"

###############################################################################
# PACKAGES
###############################################################################
step "STEP 5: Installing required system packages"
apt install -y \
  sudo curl git ca-certificates gnupg lsb-release \
  build-essential \
  nginx supervisor redis-server \
  mariadb-client \
  python3 python3-dev python3-venv python3-pip \
  xvfb wkhtmltopdf \
  libmysqlclient-dev \
  libjpeg-dev zlib1g-dev \
  libffi-dev libssl-dev
ok "Base packages installed"

step "STEP 6: Installing Node.js 18 + Yarn"
# NodeSource setup sometimes re-run; safe.
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs
npm install -g yarn
node -v
yarn -v
ok "Node.js and Yarn installed"

###############################################################################
# EXTERNAL DB CONNECTIVITY CHECK
###############################################################################
step "STEP 7: Checking external MariaDB connectivity"
echo "DB_HOST=$DB_HOST"
echo "DB_PORT=$DB_PORT"
echo "DB_ROOT_USER=$DB_ROOT_USER"
# simple connectivity check
if ! command -v mysql >/dev/null 2>&1; then
  die "mysql client not found even after install."
fi

# Use TCP + short timeout. Avoid leaking password in process list by using env var.
export MYSQL_PWD="$DB_ROOT_PASSWORD"
if mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -e "SELECT 1;" >/dev/null 2>&1; then
  ok "External MariaDB connection OK"
else
  unset MYSQL_PWD
  die "Cannot connect to MariaDB at ${DB_HOST}:${DB_PORT} as ${DB_ROOT_USER}.
Fix on DB server: allow network access, bind-address=0.0.0.0, firewall rules, and grants for this client IP."
fi
unset MYSQL_PWD

###############################################################################
# CREATE FRAPPE USER
###############################################################################
step "STEP 8: Creating/ensuring '${FRAPPE_USER}' user exists"
if ! id "$FRAPPE_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$FRAPPE_USER"
  usermod -aG sudo "$FRAPPE_USER"
  ok "User ${FRAPPE_USER} created"
else
  ok "User ${FRAPPE_USER} already exists"
fi

mkdir -p "$FRAPPE_HOME"
chown -R "$FRAPPE_USER:$FRAPPE_USER" "$FRAPPE_HOME"
ok "Home directory permissions OK"

###############################################################################
# BENCH + APPS + SITE (AS FRAPPE USER)
###############################################################################
step "STEP 9: Installing bench + initializing bench directory (runs as ${FRAPPE_USER})"

sudo -u "$FRAPPE_USER" bash <<EOF
set -euo pipefail

echo "---- Running as: \$(whoami) ----"
python3 --version

echo "[9.1] Upgrade pip tooling"
python3 -m pip install --upgrade pip setuptools wheel

echo "[9.2] Install frappe-bench (user scope)"
python3 -m pip install --upgrade frappe-bench

echo "[9.3] Ensure bench directory exists"
if [ ! -d "$BENCH_DIR" ]; then
  bench init "$BENCH_DIR" --frappe-branch "$FRAPPE_BRANCH" --python python3
fi

cd "$BENCH_DIR"

echo "[9.4] Ensure required directories exist"
mkdir -p config logs

echo "[9.5] Fetch ERPNext and HRMS apps (idempotent)"
bench get-app erpnext --branch "$ERPNEXT_BRANCH" || true
bench get-app hrms --branch "$HRMS_BRANCH" || true

echo "[9.6] Create site using EXTERNAL MariaDB (idempotent)"
if [ ! -d "sites/$SITE_NAME" ]; then
  bench new-site "$SITE_NAME" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --db-root-password "$DB_ROOT_PASSWORD"
fi

echo "[9.7] Install apps into site (idempotent)"
bench --site "$SITE_NAME" install-app erpnext || true
bench --site "$SITE_NAME" install-app hrms || true

echo "[9.8] Quick sanity: site_config.json"
test -f "sites/$SITE_NAME/site_config.json"
grep -E '"db_host"|\"db_port\"' "sites/$SITE_NAME/site_config.json" || true

echo "---- Bench + Site setup completed ----"
EOF

ok "Bench + apps + site done"

###############################################################################
# PRODUCTION SETUP (ROOT, FROM BENCH DIR)
###############################################################################
step "STEP 10: Setting up production (Supervisor + Nginx) - MUST run from bench dir"
cd "$BENCH_DIR"
# Ensure config dir exists (prevents ./config/supervisor.conf error)
mkdir -p "$BENCH_DIR/config"

bench setup production "$FRAPPE_USER"
ok "Production setup complete"

###############################################################################
# START SERVICES
###############################################################################
step "STEP 11: Restarting services"
supervisorctl reread
supervisorctl update
supervisorctl restart all || true
systemctl restart redis-server
systemctl restart nginx
ok "Services restarted"

###############################################################################
# FINAL HEALTH CHECKS
###############################################################################
step "STEP 12: Health checks"
echo "Supervisor status:"
supervisorctl status || true

echo "Nginx status:"
systemctl --no-pager --full status nginx | sed -n '1,12p' || true

echo "Redis status:"
systemctl --no-pager --full status redis-server | sed -n '1,12p' || true

echo "Bench doctor (may warn; should not error):"
sudo -u "$FRAPPE_USER" bash -lc "cd '$BENCH_DIR' && bench doctor" || true

###############################################################################
# DONE
###############################################################################
step "DONE"
echo "✅ Installation completed."
echo "➡ Open: http://<LXC-IP>"
echo "➡ Site: $SITE_NAME"
echo "➡ Login: Administrator"
echo "➡ Pass : $ADMIN_PASSWORD"
echo "➡ Log  : $LOG_FILE"
echo ""
echo "If you use a domain, point it to this LXC IP and (optionally) set up SSL."
