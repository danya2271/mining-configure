#!/bin/bash

# --- ПУТИ И КОНСТАНТЫ ---
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog.sh"

GPU_SERVICE="miner-gpu.service"
CPU_SERVICE="miner-cpu.service"
WATCHDOG_SERVICE="mining-watchdog.service"

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. ПРОВЕРКА И УСТАНОВКА ---
check_install() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}Первый запуск. Начинаем настройку...${NC}"
        install_dependencies
        setup_config
        create_miner_services
        create_watchdog_script
        echo -e "${GREEN}Установка завершена!${NC}"
        read -p "Нажмите Enter для входа в меню..."
    fi
}

install_dependencies() {
    echo -e "${BLUE}=== [1/4] Установка зависимостей ===${NC}"
    if command -v yay &> /dev/null; then AUR="yay"; elif command -v paru &> /dev/null; then AUR="paru"; else
        echo -e "${RED}Ошибка: Не найден yay или paru.${NC}"; exit 1;
    fi

    sudo pacman -S --needed --noconfirm nvidia nvidia-utils cuda gamemode xmrig git base-devel xprintidle

    echo -e "${BLUE}Выберите майнер для GPU:${NC}"
    echo "1) Gminer (KawPow/RVN - Рекомендуется)"
    echo "2) Rigel (Nexa/Alephium)"
    read -p "> " min_choice

    if [ "$min_choice" == "2" ]; then
        $AUR -S --needed --noconfirm rigel-bin
        echo "MINER_BIN=/usr/bin/rigel" > /tmp/miner_path
    else
        $AUR -S --needed --noconfirm gminer-bin
        echo "MINER_BIN=/usr/bin/gminer" > /tmp/miner_path
    fi
}

setup_config() {
    echo -e "${BLUE}=== [2/4] Настройка кошельков ===${NC}"
    mkdir -p "$CONFIG_DIR"

    read -p "Кошелек GPU (RVN/NEXA): " gpu_wal
    read -p "Кошелек CPU (XMR): " cpu_wal
    [ -z "$cpu_wal" ] && cpu_wal="donate"

    source /tmp/miner_path

    # Дефолтные настройки
    if [[ "$MINER_BIN" == *"rigel"* ]]; then
        ALGO="nexapow"
        SERVER="pool.woolypooly.com:3094"
    else
        ALGO="kawpow"
        SERVER="ravencoin.flypool.org:3333"
    fi

    # В конфиге больше нет настроек питания
    cat <<EOF > "$ENV_FILE"
MINER_BIN=$MINER_BIN
GPU_ALGO=$ALGO
GPU_SERVER=$SERVER
GPU_WALLET=$gpu_wal
CPU_WALLET=$cpu_wal
# Включать ли CPU майнинг через Watchdog? (true/false)
# Т.к. у вас Unlock Turbo Boost, ставим true по умолчанию
USE_CPU_MINING=true
# Время простоя в секундах до запуска майнинга
IDLE_TIMEOUT=60
EOF
}

# --- 2. СОЗДАНИЕ СЛУЖБ МАЙНЕРОВ ---
create_miner_services() {
    echo -e "${BLUE}=== [3/4] Создание служб Systemd ===${NC}"
    mkdir -p "$HOME/.config/systemd/user/"

    # GPU Service
    cat <<EOF > "$HOME/.config/systemd/user/$GPU_SERVICE"
[Unit]
Description=GPU Miner Managed Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
# Запуск без параметров разгона/PL
ExecStart=/bin/bash -c '\$MINER_BIN --algo \$GPU_ALGO --server \$GPU_SERVER --user \$GPU_WALLET'
Restart=always
Nice=15

[Install]
WantedBy=default.target
EOF

    # CPU Service (XMRig)
    cat <<EOF > "$HOME/.config/systemd/user/$CPU_SERVICE"
[Unit]
Description=CPU Miner Managed Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
# 26 потоков из 28
ExecStart=/bin/bash -c '/usr/bin/xmrig -o xmr.nmam.net:3333 -u \$CPU_WALLET -k --coin monero -t 26'
Restart=always
Nice=19

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
}

# --- 3. СОЗДАНИЕ WATCHDOG ---
create_watchdog_script() {
    echo -e "${BLUE}=== [4/4] Настройка Watchdog ===${NC}"

    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
source "$HOME/.config/mining-manager/mining.env"

GPU_SRV="miner-gpu.service"
CPU_SRV="miner-cpu.service"

is_video_playing() {
    # Проверка NVDEC/NVENC
    counts=$(nvidia-smi --query-gpu=utilization.decoder,utilization.encoder --format=csv,noheader,nounits)
    dec=$(echo $counts | cut -d ',' -f 1 | xargs)
    enc=$(echo $counts | cut -d ',' -f 2 | xargs)
    if [ "$dec" -gt 0 ] || [ "$enc" -gt 0 ]; then return 0; else return 1; fi
}

start_miners() {
    if ! systemctl --user is-active --quiet $GPU_SRV; then
        systemctl --user start $GPU_SRV
    fi
    if [ "$USE_CPU_MINING" = "true" ]; then
        if ! systemctl --user is-active --quiet $CPU_SRV; then
            systemctl --user start $CPU_SRV
        fi
    fi
}

stop_miners() {
    if systemctl --user is-active --quiet $GPU_SRV; then
        systemctl --user stop $GPU_SRV
    fi
    if systemctl --user is-active --quiet $CPU_SRV; then
        systemctl --user stop $CPU_SRV
    fi
}

while true; do
    idle_ms=$(xprintidle)
    idle_sec=$((idle_ms / 1000))

    if [ "$idle_sec" -lt "$IDLE_TIMEOUT" ]; then
        stop_miners
    elif is_video_playing; then
        stop_miners
    else
        start_miners
    fi
    sleep 5
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat <<EOF > "$HOME/.config/systemd/user/$WATCHDOG_SERVICE"
[Unit]
Description=Mining Watchdog (Idle Detector)
After=network.target
[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now $WATCHDOG_SERVICE
}

# --- МЕНЮ ---
edit_config() {
    nano "$ENV_FILE"
    echo "Перезапуск Watchdog..."
    systemctl --user restart $WATCHDOG_SERVICE
}

toggle_watchdog() {
    if systemctl --user is-active --quiet $WATCHDOG_SERVICE; then
        systemctl --user stop $WATCHDOG_SERVICE
        systemctl --user stop $GPU_SERVICE
        systemctl --user stop $CPU_SERVICE
        echo -e "${RED}Watchdog и майнинг остановлены.${NC}"
    else
        systemctl --user start $WATCHDOG_SERVICE
        echo -e "${GREEN}Watchdog запущен.${NC}"
    fi
    read -p "Enter..."
}

force_start() {
    echo "Принудительный запуск (Watchdog остановлен)..."
    systemctl --user stop $WATCHDOG_SERVICE
    systemctl --user start $GPU_SERVICE
    [ "$(grep USE_CPU_MINING $ENV_FILE | cut -d= -f2)" == "true" ] && systemctl --user start $CPU_SERVICE
    read -p "Нажмите Enter, чтобы вернуть управление Watchdog..."
    systemctl --user start $WATCHDOG_SERVICE
}

show_status() {
    echo -e "\n${CYAN}--- СТАТУС (Lite Mode) ---${NC}"

    echo -n "Авто-режим (Watchdog): "
    if systemctl --user is-active --quiet $WATCHDOG_SERVICE; then
        source "$ENV_FILE"
        echo -e "${GREEN}ВКЛЮЧЕН${NC} (Старт через ${IDLE_TIMEOUT}с)"
    else
        echo -e "${RED}ВЫКЛЮЧЕН${NC}"
    fi

    echo -n "GPU: "
    systemctl --user is-active --quiet $GPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}ОЖИДАНИЕ${NC}"

    echo -n "CPU: "
    systemctl --user is-active --quiet $CPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}ОЖИДАНИЕ${NC}"
    echo "--------------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER (Lite / No OC) ===${NC}"
        show_status
        echo "1. Вкл/Выкл Авто-режим"
        echo "2. Настройки (Кошелек / CPU)"
        echo "3. Принудительный старт"
        echo "4. Логи GPU"
        echo "5. Логи CPU"
        echo "6. Выход"
        echo ""
        read -p "Выбор: " choice

        case $choice in
            1) toggle_watchdog ;;
            2) edit_config ;;
            3) force_start ;;
            4) journalctl --user -f -u $GPU_SERVICE ;;
            5) journalctl --user -f -u $CPU_SERVICE ;;
            6) exit 0 ;;
            *) echo "Неверно." ;;
        esac
    done
}

check_install
main_menu
