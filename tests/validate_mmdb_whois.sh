#!/bin/bash

# validate_mmdb_whois.sh
# Compare Lua MMDB lookups against mmdblookup command-line tool
# Usage: ./validate_mmdb_whois.sh [IP1] [IP2] ... or ./validate_mmdb_whois.sh -f ip_list.txt

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_CMD="lua5.4"
LUA_PATH="$SCRIPT_DIR/../?.lua;$SCRIPT_DIR/../?/init.lua;;"
MMDB_SCRIPT="$SCRIPT_DIR/mmdb_validate.lua"
MMDBLOOKUP_CMD="mmdblookup"
COUNTRY_DB="$SCRIPT_DIR/../GeoLite2-Country.mmdb"
ASN_DB="$SCRIPT_DIR/../GeoLite2-ASN.mmdb"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color



# Error handling
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Warning
warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Success
success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

# Info
info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

# Setup
setup() {
    # Check dependencies
    command -v "$LUA_CMD" >/dev/null 2>&1 || error "Lua not found. Please install lua5.4"
    command -v "$MMDBLOOKUP_CMD" >/dev/null 2>&1 || error "mmdblookup not found. Please install mmdblookup"

    # Check if MMDB script exists
    [ -f "$MMDB_SCRIPT" ] || error "MMDB validation script not found: $MMDB_SCRIPT"

    # Check if DB files exist
    [ -f "$COUNTRY_DB" ] || error "Country DB not found: $COUNTRY_DB"
    [ -f "$ASN_DB" ] || error "ASN DB not found: $ASN_DB"
}

# Get Lua data for IP
get_lua_data() {
    local ip="$1"
    local country_output asn_output

    if ! country_output=$("LUA_PATH=$LUA_PATH $LUA_CMD" "$MMDB_SCRIPT" "$ip" "country" "country" "iso_code" 2>/dev/null | head -1); then
        echo "ERROR: Failed to get country data for $ip"
        return 1
    fi

    if ! asn_output=$("LUA_PATH=$LUA_PATH $LUA_CMD" "$MMDB_SCRIPT" "$ip" "asn" "autonomous_system_number" 2>/dev/null | head -1); then
        echo "ERROR: Failed to get ASN data for $ip"
        return 1
    fi

    # Normalize Lua outputs to match mmdblookup (empty for no data)
    if [ "$country_output" = "Unknown" ] || [ -z "$country_output" ]; then
        country_output=""
    fi
    if [ "$asn_output" = "AS0" ] || [ "$asn_output" = "Unknown" ] || [ -z "$asn_output" ]; then
        asn_output=""
    fi

    echo "COUNTRY=$country_output"
    echo "ASN=$asn_output"
}

# Get CLI data for IP
get_cli_data() {
    local ip="$1"

    # Get country
    local country
    if ! country=$("$MMDBLOOKUP_CMD" --file "$COUNTRY_DB" --ip "$ip" country iso_code 2>/dev/null | jq -r '.iso_code // empty' 2>/dev/null); then
        country=""
    fi

    # Get ASN
    local asn
    if ! asn=$("$MMDBLOOKUP_CMD" --file "$ASN_DB" --ip "$ip" autonomous_system_number 2>/dev/null | jq -r '.autonomous_system_number // empty' 2>/dev/null); then
        asn=""
    fi

    echo "COUNTRY=$country"
    echo "ASN=$asn"
}

# Compare Lua MMDB vs mmdblookup data
compare_data() {
    local ip="$1"
    local lua_data="$2"
    local cli_data="$3"

    # Parse Lua data
    local lua_country=$(echo "$lua_data" | grep "^COUNTRY=" | cut -d'=' -f2)
    local lua_asn=$(echo "$lua_data" | grep "^ASN=" | cut -d'=' -f2)

    # Parse CLI data
    local cli_country=$(echo "$cli_data" | grep "^COUNTRY=" | cut -d'=' -f2)
    local cli_asn=$(echo "$cli_data" | grep "^ASN=" | cut -d'=' -f2)

    # For ASN comparison, strip "AS" prefix from Lua output if present
    local lua_asn_normalized="$lua_asn"
    if [[ "$lua_asn" == AS* ]]; then
        lua_asn_normalized="${lua_asn#AS}"
    fi

    # Compare
    local country_match=$([ "$lua_country" = "$cli_country" ] && echo "✓" || echo "✗")
    local asn_match=$([ "$lua_asn_normalized" = "$cli_asn" ] && echo "✓" || echo "✗")

    # Display results only if there are mismatches
    if [ "$country_match" = "✗" ] || [ "$asn_match" = "✗" ]; then
        echo "IP: $ip"
        if [ "$country_match" = "✗" ]; then
            echo "  Country: Lua=$lua_country, CLI=$cli_country"
        fi
        if [ "$asn_match" = "✗" ]; then
            echo "  ASN: Lua=$lua_asn, CLI=$cli_asn"
        fi
        echo
    fi


}

# Main validation function
validate_ip() {
    local ip="$1"

    # Get Lua MMDB data
    local lua_data
    if ! lua_data=$(get_lua_data "$ip"); then
        warning "Failed to get Lua MMDB data for $ip"
        return 1
    fi

    # Get CLI data
    local cli_data
    if ! cli_data=$(get_cli_data "$ip"); then
        warning "Failed to get CLI data for $ip"
        return 1
    fi

    # Compare
    compare_data "$ip" "$lua_data" "$cli_data"
}

# Main function
main() {
    setup

    echo "=== Lua vs CLI Validation ==="

    local total_ips=0
    local processed_ips=0

    # Process IPs from arguments or file
    if [ "$1" = "-f" ] && [ -n "$2" ]; then
        # Read from file
        while IFS= read -r ip || [ -n "$ip" ]; do
            # Skip empty lines and comments
            [ -z "$ip" ] || [[ "$ip" =~ ^[[:space:]]*# ]] && continue

            total_ips=$((total_ips + 1))
            if validate_ip "$ip"; then
                processed_ips=$((processed_ips + 1))
            fi
        done < "$2"
    else
        # Process command line arguments
        for ip in "$@"; do
            total_ips=$((total_ips + 1))
            if validate_ip "$ip"; then
                processed_ips=$((processed_ips + 1))
            fi
        done
    fi

    echo
    echo "=== Summary ==="
    echo "Processed: $processed_ips/$total_ips IPs"

    if [ $processed_ips -eq $total_ips ]; then
        success "All IPs processed successfully"
    else
        warning "Some IPs failed to process"
        exit 1
    fi
}

# Show usage
usage() {
    echo "Usage: $0 [IP1] [IP2] ... or $0 -f ip_list.txt"
    echo "Validate Lua lookups against CLI tool"
    echo ""
    echo "Options:"
    echo "  -f FILE    Read IP addresses from file (one per line)"
    echo "  -h         Show this help"
    exit 1
}

# Parse arguments
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

main "$@"
