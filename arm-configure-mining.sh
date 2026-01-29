#!/bin/bash

# ============================================================
# MINING MANAGER v9.4 (Strict + Force Mode + Source Compile)
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

# --- 1. INSTALLATION & COMPILE FUNCTIONS ---

install_base_deps() {
    echo -e "${BLUE}Installing base system tools...${NC}"
    pkg update -y
    pkg install -y termux-tools jq procps grep

    echo -e "${BLUE}Optimizing Huge Pages...${NC}"
    echo 1280 > /proc/sys/vm/nr_hugepages
}

compile_xmrig() {
    echo -e "${CYAN}=== COMPILING XMRIG FROM SOURCE (ARM64) ===${NC}"
    echo -e "${YELLOW}This process will take 5-15 minutes.${NC}"

    # 1. Install Build Dependencies
    pkg install -y git cmake libuv openssl clang make hwloc

    # 2. Clone
    cd "$HOME"
    if [ -d "xmrig" ]; then
        echo -e "${YELLOW}Existing xmrig folder found. Updating...${NC}"
        cd xmrig
        git pull
    else
        git clone https://github.com/xmrig/xmrig.git
        cd xmrig
    fi

    # 3. Build
    mkdir -p build && cd build
    echo -e "${BLUE}Configuring CMake...${NC}"
    # Disable OpenCL/CUDA for pure CPU mining to save build time/errors
    cmake .. -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DCMAKE_BUILD_TYPE=Release

    echo -e "${BLUE}Compiling (This takes time)...${NC}"
    make -j$(nproc)

    if [ -f "./xmrig" ]; then
        echo -e "${GREEN}Compilation Successful!${NC}"
        return 0
    else
        echo -e "${RED}Compilation Failed.${NC}"
        return 1
    fi
}

install_xmrig_menu() {
    clear
    echo -e "${CYAN}=== XMRIG INSTALLATION WIZARD ===${NC}"
    echo "1. Install via Package Manager (Fast, Standard Version)"
    echo "2. Compile from Source (Slow, Optimized, Latest Version)"
    echo "3. Skip (I already have it)"
    echo ""
    read -p "> " install_choice

    XM_PATH="xmrig" # Default global path

    case $install_choice in
        1)
            pkg install -y xmrig
            XM_PATH="xmrig"
            ;;
        2)
            if compile_xmrig; then
                XM_PATH="$HOME/xmrig/build/xmrig"
            else
                echo -e "${RED}Falling back to package manager...${NC}"
                sleep 2
                pkg install -y xmrig
                XM_PATH="xmrig"
            fi
            ;;
        3)
            # User claims to have it. Check generic or local.
            if [ -f "$HOME/xmrig/build/xmrig" ]; then
                XM_PATH="$HOME/xmrig/build/xmrig"
            else
                XM_PATH="xmrig"
            fi
            ;;
    esac

    # Save the path temporarily to return it or write to config
    echo "$XM_PATH" > "$CONFIG_DIR/temp_bin_path"
}

setup_config() {
    touch "$RUNTIME_ENV"
    echo "AUTO" > "$MODE_FILE"

    # Run Install Wizard
    install_xmrig_menu
    CPU_BIN_PATH=$(cat "$CONFIG_DIR/temp_bin_path")
    rm "$CONFIG_DIR/temp_bin_path"

    echo -e "${CYAN}=== CONFIGURATION ===${NC}"

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
CPU_BIN=$CPU_BIN_PATH
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

                    # Verify binary exists
                    if [ ! -x "$(command -v $CPU_BIN)" ] && [ ! -f "$CPU_BIN" ]; then
                        echo "ERROR: XMRig binary not found at $CPU_BIN" >> "$LOG_FILE"
                        sleep 10
                        continue
                    fi

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
    start_watchdog
}

# --- 3. MENU INTERFACE ---

show_status() {
    echo -e "\n${CYAN}--- MINER STATUS ---${NC}"

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

    # If sensors failed to read, show N/A
    if [ -z "$BAT_CAP" ]; then BAT_CAP="N/A"; fi

    echo -n "Battery:      "
    if [ "$BAT_CAP" == "100" ] && [[ "$BAT_STAT" == "Charging" || "$BAT_STAT" == "Full" ]]; then
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
        # Display binary type
        if [[ "$CPU_BIN" == *"build/xmrig"* ]]; then
            TYPE="(Compiled)"
        else
            TYPE="(Pkg)"
        fi
        echo -e "${GREEN}RUNNING $TYPE${NC} (Threads: $CPU_THREADS)"
    else
        echo -e "${YELLOW}STOPPED${NC}"
    fi
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v9.4 (ARM64) ===${NC}"
        show_status
        echo "1. Set Mode: AUTO (Strict)"
        echo "2. Set Mode: FORCE START"
        echo "3. Set Mode: FORCE STOP"
        echo "--------------------------------"
        echo "4. INSTALL / UPDATE XMRig"
        echo "5. Restart Watchdog"
        echo "6. KILL EVERYTHING (Exit)"
        echo "7. Edit Config"
        echo "8. View Logs"
        echo "9. Exit Menu"
        echo ""
        read -p "> " choice
        case $choice in
            1) set_mode "AUTO" ;;
            2) set_mode "FORCE_START" ;;
            3) set_mode "FORCE_STOP" ;;
            4)
               install_base_deps
               install_xmrig_menu
               CPU_BIN_PATH=$(cat "$CONFIG_DIR/temp_bin_path")
               rm "$CONFIG_DIR/temp_bin_path"
               # Update Config with new path
               sed -i "s|CPU_BIN=.*|CPU_BIN=$CPU_BIN_PATH|" "$ENV_FILE"
               echo -e "${GREEN}Updated binary path to: $CPU_BIN_PATH${NC}"
               sleep 2
               ;;
            5) stop_all_services; start_watchdog ;;
            6) stop_all_services; exit 0 ;;
            7) nano "$ENV_FILE" ;;
            8) tail -f "$LOG_FILE" ;;
            9) exit 0 ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then
    install_base_deps
    setup_config
fi

main_menu
