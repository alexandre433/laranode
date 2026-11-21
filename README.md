# Laranode - Open-Source Hosting Control Panel

Laranode is a simple but powerful open-source alternative to cPanel and Plesk, designed to simplify VPS and dedicated server management. With an intuitive interface and robust features, Laranode makes it easy to deploy and manage websites, databases, SSL certificates, and more.

## Features

✅ **Self-Hosted** – Full control over your server with NO licensing fees.

✅ **Multi-Account Support** – Role-based access control for admins and users.  

✅ **Website Management** – Easily create and manage multiple websites.  

✅ **SSL with Let's Encrypt** – Secure your websites with free SSL certificates with a click of a button.

✅ **File Manager** – Built-in (from the ground up) web-based file manager for quick access.  

✅ **Live System Stats** – Monitor CPU, memory, and network usage in real-time. 

✅ **LAMP Stack Administration** – Manage Apache, MySQL, and PHP with ease.  

✅ **User-Friendly Interface** – Clean and simple UI designed for efficiency.  

✅ **MySQL Database Management** – Create and control MySQL databases.  

✅ **UFW Firewall** – Manage uncomplicated firewall rules with ease directly from the web interface.  

## Installation

Laranode can be installed on a FRESH VPS or dedicated server.

### Min. Requirements
- Ubuntu 24.04 **or** Debian 13 (trixie). The installer detects the OS; anything else is refused.
- 1vCPU
- 2GB RAM
- 10GB Disk Space

### Quick Install
Run on a clean Ubuntu 24.04 or Debian 13 server as root:
```bash
curl -sSL https://raw.githubusercontent.com/alexandre433/laranode/refs/heads/main/laranode-scripts/bin/laranode-installer.sh | bash
```

### Supported operating systems

| | Ubuntu 24.04 | Debian 13 (trixie) |
|---|---|---|
| PHP 8.4 source | ondrej/php PPA | Debian's own `php8.4` packages (no third-party repo) |
| Default database | MySQL 8 (`mysql-server`) | PostgreSQL 17 (Debian has no `mysql-server`) |
| MySQL on that OS | installed by the installer | only an existing MySQL / Percona / MariaDB server is reused |
| PostgreSQL | distro default (16) | 17 |

The installer never removes packages and, on Proxmox/CloudPanel hosts, never upgrades host-stack packages: every `apt-get install` is simulated first and the install aborts if apt would remove anything.

### Installer options (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `LARANODE_OS` | auto-detect | `ubuntu` or `debian`. Force the package path on a derivative distro (the version must still be 24.04 / 13) |
| `LARANODE_DB_ENGINE` | `mysql` on Ubuntu, `pgsql` on Debian | `mysql` or `pgsql`. Only that engine's server package is installed |
| `LARANODE_HTTP_PORT` | 80 if free, else 8080 | Apache port the panel listens on |
| `LARANODE_BIND` | `local` on Proxmox/CloudPanel, else `all` | `all`, `local` (127.0.0.1) or an IPv4 address. Reach a local-bound panel over an SSH tunnel |
| `LARANODE_DATA_DIR` | distro default | Fresh PostgreSQL install only: keep cluster data under `<dir>/postgresql/<ver>/<cluster>` (e.g. a larger disk) |
| `LARANODE_MYSQL_ROOT_PASSWORD` | - | Needed when an existing MySQL root uses password auth |
| `LARANODE_PG_PORT` | auto (single cluster) | Select the cluster when several PostgreSQL clusters exist |
| `LARANODE_APP_URL` | public IP | Sets `APP_URL` and the Reverb host |
| `LARANODE_UNATTENDED` | `0` | `1` takes every default and suppresses prompts. Required when stdin is not a terminal (`curl | bash`, CI): without it the install stops at the confirmation instead of proceeding silently |

Example: `LARANODE_UNATTENDED=1 LARANODE_DB_ENGINE=pgsql LARANODE_BIND=local bash laranode-installer.sh`

### Installing next to existing services

The installer is safe to run on a host that already has services:

- **nginx on :80** - the panel vhost goes on :8080, the existing server is untouched.
- **Apache on :80 (live sites)** - kept exactly as is: its `Listen` lines, `000-default` and sites stay, mod_ssl is not enabled, the PHP-FPM handler is set in the panel vhost only, and Apache is gracefully reloaded (same process, no dropped connections), never restarted. `LARANODE_BIND` cannot narrow :80 beside it: pick another `LARANODE_HTTP_PORT`.
- **Apache or PHP-FPM installed but stopped** - treated as the owner's, not ours: refused up front (nothing changed) unless `LARANODE_START_STOPPED=1`, which only starts it. It is never enabled at boot, so it and the panel stay down after a reboot unless you enable it. Refused regardless when its own `Listen` port is held by another service.
- **PHP-FPM 8.4 already running** - its pools are never restarted: service starts are held back while the PHP packages install and the pool is only reloaded. If the installer is killed mid-install, the next run removes its leftover guard.
- **A step fails after Apache was changed** - the installer puts the owner's Apache back (Listen line, panel vhost, modules it enabled) and reloads it, so a later restart of that Apache does not trip over the half-done install.
- **No `ss` installed** - ports are probed through `/proc/net/tcp`; nothing is installed before you confirm.
- **Panel port already in use** - refused with the holder named before any change (a graceful Apache reload that cannot bind a new port can take live sites down). Pick a free `LARANODE_HTTP_PORT`.
- **Existing MySQL / Percona / MariaDB** - reused as is; `mysql-server` is never installed over it.
- **Existing PostgreSQL clusters** - client only; set `LARANODE_PG_PORT` to the cluster the panel may use.
- **Proxmox VE** - ufw is never installed or enabled, ports 22/85/111/443/3128/8006 are refused, the panel binds 127.0.0.1.
- **CloudPanel** - no PPA, nothing installed over its PHP/nginx/Percona, panel on :8090, Reverb on :8081, no ufw rules, binds 127.0.0.1.

The installer writes `/etc/laranode/service-manifest.json` listing which services it manages and which were already there (see `CLAUDE.md`, "Service manifest").

## Getting Started
Once installed, access Laranode via your browser:
```
http://your-server-ip
OR if you pointed your domain/subdomain
http://your-domain.tld
```
Login with the credentials provided during installation.

## Screenshots

| Light | Dark |
|:------:|:----:|
| <img src="laranode-screenshots/2-dashboard.png" alt="Dashboard (Light)" width="400"/> | <img src="laranode-screenshots/1-dashboard-dark.png" alt="Dashboard (Dark)" width="400"/> |
| <img src="laranode-screenshots/3-stats-history.png" alt="Stats History (Light)" width="400"/> | <img src="laranode-screenshots/3-stats-history-dark.png" alt="Stats History (Dark)" width="400"/> |
| <img src="laranode-screenshots/4-accounts.png" alt="Accounts (Light)" width="400"/> | <img src="laranode-screenshots/4-accounts-dark.png" alt="Accounts (Dark)" width="400"/> |
| <img src="laranode-screenshots/5-create-account.png" alt="Create Account (Light)" width="400"/> | <img src="laranode-screenshots/5-create-account-dark.png" alt="Create Account (Dark)" width="400"/> |
| <img src="laranode-screenshots/6-websites.png" alt="Websites (Light)" width="400"/> | <img src="laranode-screenshots/6-websites-dark.png" alt="Websites (Dark)" width="400"/> |
| <img src="laranode-screenshots/7-filemanager.png" alt="File Manager (Light)" width="400"/> | <img src="laranode-screenshots/7-filemanager-dark.png" alt="File Manager (Dark)" width="400"/> |
| <img src="laranode-screenshots/8-db.png" alt="Database Manager (Light)" width="400"/> | <img src="laranode-screenshots/8-db-dark.png" alt="Database Manager (Dark)" width="400"/> |
| <img src="laranode-screenshots/9-firewall.png" alt="Firewall (Light)" width="400"/> | <img src="laranode-screenshots/9-firewall-dark.png" alt="Firewall (Dark)" width="400"/> |

## Minimum Requirements


## 1-Click Deployment with DigitalOcean
[![DigitalOcean Logo](https://opensource.nyc3.cdn.digitaloceanspaces.com/attribution/assets/SVG/DO_Logo_horizontal_blue.svg)](https://marketplace.digitalocean.com/apps/laranode-panel?refcode=833110c66c2c&action=deploy)

## Roadmap - Future Release Plans

- 🔹 PHP Manager - install, update, remove PHP versions
- 🔹 Backup Manager - backup websites, databases, and files

## Contributing
Laranode is open-source and welcomes contributions! Feel free to submit issues, feature requests, or pull requests.

## License
Laranode is open-source and released under the [MIT license](https://opensource.org/licenses/MIT).
---

⭐ **Star this repo to support the project!**
