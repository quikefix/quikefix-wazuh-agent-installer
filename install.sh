#!/usr/bin/env bash
#
# QuikeFix Wazuh Agent Universal Installer - Linux
# Repository: quikefix/quikefix-wazuh-agent-installer
#

set -u
set -o pipefail

# ============================================================
# CONFIGURATION
# ============================================================

WAZUH_MANAGER="${WAZUH_MANAGER:-wazuh-agent.quikefix.info}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname -s 2>/dev/null || hostname)}"
WAZUH_REPO="https://packages.wazuh.com/4.x/apt/"
WAZUH_KEY_URL="https://packages.wazuh.com/key/GPG-KEY-WAZUH"

LOG_FILE="/var/log/quikefix-wazuh-install.log"
OSSEC_CONF="/var/ossec/etc/ossec.conf"

PLAN_USED="None"

# ============================================================
# OUTPUT
# ============================================================

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
blue='\033[0;34m'
reset='\033[0m'

log() {
    echo -e "$*" | tee -a "$LOG_FILE"
}

ok() {
    log "${green}[PASS]${reset} $*"
}

warn() {
    log "${yellow}[WARN]${reset} $*"
}

fail() {
    log "${red}[FAIL]${reset} $*"
}

info() {
    log "${blue}[INFO]${reset} $*"
}

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this installer as root or with sudo."
    exit 1
fi

touch "$LOG_FILE" 2>/dev/null || {
    echo "Unable to create $LOG_FILE"
    exit 1
}

log ""
log "============================================================"
log " QUIKEFIX WAZUH AGENT INSTALLER"
log "============================================================"
log "Started      : $(date)"
log "Hostname     : $(hostname)"
log "Agent Name   : $WAZUH_AGENT_NAME"
log "Manager      : $WAZUH_MANAGER"
log "============================================================"

# ============================================================
# OS DETECTION
# ============================================================

if [ ! -r /etc/os-release ]; then
    fail "Cannot determine Linux distribution."
    exit 1
fi

. /etc/os-release

OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

info "Operating system: ${PRETTY_NAME:-$OS_ID}"
info "Architecture: $ARCH"

case "$OS_ID" in
    ubuntu|debian)
        ok "Supported Debian-family operating system detected."
        ;;
    *)
        fail "V1 currently supports Ubuntu and Debian."
        fail "Detected: $OS_ID $OS_VERSION"
        exit 1
        ;;
esac

# ============================================================
# REQUIRED COMMANDS
# ============================================================

info "Checking prerequisites..."

export DEBIAN_FRONTEND=noninteractive

apt-get update >>"$LOG_FILE" 2>&1 || warn "Initial apt update returned an error."

REQUIRED_PACKAGES=(
    curl
    ca-certificates
    gnupg
    netcat-openbsd
)

for package in "${REQUIRED_PACKAGES[@]}"; do

    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
       grep -q "install ok installed"; then

        ok "$package already installed."

    else

        info "Installing prerequisite: $package"

        if apt-get install -y "$package" >>"$LOG_FILE" 2>&1; then
            ok "$package installed."
        else
            fail "Could not install prerequisite: $package"
        fi

    fi

done

# ============================================================
# DNS TEST
# ============================================================

info "Testing manager DNS..."

if getent ahostsv4 "$WAZUH_MANAGER" >/dev/null 2>&1; then

    MANAGER_IP="$(getent ahostsv4 "$WAZUH_MANAGER" |
                  awk 'NR==1 {print $1}')"

    ok "$WAZUH_MANAGER resolves to $MANAGER_IP"

else

    fail "DNS resolution failed for $WAZUH_MANAGER"
    exit 1

fi

# ============================================================
# NETWORK TEST
# ============================================================

test_port() {

    local port="$1"

    if nc -z -w5 "$WAZUH_MANAGER" "$port" >/dev/null 2>&1; then
        ok "TCP $port reachable."
        return 0
    else
        warn "TCP $port is not currently reachable."
        return 1
    fi
}

test_port 1514 || true
test_port 1515 || true

# ============================================================
# EXISTING AGENT
# ============================================================

if dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null |
   grep -q "install ok installed"; then

    ok "Existing Wazuh agent detected."

else

    info "Wazuh agent is not currently installed."

fi

# ============================================================
# PLAN A
# OFFICIAL WAZUH APT REPOSITORY
# ============================================================

install_plan_a() {

    info "PLAN A: Installing through official Wazuh repository."

    mkdir -p /usr/share/keyrings

    rm -f /usr/share/keyrings/wazuh.gpg.tmp

    if ! curl -fsSL "$WAZUH_KEY_URL" |
         gpg --dearmor --yes \
         -o /usr/share/keyrings/wazuh.gpg >>"$LOG_FILE" 2>&1; then

        warn "PLAN A: Unable to install Wazuh signing key."
        return 1

    fi

    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] $WAZUH_REPO stable main" \
        > /etc/apt/sources.list.d/wazuh.list

    if ! apt-get update >>"$LOG_FILE" 2>&1; then
        warn "PLAN A: Repository update failed."
        return 1
    fi

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install -y wazuh-agent >>"$LOG_FILE" 2>&1; then

        PLAN_USED="Plan A - Official repository"
        return 0
    fi

    warn "PLAN A failed."
    return 1
}

# ============================================================
# PLAN B
# REPAIR PACKAGE STATE + RETRY
# ============================================================

install_plan_b() {

    info "PLAN B: Repairing package manager and retrying."

    dpkg --configure -a >>"$LOG_FILE" 2>&1 || true

    apt-get -f install -y >>"$LOG_FILE" 2>&1 || true

    apt-get clean >>"$LOG_FILE" 2>&1 || true

    rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true

    apt-get update >>"$LOG_FILE" 2>&1 || true

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install --reinstall -y wazuh-agent >>"$LOG_FILE" 2>&1; then

        PLAN_USED="Plan B - Package repair/reinstall"
        return 0
    fi

    warn "PLAN B failed."
    return 1
}

# ============================================================
# PLAN C
# DIRECT PACKAGE DOWNLOAD FROM WAZUH REPOSITORY
# ============================================================

install_plan_c() {

    info "PLAN C: Attempting direct package retrieval."

    local package_url
    local temp_deb="/tmp/quikefix-wazuh-agent.deb"

    package_url="$(
        apt-get download --print-uris wazuh-agent 2>/dev/null |
        awk -F"'" '/^'\''http/ {print $2; exit}'
    )"

    if [ -z "$package_url" ]; then
        warn "PLAN C: Could not determine package URL."
        return 1
    fi

    info "Downloading Wazuh package."

    if ! curl -fL "$package_url" -o "$temp_deb" >>"$LOG_FILE" 2>&1; then
        warn "PLAN C: Package download failed."
        return 1
    fi

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install -y "$temp_deb" >>"$LOG_FILE" 2>&1; then

        PLAN_USED="Plan C - Direct package"
        rm -f "$temp_deb"
        return 0
    fi

    rm -f "$temp_deb"

    warn "PLAN C failed."
    return 1
}

# ============================================================
# INSTALL / REPAIR
# ============================================================

if ! dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null |
     grep -q "install ok installed"; then

    install_plan_a || install_plan_b || install_plan_c || {

        fail "All installation plans failed."
        fail "Review: $LOG_FILE"
        exit 1

    }

else

    PLAN_USED="Existing installation"

fi

# ============================================================
# VERIFY CONFIGURATION
# ============================================================

if [ ! -f "$OSSEC_CONF" ]; then

    fail "$OSSEC_CONF does not exist."
    exit 1

fi

info "Checking Wazuh manager configuration."

CURRENT_MANAGER="$(
    sed -n '/<server>/,/<\/server>/p' "$OSSEC_CONF" |
    sed -n 's:.*<address>\(.*\)</address>.*:\1:p' |
    head -n1
)"

if [ "$CURRENT_MANAGER" != "$WAZUH_MANAGER" ]; then

    warn "Current manager is: ${CURRENT_MANAGER:-not configured}"
    info "Changing manager to $WAZUH_MANAGER"

    if grep -q '<address>.*</address>' "$OSSEC_CONF"; then

        sed -i \
        "0,/<address>.*<\/address>/s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" \
        "$OSSEC_CONF"

    else

        fail "Unable to locate manager address in ossec.conf."
        exit 1

    fi

fi

CONFIGURED_MANAGER="$(
    sed -n '/<server>/,/<\/server>/p' "$OSSEC_CONF" |
    sed -n 's:.*<address>\(.*\)</address>.*:\1:p' |
    head -n1
)"

if [ "$CONFIGURED_MANAGER" = "$WAZUH_MANAGER" ]; then
    ok "Manager configuration verified."
else
    fail "Manager configuration verification failed."
    exit 1
fi

# ============================================================
# START AGENT
# ============================================================

info "Starting Wazuh agent."

systemctl daemon-reload

systemctl enable wazuh-agent >>"$LOG_FILE" 2>&1 || true

systemctl restart wazuh-agent >>"$LOG_FILE" 2>&1 || {

    warn "Initial service start failed."

    sleep 3

    systemctl restart wazuh-agent >>"$LOG_FILE" 2>&1 || {

        fail "Wazuh agent service failed to start."
        systemctl status wazuh-agent --no-pager -l |
            tee -a "$LOG_FILE"

        exit 1
    }
}

sleep 5

# ============================================================
# FINAL VERIFICATION
# ============================================================

SERVICE_STATE="$(systemctl is-active wazuh-agent 2>/dev/null || true)"

if [ "$SERVICE_STATE" = "active" ]; then

    ok "Wazuh agent service is ACTIVE."

else

    fail "Wazuh agent service state: $SERVICE_STATE"
    exit 1

fi

CONNECTED="Unknown"

if grep -qiE \
   'Connected to the server|Connected to server|Server responded' \
   /var/ossec/logs/ossec.log 2>/dev/null; then

    CONNECTED="YES"

elif grep -qiE \
     'Unable to connect|Connection refused|No client configured|Invalid server address' \
     /var/ossec/logs/ossec.log 2>/dev/null; then

    CONNECTED="CHECK LOG"

fi

# ============================================================
# SUMMARY
# ============================================================

log ""
log "============================================================"
log " QUIKEFIX WAZUH INSTALLATION RESULT"
log "============================================================"
log "OS             : ${PRETTY_NAME:-$OS_ID}"
log "Architecture   : $ARCH"
log "Agent Name     : $WAZUH_AGENT_NAME"
log "Manager        : $WAZUH_MANAGER"
log "Install Method : $PLAN_USED"
log "Service        : $SERVICE_STATE"
log "Connection     : $CONNECTED"
log "Log            : $LOG_FILE"
log "============================================================"

if [ "$SERVICE_STATE" = "active" ]; then

    log "${green}RESULT: SUCCESS${reset}"
    exit 0

else

    log "${red}RESULT: FAILED${reset}"
    exit 1

fi
