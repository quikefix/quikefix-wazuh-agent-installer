#!/usr/bin/env bash
#
# QuikeFix Wazuh Agent Universal Installer - Linux
# Secure Private Edition
#

set -u
set -o pipefail

# ============================================================
# CONFIGURATION
# ============================================================

WAZUH_MANAGER="${WAZUH_MANAGER:-wazuh-agent.quikefix.info}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname -s 2>/dev/null || hostname)}"

# PRIVATE REPOSITORY ONLY.
# Replace the placeholder below with the enrollment password stored in:
# /var/ossec/etc/authd.pass
WAZUH_ENROLLMENT_PASSWORD="${WAZUH_ENROLLMENT_PASSWORD:-FcD09z0XRQKt0ucDMRvMhdFuqyEuwXG75HDFD+nBqyc=}"

WAZUH_REPO="https://packages.wazuh.com/4.x/apt/"
WAZUH_KEY_URL="https://packages.wazuh.com/key/GPG-KEY-WAZUH"

LOG_FILE="/var/log/quikefix-wazuh-install.log"
OSSEC_CONF="/var/ossec/etc/ossec.conf"
OSSEC_LOG="/var/ossec/logs/ossec.log"
CLIENT_KEYS="/var/ossec/etc/client.keys"

CONNECTION_WAIT="${CONNECTION_WAIT:-60}"
CONNECTION_INTERVAL=5

INSTALL_METHOD="None"
CONNECTION_STATE="NO"
SERVICE_STATE="unknown"
MANAGER_IP="Unknown"
OSSEC_LOG_START_LINE=0

# ============================================================
# OUTPUT FUNCTIONS
# ============================================================

log()
{
    local level="$1"
    shift
    local message="$*"

    printf '[%s] %s\n' "$level" "$message"

    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s [%s] %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$level" \
            "$message" \
            >>"$LOG_FILE" 2>/dev/null || true
    fi
}

info()
{
    log "INFO" "$@"
}

pass()
{
    log "PASS" "$@"
}

warn()
{
    log "WARN" "$@"
}

fail()
{
    log "FAIL" "$@"
}

separator()
{
    echo "============================================================"
}

# ============================================================
# HEADER
# ============================================================

separator
echo " QUIKEFIX WAZUH AGENT INSTALLER"
separator
echo "Started      : $(date)"
echo "Hostname     : $(hostname -f 2>/dev/null || hostname)"
echo "Agent Name   : $WAZUH_AGENT_NAME"
echo "Manager      : $WAZUH_MANAGER"
separator

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "[FAIL] Root privileges are required."
    echo
    echo "Run using:"
    echo "sudo bash install.sh"
    exit 1
fi

touch "$LOG_FILE" 2>/dev/null || {
    echo "[FAIL] Unable to create $LOG_FILE"
    exit 1
}

chmod 600 "$LOG_FILE" 2>/dev/null || true

# ============================================================
# OPERATING SYSTEM DETECTION
# ============================================================

if [ ! -f /etc/os-release ]; then
    fail "Unable to identify the operating system."
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

OS_NAME="${PRETTY_NAME:-${NAME:-Unknown}}"
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

info "Operating system: $OS_NAME"
info "Architecture: $ARCH"

case "$OS_ID" in
    ubuntu|debian)
        pass "Supported Debian-family operating system detected."
        ;;
    *)
        if echo "$OS_LIKE" | grep -qi "debian"; then
            pass "Supported Debian-family operating system detected."
        else
            fail "This version currently supports Debian/Ubuntu-family Linux."
            exit 1
        fi
        ;;
esac

# ============================================================
# PREREQUISITES
# ============================================================

info "Checking prerequisites..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >>"$LOG_FILE" 2>&1 || {
    fail "apt package index update failed."
    exit 1
}

install_prerequisite()
{
    local package="$1"
    local command_name="${2:-$1}"

    if command -v "$command_name" >/dev/null 2>&1; then
        pass "$package already installed."
        return 0
    fi

    info "Installing prerequisite: $package"

    if apt-get install -y "$package" >>"$LOG_FILE" 2>&1; then
        pass "$package installed."
    else
        fail "Unable to install prerequisite: $package"
        exit 1
    fi
}

install_prerequisite "curl" "curl"
install_prerequisite "ca-certificates" "update-ca-certificates"
install_prerequisite "gnupg" "gpg"
install_prerequisite "netcat-openbsd" "nc"

# ============================================================
# DNS CHECK
# ============================================================

info "Testing manager DNS..."

MANAGER_IP="$(
    getent ahostsv4 "$WAZUH_MANAGER" 2>/dev/null |
    awk 'NR==1 {print $1}'
)"

if [ -z "$MANAGER_IP" ]; then
    fail "DNS resolution failed for $WAZUH_MANAGER"
    exit 1
fi

pass "$WAZUH_MANAGER resolves to $MANAGER_IP"

# ============================================================
# NETWORK CHECKS
# ============================================================

if nc -z -w5 "$WAZUH_MANAGER" 1514 >/dev/null 2>&1; then
    pass "TCP 1514 reachable."
else
    fail "TCP 1514 is unreachable."
    fail "Agent communication cannot continue."
    exit 1
fi

if nc -z -w5 "$WAZUH_MANAGER" 1515 >/dev/null 2>&1; then
    pass "TCP 1515 reachable."
else
    warn "TCP 1515 enrollment port is unreachable."

    if [ ! -s "$CLIENT_KEYS" ]; then
        fail "This machine is not enrolled and TCP 1515 is required."
        exit 1
    fi

    warn "Existing enrollment key detected; continuing."
fi

# ============================================================
# EXISTING INSTALLATION CHECK
# ============================================================

if dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null |
    grep -q "install ok installed"
then
    pass "Existing Wazuh agent detected."
    INSTALL_METHOD="Existing installation"
else
    info "Wazuh agent is not currently installed."
fi

# ============================================================
# REPOSITORY SETUP
# ============================================================

setup_wazuh_repository()
{
    info "Configuring official Wazuh repository."

    mkdir -p /usr/share/keyrings

    rm -f /usr/share/keyrings/wazuh.gpg

    if ! curl -fsSL "$WAZUH_KEY_URL" |
        gpg --dearmor --yes \
            -o /usr/share/keyrings/wazuh.gpg \
            >>"$LOG_FILE" 2>&1
    then
        warn "Unable to install Wazuh repository signing key."
        return 1
    fi

    cat >/etc/apt/sources.list.d/wazuh.list <<EOF
deb [signed-by=/usr/share/keyrings/wazuh.gpg] $WAZUH_REPO stable main
EOF

    if ! apt-get update >>"$LOG_FILE" 2>&1; then
        warn "Wazuh repository update failed."
        return 1
    fi

    return 0
}

# ============================================================
# PLAN A - OFFICIAL REPOSITORY
# ============================================================

install_plan_a()
{
    info "PLAN A: Installing through official Wazuh repository."

    setup_wazuh_repository || return 1

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install -y wazuh-agent >>"$LOG_FILE" 2>&1
    then
        INSTALL_METHOD="Plan A - Official repository"
        pass "Wazuh agent installed through official repository."
        return 0
    fi

    warn "PLAN A failed."
    return 1
}

# ============================================================
# PLAN B - PACKAGE REPAIR / REINSTALL
# ============================================================

install_plan_b()
{
    info "PLAN B: Repairing package state and retrying installation."

    dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    apt-get -f install -y >>"$LOG_FILE" 2>&1 || true

    setup_wazuh_repository || true

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install --reinstall -y wazuh-agent \
       >>"$LOG_FILE" 2>&1
    then
        INSTALL_METHOD="Plan B - Package repair"
        pass "Wazuh agent installed using repair/reinstall."
        return 0
    fi

    warn "PLAN B failed."
    return 1
}

# ============================================================
# PLAN C - DIRECT PACKAGE RETRIEVAL
# ============================================================

install_plan_c()
{
    info "PLAN C: Attempting direct Wazuh package installation."

    setup_wazuh_repository || true

    local package_url

    package_url="$(
        apt-get --print-uris --yes install wazuh-agent 2>/dev/null |
        awk -F"'" '/^'\''https?:/ {print $2}' |
        grep -E '/wazuh-agent_[^/]*\.deb$' |
        head -n1
    )"

    if [ -z "$package_url" ]; then
        warn "Unable to determine direct Wazuh package URL."
        return 1
    fi

    info "Direct package URL discovered."

    local package_file="/tmp/quikefix-wazuh-agent.deb"

    rm -f "$package_file"

    if ! curl -fL "$package_url" -o "$package_file" \
        >>"$LOG_FILE" 2>&1
    then
        warn "Direct package download failed."
        return 1
    fi

    if WAZUH_MANAGER="$WAZUH_MANAGER" \
       WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
       apt-get install -y "$package_file" >>"$LOG_FILE" 2>&1
    then
        INSTALL_METHOD="Plan C - Direct package"
        pass "Wazuh agent installed using direct package."
        rm -f "$package_file"
        return 0
    fi

    rm -f "$package_file"

    warn "PLAN C failed."
    return 1
}

# ============================================================
# INSTALL IF REQUIRED
# ============================================================

if ! dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null |
    grep -q "install ok installed"
then

    if ! install_plan_a; then
        if ! install_plan_b; then
            if ! install_plan_c; then
                fail "All Wazuh installation methods failed."
                fail "Review $LOG_FILE"
                exit 1
            fi
        fi
    fi
fi

# ============================================================
# VERIFY PACKAGE
# ============================================================

if ! dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null |
    grep -q "install ok installed"
then
    fail "Wazuh package verification failed."
    exit 1
fi

pass "Wazuh agent package verified."

# ============================================================
# VERIFY / REPAIR MANAGER CONFIGURATION
# ============================================================

if [ ! -f "$OSSEC_CONF" ]; then
    fail "Wazuh configuration file was not found: $OSSEC_CONF"
    exit 1
fi

info "Checking Wazuh manager configuration."

CURRENT_MANAGER="$(
    sed -n \
        's:.*<address>[[:space:]]*\([^<]*\)[[:space:]]*</address>.*:\1:p' \
        "$OSSEC_CONF" |
    head -n1 |
    xargs
)"

if [ "$CURRENT_MANAGER" != "$WAZUH_MANAGER" ]; then

    warn "Current manager is: ${CURRENT_MANAGER:-Unknown}"
    info "Changing manager to $WAZUH_MANAGER"

    BACKUP_FILE="$OSSEC_CONF.quikefix-backup-$(date '+%Y%m%d-%H%M%S')"

    cp "$OSSEC_CONF" "$BACKUP_FILE" || {
        fail "Unable to back up ossec.conf."
        exit 1
    }

    if grep -q '<address>.*</address>' "$OSSEC_CONF"; then

        sed -i \
            "0,/<address>.*<\/address>/s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" \
            "$OSSEC_CONF"

    else

        fail "Unable to locate manager <address> in ossec.conf."
        exit 1

    fi
fi

CURRENT_MANAGER="$(
    sed -n \
        's:.*<address>[[:space:]]*\([^<]*\)[[:space:]]*</address>.*:\1:p' \
        "$OSSEC_CONF" |
    head -n1 |
    xargs
)"

if [ "$CURRENT_MANAGER" != "$WAZUH_MANAGER" ]; then
    fail "Manager configuration verification failed."
    exit 1
fi

pass "Manager configuration verified."

# ============================================================
# SECURE AGENT ENROLLMENT
# ============================================================

if [ ! -s "$CLIENT_KEYS" ]; then

    info "No existing Wazuh enrollment key detected."
    info "Starting password-protected enrollment."

    if [ -z "${WAZUH_ENROLLMENT_PASSWORD:-}" ] ||
       [ "$WAZUH_ENROLLMENT_PASSWORD" = "PUT-YOUR-PRIVATE-PASSWORD-HERE" ]
    then
        fail "Private Wazuh enrollment password has not been configured."
        exit 1
    fi

    if [ ! -x /var/ossec/bin/agent-auth ]; then
        fail "Wazuh agent-auth utility was not found."
        exit 1
    fi

    #
    # Do not log the command itself because it contains the password.
    #
    ENROLL_OUTPUT="$(
        /var/ossec/bin/agent-auth \
            -m "$WAZUH_MANAGER" \
            -p 1515 \
            -A "$WAZUH_AGENT_NAME" \
            -P "$WAZUH_ENROLLMENT_PASSWORD" \
            2>&1
    )"

    ENROLL_RC=$?

    #
    # Log sanitized enrollment output.
    #
    printf '%s\n' "$ENROLL_OUTPUT" |
        sed 's/[Pp]assword[^ ]*/password/g' \
        >>"$LOG_FILE" 2>/dev/null || true

    unset ENROLL_OUTPUT

    if [ "$ENROLL_RC" -ne 0 ]; then
        fail "Secure Wazuh enrollment failed."
        fail "Review $LOG_FILE"
        exit 1
    fi

    if [ ! -s "$CLIENT_KEYS" ]; then
        fail "Enrollment completed without creating a client key."
        exit 1
    fi

    pass "Secure Wazuh enrollment completed."

else

    pass "Existing Wazuh enrollment key detected."

fi

# ============================================================
# CAPTURE LOG POSITION BEFORE RESTART
# ============================================================

if [ -f "$OSSEC_LOG" ]; then
    OSSEC_LOG_START_LINE="$(
        wc -l <"$OSSEC_LOG" 2>/dev/null || echo 0
    )"
fi

case "$OSSEC_LOG_START_LINE" in
    ''|*[!0-9]*)
        OSSEC_LOG_START_LINE=0
        ;;
esac

# ============================================================
# START AGENT
# ============================================================

info "Starting Wazuh agent."

systemctl daemon-reload

systemctl enable wazuh-agent >>"$LOG_FILE" 2>&1 || true

if ! systemctl restart wazuh-agent >>"$LOG_FILE" 2>&1; then

    warn "Initial service start failed."

    sleep 3

    if ! systemctl restart wazuh-agent >>"$LOG_FILE" 2>&1; then
        fail "Wazuh agent service failed to start."
        exit 1
    fi
fi

# ============================================================
# SERVICE VERIFICATION
# ============================================================

sleep 3

if systemctl is-active --quiet wazuh-agent; then
    SERVICE_STATE="active"
    pass "Wazuh agent service is ACTIVE."
else
    SERVICE_STATE="$(
        systemctl is-active wazuh-agent 2>/dev/null || echo inactive
    )"

    fail "Wazuh agent service is not active."
    exit 1
fi

# ============================================================
# CONNECTION VERIFICATION
# ============================================================

info "Waiting for Wazuh manager connection (up to ${CONNECTION_WAIT}s)..."

ELAPSED=0
CONNECTION_STATE="NO"

while [ "$ELAPSED" -lt "$CONNECTION_WAIT" ]; do

    if [ -f "$OSSEC_LOG" ]; then

        NEW_LOG="$(
            tail -n "+$((OSSEC_LOG_START_LINE + 1))" \
                "$OSSEC_LOG" 2>/dev/null || true
        )"

        if printf '%s\n' "$NEW_LOG" |
            grep -qiE \
            'Connected to the server|Connected to server|Server responded|Agent is now online'
        then
            CONNECTION_STATE="YES"
            pass "Agent successfully connected to Wazuh manager."
            break
        fi

        if printf '%s\n' "$NEW_LOG" |
            grep -qiE \
            'Invalid server address|Invalid password|Authentication error|Duplicate agent name|Unable to add agent'
        then
            warn "Wazuh reported an authentication/enrollment error."
            break
        fi
    fi

    #
    # Secondary verification using an established TCP session.
    #
    if command -v ss >/dev/null 2>&1; then

        if ss -tn 2>/dev/null |
            grep -E 'ESTAB' |
            grep -qE "(${MANAGER_IP//./\\.}|$WAZUH_MANAGER):1514"
        then
            CONNECTION_STATE="YES"
            pass "Established Wazuh TCP 1514 connection detected."
            break
        fi
    fi

    sleep "$CONNECTION_INTERVAL"

    ELAPSED=$((ELAPSED + CONNECTION_INTERVAL))

    info "Waiting for manager connection... $ELAPSED/$CONNECTION_WAIT seconds"
done

unset NEW_LOG 2>/dev/null || true

# ============================================================
# FINAL SERVICE CHECK
# ============================================================

if systemctl is-active --quiet wazuh-agent; then
    SERVICE_STATE="active"
else
    SERVICE_STATE="$(
        systemctl is-active wazuh-agent 2>/dev/null || echo inactive
    )"
fi

# ============================================================
# FINAL RESULT
# ============================================================

echo
separator
echo " QUIKEFIX WAZUH INSTALLATION RESULT"
separator
echo "OS             : $OS_NAME"
echo "Architecture   : $ARCH"
echo "Agent Name     : $WAZUH_AGENT_NAME"
echo "Manager        : $WAZUH_MANAGER"
echo "Manager IP     : $MANAGER_IP"
echo "Install Method : $INSTALL_METHOD"
echo "Service        : $SERVICE_STATE"
echo "Connection     : $CONNECTION_STATE"
echo "Log            : $LOG_FILE"
separator

if [ "$SERVICE_STATE" = "active" ] &&
   [ "$CONNECTION_STATE" = "YES" ]
then
    echo "RESULT: SUCCESS"
    exit 0
fi

fail "Wazuh installation did not pass final connection verification."
fail "Review:"
fail "  $LOG_FILE"
fail "  $OSSEC_LOG"

echo "RESULT: FAILED"
exit 1
