#!/bin/bash
# =================================================================
# Pangolin Monitoring Script
# Description: Comprehensive monitoring system for Pangolin server,
# containers, and bandwidth usage with Pushover notifications
# CREDITS: https://forum.hhf.technology/
# https://forum.hhf.technology/t/setting-up-automated-pangolin-monitoring-with-systemd
# =================================================================

# Farben für eine schönere Shell-Ausgabe
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Keine Farbe

# Funktion zur Eingabeaufforderung mit Standardwerten und Validierung
prompt() {
    local prompt_text=$1
    local input

    read -p "$(echo -e "${YELLOW}${prompt_text}: ${NC}")" input
    echo "$input"
}

# Benutzereingaben für notwendige Daten
PANGOLIN_URL=$(prompt "Enter Pangolin URL (e.g., https://pangolin.testing.your.domain)")
PANGOLIN_EMAIL=$(prompt "Enter Pangolin Email")
read -sp "$(echo -e "${YELLOW}Enter Pangolin Password: ${NC}")" PANGOLIN_PASSWORD
echo
PANGOLIN_ORG=$(prompt "Enter Pangolin Organization")
PUSHOVER_USER_KEY=$(prompt "Enter Pushover User Key")
PUSHOVER_API_TOKEN=$(prompt "Enter Pushover API Token")
CHECK_INTERVAL=$(prompt "Enter Check Interval (seconds, default: 60)")
CHECK_INTERVAL=${CHECK_INTERVAL:-60}

LOG_FILE="/var/log/pangolin-monitor.log"
COOKIE_JAR="/tmp/.pangolin_cookies"
ALERT_SENT=false

# Monitoring thresholds and container configuration
CONTAINER_NAMES=("pangolin" "gerbil" "traefik")
BANDWIDTH_WARNING_THRESHOLD=1000  # MB
BANDWIDTH_CRITICAL_THRESHOLD=2000 # MB

# Security: Set strict permissions
umask 077

# ====== Dependency Management Functions ======

# Function to install jq based on the system's package manager
install_jq() {
    log_message "INFO" "Installing jq package..."
    
    if command -v apt-get &> /dev/null; then
        log_message "INFO" "Using apt package manager"
        apt-get update && apt-get install -y jq
    elif command -v yum &> /dev/null; then
        log_message "INFO" "Using yum package manager"
        yum install -y epel-release && yum install -y jq
    elif command -v dnf &> /dev/null; then
        log_message "INFO" "Using dnf package manager"
        dnf install -y jq
    elif command -v zypper &> /dev/null; then
        log_message "INFO" "Using zypper package manager"
        zypper install -y jq
    elif command -v pacman &> /dev/null; then
        log_message "INFO" "Using pacman package manager"
        pacman -Sy --noconfirm jq
    else
        log_message "ERROR" "Could not detect package manager. Please install jq manually."
        return 1
    fi

    if command -v jq &> /dev/null; then
        log_message "INFO" "jq installed successfully"
        return 0
    else
        log_message "ERROR" "Failed to install jq"
        return 1
    fi
}

# Function to install bc calculator
install_bc() {
    log_message "INFO" "Installing bc package..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y bc
    elif command -v yum &> /dev/null; then
        yum install -y bc
    elif command -v dnf &> /dev/null; then
        dnf install -y bc
    elif command -v zypper &> /dev/null; then
        zypper install -y bc
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm bc
    else
        log_message "ERROR" "Could not install bc. Please install it manually."
        return 1
    fi

    if command -v bc &> /dev/null; then
        log_message "INFO" "bc installed successfully"
        return 0
    else
        log_message "ERROR" "Failed to install bc"
        return 1
    fi
}

# Check for root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run as root to install required packages.${NC}"
        exit 1
    fi
}

# Check and install all required dependencies
check_dependencies() {
    log_message "INFO" "Checking for required dependencies..."
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_message "WARNING" "jq not found. Attempting to install..."
        if ! install_jq; then
            log_message "ERROR" "Failed to install jq. Please install it manually."
            send_pushover_alert "❌ Failed to install required dependency (jq)" "1"
            exit 1
        fi
    fi
    
    # Check for bc
    if ! command -v bc &> /dev/null; then
        log_message "WARNING" "bc not found. Attempting to install..."
        if ! install_bc; then
            log_message "ERROR" "Failed to install bc. Please install it manually."
            send_pushover_alert "❌ Failed to install required dependency (bc)" "1"
            exit 1
        fi
    fi
}

# ====== Utility Functions ======

# Logging function with timestamps and debug info
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
    if [ "$level" = "DEBUG" ]; then
        echo -e "${GREEN}[$level] $message${NC}" >&2
    fi
}

# Pushover alert function
send_pushover_alert() {
    local message="$1"
    local priority="$2"

    response=$(curl -s \
         --form-string "token=$PUSHOVER_API_TOKEN" \
         --form-string "user=$PUSHOVER_USER_KEY" \
         --form-string "message=$message" \
         --form-string "priority=$priority" \
         https://api.pushover.net/1/messages.json)
    
    if [ $? -eq 0 ]; then
        log_message "INFO" "Pushover notification sent successfully."
    else
        log_message "ERROR" "Failed to send Pushover notification."
    fi
    
    log_message "DEBUG" "Pushover response: $response"
}

# ====== Authentication Functions ======

# Handle authentication with Pangolin server
authenticate() {
    log_message "INFO" "Starting authentication process..."
    rm -f "$COOKIE_JAR"
    
    local response
    response=$(curl -s -i \
        -X POST \
        -c "$COOKIE_JAR" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Accept: application/json" \
        -H "Origin: ${PANGOLIN_URL}" \
        -H "X-CSRF-Token: x-csrf-protection" \
        -d "{\"email\":\"${PANGOLIN_EMAIL}\",\"password\":\"${PANGOLIN_PASSWORD}\"}" \
        "${PANGOLIN_URL}/api/v1/auth/login")
    
    log_message "DEBUG" "Login response: $response"
    
    if echo "$response" | grep -q '"success":true'; then
        if grep -q "p_session" "$COOKIE_JAR"; then
            log_message "INFO" "Authentication successful and session cookie stored"
            return 0
        fi
        log_message "ERROR" "Authentication succeeded but no session cookie stored"
        return 1
    fi
    
    local error_message
    error_message=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    log_message "ERROR" "Authentication failed: ${error_message:-Unknown error}"
    send_pushover_alert "🔒 Authentication failed: ${error_message:-Unknown error}" "1"
    return 1
}

# Make authenticated requests with rate limit awareness
make_authenticated_request() {
    local endpoint="$1"
    local method="${2:-GET}"
    
    if [ ! -f "$COOKIE_JAR" ]; then
        authenticate || return 1
    fi
    
    local response
    response=$(curl -s -i \
        -X "$method" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Accept: application/json" \
        -H "Origin: ${PANGOLIN_URL}" \
        -H "X-CSRF-Token: x-csrf-protection" \
        "${PANGOLIN_URL}/api/v1${endpoint}")
    
    # Check rate limits
    local remaining
    remaining=$(echo "$response" | grep -i "x-ratelimit-remaining" | cut -d' ' -f2 | tr -d '\r')
    if [ -n "$remaining" ] && [ "$remaining" -lt 10 ]; then
        log_message "WARNING" "Rate limit running low: $remaining requests remaining"
    fi
    
    # Handle session expiration
    if echo "$response" | grep -q '"message":"Unauthorized"'; then
        log_message "INFO" "Session expired, reauthenticating..."
        authenticate || return 1
        
        response=$(curl -s -i \
            -X "$method" \
            -b "$COOKIE_JAR" \
            -H "Content-Type: application/json; charset=utf-8" \
            -H "Accept: application/json" \
            -H "Origin: ${PANGOLIN_URL}" \
            -H "X-CSRF-Token: x-csrf-protection" \
            "${PANGOLIN_URL}/api/v1${endpoint}")
    fi
    
    echo "$response" | awk 'BEGIN{RS="\r\n\r\n"} NR==2'
}

# ====== Monitoring Functions ======

# Check container health status
check_container_health() {
    local container_name="$1"
    
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    local health
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)
    
    if [ -z "$status" ]; then
        log_message "ERROR" "Container $container_name not found"
        send_pushover_alert "🚫 Container $container_name not found!" "1"
        return 1
    fi
    
    if [ "$status" != "running" ]; then
        log_message "ERROR" "Container $container_name is $status"
        send_pushover_alert "⚠️ Container $container_name is $status" "1"
        return 1
    fi
    
    if [ "$health" != "none" ] && [ "$health" != "healthy" ]; then
        log_message "ERROR" "Container $container_name health check: $health"
        send_pushover_alert "🏥 Container $container_name health check failed: $health" "0"
        return 1
    fi
    
    log_message "INFO" "Container $container_name is running and healthy"
    return 0
}

# Monitor server bandwidth usage
check_server_bandwidth() {
    local sites_response
    sites_response=$(make_authenticated_request "/org/${PANGOLIN_ORG}/sites")
    
    if echo "$sites_response" | grep -q '"success":true'; then
        local total_bytes_in=0
        local total_bytes_out=0
        
        while IFS= read -r site; do
            local bytes_in=$(echo "$site" | jq -r '.megabytesIn')
            local bytes_out=$(echo "$site" | jq -r '.megabytesOut')
            
            if [[ $bytes_in != "null" && $bytes_in =~ ^[0-9]*\.?[0-9]*$ ]]; then
                total_bytes_in=$(echo "$total_bytes_in + $bytes_in" | bc)
            fi
            if [[ $bytes_out != "null" && $bytes_out =~ ^[0-9]*\.?[0-9]*$ ]]; then
                total_bytes_out=$(echo "$total_bytes_out + $bytes_out" | bc)
            fi
        done < <(echo "$sites_response" | jq -c '.data.sites[]')
        
        total_bytes_in=$(printf "%.2f" "$total_bytes_in")
        total_bytes_out=$(printf "%.2f" "$total_bytes_out")
        
        log_message "INFO" "Total bandwidth: IN=${total_bytes_in}MB OUT=${total_bytes_out}MB"
        
        if (( $(echo "$total_bytes_in > $BANDWIDTH_CRITICAL_THRESHOLD" | bc -l) )) || \
           (( $(echo "$total_bytes_out > $BANDWIDTH_CRITICAL_THRESHOLD" | bc -l) )); then
            send_pushover_alert "🚨 Critical bandwidth usage! IN=${total_bytes_in}MB OUT=${total_bytes_out}MB" "1"
        elif (( $(echo "$total_bytes_in > $BANDWIDTH_WARNING_THRESHOLD" | bc -l) )) || \
             (( $(echo "$total_bytes_out > $BANDWIDTH_WARNING_THRESHOLD" | bc -l) )); then
            send_pushover_alert "⚠️ High bandwidth usage! IN=${total_bytes_in}MB OUT=${total_bytes_out}MB" "0"
        fi
        
        return 0
    else
        log_message "ERROR" "Failed to fetch bandwidth metrics"
        send_pushover_alert "📊 Failed to fetch bandwidth metrics" "1"
        return 1
    fi
}

# Comprehensive server health check
check_server_health() {
    log_message "INFO" "Checking server health..."
    
    # Check container health
    for container in "${CONTAINER_NAMES[@]}"; do
        check_container_health "$container"
    done
    
    # Check bandwidth
    check_server_bandwidth
    
    # Check site status
    local response
    response=$(make_authenticated_request "/org/${PANGOLIN_ORG}/sites")
    
    if echo "$response" | grep -q '"success":true'; then
        local online_count=$(echo "$response" | grep -o '"online":true' | wc -l)
        local total_sites=$(echo "$response" | jq -r '.data.pagination.total')
        
        log_message "INFO" "Health check: $online_count/$total_sites sites online"
        
        local all_sites_online=true
        
        while IFS= read -r site; do
            local site_name=$(echo "$site" | jq -r '.name')
            local site_id=$(echo "$site" | jq -r '.niceId')
            local bytes_in=$(echo "$site" | jq -r '.megabytesIn')
            local bytes_out=$(echo "$site" | jq -r '.megabytesOut')
            local is_online=$(echo "$site" | jq -r '.online')
            
            log_message "INFO" "Site $site_name ($site_id): IN=${bytes_in}MB OUT=${bytes_out}MB Online=$is_online"
            
            if [ "$is_online" = "false" ]; then
                all_sites_online=false
                if [ "$ALERT_SENT" = false ]; then
                    send_pushover_alert "⚠️ Site $site_name ($site_id) is offline!" "0"
                    ALERT_SENT=true
                fi
            fi
        done < <(echo "$response" | jq -c '.data.sites[]')
        
        if [ "$online_count" -lt "$total_sites" ]; then
            if [ "$ALERT_SENT" = false ]; then
                send_pushover_alert "⚠️ Some sites are offline ($online_count/$total_sites online)" "0"
                ALERT_SENT=true
            fi
        fi
        
        if [ "$all_sites_online" = true ]; then
            log_message "INFO" "All sites are online. No alert needed."
            ALERT_SENT=false
        fi
        
        return 0
    else
        local error_message
        error_message=$(echo "$response" | jq -r '.message')
        log_message "ERROR" "Health check failed: ${error_message:-Unknown error}"
        send_pushover_alert "🚨 Health check failed: ${error_message:-Unknown error}" "1"
        return 1
    fi
}

# ====== Main Function ======

main() {
    log_message "INFO" "Starting Pangolin monitoring service"
    
    # Check root privileges and dependencies
    check_root
    check_dependencies
    
    # Clean up any leftover files
    rm -f "$COOKIE_JAR"
    
    # Set up cleanup trap for graceful exit
    trap 'log_message "INFO" "Cleaning up and exiting..."; rm -f "$COOKIE_JAR"' EXIT INT TERM
    
    # Initial authentication with retry mechanism
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        if authenticate; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_message "INFO" "Authentication failed, retrying in 5 seconds (attempt $retry_count of $max_retries)"
            sleep 5
        fi
    done
    
    # Handle authentication failure
    if [ $retry_count -eq $max_retries ]; then
        log_message "ERROR" "Failed to authenticate after $max_retries attempts"
        send_pushover_alert "❌ Authentication failed after multiple attempts" "1"
        exit 1
    fi
    
    # Main monitoring loop
    while true; do
        log_message "INFO" "Starting monitoring cycle"
        
        # Perform health check with error handling
        if ! check_server_health; then
            log_message "WARNING" "Health check failed, will retry next cycle"
        fi
        
        # Wait for next check interval
        log_message "DEBUG" "Sleeping for $CHECK_INTERVAL seconds"
        sleep "$CHECK_INTERVAL"
    done
}

# ====== Script Entry Point ======

# Start monitoring with error handling
if ! main; then
    log_message "ERROR" "Monitor failed, please check logs at $LOG_FILE"
    send_pushover_alert "❌ Monitor crashed, requires attention!" "1"
    exit 1
fi