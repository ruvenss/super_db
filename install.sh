#!/usr/bin/env bash
# =============================================================================
#  MariaDB Ultra-Performance Installer for Ubuntu 24.04
#  Purpose : Payment & Transaction workloads (OLTP-optimised)
#  Network : Private LAN only — no public IP
#  Client  : PHP 8.3 with persistent connections from a dedicated app server
#
#  Usage   : sudo bash mariadb-ultra-install.sh [APP_SERVER_LAN_IP]
#            e.g.  sudo bash mariadb-ultra-install.sh 10.0.0.5
#
#  The script will:
#    1. Detect hardware (RAM, vCPU, storage type)
#    2. Install MariaDB 11.4 LTS from the official repo
#    3. Write a fully hardware-aware /etc/mysql/mariadb.conf.d/99-ultra.cnf
#    4. Harden the installation (remove test dbs, anonymous users, etc.)
#    5. Apply kernel / OS-level tuning (sysctl + limits)
#    6. Create a dedicated payment DB + restricted user
#    7. Print a post-install summary
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal()   { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "Run as root: sudo bash $0"

APP_SERVER_IP="${1:-}"   # Optional: LAN IP of the PHP app server

# =============================================================================
#  STEP 1 — Hardware detection
# =============================================================================
section "1/7 · Detecting Hardware"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
VCPUS=$(nproc)

# Storage type detection (prefer the data partition's device)
DATA_DEVICE=$(df --output=source /var/lib/mysql 2>/dev/null | tail -1 || df --output=source / | tail -1)
DATA_DEVICE=$(echo "$DATA_DEVICE" | sed 's/[0-9]*$//')   # strip partition number
ROTATIONAL=$(cat /sys/block/$(basename "$DATA_DEVICE")/queue/rotational 2>/dev/null || echo "0")
if [[ "$ROTATIONAL" == "0" ]]; then
    STORAGE_TYPE="SSD/NVMe"
    IO_SCHEDULER="none"
else
    STORAGE_TYPE="HDD"
    IO_SCHEDULER="mq-deadline"
fi

info "RAM   : ${TOTAL_RAM_GB} GB (${TOTAL_RAM_MB} MB)"
info "vCPUs : ${VCPUS}"
info "Storage: ${STORAGE_TYPE}"

# ── Derived tuning values ─────────────────────────────────────────────────────
# InnoDB buffer pool: 70 % of RAM (payments DB is read-heavy after warm-up)
BUFFER_POOL_MB=$((TOTAL_RAM_MB * 70 / 100))
# Round down to nearest 128 MB boundary for cleaner huge-page alignment
BUFFER_POOL_MB=$(( (BUFFER_POOL_MB / 128) * 128 ))
[[ $BUFFER_POOL_MB -lt 128 ]] && BUFFER_POOL_MB=128

# Buffer pool instances: 1 per GB, capped at 64, minimum 1
BP_INSTANCES=$(( BUFFER_POOL_MB / 1024 ))
[[ $BP_INSTANCES -lt 1  ]] && BP_INSTANCES=1
[[ $BP_INSTANCES -gt 64 ]] && BP_INSTANCES=64

# InnoDB redo log size: larger = fewer checkpoints, better throughput
# 512 MB per 4 GB RAM, capped at 4 GB
REDO_LOG_MB=$(( (TOTAL_RAM_GB / 4) * 512 ))
[[ $REDO_LOG_MB -lt 512  ]] && REDO_LOG_MB=512
[[ $REDO_LOG_MB -gt 4096 ]] && REDO_LOG_MB=4096

# InnoDB I/O threads: scale with vCPUs
IO_READ_THREADS=$(( VCPUS > 8 ? 8 : VCPUS ))
IO_WRITE_THREADS=$(( VCPUS > 8 ? 8 : VCPUS ))

# InnoDB io_capacity: SSD >> HDD
if [[ "$STORAGE_TYPE" == "SSD/NVMe" ]]; then
    IO_CAPACITY=4000
    IO_CAPACITY_MAX=8000
    FLUSH_METHOD="O_DIRECT_NO_FSYNC"
else
    IO_CAPACITY=800
    IO_CAPACITY_MAX=2000
    FLUSH_METHOD="O_DIRECT"
fi

# Thread pool size for persistent PHP connections
THREAD_POOL_SIZE=$VCPUS

# Max connections: PHP persistent pool × safety factor
# Assume app server uses up to 4× vCPUs persistent connections; add 50 headroom
MAX_CONNECTIONS=$(( VCPUS * 4 * 4 + 50 ))
[[ $MAX_CONNECTIONS -lt 100  ]] && MAX_CONNECTIONS=100
[[ $MAX_CONNECTIONS -gt 2000 ]] && MAX_CONNECTIONS=2000

# Per-session memory (lower is better on a dedicated DB server)
SORT_BUFFER_MB=4
JOIN_BUFFER_MB=4
READ_BUFFER_MB=2
READ_RND_BUFFER_MB=8

# tmp_table_size / max_heap_table_size
TMP_TABLE_MB=64

# Table open cache
TABLE_OPEN_CACHE=$(( VCPUS * 400 ))
[[ $TABLE_OPEN_CACHE -lt 2000 ]] && TABLE_OPEN_CACHE=2000

# Key buffer (MyISAM; keep small — we use InnoDB exclusively)
KEY_BUFFER_MB=32

# Query cache is REMOVED from MariaDB 10.10+; we leave it out entirely.

info "Buffer Pool : ${BUFFER_POOL_MB} MB (${BP_INSTANCES} instances)"
info "Redo Log    : ${REDO_LOG_MB} MB"
info "Max Conns   : ${MAX_CONNECTIONS}"
info "Thread Pool : ${THREAD_POOL_SIZE}"

# =============================================================================
#  STEP 2 — Install MariaDB 11.4 LTS
# =============================================================================
section "2/7 · Installing MariaDB 11.4 LTS"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl gnupg lsb-release software-properties-common

# Official MariaDB repo
MARIADB_VERSION="11.4"
curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
    | bash -s -- --mariadb-server-version="mariadb-${MARIADB_VERSION}" --skip-maxscale --skip-tools

apt-get update -qq
apt-get install -y -qq \
    mariadb-server \
    mariadb-client \
    mariadb-backup \
    libmariadbd-dev

systemctl enable mariadb

# Create secure_file_priv directory before first start
mkdir -p /var/lib/mysql-files
chown mysql:mysql /var/lib/mysql-files
chmod 750 /var/lib/mysql-files

systemctl start  mariadb
ok "MariaDB ${MARIADB_VERSION} installed and running"

# =============================================================================
#  STEP 3 — Write the ultra-performance configuration
# =============================================================================
section "3/7 · Writing Performance Configuration"

CNF=/etc/mysql/mariadb.conf.d/99-ultra.cnf

cat > "$CNF" <<EOF
# =============================================================================
#  99-ultra.cnf — Auto-generated by mariadb-ultra-install.sh
#  Server  : ${TOTAL_RAM_GB}GB RAM · ${VCPUS} vCPU · ${STORAGE_TYPE}
#  Purpose : OLTP Payments & Transactions
#  Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

[mysqld]

# ── Network ──────────────────────────────────────────────────────────────────
# Bind only to localhost + LAN interface; NEVER to 0.0.0.0
bind-address            = 127.0.0.1
# If you need LAN access too, set this to the server's LAN IP:
# bind-address          = 10.0.0.X
port                    = 3306
skip-name-resolve                       # no DNS lookups on every connect

# ── Thread Pool (critical for persistent PHP-FPM connections) ─────────────────
# In MariaDB 10.5+ the thread pool is built-in — do NOT use plugin-load-add
thread_handling         = pool-of-threads
thread_pool_size        = ${THREAD_POOL_SIZE}
thread_pool_max_threads = ${MAX_CONNECTIONS}
thread_pool_stall_limit = 30            # ms before a stalled query gets new thread
thread_pool_idle_timeout= 60            # idle thread TTL in seconds

# ── Connections ───────────────────────────────────────────────────────────────
max_connections         = ${MAX_CONNECTIONS}
max_connect_errors      = 1000000
wait_timeout            = 600           # keep persistent connections alive
interactive_timeout     = 600
connect_timeout         = 10
back_log                = 512           # connection request queue depth

# ── InnoDB Buffer Pool ────────────────────────────────────────────────────────
innodb_buffer_pool_size = ${BUFFER_POOL_MB}M
innodb_buffer_pool_load_at_startup  = 1
innodb_buffer_pool_dump_at_shutdown = 1
innodb_buffer_pool_dump_pct         = 100

# ── InnoDB I/O ────────────────────────────────────────────────────────────────
innodb_flush_method         = ${FLUSH_METHOD}
innodb_io_capacity          = ${IO_CAPACITY}
innodb_io_capacity_max      = ${IO_CAPACITY_MAX}
innodb_read_io_threads      = ${IO_READ_THREADS}
innodb_write_io_threads     = ${IO_WRITE_THREADS}
innodb_use_native_aio       = 1

# ── InnoDB Redo Log ───────────────────────────────────────────────────────────
# Larger log = fewer checkpoint stalls = better write throughput
innodb_log_file_size        = ${REDO_LOG_MB}M
innodb_log_buffer_size      = 64M       # buffer before flush; fine for most txns

# ── InnoDB Durability — PAYMENT-SAFE settings ─────────────────────────────────
# DO NOT change these for a payment system.
# innodb_flush_log_at_trx_commit=1 : every COMMIT flushes to disk (ACID)
# sync_binlog=1                    : binlog flushed per transaction
innodb_flush_log_at_trx_commit = 1      # ACID-compliant; do not lower for payments
sync_binlog                    = 1      # crash-safe binlog
innodb_doublewrite             = 1      # protects against partial page writes

# ── InnoDB Row Format & Page ──────────────────────────────────────────────────
innodb_file_per_table           = 1     # one .ibd per table — easier backup
innodb_default_row_format       = DYNAMIC
innodb_page_size                = 16384 # 16K default; good for OLTP
innodb_strict_mode              = 1     # fail loudly on bad CREATE TABLE

# ── InnoDB Concurrency ────────────────────────────────────────────────────────
# innodb_thread_concurrency, innodb_concurrency_tickets, innodb_commit_concurrency
# were removed in MariaDB 11.4 — InnoDB manages concurrency automatically
innodb_spin_wait_delay          = 6

# ── InnoDB Adaptive ──────────────────────────────────────────────────────────
innodb_adaptive_hash_index      = 1     # beneficial for repeated PK lookups
innodb_adaptive_flushing        = 1
innodb_adaptive_flushing_lwm    = 10
innodb_lru_scan_depth           = 1024

# ── InnoDB Change Buffering ───────────────────────────────────────────────────
# innodb_change_buffering and innodb_change_buffer_max_size were removed in
# MariaDB 11.4 — the change buffer itself was removed from InnoDB internals

# ── InnoDB Temp & Sort ────────────────────────────────────────────────────────
innodb_sort_buffer_size         = 8M
tmp_table_size                  = ${TMP_TABLE_MB}M
max_heap_table_size             = ${TMP_TABLE_MB}M
tmpdir                          = /tmp

# ── Per-Session Memory (keep low — many persistent connections) ────────────────
sort_buffer_size                = ${SORT_BUFFER_MB}M
join_buffer_size                = ${JOIN_BUFFER_MB}M
read_buffer_size                = ${READ_BUFFER_MB}M
read_rnd_buffer_size            = ${READ_RND_BUFFER_MB}M
bulk_insert_buffer_size         = 32M

# ── Table Cache ───────────────────────────────────────────────────────────────
table_open_cache                = ${TABLE_OPEN_CACHE}
table_definition_cache          = 4096
table_open_cache_instances      = $(( VCPUS > 8 ? 8 : VCPUS ))
open_files_limit                = 65536

# ── MyISAM (minimised — use InnoDB for everything) ────────────────────────────
key_buffer_size                 = ${KEY_BUFFER_MB}M
myisam_sort_buffer_size         = 128M

# ── Binary Log (required for crash safety on payment systems) ─────────────────
log_bin                         = /var/log/mysql/mariadb-bin
log_bin_index                   = /var/log/mysql/mariadb-bin.index
binlog_format                   = ROW                # most reliable for replication
binlog_row_image                = FULL
expire_logs_days                = 7
max_binlog_size                 = 256M
binlog_cache_size               = 2M
binlog_stmt_cache_size          = 2M

# ── Slow Query Log ────────────────────────────────────────────────────────────
slow_query_log                  = 1
slow_query_log_file             = /var/log/mysql/mariadb-slow.log
long_query_time                 = 0.5   # log queries slower than 500ms
log_queries_not_using_indexes   = 0     # set to 1 during development only
log_slow_admin_statements       = 1
min_examined_row_limit          = 100

# ── General Settings ──────────────────────────────────────────────────────────
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci
transaction_isolation           = READ-COMMITTED   # best for OLTP; reduces lock contention
                                                    # vs REPEATABLE-READ default
lower_case_table_names          = 0
explicit_defaults_for_timestamp = 1
sql_mode                        = STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

# ── Performance Schema (lightweight monitoring) ────────────────────────────────
performance_schema              = ON
performance_schema_instrument   = 'wait/%=ON'

# ── Scheduler ────────────────────────────────────────────────────────────────
event_scheduler                 = OFF   # disable unless you explicitly need it

# ── Security ─────────────────────────────────────────────────────────────────
local_infile                    = 0
secure_file_priv                = /var/lib/mysql-files

[mysqldump]
quick
quote-names
max_allowed_packet              = 512M
single-transaction              # hot backup of InnoDB without locks

[mariadb]
# MariaDB-specific extras
innodb_encrypt_tables           = OFF   # enable if at-rest encryption needed
innodb_encrypt_log              = OFF   # enable with encryption plugin

[client]
default-character-set           = utf8mb4
EOF

ok "Configuration written to ${CNF}"

# =============================================================================
#  STEP 4 — OS / Kernel Tuning
# =============================================================================
section "4/7 · Kernel & OS Tuning"

# ── sysctl ────────────────────────────────────────────────────────────────────
SYSCTL_FILE=/etc/sysctl.d/90-mariadb-perf.conf
cat > "$SYSCTL_FILE" <<EOF
# MariaDB ultra-performance kernel tuning
# Generated by mariadb-ultra-install.sh

# Virtual memory
vm.swappiness                   = 1     # almost never swap; keep DB in RAM
vm.dirty_ratio                  = 15
vm.dirty_background_ratio       = 5
vm.dirty_expire_centisecs       = 500
vm.dirty_writeback_centisecs    = 100

# Network (for LAN connections from app server)
net.core.somaxconn              = 65535
net.core.netdev_max_backlog     = 65535
net.ipv4.tcp_max_syn_backlog    = 65535
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_keepalive_time     = 300
net.ipv4.tcp_keepalive_intvl    = 30
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.ip_local_port_range    = 1024 65535

# File descriptors
fs.file-max                     = 2097152
fs.aio-max-nr                   = 1048576
EOF

sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
ok "sysctl tuning applied"

# ── Limits ────────────────────────────────────────────────────────────────────
LIMITS_FILE=/etc/security/limits.d/90-mariadb.conf
cat > "$LIMITS_FILE" <<EOF
# MariaDB process limits
mysql   soft    nofile  65536
mysql   hard    nofile  65536
mysql   soft    nproc   65536
mysql   hard    nproc   65536
EOF

# ── systemd service override ──────────────────────────────────────────────────
OVERRIDE_DIR=/etc/systemd/system/mariadb.service.d
mkdir -p "$OVERRIDE_DIR"
cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Service]
LimitNOFILE=65536
LimitNPROC=65536
# Nice priority for DB process
Nice=-5
IOSchedulingClass=realtime
IOSchedulingPriority=0
EOF

systemctl daemon-reload
ok "systemd limits configured"

# ── I/O scheduler ─────────────────────────────────────────────────────────────
BASE_DEV=$(basename "$DATA_DEVICE")
SCHED_RULE=/etc/udev/rules.d/60-mariadb-io-sched.rules
cat > "$SCHED_RULE" <<EOF
# Set optimal I/O scheduler for MariaDB data device
ACTION=="add|change", KERNEL=="${BASE_DEV}", ATTR{queue/scheduler}="${IO_SCHEDULER}"
EOF

# Apply immediately (best-effort)
if [[ -w /sys/block/${BASE_DEV}/queue/scheduler ]]; then
    echo "$IO_SCHEDULER" > /sys/block/${BASE_DEV}/queue/scheduler 2>/dev/null || true
fi
ok "I/O scheduler set to '${IO_SCHEDULER}' for ${BASE_DEV}"

# ── Transparent Huge Pages — DISABLE for databases ────────────────────────────
THP_FILE=/etc/systemd/system/disable-thp.service
cat > "$THP_FILE" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mariadb.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-thp.service > /dev/null 2>&1
ok "Transparent Huge Pages disabled"

# =============================================================================
#  STEP 5 — Security Hardening
# =============================================================================
section "5/7 · Security Hardening"

# Equivalent of mysql_secure_installation, non-interactive
ROOT_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

mysql --user=root <<SQL
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Remove remote root
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';

FLUSH PRIVILEGES;
SQL

# Store root credentials in a root-only readable file
CREDS_FILE=/root/.mariadb_root_credentials
cat > "$CREDS_FILE" <<EOF
# MariaDB root credentials — KEEP SECURE
[client]
user=root
password=${ROOT_PASS}
socket=/run/mysqld/mysqld.sock
EOF
chmod 600 "$CREDS_FILE"
ok "Root password set and stored in ${CREDS_FILE}"

# ── Firewall: allow only LAN ──────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw deny 3306/tcp comment "Block public MariaDB" 2>/dev/null || true
    if [[ -n "$APP_SERVER_IP" ]]; then
        ufw allow from "$APP_SERVER_IP" to any port 3306 proto tcp comment "PHP app server → MariaDB" 2>/dev/null || true
        ok "UFW: port 3306 allowed only from ${APP_SERVER_IP}"
    else
        warn "No APP_SERVER_IP provided — port 3306 blocked everywhere (adjust manually)"
    fi
fi

# =============================================================================
#  STEP 6 — Create Payment Database & User
# =============================================================================
section "6/7 · Creating Payment Database & User"

DB_NAME="payments_db"
DB_USER="payments_app"
DB_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Determine bind/grant host
if [[ -n "$APP_SERVER_IP" ]]; then
    GRANT_HOST="$APP_SERVER_IP"
else
    GRANT_HOST="10.0.0.%"   # fallback: any private /8 host
    warn "Defaulting DB user grant to 10.0.0.% — adjust if needed"
fi

mysql --defaults-file="$CREDS_FILE" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

-- Restricted payments user: no FILE, no SUPER, no GRANT OPTION
CREATE USER IF NOT EXISTS '${DB_USER}'@'${GRANT_HOST}'
    IDENTIFIED BY '${DB_PASS}';

GRANT SELECT, INSERT, UPDATE, DELETE, INDEX, CREATE TEMPORARY TABLES
    ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${GRANT_HOST}';

-- Allow calling stored procedures (common in payment flows)
GRANT EXECUTE ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${GRANT_HOST}';

FLUSH PRIVILEGES;
SQL

APP_CREDS_FILE=/root/.mariadb_app_credentials
cat > "$APP_CREDS_FILE" <<EOF
# MariaDB application credentials — KEEP SECURE
[client]
host=${GRANT_HOST}
port=3306
user=${DB_USER}
password=${DB_PASS}
database=${DB_NAME}
EOF
chmod 600 "$APP_CREDS_FILE"
ok "Database '${DB_NAME}' and user '${DB_USER}'@'${GRANT_HOST}' created"
ok "App credentials stored in ${APP_CREDS_FILE}"

# =============================================================================
#  STEP 7 — Restart & Validate
# =============================================================================
section "7/7 · Restart & Validate"

systemctl restart mariadb
sleep 2

if systemctl is-active --quiet mariadb; then
    ok "MariaDB is running"
else
    fatal "MariaDB failed to start — check: journalctl -u mariadb -n 50"
fi

# Quick smoke test
UPTIME=$(mysql --defaults-file="$CREDS_FILE" -sNe "SELECT 'OK: ' || VERSION()" 2>/dev/null || echo "FAILED")
if [[ "$UPTIME" == FAILED* ]]; then
    fatal "Cannot connect to MariaDB after restart"
else
    ok "MariaDB version: $UPTIME"
fi

# Verify buffer pool size was accepted
BP_ACTUAL=$(mysql --defaults-file="$CREDS_FILE" -sNe \
    "SELECT ROUND(@@innodb_buffer_pool_size/1024/1024) AS mb" 2>/dev/null || echo "?")
ok "InnoDB buffer pool active: ${BP_ACTUAL} MB"

# Verify thread pool
TP_ACTIVE=$(mysql --defaults-file="$CREDS_FILE" -sNe \
    "SELECT @@thread_handling" 2>/dev/null || echo "?")
ok "Thread handling: ${TP_ACTIVE}"

# =============================================================================
#  Post-Install Summary
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          MariaDB Ultra-Performance — Install Complete        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Server Hardware Detected${NC}"
printf  "  %-28s %s\n"  "RAM:"          "${TOTAL_RAM_GB} GB"
printf  "  %-28s %s\n"  "vCPUs:"        "${VCPUS}"
printf  "  %-28s %s\n"  "Storage type:" "${STORAGE_TYPE}"
echo ""
echo -e "  ${CYAN}Key Tuning Values Applied${NC}"
printf  "  %-28s %s\n"  "InnoDB Buffer Pool:"   "${BUFFER_POOL_MB} MB (${BP_INSTANCES} instances)"
printf  "  %-28s %s\n"  "InnoDB Redo Log:"      "${REDO_LOG_MB} MB"
printf  "  %-28s %s\n"  "Max Connections:"      "${MAX_CONNECTIONS}"
printf  "  %-28s %s\n"  "Thread Pool Size:"     "${THREAD_POOL_SIZE}"
printf  "  %-28s %s\n"  "Flush Method:"         "${FLUSH_METHOD}"
printf  "  %-28s %s\n"  "IO Capacity:"          "${IO_CAPACITY} / ${IO_CAPACITY_MAX} (max)"
printf  "  %-28s %s\n"  "Transaction Isolation:" "READ-COMMITTED"
printf  "  %-28s %s\n"  "flush_log_at_trx_commit:" "1 (ACID / payment-safe)"
printf  "  %-28s %s\n"  "sync_binlog:"          "1 (crash-safe)"
echo ""
echo -e "  ${CYAN}Database & Credentials${NC}"
printf  "  %-28s %s\n"  "Database:"     "${DB_NAME}"
printf  "  %-28s %s\n"  "App User:"     "${DB_USER}@${GRANT_HOST}"
printf  "  %-28s %s\n"  "Root creds:"   "${CREDS_FILE}"
printf  "  %-28s %s\n"  "App creds:"    "${APP_CREDS_FILE}"
echo ""
echo -e "  ${CYAN}Config Files Written${NC}"
printf  "  %-28s %s\n"  "MariaDB config:"   "${CNF}"
printf  "  %-28s %s\n"  "sysctl tuning:"    "${SYSCTL_FILE}"
printf  "  %-28s %s\n"  "Limits:"           "${LIMITS_FILE}"
printf  "  %-28s %s\n"  "systemd override:" "${OVERRIDE_DIR}/override.conf"
echo ""
echo -e "  ${YELLOW}Next Steps${NC}"
echo    "  1. Copy app credentials to the PHP server:"
echo    "     scp ${APP_CREDS_FILE} user@APP_SERVER:/etc/mysql-app.cnf"
echo    ""
echo    "  2. PHP PDO connection string:"
echo    "     \$dsn = 'mysql:host=${GRANT_HOST};port=3306;dbname=${DB_NAME};charset=utf8mb4';"
echo    "     Use ATTR_PERSISTENT => true for persistent connections."
echo    ""
echo    "  3. If bind-address needs to be the LAN IP (not 127.0.0.1), edit:"
echo    "     ${CNF}  → change bind-address to this server's LAN IP"
echo    "     Then: systemctl restart mariadb"
echo    ""
echo    "  4. Monitor slow queries:"
echo    "     tail -f /var/log/mysql/mariadb-slow.log"
echo    ""
echo    "  5. For hot backups (zero downtime):"
echo    "     mariabackup --backup --target-dir=/backup/$(date +%Y%m%d) \\"
echo    "       --user=root --defaults-file=${CREDS_FILE}"
echo    ""
echo -e "  ${RED}SECURITY REMINDERS${NC}"
echo    "  • Credentials in /root/.mariadb_* are root-only readable (chmod 600)."
echo    "  • Port 3306 must NEVER be exposed to the public internet."
echo    "  • Rotate passwords after copying them to the app server."
echo    "  • Enable binary log retention monitoring for GDPR/PCI compliance."
echo    ""