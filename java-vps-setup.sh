#!/usr/bin/env bash
# =============================================================================
# java-vps-setup.sh - one-shot setup of a fresh Ubuntu VPS for Java hosting
# Written for Ubuntu 24.04 LTS or newer on a clean server, run as root.
# STATUS: syntax-checked and tested against mocks only. Try it on a throwaway
# VPS first and read the script before you run it on anything that matters.
#
# Modes (MODE):
#   tomcat      -> Tomcat from the Ubuntu repositories (WAR apps), behind Nginx
#   springboot  -> a service for a JAR app (/opt/app/app.jar), behind Nginx
#                  (same mode for Spring Boot, Quarkus uber-jar and Micronaut; you can
#                   also pass MODE=quarkus / MODE=micronaut / MODE=jar)
#   wildfly     -> WildFly (Jakarta EE, EJB/JMS/CDI), latest release from GitHub
#   payara      -> Payara Server (Jakarta EE), from Maven Central
#   docker      -> Docker + Compose; you bring your own container image
#
# Extra variables for these modes:
#   WILDFLY_VERSION=42.0.0.Final     # empty = latest
#   PAYARA_MAJOR=7 PAYARA_VERSION=   # 7 (Jakarta EE 11) or 6; empty version = latest of that major
#   DOCKER_IMAGE=registry/image:tag  # empty = the container starts after the first 'deploy-app'
#
# Examples:
#   MODE=tomcat JAVA_VERSION=21 DOMAIN=example.com EMAIL=you@example.com \
#     SSH_PUBKEY="ssh-ed25519 AAAA... you@pc" bash java-vps-setup.sh
#
#   MODE=springboot JAVA_VERSION=21 DOMAIN=api.example.com EMAIL=you@example.com \
#     SSH_PUBKEY="ssh-ed25519 AAAA..." bash java-vps-setup.sh
#
# Optional (backup and monitoring):
#   RESTIC_REPOSITORY="sftp:user@backup.example.com:/backups/server1"
#   RESTIC_PASSWORD="a-strong-password"
#   MONITOR_IP="1.2.3.4"    # IP of your monitoring server (opens port 9100 for it only)
#
# Optional (database on the same VPS, listens on localhost ONLY):
#   DB_ENGINE=mysql         # mysql | mariadb | postgresql | none (default none)
#   DB_NAME=app DB_USER=app # database and user names (default "app")
#   DB_PASSWORD="..."       # if omitted a random password is generated
#   Credentials are written to /root/db-credentials.txt (root only).
#   Example: MODE=springboot DB_ENGINE=postgresql DOMAIN=api.example.com EMAIL=... bash java-vps-setup.sh
#
# IMPORTANT: do not close your existing SSH session until you have confirmed
# that key login works in a new one.
# =============================================================================
set -euo pipefail

# ---------- settings (override through the environment) ----------
MODE="${MODE:-tomcat}"                  # tomcat | springboot | wildfly | payara | docker
JAVA_VERSION="${JAVA_VERSION:-21}"      # 8, 11, 17, 21 ... (depends on the Ubuntu repo; unused for docker)
TOMCAT_PKG="${TOMCAT_PKG:-tomcat10}"    # tomcat9 | tomcat10 (depends on the Ubuntu release)
DOMAIN="${DOMAIN:-}"                    # if set (with EMAIL), a Let's Encrypt certificate is requested
EMAIL="${EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-admin}"       # administration user (sudo)
SSH_PUBKEY="${SSH_PUBKEY:-}"            # public SSH key; if given, SSH password login is disabled
APP_PORT="${APP_PORT:-8080}"            # port the application listens on (local only)
HEAP_PERCENT="${HEAP_PERCENT:-}"        # percent of RAM for the JVM heap (empty = auto: 60, or 45 with a database on the same VPS)
SWAP_MB="${SWAP_MB:-1024}"              # swap file size if there is no swap yet (0 = no swap)
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
MONITOR_IP="${MONITOR_IP:-}"
DB_ENGINE="${DB_ENGINE:-none}"          # none | mysql | mariadb | postgresql
DB_NAME="${DB_NAME:-app}"
DB_USER="${DB_USER:-app}"
DB_PASSWORD="${DB_PASSWORD:-}"          # empty = random password
DB_SUMMARY="not installed"
WILDFLY_VERSION="${WILDFLY_VERSION:-}"  # e.g. 42.0.0.Final; empty = latest
PAYARA_MAJOR="${PAYARA_MAJOR:-7}"       # 7 (Jakarta EE 11) or 6
PAYARA_VERSION="${PAYARA_VERSION:-}"    # e.g. 7.2026.10; empty = latest of PAYARA_MAJOR
DOCKER_IMAGE="${DOCKER_IMAGE:-}"        # your image, e.g. ghcr.io/company/app:1.0
JAVA_INFO="inside the container (from the image)"

if [[ -z "$HEAP_PERCENT" ]]; then
  if [[ "$DB_ENGINE" == "none" ]]; then HEAP_PERCENT=60; else HEAP_PERCENT=45; fi
fi

LOG_FILE="/var/log/java-vps-setup.log"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------- helper functions ----------
log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die()  { echo -e "\n[x] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
case "$MODE" in
  quarkus|micronaut|jar) MODE="springboot" ;;   # they run as a plain JAR
esac
[[ "$MODE" =~ ^(tomcat|springboot|wildfly|payara|docker)$ ]] || die "MODE must be: tomcat, springboot, wildfly, payara or docker."
[[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] || die "JAVA_VERSION must be a number (e.g. 17 or 21)."
[[ "$PAYARA_MAJOR" =~ ^[0-9]+$ ]] || die "PAYARA_MAJOR must be a number (6 or 7)."
[[ -z "$WILDFLY_VERSION" || "$WILDFLY_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "WILDFLY_VERSION contains invalid characters."
[[ -z "$PAYARA_VERSION"  || "$PAYARA_VERSION"  =~ ^[0-9A-Za-z._-]+$ ]] || die "PAYARA_VERSION contains invalid characters."
[[ -z "$DOCKER_IMAGE"    || "$DOCKER_IMAGE"    =~ ^[A-Za-z0-9._:/@-]+$ ]] || die "DOCKER_IMAGE contains invalid characters."
[[ "$HEAP_PERCENT" =~ ^[0-9]+$ ]] && (( HEAP_PERCENT >= 20 && HEAP_PERCENT <= 85 )) || die "HEAP_PERCENT must be between 20 and 85."
case "$DB_ENGINE" in
  none|mysql|mariadb|postgresql) ;;
  *) die "DB_ENGINE must be: none, mysql, mariadb or postgresql." ;;
esac
[[ "$DB_NAME" =~ ^[A-Za-z][A-Za-z0-9_]{0,31}$ ]] || die "DB_NAME may contain only letters, digits and _ (max 32, starts with a letter)."
[[ "$DB_USER" =~ ^[A-Za-z][A-Za-z0-9_]{0,31}$ ]] || die "DB_USER may contain only letters, digits and _ (max 32, starts with a letter)."
if [[ -n "$DB_PASSWORD" ]]; then
  [[ "$DB_PASSWORD" =~ ^[A-Za-z0-9_.+=@-]{12,}$ ]] || die "DB_PASSWORD: at least 12 characters, allowed A-Z a-z 0-9 _ . + = @ - (or leave empty for a random one)."
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

. /etc/os-release
log "System: ${PRETTY_NAME} | MODE=${MODE} | Java=${JAVA_VERSION}"

TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
HEAP_MB=$(( TOTAL_MB * HEAP_PERCENT / 100 ))
(( HEAP_MB >= 128 )) || HEAP_MB=128
XMS_MB=$(( HEAP_MB / 2 ))
log "RAM: ${TOTAL_MB} MB -> JVM heap: ${HEAP_MB} MB (Xms ${XMS_MB} MB)"

# ---------- 1. base packages and automatic security updates ----------
base_setup() {
  log "Updating the system and installing base packages"
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y curl wget ca-certificates gnupg ufw fail2ban unattended-upgrades \
                     htop nano unzip nginx

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades
}

# ---------- 2. swap ----------
swap_setup() {
  if (( SWAP_MB > 0 )) && [[ -z "$(swapon --show --noheadings)" ]]; then
    log "Creating ${SWAP_MB} MB of swap"
    fallocate -l "${SWAP_MB}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null
  else
    log "Swap already exists or is disabled - skipping"
  fi
}

# ---------- 3. admin user and SSH ----------
ssh_setup() {
  if [[ -z "$SSH_PUBKEY" ]]; then
    warn "SSH_PUBKEY not set - SSH is left as it is (password login allowed). Recommended: pass a key."
    return
  fi
  log "Creating user '${ADMIN_USER}' and enabling key-only login"
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
  echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${ADMIN_USER}"
  chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"

  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
  grep -qxF "$SSH_PUBKEY" "/home/${ADMIN_USER}/.ssh/authorized_keys" 2>/dev/null \
    || echo "$SSH_PUBKEY" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"

  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 4
EOF
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
  else
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    warn "sshd configuration failed validation - reverted."
  fi
}

# ---------- 4. firewall and fail2ban ----------
firewall_setup() {
  log "Firewall (UFW) i fail2ban"
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  if [[ -n "$MONITOR_IP" ]]; then
    ufw allow from "$MONITOR_IP" to any port 9100 proto tcp
  fi
  ufw --force enable

  cat > /etc/fail2ban/jail.d/sshd-local.conf <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

# ---------- 5. Java ----------
java_setup() {
  log "Installing OpenJDK ${JAVA_VERSION}"
  if ! apt-get install -y "openjdk-${JAVA_VERSION}-jdk-headless"; then
    echo "Available versions:"
    apt-cache search --names-only '^openjdk-[0-9]+-jdk-headless$' || true
    die "openjdk-${JAVA_VERSION}-jdk-headless is not available in this Ubuntu release."
  fi
  JAVA_HOME_DIR="$(ls -d /usr/lib/jvm/java-${JAVA_VERSION}-openjdk-* | head -n1)"
  update-alternatives --set java "${JAVA_HOME_DIR}/bin/java" || true
  JAVA_INFO="$(${JAVA_HOME_DIR}/bin/java -version 2>&1 | head -n1)"
  log "Java: ${JAVA_INFO}"
}

# ---------- 6a. Tomcat mode ----------
tomcat_setup() {
  log "Installing ${TOMCAT_PKG}"
  apt-get install -y "$TOMCAT_PKG"

  local defaults="/etc/default/${TOMCAT_PKG}"
  {
    echo ""
    echo "# --- added by java-vps-setup.sh ---"
    echo "JAVA_HOME=${JAVA_HOME_DIR}"
    echo "JAVA_OPTS=\"-Djava.awt.headless=true -Xms${XMS_MB}m -Xmx${HEAP_MB}m -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError\""
  } >> "$defaults"

  local server_xml="/etc/${TOMCAT_PKG}/server.xml"
  if [[ -f "$server_xml" ]]; then
    # Tomcat listens locally only; the outside world goes through Nginx
    if ! grep -q 'address="127.0.0.1"' "$server_xml"; then
      sed -i "0,/<Connector port=\"8080\"/s//<Connector port=\"8080\" address=\"127.0.0.1\"/" "$server_xml"
    fi
    # Correct client IPs and https behind the proxy
    if ! grep -q 'RemoteIpValve' "$server_xml"; then
      sed -i 's#</Host>#  <Valve className="org.apache.catalina.valves.RemoteIpValve" />\n      </Host>#' "$server_xml"
    fi
  fi

  systemctl enable "$TOMCAT_PKG"
  systemctl restart "$TOMCAT_PKG"
  APP_PORT=8080
  log "Tomcat webapps folder: /var/lib/${TOMCAT_PKG}/webapps (copy WAR files here)"
}

# ---------- helper: application port and address through environment variables ----------
# Spring Boot, Quarkus and Micronaut read these variables, so one mechanism fits all.
app_port_env() {
  cat <<EOF
SERVER_PORT=${APP_PORT}
SERVER_ADDRESS=127.0.0.1
QUARKUS_HTTP_PORT=${APP_PORT}
QUARKUS_HTTP_HOST=127.0.0.1
MICRONAUT_SERVER_PORT=${APP_PORT}
MICRONAUT_SERVER_HOST=127.0.0.1
EOF
}

# ---------- helper: download with checksum verification (sha1) ----------
download_verified() {   # $1 = url, $2 = output file, $3 = url of the .sha1 (optional)
  curl -fSL --retry 3 "$1" -o "$2"
  if [[ -n "${3:-}" ]]; then
    local expected
    expected="$(curl -fsSL "$3" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ -n "$expected" ]]; then
      echo "${expected}  $2" | sha1sum -c - >/dev/null || die "Checksum mismatch for $1"
      log "Checksum OK ($(basename "$2"))"
    else
      warn "No checksum available for $1 - skipping verification."
    fi
  fi
}

# ---------- 6b. JAR mode (Spring Boot / Quarkus uber-jar / Micronaut) ----------
springboot_setup() {
  log "Preparing the service for a JAR application"
  id app >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/app --shell /usr/sbin/nologin app
  install -d -o app -g app -m 750 /opt/app

  {
    echo "JAVA_OPTS=-Xms${XMS_MB}m -Xmx${HEAP_MB}m -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError"
    app_port_env
    echo "# Add your own variables here, for example:"
    echo "# SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/dbname"
  } > /etc/app.env
  chmod 640 /etc/app.env
  chown root:app /etc/app.env

  cat > /etc/systemd/system/app.service <<EOF
[Unit]
Description=Java application
After=network.target

[Service]
User=app
Group=app
WorkingDirectory=/opt/app
EnvironmentFile=-/etc/app.env
ExecStart=${JAVA_HOME_DIR}/bin/java \$JAVA_OPTS -jar /opt/app/app.jar
SuccessExitStatus=143
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /usr/local/bin/deploy-app <<'EOF'
#!/usr/bin/env bash
# Usage: sudo deploy-app /path/to/new.jar
set -euo pipefail
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: deploy-app new.jar"; exit 1; }
[[ -f /opt/app/app.jar ]] && cp /opt/app/app.jar /opt/app/app.jar.prev
install -o app -g app -m 640 "$1" /opt/app/app.jar
systemctl restart app
sleep 3
systemctl --no-pager --lines=15 status app || true
EOF
  chmod +x /usr/local/bin/deploy-app

  systemctl daemon-reload
  systemctl enable app
  if [[ -f /opt/app/app.jar ]]; then
    systemctl restart app
  else
    warn "No /opt/app/app.jar yet - the service will start after the first 'sudo deploy-app new.jar'."
  fi
}

# ---------- 6d. WildFly mode ----------
wildfly_setup() {
  log "Installing WildFly"
  if (( JAVA_VERSION < 17 )); then
    warn "Recent WildFly releases need Java 17+ (JAVA_VERSION=${JAVA_VERSION})."
  fi

  local ver="$WILDFLY_VERSION"
  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/wildfly/wildfly/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
  fi
  [[ -n "$ver" ]] || die "Cannot determine the WildFly version. Set e.g. WILDFLY_VERSION=42.0.0.Final"
  log "WildFly ${ver}"

  local tmp; tmp="$(mktemp -d)"
  download_verified "https://github.com/wildfly/wildfly/releases/download/${ver}/wildfly-${ver}.tar.gz" \
                    "${tmp}/wildfly.tar.gz" \
                    "https://downloads.jboss.org/wildfly/${ver}/wildfly-${ver}.tar.gz.sha1"
  tar -xzf "${tmp}/wildfly.tar.gz" -C "$tmp"
  [[ -d "${tmp}/wildfly-${ver}" ]] || die "Unexpected WildFly archive layout."
  rm -rf "/opt/wildfly-${ver}"
  mv "${tmp}/wildfly-${ver}" "/opt/wildfly-${ver}"
  ln -sfn "/opt/wildfly-${ver}" /opt/wildfly
  rm -rf "$tmp"

  id wildfly >/dev/null 2>&1 || useradd --system --home-dir /opt/wildfly --shell /usr/sbin/nologin wildfly
  chown -R wildfly:wildfly "/opt/wildfly-${ver}"

  # Proxy address forwarding (Nginx) and root context: remove the default welcome page
  cat > /tmp/wildfly-setup.cli <<'EOF'
embed-server --std-out=echo
/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding, value=true)
/subsystem=undertow/server=default-server/host=default-host/location=\/:remove
stop-embedded-server
EOF
  chown wildfly:wildfly /tmp/wildfly-setup.cli
  (cd /tmp && runuser -u wildfly -- env JAVA_HOME="$JAVA_HOME_DIR" /opt/wildfly/bin/jboss-cli.sh --file=/tmp/wildfly-setup.cli) \
    || warn "The WildFly CLI step did not finish (check ROOT.war as the root context and proxy-address-forwarding)."
  rm -f /tmp/wildfly-setup.cli

  cat > /etc/systemd/system/wildfly.service <<EOF
[Unit]
Description=WildFly
After=network.target

[Service]
User=wildfly
Group=wildfly
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment="JAVA_OPTS=-Xms${XMS_MB}m -Xmx${HEAP_MB}m -XX:MetaspaceSize=96m -XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv4Stack=true -Djboss.modules.system.pkgs=org.jboss.byteman -Djava.awt.headless=true"
ExecStart=/opt/wildfly/bin/standalone.sh -b 127.0.0.1 -bmanagement 127.0.0.1
SuccessExitStatus=143
Restart=on-failure
RestartSec=5
LimitNOFILE=102642

[Install]
WantedBy=multi-user.target
EOF

  cat > /usr/local/bin/deploy-app <<'EOF'
#!/usr/bin/env bash
# Usage: sudo deploy-app /path/to/app.war   (deployed as ROOT.war = the domain root)
set -euo pipefail
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: deploy-app app.war"; exit 1; }
install -o wildfly -g wildfly -m 640 "$1" /opt/wildfly/standalone/deployments/ROOT.war
sleep 5
ls -l /opt/wildfly/standalone/deployments/ | grep -E 'ROOT\.war\.(deployed|failed|isdeploying)' || echo "No status yet - check: journalctl -u wildfly -n 50"
EOF
  chmod +x /usr/local/bin/deploy-app

  APP_PORT=8080
  systemctl daemon-reload
  systemctl enable --now wildfly
  log "WildFly started. The admin console (9990) is local only: use an SSH tunnel (ssh -L 9990:127.0.0.1:9990 ...). Add a user with /opt/wildfly/bin/add-user.sh"
}

# ---------- 6e. Payara mode ----------
payara_setup() {
  log "Installing Payara Server (major ${PAYARA_MAJOR})"
  if (( PAYARA_MAJOR >= 7 && JAVA_VERSION < 21 )); then
    warn "Payara 7 (Jakarta EE 11) probably needs Java 21 or newer (JAVA_VERSION=${JAVA_VERSION}). Check the docs or set PAYARA_MAJOR=6."
  fi

  local ver="$PAYARA_VERSION"
  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://repo1.maven.org/maven2/fish/payara/distributions/payara/maven-metadata.xml \
           | grep -oE "<version>${PAYARA_MAJOR}\.[0-9.]+</version>" | sed -E 's#</?version>##g' | sort -V | tail -n1 || true)"
  fi
  [[ -n "$ver" ]] || die "Cannot determine the Payara version. Set e.g. PAYARA_VERSION=7.2026.10"
  log "Payara ${ver}"

  local url="https://repo1.maven.org/maven2/fish/payara/distributions/payara/${ver}/payara-${ver}.zip"
  local tmp; tmp="$(mktemp -d)"
  download_verified "$url" "${tmp}/payara.zip" "${url}.sha1"
  unzip -q "${tmp}/payara.zip" -d "${tmp}/x"
  local top; top="$(find "${tmp}/x" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$top" ]] || die "Unexpected Payara archive layout."
  rm -rf "/opt/payara-${ver}"
  mv "$top" "/opt/payara-${ver}"
  ln -sfn "/opt/payara-${ver}" /opt/payara
  rm -rf "$tmp"

  id payara >/dev/null 2>&1 || useradd --system --home-dir /opt/payara --shell /usr/sbin/nologin payara
  chown -R payara:payara "/opt/payara-${ver}"

  local dx="/opt/payara/glassfish/domains/domain1/config/domain.xml"
  if [[ -f "$dx" ]]; then
    sed -i -E "s#<jvm-options>-Xmx[0-9]+[mMgG]</jvm-options>#<jvm-options>-Xmx${HEAP_MB}m</jvm-options>#g" "$dx"
    grep -q "<jvm-options>-Xmx${HEAP_MB}m</jvm-options>" "$dx" \
      || warn "No -Xmx found in domain.xml - set the heap by hand: asadmin create-jvm-options -Xmx${HEAP_MB}m"
    # HTTP and admin listeners on localhost only; the outside world goes through Nginx
    # (replace an existing address attribute, or add one: a duplicate attribute breaks the XML)
    sed -i -E '/<network-listener .*name="(http-listener-1|admin-listener)"/{ s# address="[^"]*"##g; s#<network-listener #<network-listener address="127.0.0.1" #; }' "$dx"
  else
    warn "domain.xml not found (${dx}) - set the heap and listener addresses by hand."
  fi

  install -d -o payara -g payara -m 750 /var/lib/payara-deploy

  cat > /etc/systemd/system/payara.service <<EOF
[Unit]
Description=Payara Server (domain1)
After=network.target

[Service]
User=payara
Group=payara
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment=AS_JAVA=${JAVA_HOME_DIR}
ExecStart=/opt/payara/bin/asadmin start-domain --verbose domain1
ExecStop=/opt/payara/bin/asadmin stop-domain domain1
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  cat > /usr/local/bin/deploy-app <<'EOF'
#!/usr/bin/env bash
# Usage: sudo deploy-app /path/to/app.war   (deployed at the root context "/")
set -euo pipefail
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: deploy-app app.war"; exit 1; }
install -o payara -g payara -m 640 "$1" /var/lib/payara-deploy/app.war
# Payara needs a minute after the first start: wait for the admin port (4848), up to 2 minutes
for _ in $(seq 1 60); do
  (exec 3<>/dev/tcp/127.0.0.1/4848) 2>/dev/null && break
  sleep 2
done
cd /tmp
runuser -u payara -- /opt/payara/bin/asadmin deploy --force=true --contextroot / --name app /var/lib/payara-deploy/app.war
EOF
  chmod +x /usr/local/bin/deploy-app

  APP_PORT=8080
  systemctl daemon-reload
  systemctl enable --now payara
  log "Payara started (the first start can take a minute or two). The admin console (4848) is local only: use an SSH tunnel."
}

# ---------- 6f. Docker mode ----------
docker_setup() {
  log "Installing Docker"
  apt-get install -y docker.io
  apt-get install -y docker-compose-v2 \
    || apt-get install -y docker-compose-plugin \
    || warn "Docker Compose could not be installed from the Ubuntu repositories - install it by hand."

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl enable docker
  systemctl restart docker

  install -d -m 750 /opt/docker-app
  local mem_mb=$(( HEAP_MB * 5 / 4 ))

  {
    echo "# Environment variables for the container (env_file in /opt/docker-app/compose.yaml)"
    app_port_env
    echo "# Add your own variables here"
  } > /etc/app.env
  chmod 600 /etc/app.env

  echo "IMAGE=${DOCKER_IMAGE}" > /opt/docker-app/.env

  # network_mode: host -> the app listens on 127.0.0.1:${APP_PORT}, UFW still applies,
  # and a database on the same server (localhost) is reachable from the container.
  cat > /opt/docker-app/compose.yaml <<EOF
services:
  app:
    image: "\${IMAGE:?Set IMAGE in /opt/docker-app/.env or run deploy-app}"
    restart: unless-stopped
    network_mode: host
    env_file:
      - /etc/app.env
    environment:
      JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
    mem_limit: ${mem_mb}m
EOF

  cat > /usr/local/bin/deploy-app <<'EOF'
#!/usr/bin/env bash
# Usage: sudo deploy-app registry/image:tag
set -euo pipefail
[[ $# -eq 1 && "$1" =~ ^[A-Za-z0-9._:/@-]+$ ]] || { echo "Usage: deploy-app registry/image:tag"; exit 1; }
cd /opt/docker-app
sed -i "s|^IMAGE=.*|IMAGE=$1|" .env
docker compose pull
docker compose up -d
docker compose ps
EOF
  chmod +x /usr/local/bin/deploy-app

  if [[ -n "$DOCKER_IMAGE" && "$DB_ENGINE" == "none" ]]; then
    (cd /opt/docker-app && docker compose up -d)
  elif [[ -z "$DOCKER_IMAGE" ]]; then
    warn "DOCKER_IMAGE not set - the container will start after: sudo deploy-app registry/image:tag (private registry: docker login first)"
  fi
}

# ---------- 6c. database (optional) ----------
db_setup() {
  [[ "$DB_ENGINE" != "none" ]] || { log "No database requested (DB_ENGINE=none)"; return; }
  log "Installing the database: ${DB_ENGINE}"

  if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(openssl rand -hex 16)"
  fi

  local bp=$(( TOTAL_MB * 15 / 100 ))
  (( bp >= 64 )) || bp=64
  local jdbc_url="" port=""

  case "$DB_ENGINE" in
    mysql|mariadb)
      local pkg="mysql-server" svc="mysql" jdbc="mysql"
      if [[ "$DB_ENGINE" == "mariadb" ]]; then pkg="mariadb-server"; svc="mariadb"; jdbc="mariadb"; fi
      apt-get install -y "$pkg"
      mkdir -p /etc/mysql/conf.d
      cat > /etc/mysql/conf.d/99-javahost.cnf <<EOF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = ${bp}M
character-set-server = utf8mb4
EOF
      systemctl enable "$svc"
      systemctl restart "$svc"
      mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
      port=3306
      jdbc_url="jdbc:${jdbc}://localhost:${port}/${DB_NAME}"

      cat > /usr/local/bin/db-dump <<'EOF'
#!/usr/bin/env bash
# Daily dump of all databases to /var/backups/db (kept for 3 days)
set -euo pipefail
install -d -m 700 /var/backups/db
mysqldump --single-transaction --routines --events --all-databases | gzip > "/var/backups/db/all-$(date +%F).sql.gz"
find /var/backups/db -name 'all-*.sql.gz' -mtime +3 -delete
EOF
      ;;

    postgresql)
      apt-get install -y postgresql
      systemctl enable --now postgresql
      local d
      for d in /etc/postgresql/*/main/conf.d; do
        [[ -d "$d" ]] || continue
        cat > "${d}/99-javahost.conf" <<EOF
listen_addresses = 'localhost'
shared_buffers = ${bp}MB
EOF
      done
      systemctl restart postgresql

      pg() { (cd /tmp && runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"); }
      if pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
        pg -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}'"
      else
        pg -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}'"
      fi
      if ! pg -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
        pg -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8'"
      fi
      port=5432
      jdbc_url="jdbc:postgresql://localhost:${port}/${DB_NAME}"

      cat > /usr/local/bin/db-dump <<'EOF'
#!/usr/bin/env bash
# Daily dump of all databases to /var/backups/db (kept for 3 days)
set -euo pipefail
install -d -m 700 /var/backups/db
(cd /tmp && runuser -u postgres -- pg_dumpall) | gzip > "/var/backups/db/all-$(date +%F).sql.gz"
find /var/backups/db -name 'all-*.sql.gz' -mtime +3 -delete
EOF
      ;;
  esac

  chmod +x /usr/local/bin/db-dump
  echo '30 2 * * * root /usr/local/bin/db-dump' > /etc/cron.d/db-dump
  chmod 644 /etc/cron.d/db-dump

  install -m 600 /dev/null /root/db-credentials.txt
  cat > /root/db-credentials.txt <<EOF
Engine:   ${DB_ENGINE}
Database: ${DB_NAME}
User:     ${DB_USER}
Password: ${DB_PASSWORD}
Host:     localhost (the database listens locally only, port ${port} is not open to the outside)
JDBC:     ${jdbc_url}
Dump:     /usr/local/bin/db-dump  (daily at 02:30 -> /var/backups/db)
EOF

  # JAR and Docker mode: connection settings go into /etc/app.env
  if [[ -f /etc/app.env ]]; then
    cat >> /etc/app.env <<EOF
SPRING_DATASOURCE_URL=${jdbc_url}
SPRING_DATASOURCE_USERNAME=${DB_USER}
SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
EOF
    case "$MODE" in
      springboot) if [[ -f /opt/app/app.jar ]]; then systemctl restart app; fi ;;
      docker)     if [[ -n "$DOCKER_IMAGE" ]]; then (cd /opt/docker-app && docker compose up -d --force-recreate); fi ;;
    esac
  fi

  DB_SUMMARY="${DB_ENGINE} | database '${DB_NAME}', user '${DB_USER}' | credentials: /root/db-credentials.txt"
  log "Database ready. Credentials: /root/db-credentials.txt"
}

# ---------- 7. Nginx reverse proxy + SSL ----------
nginx_setup() {
  log "Nginx reverse proxy to 127.0.0.1:${APP_PORT}"
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/java-app <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN:-_};

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/java-app /etc/nginx/sites-enabled/java-app
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ -n "$DOMAIN" && -n "$EMAIL" ]]; then
    log "Let's Encrypt certificate for ${DOMAIN}"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect \
      || warn "Certbot failed (check that DNS for ${DOMAIN} points to this server). Run later: certbot --nginx -d ${DOMAIN}"
  else
    warn "DOMAIN/EMAIL not set - skipping SSL."
  fi
}

# ---------- 8. backup (restic) - optional ----------
backup_setup() {
  [[ -n "$RESTIC_REPOSITORY" && -n "$RESTIC_PASSWORD" ]] || { log "Backup not configured (RESTIC_* not set)"; return; }
  log "Configuring restic backups"
  apt-get install -y restic

  cat > /etc/restic.env <<EOF
RESTIC_REPOSITORY=${RESTIC_REPOSITORY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
EOF
  chmod 600 /etc/restic.env

  local paths="/etc"
  case "$MODE" in
    tomcat)     paths="/etc /var/lib/${TOMCAT_PKG}/webapps" ;;
    springboot) paths="/etc /opt/app" ;;
    wildfly)    paths="/etc /opt/wildfly/standalone/deployments /opt/wildfly/standalone/configuration /opt/wildfly/standalone/data" ;;
    payara)     paths="/etc /opt/payara/glassfish/domains/domain1 /var/lib/payara-deploy" ;;
    docker)     paths="/etc /opt/docker-app" ;;
  esac
  local dump_pre=""
  if [[ "$DB_ENGINE" != "none" ]]; then
    paths="${paths} /var/backups/db"
    dump_pre="ExecStartPre=/usr/local/bin/db-dump"
  fi
  cat > /etc/systemd/system/restic-backup.service <<EOF
[Unit]
Description=Restic backup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic.env
${dump_pre}
ExecStart=/bin/sh -c 'restic snapshots >/dev/null 2>&1 || restic init'
ExecStart=/bin/sh -c 'restic backup ${paths} --exclude-if-present .nobackup'
ExecStart=/bin/sh -c 'restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune'
EOF

  cat > /etc/systemd/system/restic-backup.timer <<'EOF'
[Unit]
Description=Daily restic backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now restic-backup.timer
  log "Test backup: systemctl start restic-backup.service"
}

# ---------- 9. monitoring (node exporter) - optional ----------
monitoring_setup() {
  [[ -n "$MONITOR_IP" ]] || return 0
  log "Installing prometheus-node-exporter (port 9100 open only for ${MONITOR_IP})"
  apt-get install -y prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter
}

# ---------- run ----------
base_setup
swap_setup
ssh_setup
firewall_setup
if [[ "$MODE" != "docker" ]]; then java_setup; fi
case "$MODE" in
  tomcat)     tomcat_setup ;;
  springboot) springboot_setup ;;
  wildfly)    wildfly_setup ;;
  payara)     payara_setup ;;
  docker)     docker_setup ;;
esac
db_setup
nginx_setup
backup_setup
monitoring_setup

log "DONE"
cat <<EOF

--------------------------------------------------------------
 Mode:       ${MODE}
 Java:       ${JAVA_INFO}
 JVM heap:   ${HEAP_MB} MB of ${TOTAL_MB} MB RAM
 Domain:     ${DOMAIN:-not set}
 Database:   ${DB_SUMMARY}
 Log:       ${LOG_FILE}

 Next steps:
   tomcat:     copy WAR files to /var/lib/${TOMCAT_PKG}/webapps/ (ROOT.war for the domain root)
   springboot: sudo deploy-app /path/to/app.jar      (Spring Boot, Quarkus uber-jar, Micronaut)
   wildfly:    sudo deploy-app /path/to/app.war      (becomes ROOT.war = the domain root)
   payara:     sudo deploy-app /path/to/app.war      (context root "/")
   docker:     sudo deploy-app registry/image:tag    (private registry: docker login first)
   SSH:        ${SSH_PUBKEY:+ssh ${ADMIN_USER}@<IP>  (check in a NEW session before you close the old one)}
--------------------------------------------------------------
EOF
