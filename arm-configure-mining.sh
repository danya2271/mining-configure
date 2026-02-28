#!/bin/bash

# ============================================================
# MINING MANAGER v11.7 (Ubuntu Minimal Fix)
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
touch "$LOG_FILE" "$DEBUG_LOG"
chmod 777 "$LOG_FILE" "$DEBUG_LOG" 2>/dev/null

# --- 2. AGGRESSIVE AUTO-REPAIR ---

fix_binary_path() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        # Пропускаем проверку, если это PRoot
        if [[ "$CPU_BIN" != "coreminer_proot" ]]; then
             if [ ! -f "$CPU_BIN" ] && ! command -v "$CPU_BIN" >/dev/null 2>&1; then
                echo -e "${RED}Error: Configured binary '$CPU_BIN' missing.${NC}"
                SYSTEM_BIN=$(command -v xmrig)
                if [ -x "$SYSTEM_BIN" ]; then
                    echo -e "${GREEN}Repaired via System XMRig!${NC}"
                    sed -i "s|^CPU_BIN=.*|CPU_BIN=$SYSTEM_BIN|" "$ENV_FILE"
                    CPU_BIN=$SYSTEM_BIN
                fi
            fi
        fi
    fi
}

# --- 3. INSTALLATION ---

install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    pkg update -y
    pkg install -y git cmake libuv openssl clang make hwloc pkg-config termux-tools jq procps grep tsu curl tar proot-distro
    if ! command -v sudo &> /dev/null; then echo -e "${RED}Error: 'sudo' missing.${NC}"; return 1; fi
}

install_coreminer() {
    echo -e "${CYAN}=== INSTALLING COREMINER (via Ubuntu Minimal) ===${NC}"
    echo -e "${YELLOW}Alpine failed due to glibc incompatibility. Switching to Ubuntu...${NC}"

    pkg install -y proot-distro wget tar

    # Удаляем старую установку если была
    echo -e "${BLUE}Cleaning old containers...${NC}"
    proot-distro remove alpine 2>/dev/null
    proot-distro remove ubuntu 2>/dev/null

    echo -e "${BLUE}Installing Ubuntu...${NC}"
    proot-distro install ubuntu

    echo -e "${BLUE}Configuring & Cleaning...${NC}"
    # Устанавливаем, качаем майнер и СРАЗУ чистим кэш apt для экономии места
    proot-distro login ubuntu -- bash -c "apt-get update && \
    apt-get install -y wget tar --no-install-recommends && \
    wget -qO /root/coreminer.tar.gz https://github.com/catchthatrabbit/coreminer/releases/download/v0.19.89/coreminer-linux-arm64.tar.gz && \
    cd /root && tar -xzf coreminer.tar.gz && \
    rm /root/coreminer.tar.gz && \
    chmod +x /root/coreapp/coreminer && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*"

    if proot-distro login ubuntu -- test -x /root/coreapp/coreminer; then
         echo -e "${GREEN}Success! CoreMiner installed in Ubuntu.${NC}"
         return 0
    else
         echo -e "${RED}Failed to install CoreMiner.${NC}"
         return 1
    fi
}

install_menu() {
    clear
    echo -e "${CYAN}=== INSTALL WIZARD ===${NC}"
    echo "1. Install XMRig Package"
    echo "2. Compile XMRig Source"
    echo "3. Install CoreMiner via Ubuntu (Stable)"
    echo "4. Skip"
    read -p "> " ch
    case $ch in
        1) pkg install -y xmrig; BIN=$(command -v xmrig) ;;
        2) BIN=$(command -v xmrig) ;;
        3) install_coreminer; BIN="coreminer_proot" ;;
        *)
            if grep -q "coreminer_proot" "$ENV_FILE" 2>/dev/null; then BIN="coreminer_proot"; else BIN=$(command -v xmrig); fi ;;
    esac
    [ -z "$BIN" ] && BIN="xmrig"
    echo "$BIN" > "$CONFIG_DIR/bin_path"
}

setup_config() {
    install_menu
    BIN_PATH=$(cat "$CONFIG_DIR/bin_path")
    rm "$CONFIG_DIR/bin_path"
    echo "AUTO" > "$MODE_FILE"

    local default_pool="gulf.moneroocean.stream:10128"
    if [ "$BIN_PATH" == "coreminer_proot" ]; then
        default_pool="51.15.18.10:1905"
    fi

    read -p "Pool [$default_pool]: " pool; pool=${pool:-$default_pool}
    read -p "Wallet: " wallet
    read -p "Worker [AndroidWorker]: " worker; worker=${worker:-AndroidWorker}
    read -p "Threads [$(nproc)]: " threads; threads=${threads:-$(nproc)}

    cat <<EOF > "$ENV_FILE"
CPU_BIN=$BIN_PATH
CPU_SERVER=$pool
CPU_WALLET=$wallet
CPU_WORKER=$worker
CPU_THREADS=$threads
EOF
}

# --- 4. BACKGROUND SERVICE ---

generate_watchdog_script() {
    cat <<EOF > "$WATCHDOG_SCRIPT"
#!${TERMUX_BASH}
# WATCHDOG SCRIPT (v11.7)
ENV_FILE="${ENV_FILE}"
MODE_FILE="${MODE_FILE}"
MINER_PID_FILE="${MINER_PID_FILE}"
LOG_FILE="${LOG_FILE}"

export PREFIX=/data/data/com.termux/files/usr
export PATH=\$PREFIX/bin:\$PATH

touch "\$MINER_PID_FILE"
chmod 644 "\$MINER_PID_FILE"
source "\$ENV_FILE"

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
    if [ -f "\$MINER_PID_FILE" ]; then
        PID=\$(cat "\$MINER_PID_FILE")
        if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
            echo "\$(date): Stopping miner (\$1)" >> "\$LOG_FILE"
            kill "\$PID"
            pkill -f coreminer 2>/dev/null
        fi
        > "\$MINER_PID_FILE"
    fi
}

while true; do
    if [ ! -f "\$MODE_FILE" ]; then echo "AUTO" > "\$MODE_FILE"; fi
    MODE=\$(cat "\$MODE_FILE")
    SHOULD_MINE=false; REASON=""

    if [ "\$MODE" == "FORCE_START" ]; then SHOULD_MINE=true
    elif [ "\$MODE" == "FORCE_STOP" ]; then SHOULD_MINE=false; REASON="Force Stop"
    else
        if check_power; then
            if ! is_screen_on; then SHOULD_MINE=true; else REASON="Screen ON"; fi
        else REASON="Power < 100%"; fi
    fi

    CURRENT_PID=\$(cat "\$MINER_PID_FILE")
    if [ "\$SHOULD_MINE" = true ]; then
        if [ -z "\$CURRENT_PID" ] || ! kill -0 "\$CURRENT_PID" 2>/dev/null; then
            echo "\$(date): Starting Miner (\$MODE)..." >> "\$LOG_FILE"

            if [ "\$CPU_BIN" == "coreminer_proot" ]; then
                # RUN UBUNTU
                nohup proot-distro login ubuntu -- /root/coreapp/coreminer -P "stratum+tcp://\${CPU_WALLET}.\${CPU_WORKER}:x@\${CPU_SERVER}" -t "\$CPU_THREADS" >> "\$LOG_FILE" 2>&1 &
            else
                # RUN XMRIG
                nohup "\$CPU_BIN" -o "\$CPU_SERVER" -u "\$CPU_WALLET" -p "\$CPU_WORKER" --threads="\$CPU_THREADS" --cpu-no-yield --randomx-1gb-pages --donate-level=1 --config=/dev/null --no-color --log-file="\$LOG_FILE" --print-time=30 > /dev/null 2>&1 &
            fi
            echo \$! > "\$MINER_PID_FILE"
        fi
    else kill_miner "\$REASON"; fi
    sleep 5
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"
}

start_watchdog() {
    fix_binary_path
    if ! command -v sudo &> /dev/null; then echo -e "${RED}Error: 'sudo' missing.${NC}"; return; fi
    stop_all
    echo "--- Startup Log ---" > "$DEBUG_LOG"
    sudo chmod -R 777 "$CONFIG_DIR" 2>/dev/null
    generate_watchdog_script
    sudo nohup "$TERMUX_BASH" "$WATCHDOG_SCRIPT" >> "$DEBUG_LOG" 2>&1 &
    sleep 2
    local PID; PID=$(pgrep -f "watchdog_runner.sh")
    if [ -n "$PID" ]; then
        echo "$PID" | sudo tee "$WATCHDOG_PID_FILE" > /dev/null
        echo -e "${GREEN}Watchdog running (PID: $PID).${NC}"
    else
        echo -e "${RED}FAILED. Check debug.log.${NC}"
    fi
}

stop_all() {
    echo -e "${RED}Stopping...${NC}"
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local WPID; WPID=$(cat "$WATCHDOG_PID_FILE")
        if [ -n "$WPID" ]; then sudo kill "$WPID" 2>/dev/null; fi
    fi
    sudo pkill -f watchdog_runner.sh
    sudo pkill -f xmrig
    sudo pkill -f coreminer
    sudo rm -f "$WATCHDOG_PID_FILE"
    if [ -f "$MINER_PID_FILE" ]; then sudo sh -c '> "$MINER_PID_FILE"'; fi
    echo "Done."
}

set_mode() { echo "$1" > "$MODE_FILE"; echo -e "Mode: ${CYAN}$1${NC}"; }

show_status() {
    echo -e "\n${CYAN}--- STATUS (v11.7 Ubuntu) ---${NC}"
    [ ! -f "$MODE_FILE" ] && echo "AUTO" > "$MODE_FILE"
    MODE=$(cat "$MODE_FILE")
    echo -e "Mode: ${CYAN}$MODE${NC}"

    if pgrep -f "watchdog_runner.sh" > /dev/null; then echo -e "Watchdog: ${GREEN}RUNNING${NC}"; else echo -e "Watchdog: ${RED}STOPPED${NC}"; fi

    local MINER_IS_RUNNING=false
    if [ -f "$MINER_PID_FILE" ]; then
        local MINER_PID; MINER_PID=$(sudo cat "$MINER_PID_FILE")
        if [ -n "$MINER_PID" ] && sudo kill -0 "$MINER_PID" 2>/dev/null; then MINER_IS_RUNNING=true; fi
    fi

    if [ "$MINER_IS_RUNNING" = true ]; then
        if grep -q "coreminer_proot" "$ENV_FILE" 2>/dev/null; then
            echo -e "Miner:    ${GREEN}RUNNING (CoreMiner/Ubuntu)${NC}"
        else
            echo -e "Miner:    ${GREEN}RUNNING (XMRig)${NC}"
        fi
    else
        echo -e "Miner:    ${YELLOW}STOPPED${NC}"
    fi
    echo "---------------------------"
}

view_logs() {
    echo -e "${BLUE}1. Snapshot${NC}"; echo -e "${BLUE}2. Stream${NC}"; echo -e "${BLUE}3. Clear${NC}"
    read -p "> " lch
    case $lch in
        1) tail -n 20 "$LOG_FILE"; read -p "...";;
        2) tail -f "$LOG_FILE";;
        3) echo "" > "$LOG_FILE"; echo "Cleared."; sleep 1;;
    esac
}

main_menu() {
    if [ ! -f "$ENV_FILE" ]; then install_deps; setup_config; fi
    fix_binary_path
    while true; do
        clear; echo -e "${BLUE}=== MINING MANAGER ===${NC}"; show_status
        echo "1. Set Mode: AUTO"; echo "2. Set Mode: FORCE START"; echo "3. Set Mode: FORCE STOP"
        echo "4. START Watchdog (Sudo)"; echo "5. STOP Everything"
        echo "6. Install / Re-Configure"; echo "7. Edit Config"; echo "8. Logs"; echo "9. Exit"
        read -p "> " c
        case $c in
            1) set_mode "AUTO" ;; 2) set_mode "FORCE_START" ;; 3) set_mode "FORCE_STOP" ;;
            4) start_watchdog; read -p "..." ;; 5) stop_all; read -p "..." ;;
            6) install_deps; setup_config ;; 7) nano "$ENV_FILE" ;; 8) view_logs ;; 9) exit 0 ;;
        esac
    done
}

main_menu
