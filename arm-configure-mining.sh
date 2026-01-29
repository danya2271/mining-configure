#!/bin/bash

# ============================================================
# MINING MANAGER v10.1 (Fix: Sudo Paths & Debugging)
# ============================================================

# Define Paths
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog_runner.sh"
WATCHDOG_PID_FILE="$CONFIG_DIR/watchdog.pid"
MINER_PID_FILE="$CONFIG_DIR/xmrig.pid"
LOG_FILE="$CONFIG_DIR/miner.log"
DEBUG_LOG="$CONFIG_DIR/debug.log"
MODE_FILE="$CONFIG_DIR/mode"

# Detect absolute path to bash in Termux
TERMUX_BASH=$(command -v bash)

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. INITIAL CHECKS ---
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${YELLOW}Warning: You are running this script as ROOT.${NC}"
    echo "Please run as a normal user. The script will ask for sudo internally."
    read -p "Press Enter to continue anyway..."
fi

mkdir -p "$CONFIG_DIR"

# --- 2. INSTALLATION (User Mode) ---

install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    pkg update -y
    pkg install -y git cmake libuv openssl clang make hwloc pkg-config termux-tools jq procps grep tsu

    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}Error: 'sudo' command not found. Install 'tsu'.${NC}"
        return 1
    fi
}

compile_xmrig() {
    echo -e "${CYAN}=== COMPILING XMRIG ===${NC}"
    if ! command -v cmake &> /dev/null; then pkg install -y git cmake libuv openssl clang make hwloc pkg-config; fi

    cd "$HOME"
    if [ -d "xmrig" ]; then cd xmrig && git pull; else git clone https://github.com/xmrig/xmrig.git && cd xmrig; fi

    rm -rf build && mkdir -p build && cd build
    echo -e "${BLUE}Configuring (No HWLOC/CUDA/OpenCL)...${NC}"
    cmake .. -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DWITH_HWLOC=OFF -DCMAKE_BUILD_TYPE=Release

    echo -e "${BLUE}Compiling...${NC}"
    make -j$(nproc)

    if [ -f "xmrig" ]; then echo -e "${GREEN}Success!${NC}"; return 0; else echo -e "${RED}Failed.${NC}"; return 1; fi
}

install_menu() {
    clear
    echo -e "${CYAN}=== INSTALL WIZARD ===${NC}"
    echo "1. Install Package"
    echo "2. Compile Source"
    echo "3. Skip"
    read -p "> " ch
    case $ch in
        1) pkg install -y xmrig; BIN="xmrig" ;;
        2) compile_xmrig && BIN="$HOME/xmrig/build/xmrig" || BIN="xmrig" ;;
        *) if [ -f "$HOME/xmrig/build/xmrig" ]; then BIN="$HOME/xmrig/build/xmrig"; else BIN="xmrig"; fi ;;
    esac
    echo "$BIN" > "$CONFIG_DIR/bin_path"
}

setup_config() {
    install_menu
    BIN_PATH=$(cat "$CONFIG_DIR/bin_path")
    rm "$CONFIG_DIR/bin_path"
    echo "AUTO" > "$MODE_FILE"

    read -p "Pool [gulf.moneroocean.stream:10128]: " pool
    pool=${pool:-gulf.moneroocean.stream:10128}
    read -p "Wallet: " wallet
    read -p "Worker: " worker

    cat <<EOF > "$ENV_FILE"
CPU_BIN=$BIN_PATH
CPU_SERVER=$pool
CPU_WALLET=$wallet
CPU_WORKER=${worker:-AndroidWorker}
CPU_THREADS=$(nproc)
EOF
}

# --- 3. BACKGROUND SERVICE (ROOT LOGIC) ---

generate_watchdog_script() {
    # CRITICAL FIX: Use the explicit Termux Bash path in the shebang
    cat <<EOF > "$WATCHDOG_SCRIPT"
#!$TERMUX_BASH

# 1. Load Environment
source "$ENV_FILE"
MODE_FILE="$MODE_FILE"
MINER_PID="$MINER_PID_FILE"
LOG="$LOG_FILE"

# 2. Optimization
echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null

# 3. Functions
is_screen_on() {
    if dumpsys window policy | grep -q "mScreenOnFully=true"; then return 0; fi
    val=\$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
    if [ "\$val" ] && [ "\$val" -gt 0 ]; then return 0; fi
    return 1
}

check_power() {
    CAP=\$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    STAT=\$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "\$CAP" -eq 100 ] && [[ "\$STAT" == "Charging" || "\$STAT" == "Full" ]]; then return 0; fi
    return 1
}

kill_miner() {
    if [ -f "\$MINER_PID" ]; then
        PID=\$(cat "\$MINER_PID")
        if kill -0 "\$PID" 2>/dev/null; then
            echo "\$(date): Stopping (\$1)" >> "\$LOG"
            kill "\$PID"
        fi
        rm "\$MINER_PID" 2>/dev/null
    fi
}

echo "\$(date): Watchdog Started" >> "\$LOG"

while true; do
    if [ ! -f "\$MODE_FILE" ]; then echo "AUTO" > "\$MODE_FILE"; fi
    MODE=\$(cat "\$MODE_FILE")
    SHOULD_MINE=false
    REASON=""

    if [ "\$MODE" == "FORCE_START" ]; then SHOULD_MINE=true
    elif [ "\$MODE" == "FORCE_STOP" ]; then SHOULD_MINE=false; REASON="Force Stop";
    else
        if check_power; then
            if ! is_screen_on; then SHOULD_MINE=true; else REASON="Screen ON"; fi
        else REASON="Power < 100%"; fi
    fi

    if [ "\$SHOULD_MINE" = true ]; then
        if [ ! -f "\$MINER_PID" ] || ! kill -0 \$(cat "\$MINER_PID") 2>/dev/null; then
            echo "\$(date): Starting Miner (\$MODE)..." >> "\$LOG"
            nohup \$CPU_BIN -o \$CPU_SERVER -u \$CPU_WALLET -p \$CPU_WORKER \\
                --threads=\$CPU_THREADS --cpu-no-yield --randomx-1gb-pages \\
                --donate-level=1 >> "\$LOG" 2>&1 &
            echo \$! > "\$MINER_PID"
        fi
    else
        kill_miner "\$REASON"
    fi
    sleep 5
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"
}

start_watchdog() {
    if ! command -v sudo &> /dev/null; then echo -e "${RED}Error: 'sudo' missing.${NC}"; return; fi

    if [ -f "$WATCHDOG_PID_FILE" ]; then
        PID=$(cat "$WATCHDOG_PID_FILE")
        if sudo kill -0 "$PID" 2>/dev/null; then
             echo -e "${YELLOW}Already running (PID: $PID).${NC}"; return
        fi
        rm "$WATCHDOG_PID_FILE"
    fi

    echo -e "${BLUE}Generating Script...${NC}"
    generate_watchdog_script

    echo -e "${GREEN}Starting Service (Grant Sudo)...${NC}"

    # Clean debug log
    echo "--- New Run ---" > "$DEBUG_LOG"

    # CRITICAL FIX: Direct output to DEBUG_LOG to catch sudo errors
    sudo nohup "$TERMUX_BASH" "$WATCHDOG_SCRIPT" >> "$DEBUG_LOG" 2>&1 &
    PID=$!
    echo $PID > "$WATCHDOG_PID_FILE"

    echo -e "${BLUE}Verifying startup...${NC}"
    sleep 2

    # Check if process is still alive using ps
    if ps -p "$PID" > /dev/null; then
        echo -e "${GREEN}Success! Service is running (PID: $PID).${NC}"
    else
        echo -e "${RED}FAILED TO START!${NC}"
        echo -e "${YELLOW}Debug Log Output:${NC}"
        cat "$DEBUG_LOG"
        rm "$WATCHDOG_PID_FILE"
    fi
}

stop_all() {
    echo -e "${RED}Stopping...${NC}"
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        PID=$(cat "$WATCHDOG_PID_FILE")
        sudo kill "$PID" 2>/dev/null
        rm "$WATCHDOG_PID_FILE"
    fi
    if [ -f "$MINER_PID_FILE" ]; then
        PID=$(cat "$MINER_PID_FILE")
        sudo kill "$PID" 2>/dev/null
        rm "$MINER_PID_FILE"
    fi
    echo "Done."
}

set_mode() { echo "$1" > "$MODE_FILE"; echo -e "Mode: ${CYAN}$1${NC}"; }

# --- 4. MENU ---

show_status() {
    echo -e "\n${CYAN}--- STATUS (v10.1) ---${NC}"
    [ ! -f "$MODE_FILE" ] && echo "AUTO" > "$MODE_FILE"
    MODE=$(cat "$MODE_FILE")

    echo -e "Mode: ${CYAN}$MODE${NC}"

    if [ -f "$WATCHDOG_PID_FILE" ] && ps -p $(cat "$WATCHDOG_PID_FILE") >/dev/null; then
        echo -e "Watchdog: ${GREEN}RUNNING${NC}"
    else
        echo -e "Watchdog: ${RED}STOPPED${NC}"
    fi

    if [ -f "$MINER_PID_FILE" ]; then echo -e "Miner:    ${GREEN}RUNNING${NC}"; else echo -e "Miner:    ${YELLOW}STOPPED${NC}"; fi

    echo "---------------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER ===${NC}"
        show_status
        echo "1. Set Mode: AUTO"
        echo "2. Set Mode: FORCE START"
        echo "3. Set Mode: FORCE STOP"
        echo "----------------------"
        echo "4. START Watchdog (Sudo)"
        echo "5. STOP Everything"
        echo "----------------------"
        echo "6. Install / Compile"
        echo "7. Edit Config"
        echo "8. View Logs (Miner & Debug)"
        echo "9. Exit"
        read -p "> " c
        case $c in
            1) set_mode "AUTO" ;;
            2) set_mode "FORCE_START" ;;
            3) set_mode "FORCE_STOP" ;;
            4) start_watchdog; read -p "Press Enter..." ;;
            5) stop_all; read -p "Press Enter..." ;;
            6) install_deps; setup_config ;;
            7) nano "$ENV_FILE" ;;
            8)
               echo -e "${YELLOW}--- DEBUG LOG ---${NC}"
               cat "$DEBUG_LOG"
               echo -e "\n${YELLOW}--- MINER LOG ---${NC}"
               tail -n 10 "$LOG_FILE"
               read -p "Press Enter..."
               ;;
            9) exit 0 ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then install_deps; setup_config; fi
main_menu
