#!/bin/bash

# ============================================================
# MINING MANAGER v10.0 (Fix: Disable HWLOC & Clean Build)
# ============================================================

# Define Paths (Relative to User Home)
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog_runner.sh"
WATCHDOG_PID_FILE="$CONFIG_DIR/watchdog.pid"
MINER_PID_FILE="$CONFIG_DIR/xmrig.pid"
LOG_FILE="$CONFIG_DIR/miner.log"
MODE_FILE="$CONFIG_DIR/mode"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. INITIAL CHECKS ---

# Ensure we are NOT root (User Mode UI)
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${YELLOW}Warning: You are running this script as ROOT.${NC}"
    echo "Please run as a normal user (./script.sh). The script will ask for sudo when needed."
    echo ""
    read -p "Press Enter to continue anyway..."
fi

mkdir -p "$CONFIG_DIR"

# --- 2. INSTALLATION FUNCTIONS (User Mode) ---

install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    pkg update -y
    # Added pkg-config to help find libraries
    pkg install -y git cmake libuv openssl clang make hwloc pkg-config termux-tools jq procps grep tsu

    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}Error: 'sudo' command not found.${NC}"
        echo "Please install it: pkg install tsu (or termux-sudo)"
        return 1
    fi
}

compile_xmrig() {
    echo -e "${CYAN}=== COMPILING XMRIG (Native User Mode) ===${NC}"

    # 1. Install Build Tools if missing
    if ! command -v cmake &> /dev/null; then
        echo -e "${YELLOW}Installing build tools...${NC}"
        pkg install -y git cmake libuv openssl clang make hwloc pkg-config
    fi

    # 2. Get Source
    cd "$HOME"
    if [ -d "xmrig" ]; then
        echo -e "${BLUE}Updating XMRig source...${NC}"
        cd xmrig && git pull
    else
        echo -e "${BLUE}Cloning XMRig...${NC}"
        git clone https://github.com/xmrig/xmrig.git
        cd xmrig
    fi

    # 3. Clean Build Directory (Fix for cached errors)
    echo -e "${BLUE}Cleaning old build...${NC}"
    rm -rf build
    mkdir -p build && cd build

    # 4. Configure CMake
    echo -e "${BLUE}Configuring Build (Disabling HWLOC to fix errors)...${NC}"

    # FIX: -DWITH_HWLOC=OFF disables the library causing your error
    cmake .. \
        -DWITH_OPENCL=OFF \
        -DWITH_CUDA=OFF \
        -DWITH_HWLOC=OFF \
        -DCMAKE_BUILD_TYPE=Release

    # 5. Compile
    echo -e "${BLUE}Compiling ($(nproc) threads)...${NC}"
    make -j$(nproc)

    if [ -f "xmrig" ]; then
        echo -e "${GREEN}Compilation Successful!${NC}"
        return 0
    else
        echo -e "${RED}Compilation Failed.${NC}"
        return 1
    fi
}

install_menu() {
    clear
    echo -e "${CYAN}=== INSTALLATION WIZARD ===${NC}"
    echo "1. Install Package (Fast, Standard)"
    echo "2. Compile Source (Slow, Optimized)"
    echo "3. Skip"
    read -p "> " ch

    case $ch in
        1) pkg install -y xmrig; BIN="xmrig" ;;
        2) compile_xmrig && BIN="$HOME/xmrig/build/xmrig" || BIN="xmrig" ;;
        *)
           if [ -f "$HOME/xmrig/build/xmrig" ]; then BIN="$HOME/xmrig/build/xmrig"; else BIN="xmrig"; fi
           ;;
    esac

    echo "$BIN" > "$CONFIG_DIR/bin_path"
}

setup_config() {
    install_menu
    BIN_PATH=$(cat "$CONFIG_DIR/bin_path")
    rm "$CONFIG_DIR/bin_path"

    echo "AUTO" > "$MODE_FILE"

    echo -e "${CYAN}=== CONFIGURATION ===${NC}"
    read -p "Pool [Default: gulf.moneroocean.stream:10128]: " pool
    pool=${pool:-gulf.moneroocean.stream:10128}
    read -p "Wallet: " wallet
    read -p "Worker Name: " worker
    worker=${worker:-AndroidWorker}

    cat <<EOF > "$ENV_FILE"
CPU_BIN=$BIN_PATH
CPU_SERVER=$pool
CPU_WALLET=$wallet
CPU_WORKER=$worker
CPU_THREADS=$(nproc)
EOF
    echo -e "${GREEN}Config Saved.${NC}"
}

# --- 3. BACKGROUND SERVICE (ROOT LOGIC) ---

generate_watchdog_script() {
    # This script will be run by SUDO
    cat <<EOF > "$WATCHDOG_SCRIPT"
#!/bin/bash

# Load Config
source "$ENV_FILE"
MODE_FILE="$MODE_FILE"
MINER_PID="$MINER_PID_FILE"
LOG="$LOG_FILE"

# 1. Apply Root Optimizations
echo 1280 > /proc/sys/vm/nr_hugepages

# 2. Helper Functions
is_screen_on() {
    # Method A: Dumpsys (Most reliable)
    if dumpsys window policy | grep -q "mScreenOnFully=true"; then return 0; fi
    # Method B: Backlight
    val=\$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
    if [ "\$val" ] && [ "\$val" -gt 0 ]; then return 0; fi
    return 1
}

check_power() {
    CAP=\$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    STAT=\$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    # Strict: 100% AND Charging/Full
    if [ "\$CAP" -eq 100 ] && [[ "\$STAT" == "Charging" || "\$STAT" == "Full" ]]; then return 0; fi
    return 1
}

kill_miner() {
    REASON=\$1
    if [ -f "\$MINER_PID" ]; then
        PID=\$(cat "\$MINER_PID")
        if kill -0 "\$PID" 2>/dev/null; then
            echo "\$(date): Stopping miner (\$REASON)" >> "\$LOG"
            kill "\$PID"
        fi
        rm "\$MINER_PID" 2>/dev/null
    fi
}

echo "\$(date): Watchdog Service Started (PID: \$\$)" >> "\$LOG"

# 3. Main Loop
while true; do
    if [ ! -f "\$MODE_FILE" ]; then echo "AUTO" > "\$MODE_FILE"; fi
    MODE=\$(cat "\$MODE_FILE")

    SHOULD_MINE=false
    REASON=""

    if [ "\$MODE" == "FORCE_START" ]; then
        SHOULD_MINE=true
    elif [ "\$MODE" == "FORCE_STOP" ]; then
        SHOULD_MINE=false
        REASON="Force Stop"
    else
        # AUTO MODE
        if check_power; then
            if ! is_screen_on; then
                SHOULD_MINE=true
            else
                REASON="Screen is ON"
            fi
        else
            REASON="Power < 100% or Unplugged"
        fi
    fi

    if [ "\$SHOULD_MINE" = true ]; then
        # Miner should be running
        if [ ! -f "\$MINER_PID" ] || ! kill -0 \$(cat "\$MINER_PID") 2>/dev/null; then
            echo "\$(date): Starting Miner (Mode: \$MODE)..." >> "\$LOG"

            # Start XMRig (Sudo environment)
            nohup \$CPU_BIN -o \$CPU_SERVER -u \$CPU_WALLET -p \$CPU_WORKER \\
                --threads=\$CPU_THREADS --cpu-no-yield --randomx-1gb-pages \\
                --donate-level=1 >> "\$LOG" 2>&1 &

            echo \$! > "\$MINER_PID"
        fi
    else
        # Miner should be stopped
        kill_miner "\$REASON"
    fi

    sleep 5
done
EOF
    # Ensure script is executable
    chmod +x "$WATCHDOG_SCRIPT"
}

start_watchdog() {
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}Error: 'sudo' command missing. Please install it.${NC}"
        return
    fi

    if [ -f "$WATCHDOG_PID_FILE" ]; then
        PID=$(cat "$WATCHDOG_PID_FILE")
        if sudo kill -0 "$PID" 2>/dev/null; then
            echo -e "${YELLOW}Watchdog service is already running (PID: $PID).${NC}"
            return
        fi
        rm "$WATCHDOG_PID_FILE"
    fi

    echo -e "${BLUE}Generating Service Script...${NC}"
    generate_watchdog_script

    echo -e "${GREEN}Starting Watchdog Service... (Please grant Sudo access)${NC}"

    sudo nohup bash "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
    echo $! > "$WATCHDOG_PID_FILE"

    echo -e "${GREEN}Service Started! Check logs for details.${NC}"
    sleep 2
}

stop_all() {
    echo -e "${RED}Stopping all services... (Please grant Sudo access)${NC}"

    if [ -f "$WATCHDOG_PID_FILE" ]; then
        PID=$(cat "$WATCHDOG_PID_FILE")
        echo "Killing Watchdog (PID: $PID)..."
        sudo kill "$PID" 2>/dev/null
        rm "$WATCHDOG_PID_FILE"
    fi

    if [ -f "$MINER_PID_FILE" ]; then
        PID=$(cat "$MINER_PID_FILE")
        echo "Killing Miner (PID: $PID)..."
        sudo kill "$PID" 2>/dev/null
        rm "$MINER_PID_FILE"
    fi

    echo -e "${GREEN}All services stopped.${NC}"
    sleep 1
}

set_mode() {
    echo "$1" > "$MODE_FILE"
    echo -e "Mode set to: ${CYAN}$1${NC}"
}

# --- 4. STATUS DISPLAY ---

show_status() {
    echo -e "\n${CYAN}--- MINER STATUS (v10.0) ---${NC}"

    [ ! -f "$MODE_FILE" ] && echo "AUTO" > "$MODE_FILE"
    MODE=$(cat "$MODE_FILE")

    echo -n "Control Mode: "
    if [ "$MODE" == "FORCE_START" ]; then echo -e "${RED}FORCE START${NC}";
    elif [ "$MODE" == "FORCE_STOP" ]; then echo -e "${RED}FORCE STOP${NC}";
    else echo -e "${GREEN}AUTO (Strict)${NC}"; fi

    echo -n "Miner State:  "
    if [ -f "$MINER_PID_FILE" ]; then
         echo -e "${GREEN}Running (PID File Found)${NC}"
    else
         echo -e "${YELLOW}Stopped${NC}"
    fi

    echo -e "${BLUE}Recent Log:${NC}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 1 "$LOG_FILE"
    else
        echo "No logs yet."
    fi
    echo "---------------------------"
}

# --- 5. MAIN MENU ---

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER (Sudo Edition) ===${NC}"
        show_status
        echo "1. Set Mode: AUTO (Strict 100% + ScreenOff)"
        echo "2. Set Mode: FORCE START"
        echo "3. Set Mode: FORCE STOP"
        echo "----------------------"
        echo "4. START Watchdog (Requires Sudo)"
        echo "5. STOP Everything (Requires Sudo)"
        echo "----------------------"
        echo "6. Install / Compile XMRig"
        echo "7. Edit Config"
        echo "8. View Full Logs"
        echo "9. Exit"
        echo ""
        read -p "> " c
        case $c in
            1) set_mode "AUTO" ;;
            2) set_mode "FORCE_START" ;;
            3) set_mode "FORCE_STOP" ;;
            4) start_watchdog ;;
            5) stop_all ;;
            6) install_deps; setup_config ;;
            7) nano "$ENV_FILE" ;;
            8) tail -f "$LOG_FILE" ;;
            9) exit 0 ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then
    install_deps
    setup_config
fi

main_menu
