# MariaDB Ultra-Performance Installer

A single Bash script that installs and fully configures **MariaDB 11.4 LTS** on **Ubuntu 24.04**, tuned for payment and transaction workloads (OLTP). It detects your server's hardware at runtime and applies optimal settings automatically — no manual config editing required.

---

## What It Does

- Installs MariaDB 11.4 LTS from the official repo
- Writes a hardware-aware performance config (`99-ultra.cnf`)
- Tunes the Linux kernel (sysctl, file limits, I/O scheduler, THP)
- Hardens the installation (removes test DBs, anonymous users, sets root password)
- Creates a `payments_db` database and a least-privilege `payments_app` user
- Locks down the firewall (UFW) to allow port 3306 only from your app server
- Prints a full post-install summary with all credentials and next steps

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Privileges | Must run as `root` (`sudo`) |
| Network | Private LAN only — never expose port 3306 to the internet |
| Client | Designed for a PHP 8.3 app server using persistent connections |

---

## Quick Start

```bash
# Download the script
curl -O https://raw.githubusercontent.com/ruvenss/super_db/main/install.sh

# Verify it (optional but recommended)
bash -n install.sh

# Run it — pass your PHP app server's LAN IP
sudo bash install.sh 10.0.0.5
```

If you don't pass an IP, it defaults to allowing any `10.0.0.*` host on port 3306.

---

## Step-by-Step Guide

### Step 1 — Prepare Your Server

Make sure you are on a **fresh Ubuntu 24.04** instance with internet access (to download packages from the MariaDB repo).

```bash
# Update the system first
sudo apt-get update && sudo apt-get upgrade -y
```

### Step 2 — Get the Script

```bash
curl -O https://raw.githubusercontent.com/ruvenss/super_db/main/install.sh
```

Or clone the repo:

```bash
git clone https://github.com/ruvenss/super_db.git
cd super_db
```

### Step 3 — (Optional) Validate Before Running

```bash
# Check for syntax errors
bash -n install.sh

# Static analysis (install shellcheck if needed)
sudo apt-get install -y shellcheck
shellcheck install.sh
```

### Step 4 — Run the Installer

```bash
# With your app server's specific LAN IP (recommended)
sudo bash install.sh 10.0.0.5

# Without an IP — allows any 10.0.0.x host (less secure)
sudo bash install.sh
```

The script will print live progress across 7 steps and exit with a full summary.

### Step 5 — Read the Post-Install Summary

At the end the script prints everything you need:

- Hardware detected (RAM, vCPUs, storage type)
- All tuning values applied
- Where credentials are stored
- Config file locations
- PHP connection string
- Backup command

---

## Command-Line Options

| Argument | Required | Description |
|---|---|---|
| `APP_SERVER_LAN_IP` | No | LAN IP of the PHP app server (e.g. `10.0.0.5`). Controls UFW firewall rule and the MariaDB `GRANT` host. If omitted, defaults to `10.0.0.%` |

**Examples:**

```bash
# Lock down to a single app server
sudo bash install.sh 10.0.0.5

# Allow entire 10.0.0.x subnet (development / multi-server setups)
sudo bash install.sh
```

---

## What Gets Installed & Configured

### MariaDB Packages

- `mariadb-server` — the database server
- `mariadb-client` — command-line client
- `mariadb-backup` — hot backup tool (zero downtime backups)

### Performance Config (`/etc/mysql/mariadb.conf.d/99-ultra.cnf`)

All values are computed from your actual hardware at install time:

| Parameter | Formula |
|---|---|
| `innodb_buffer_pool_size` | 70% of RAM, rounded to 128 MB boundary |
| `innodb_buffer_pool_instances` | 1 per GB of buffer pool, max 64 |
| `innodb_log_file_size` | 512 MB per 4 GB RAM, max 4 GB |
| `max_connections` | `(vCPUs × 4 × 4) + 50`, max 2000 |
| `thread_pool_size` | Equals vCPU count |
| `innodb_io_capacity` | 4000 (SSD/NVMe) or 800 (HDD) |
| `innodb_flush_method` | `O_DIRECT_NO_FSYNC` (SSD) or `O_DIRECT` (HDD) |

**ACID settings are intentionally strict and must not be relaxed for payment systems:**

```
innodb_flush_log_at_trx_commit = 1   # every COMMIT flushes to disk
sync_binlog                    = 1   # binlog flushed per transaction
innodb_doublewrite             = 1   # protects against partial page writes
```

### OS / Kernel Tuning

| File | What it does |
|---|---|
| `/etc/sysctl.d/90-mariadb-perf.conf` | Sets `vm.swappiness=1`, network backlog, TCP keepalives |
| `/etc/security/limits.d/90-mariadb.conf` | Raises file descriptor and process limits for the `mysql` user |
| `/etc/systemd/system/mariadb.service.d/override.conf` | Applies `LimitNOFILE`, real-time I/O priority, nice level |
| `/etc/udev/rules.d/60-mariadb-io-sched.rules` | Sets I/O scheduler: `none` for SSD, `mq-deadline` for HDD |
| `/etc/systemd/system/disable-thp.service` | Disables Transparent Huge Pages (required for stable DB performance) |

### Security Hardening

- Removes anonymous MySQL users
- Removes remote root login
- Drops the `test` database
- Sets a strong random root password (32 chars, stored in `/root/.mariadb_root_credentials`)

### Database & User

| Item | Value |
|---|---|
| Database | `payments_db` (utf8mb4, unicode_ci) |
| App user | `payments_app` |
| Granted privileges | `SELECT, INSERT, UPDATE, DELETE, INDEX, CREATE TEMPORARY TABLES, EXECUTE` |
| No access to | `FILE`, `SUPER`, `GRANT OPTION`, `DROP`, `ALTER`, `CREATE` |
| Credentials file | `/root/.mariadb_app_credentials` (chmod 600) |

---

## After Installation

### Connect from the PHP App Server

Copy the credentials file to your app server:

```bash
scp /root/.mariadb_app_credentials user@10.0.0.5:/etc/mysql-app.cnf
```

#### Using mysqli (PHP 8.3) with Persistent Connections

Prefix the host with `p:` to enable persistent connections. mysqli keeps the
connection in the process pool (PHP-FPM worker) and reuses it across requests —
this is what the MariaDB thread pool is sized for.

```php
<?php
// Persistent connection: prefix host with "p:"
$mysqli = new mysqli(
    'p:10.0.0.5',   // "p:" prefix enables persistent connections
    'payments_app',
    'YOUR_PASSWORD',
    'payments_db',
    3306
);

if ($mysqli->connect_errno) {
    throw new RuntimeException('DB connect failed: ' . $mysqli->connect_error);
}

// Always set charset explicitly
$mysqli->set_charset('utf8mb4');

// Optional: enable exception mode (PHP 8.1+)
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
```

**How persistent connections work with PHP-FPM:**

- Each PHP-FPM worker holds **one** persistent connection to MariaDB
- The connection is reused for every request handled by that worker — no reconnect overhead
- MariaDB's thread pool (`pool-of-threads`) is configured to match this pattern
- `wait_timeout = 600` keeps idle connections alive between requests
- If the server closes a stale connection, mysqli automatically reconnects on the next query

**PHP-FPM pool sizing tip** — keep `pm.max_children` in sync with MariaDB's `max_connections`:

```ini
; /etc/php/8.3/fpm/pool.d/www.conf
pm = dynamic
pm.max_children     = 50    ; must be < max_connections in 99-ultra.cnf
pm.start_servers    = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests     = 500   ; recycle workers periodically to close stale conns
```

#### Using PDO with Persistent Connections

```php
$dsn = 'mysql:host=10.0.0.5;port=3306;dbname=payments_db;charset=utf8mb4';
$pdo = new PDO($dsn, 'payments_app', 'YOUR_PASSWORD', [
    PDO::ATTR_PERSISTENT         => true,
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_EMULATE_PREPARES   => false,  // use real prepared statements
    PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
]);
```

> **mysqli vs PDO:** Both support persistent connections via the same underlying
> PHP mechanism. Use `mysqli` if you want direct access to MariaDB-specific
> features (e.g. `mysqli_multi_query`, `LOAD DATA`). Use `PDO` if you need
> database portability or prefer named parameters in prepared statements.

### If You Need LAN Access (bind-address)

By default, MariaDB only listens on `127.0.0.1`. To allow connections from the LAN:

```bash
# Edit the config
sudo nano /etc/mysql/mariadb.conf.d/99-ultra.cnf

# Change this line:
bind-address = 127.0.0.1
# To your server's LAN IP:
bind-address = 10.0.0.X

# Restart to apply
sudo systemctl restart mariadb
```

### Monitor Slow Queries

```bash
tail -f /var/log/mysql/mariadb-slow.log
```

Queries slower than 500ms are logged automatically.

### Hot Backups (Zero Downtime)

```bash
mariabackup --backup \
  --target-dir=/backup/$(date +%Y%m%d) \
  --user=root \
  --defaults-file=/root/.mariadb_root_credentials
```

### Connect as Root (for admin tasks)

```bash
sudo mysql --defaults-file=/root/.mariadb_root_credentials
```

---

## Credential Files

Both files are owned by root and chmod 600 — only root can read them.

| File | Contents |
|---|---|
| `/root/.mariadb_root_credentials` | MariaDB root password + socket path |
| `/root/.mariadb_app_credentials` | App user password + DB name + host |

**Rotate passwords after copying them to the app server.**

---

## Security Notes

- Port 3306 must **never** be exposed to the public internet
- `local_infile` is disabled (prevents `LOAD DATA LOCAL` attacks)
- `secure_file_priv` restricts file operations to `/var/lib/mysql-files`
- Binary log retention is set to 7 days — monitor for PCI/GDPR compliance
- At-rest encryption is available but **off by default** — enable via `innodb_encrypt_tables = ON` after setting up the encryption plugin

---

## Troubleshooting

**MariaDB fails to start after install:**
```bash
journalctl -u mariadb -n 50
```

**Check current buffer pool size:**
```bash
sudo mysql --defaults-file=/root/.mariadb_root_credentials \
  -e "SELECT ROUND(@@innodb_buffer_pool_size/1024/1024) AS buffer_pool_mb;"
```

**Check thread pool is active:**
```bash
sudo mysql --defaults-file=/root/.mariadb_root_credentials \
  -e "SELECT @@thread_handling;"
# Should return: pool-of-threads
```

**Syntax-check the script without running it:**
```bash
bash -n install.sh
shellcheck install.sh
```

---

## License

MIT — use freely, modify as needed.
