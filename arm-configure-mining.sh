#!/bin/bash

# ============================================================
# MINING MANAGER v9.3 (Strict + Force Mode Support)
# ============================================================

CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"
WATCHDOG_PID="$CONFIG_DIR/watchdog.pid"
MINER_PID="$CONFIG_DIR/xmrig.pid"
LOG_FILE="$CONFIG_DIR/miner.log"
MODE_FILE="$CONFIG_DIR/mode"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script requires ROOT access (su/tsu).${NC}"
    echo "Please run: tsu"
    exit 1
fi

mkdir -p "$CONFIG_DIR"

# --- 1. SYSTEM FUNCTIONS ---

install_deps() {
    echo -e "${BLUE}Installing system components...${NC}"
    pkg update -y
    pkg install -y xmrig termux-tools jq procps grep

    echo -e "${BLUE}Optimizing Huge Pages...${NC}"
    echo 1280 > /proc/sys/vm/nr_hugepages
}

setup_config() {
    touch "$RUNTIME_ENV"
    echo "AUTO" > "$MODE_FILE"
    echo -e "${CYAN}=== SETUP WIZARD ===${NC}"

    # --- CONFIG ---
    read -p "Pool Address [Default: gulf.moneroocean.stream:10128]: " cpu_server_in
    cpu_server="${cpu_server_in:-gulf.moneroocean.stream:10128}"

    read -p "Wallet Address (XMR): " cpu_wal
    read -p "Worker Name (e.g. MyPhone): " cpu_worker

    CORES=$(nproc)
    echo "Detected Cores: $CORES"
    read -p "Threads to use [Default: $CORES]: " t_idle
    t_idle="${t_idle:-$CORES}"

    # Write Config
    cat <<EOF > "$ENV_FILE"
CPU_BIN=xmrig
CPU_SERVER=$cpu_server
CPU_WALLET=$cpu_wal
CPU_WORKER=${cpu_worker:-AndroidMiner}
CPU_THREADS=$t_idle
EOF
    echo -e "${GREEN}Configuration saved.${NC}"
}

# --- 2. CORE LOGIC ---

is_screen_on() {
    # Returns 0 (True) if Screen is ON
    if dumpsys window policy | grep -q "mScreenOnFully=true"; then
        return 0
    fi
    val=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
    if [ "$val" ] && [ "$val" -gt 0 ]; then
        return 0
    fi
    return 1
}

check_power_condition() {
    # Returns 0 (True) ONLY if 100% AND Charging/Full
    BAT_CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    BAT_STAT=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

    if [ "$BAT_CAP" -eq 100 ]; then
        if [[ "$BAT_STAT" == "Charging" ]] || [[ "$BAT_STAT" == "Full" ]]; then
            return 0
        fi
    fi
    return 1
}

kill_miner() {
    REASON=$1
    if [ -f "$MINER_PID" ]; then
        PID=$(cat "$MINER_PID")
        if kill -0 "$PID" 2>/dev/null; then
            echo -e "${YELLOW}Stopping miner ($REASON)...${NC}"
            echo "$(date): Stopping miner ($REASON)" >> "$LOG_FILE"
            kill "$PID" 2>/dev/null
        fi
        rm "$MINER_PID" 2>/dev/null
    fi
}

start_watchdog() {
    if [ -f "$WATCHDOG_PID" ] && kill -0 $(cat "$WATCHDOG_PID") 2>/dev/null; then
        echo -e "${YELLOW}Watchdog already running.${NC}"
        return
    fi

    echo -e "${GREEN}Starting Watchdog...${NC}"

    (
        while true; do
            source "$ENV_FILE"

            # Default to AUTO if file missing
            if [ ! -f "$MODE_FILE" ]; then echo "AUTO" > "$MODE_FILE"; fi
            CURRENT_MODE=$(cat "$MODE_FILE")

            # --- LOGIC DECISION ---
            SHOULD_MINE=false
            STOP_REASON=""

            if [ "$CURRENT_MODE" == "FORCE_START" ]; then
                SHOULD_MINE=true
            elif [ "$CURRENT_MODE" == "FORCE_STOP" ]; then
                SHOULD_MINE=false
                STOP_REASON="Force Stop Mode Active"
            else
                # AUTO MODE (Strict Logic)
                if check_power_condition; then
                    if ! is_screen_on; then
                        SHOULD_MINE=true
                    else
                        STOP_REASON="Screen is ON"
                    fi
                else
                    STOP_REASON="Power < 100% or Unplugged"
                fi
            fi

            # --- ACTION ---
            if [ "$SHOULD_MINE" = true ]; then
                # We should be mining. Is miner running?
                if [ ! -f "$MINER_PID" ] || ! kill -0 $(cat "$MINER_PID") 2>/dev/null; then
                    echo "$(date): Starting miner (Mode: $CURRENT_MODE)..." >> "$LOG_FILE"

                    nohup $CPU_BIN -o $CPU_SERVER -u $CPU_WALLET -p $CPU_WORKER \
                        --threads=$CPU_THREADS --cpu-no-yield \
                        --randomx-1gb-pages \
                        --donate-level=1 \
                        >> "$LOG_FILE" 2>&1 &

                    echo $! > "$MINER_PID"
                fi
            else
                # We should NOT be mining.
                kill_miner "$STOP_REASON"
            fi

            sleep 5
        done
    ) &
    echo $! > "$WATCHDOG_PID"
}

stop_all_services() {
    echo -e "${RED}Stopping all services...${NC}"
    if [ -f "$WATCHDOG_PID" ]; then
        kill $(cat "$WATCHDOG_PID") 2>/dev/null
        rm "$WATCHDOG_PID"
    fi
    kill_miner "Manual Full Stop"
}

set_mode() {
    echo "$1" > "$MODE_FILE"
    echo -e "Mode switched to: ${CYAN}$1${NC}"
    # Ensure watchdog is running to apply the new mode immediately
    start_watchdog
}

# --- 3. MENU INTERFACE ---

show_status() {
    echo -e "\n${CYAN}--- MINER STATUS ---${NC}"

    # Get Mode
    [ ! -f "$MODE_FILE" ] && echo "AUTO" > "$MODE_FILE"
    MODE=$(cat "$MODE_FILE")

    echo -n "Current Mode: "
    if [ "$MODE" == "FORCE_START" ]; then
        echo -e "${RED}FORCE START (Ignoring Sensors)${NC}"
    elif [ "$MODE" == "FORCE_STOP" ]; then
        echo -e "${RED}FORCE STOP (Mining Disabled)${NC}"
    else
        echo -e "${GREEN}AUTO (Strict: 100% Batt + Screen OFF)${NC}"
    fi

    # Power Info
    BAT_CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    BAT_STAT=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

    echo -n "Battery:      "
    if [ "$BAT_CAP" -eq 100 ] && [[ "$BAT_STAT" == "Charging" || "$BAT_STAT" == "Full" ]]; then
        echo -e "${GREEN}${BAT_CAP}% ($BAT_STAT)${NC}"
    else
        echo -e "${RED}${BAT_CAP}% ($BAT_STAT)${NC}"
    fi

    echo -n "Screen:       "
    if is_screen_on; then
        echo -e "${RED}ON${NC}"
    else
        echo -e "${GREEN}OFF${NC}"
    fi

    echo -n "XMRig Miner:  "
    if [ -f "$MINER_PID" ] && kill -0 $(cat "$MINER_PID") 2>/dev/null; then
        source "$ENV_FILE" 2>/dev/null
        echo -e "${GREEN}RUNNING${NC} (Threads: $CPU_THREADS)"
    else
        echo -e "${YELLOW}STOPPED${NC}"
    fi
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v9.3 ===${NC}"
        show_status
        echo "1. Set Mode: AUTO (Strict 100% + Screen OFF)"
        echo "2. Set Mode: FORCE START (Ignore Sensors)"
        echo "3. Set Mode: FORCE STOP (Kill Miner)"
        echo "--------------------------------"
        echo "4. Restart Watchdog"
        echo "5. KILL EVERYTHING (Exit)"
        echo "6. Edit Config"
        echo "7. View Logs"
        echo "8. Exit Menu"
        echo ""
        read -p "> " choice
        case $choice in
            1) set_mode "AUTO" ;;
            2) set_mode "FORCE_START" ;;
            3) set_mode "FORCE_STOP" ;;
            4) stop_all_services; start_watchdog ;;
            5) stop_all_services; exit 0 ;;
            6) nano "$ENV_FILE" ;;
            7) tail -f "$LOG_FILE" ;;
            8) exit 0 ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then
    install_deps
    setup_config
fi

main_menu
