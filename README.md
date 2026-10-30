# java-vps-setup

One script that turns a fresh Ubuntu VPS into a Java hosting server: OpenJDK, an application server or a JAR service, Nginx with a free Let's Encrypt certificate, firewall, optional database and optional backups.

> **Status:** the script is syntax-checked and was tested against mocks. It has **not** been battle-tested on many real servers. Read it, try it on a throwaway VPS first, and keep your current SSH session open until you have confirmed that key login works.

## What it does

- Updates the system, enables automatic security updates
- Creates a swap file if the server has none, sets `vm.swappiness=10`
- Optionally creates an admin user and switches SSH to key-only login
- Configures UFW (22, 80, 443) and Fail2ban
- Installs OpenJDK 8, 11, 17 or 21 (whatever your Ubuntu release offers)
- Sizes the JVM heap from RAM: 60% of RAM, or 45% when a database runs on the same server
- Installs one of five modes, always listening on `127.0.0.1` behind Nginx:

| Mode | What you get | Deploy command |
|---|---|---|
| `tomcat` | Tomcat 9 or 10 from Ubuntu packages | copy a WAR to `/var/lib/tomcat10/webapps/` |
| `springboot` | systemd service for a JAR (Spring Boot, Quarkus uber-jar, Micronaut) | `sudo deploy-app app.jar` |
| `wildfly` | WildFly standalone, latest release | `sudo deploy-app app.war` |
| `payara` | Payara Server 7 (Jakarta EE 11) or 6 | `sudo deploy-app app.war` |
| `docker` | Docker + Compose, your own image | `sudo deploy-app registry/image:tag` |

- Optionally installs MySQL, MariaDB or PostgreSQL, bound to localhost, with a random password in `/root/db-credentials.txt` and a daily dump
- Optionally sets up encrypted daily backups with restic (7 daily, 4 weekly, 6 monthly)
- Optionally installs Prometheus node exporter, reachable only from your monitoring IP

## Usage

Run as root on a clean Ubuntu 24.04 or newer server:

```bash
curl -fsSLO https://raw.githubusercontent.com/scvetic-ui/java-vps-setup/main/java-vps-setup.sh
less java-vps-setup.sh     # read it first

MODE=springboot JAVA_VERSION=21 DOMAIN=api.example.com EMAIL=you@example.com \
  SSH_PUBKEY="ssh-ed25519 AAAA... you@pc" bash java-vps-setup.sh
```

More examples:

```bash
# Tomcat with PostgreSQL
MODE=tomcat JAVA_VERSION=21 DB_ENGINE=postgresql DOMAIN=example.com EMAIL=you@example.com bash java-vps-setup.sh

# WildFly (latest) on Java 21
MODE=wildfly JAVA_VERSION=21 DOMAIN=example.com EMAIL=you@example.com bash java-vps-setup.sh

# Payara 6 on Java 17
MODE=payara PAYARA_MAJOR=6 JAVA_VERSION=17 DOMAIN=example.com EMAIL=you@example.com bash java-vps-setup.sh

# Docker with your own image
MODE=docker DOCKER_IMAGE=ghcr.io/company/app:1.0 DOMAIN=example.com EMAIL=you@example.com bash java-vps-setup.sh
```

Point the DNS A record of `DOMAIN` at the server before you run it, or the certificate step will fail (you can run `certbot --nginx -d your.domain` later).

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `MODE` | `tomcat` | `tomcat`, `springboot`, `wildfly`, `payara`, `docker` (`quarkus`, `micronaut`, `jar` = `springboot`) |
| `JAVA_VERSION` | `21` | OpenJDK major version (not used for `docker`) |
| `TOMCAT_PKG` | `tomcat10` | `tomcat9` or `tomcat10` |
| `DOMAIN`, `EMAIL` | empty | Both set: request a Let's Encrypt certificate |
| `ADMIN_USER`, `SSH_PUBKEY` | `admin`, empty | With a key: create the user and disable password login |
| `APP_PORT` | `8080` | Local port of the application |
| `HEAP_PERCENT` | auto | Percent of RAM for the heap (20 to 85) |
| `SWAP_MB` | `1024` | Swap size when none exists, `0` to skip |
| `DB_ENGINE` | `none` | `mysql`, `mariadb`, `postgresql`, `none` |
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`, `app`, random | Database settings |
| `WILDFLY_VERSION` | latest | for example `42.0.0.Final` |
| `PAYARA_MAJOR`, `PAYARA_VERSION` | `7`, latest | Payara line and exact version |
| `DOCKER_IMAGE` | empty | Image to run in `docker` mode |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | empty | Enable nightly restic backups |
| `MONITOR_IP` | empty | Install node exporter and open port 9100 for this IP only |

## Good to know

- Everything the script prints is also written to `/var/log/java-vps-setup.log`.
- Application ports, the WildFly management port (9990) and the Payara admin port (4848) are bound to localhost. Use an SSH tunnel to reach the consoles.
- Running it twice is mostly safe but not guaranteed to be idempotent: it was written for a fresh server.
- Passwords are never printed to the log. Database credentials are in `/root/db-credentials.txt` (mode 600). The restic password is stored in `/etc/restic.env` (mode 600): keep a copy elsewhere.

## Guides

Step-by-step guides for each stack, written alongside the script: <https://www.superjavahost.com/guides>. A JVM heap calculator is at <https://www.superjavahost.com/tools/jvm-heap-calculator>.

Don't want to run any of this yourself? [Super Java Host](https://www.superjavahost.com) sets it up for you or runs it for you.

## License

MIT, see `LICENSE`.
