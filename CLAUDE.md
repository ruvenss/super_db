# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A single-file Bash installer (`install.sh`) that provisions MariaDB 11.4 LTS on Ubuntu 24.04 for OLTP payment/transaction workloads. It targets private LAN deployments with a PHP 8.3 app server using persistent connections.

## Usage

```bash
sudo bash install.sh [APP_SERVER_LAN_IP]
# e.g.: sudo bash install.sh 10.0.0.5
```

Must be run as root on Ubuntu 24.04. The `APP_SERVER_LAN_IP` arg controls UFW firewall rules and the MariaDB `GRANT` host; if omitted, it defaults to `10.0.0.%`.

## Script Architecture

The script runs 7 sequential steps, each gated by `set -euo pipefail`:

1. **Hardware detection** — reads `/proc/meminfo`, `nproc`, and `/sys/block/.../rotational` to derive all tuning values
2. **MariaDB install** — adds the official MariaDB repo and installs `mariadb-server`, `mariadb-client`, `mariadb-backup`
3. **Performance config** — writes `/etc/mysql/mariadb.conf.d/99-ultra.cnf` with all values computed from step 1
4. **OS/kernel tuning** — writes `/etc/sysctl.d/90-mariadb-perf.conf`, `/etc/security/limits.d/90-mariadb.conf`, a `systemd` service override, a udev I/O scheduler rule, and a `disable-thp.service` unit
5. **Security hardening** — non-interactive equivalent of `mysql_secure_installation`; root password stored in `/root/.mariadb_root_credentials` (chmod 600)
6. **DB + user creation** — creates `payments_db` with user `payments_app` granted only `SELECT, INSERT, UPDATE, DELETE, INDEX, CREATE TEMPORARY TABLES, EXECUTE`; credentials stored in `/root/.mariadb_app_credentials`
7. **Restart & validate** — restarts MariaDB, smoke-tests connectivity, and prints a full summary

## Key Tuning Decisions

All values in `99-ultra.cnf` are derived at runtime — nothing is hardcoded:

| Parameter | Formula |
|---|---|
| `innodb_buffer_pool_size` | 70% of RAM, rounded to 128 MB boundary |
| `innodb_buffer_pool_instances` | 1 per GB of buffer pool, capped at 64 |
| `innodb_log_file_size` | 512 MB per 4 GB RAM, capped at 4 GB |
| `max_connections` | `(vCPUs × 4 × 4) + 50`, capped at 2000 |
| `thread_pool_size` | equals vCPU count |
| `innodb_io_capacity` | 4000 (SSD) or 800 (HDD) |
| `innodb_flush_method` | `O_DIRECT_NO_FSYNC` (SSD) or `O_DIRECT` (HDD) |

**ACID settings are intentionally strict** (`innodb_flush_log_at_trx_commit=1`, `sync_binlog=1`, `innodb_doublewrite=1`) — do not relax these for a payment system.

`transaction_isolation = READ-COMMITTED` (not the MariaDB default `REPEATABLE-READ`) to reduce lock contention in OLTP workloads.

## Testing Changes

There is no test suite. To validate script changes:

```bash
# Syntax check (no execution)
bash -n install.sh

# Shellcheck static analysis (install if needed: brew install shellcheck)
shellcheck install.sh
```

Full integration testing requires an Ubuntu 24.04 VM or container with `sudo` access.
