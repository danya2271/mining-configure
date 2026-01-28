#!/bin/bash

# ============================================================
# MINING MANAGER v8.1 (FIXED EDITION)
# Оптимизировано для: RTX 4060 + Xeon E5 v3 + CachyOS + Nekoray
# Исправлено: корректное переключение потоков CPU (Active/Idle)
# ============================================================

CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env" # Новый файл для динамических переменных
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog.sh"
WATCHDOG_SERVICE="mining-watchdog.service"
GPU_SERVICE="miner-gpu.service"
CPU_SERVICE="miner-cpu.service"

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. СИСТЕМНЫЕ ФУНКЦИИ ---

install_deps() {
    echo -e "${BLUE}Установка системных компонентов...${NC}"
    if command -v yay &> /dev/null; then AUR="yay"; elif command -v paru &> /dev/null; then AUR="paru"; else echo "Нужен AUR хелпер!"; exit 1; fi
    sudo pacman -S --needed --noconfirm cuda gamemode xmrig git base-devel xprintidle

    if [ ! -f /usr/bin/gminer ] && [ ! -f /usr/bin/rigel ]; then
        echo -e "${CYAN}Выберите майнер для GPU:${NC}"
        echo "1) Gminer (Рекомендуется для RVN)"
        echo "2) Rigel"
        read -p "> " mc
        [ "$mc" == "2" ] && $AUR -S --needed --noconfirm rigel-bin || $AUR -S --needed --noconfirm gminer-bin
    fi

    # Настройка Huge Pages для Xeon
    echo -e "${BLUE}Оптимизация Huge Pages для Xeon (нужен sudo)...${NC}"
    sudo sysctl -w vm.nr_hugepages=1280
    echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/10-mining.conf > /dev/null
}

setup_config() {
    mkdir -p "$CONFIG_DIR"
    # Создаем пустой runtime файл, чтобы systemd не ругался при первом запуске
    touch "$RUNTIME_ENV"

    echo -e "${CYAN}=== МАСТЕР НАСТРОЙКИ ===${NC}"

    read -p "Кошелек GPU (Ravencoin): " gpu_wal
    read -p "Кошелек CPU (Monero): " cpu_wal
    echo -e "${YELLOW}Настройка Прокси (Nekoray):${NC}"
    echo "Введите IP:PORT (например, 127.0.0.1:2081)"
    read -p "> " proxy_input

    # Пытаемся определить путь к майнеру
    M_BIN="/usr/bin/gminer"
    [ -f /usr/bin/rigel ] && M_BIN="/usr/bin/rigel"

    cat <<EOF > "$ENV_FILE"
MINER_BIN=$M_BIN
GPU_ALGO=kawpow
GPU_SERVER=ravencoin.flypool.org:3443
GPU_WALLET=$gpu_wal
CPU_WALLET=$cpu_wal
PROXY_ADDR=$proxy_input
USE_CPU_MINING=true
CPU_THREADS_IDLE=26
CPU_THREADS_ACTIVE=2
IDLE_TIMEOUT=60
EOF
    # Инициализируем runtime значением по умолчанию
    echo "CURRENT_CPU_THREADS=2" > "$RUNTIME_ENV"

    echo -e "${GREEN}Конфигурация сохранена в $ENV_FILE${NC}"
}

create_services() {
    echo -e "${BLUE}Создание системных служб...${NC}"

    # GPU SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$GPU_SERVICE"
[Unit]
Description=GPU Miner
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
Environment=all_proxy=http://\${PROXY_ADDR}
ExecStart=\${MINER_BIN} --algo \${GPU_ALGO} --server \${GPU_SERVER} --user \${GPU_WALLET} --proxy \${PROXY_ADDR} --ssl 1
Restart=always
Nice=15
EOF

    # CPU SERVICE
    # Исправлено: теперь читает runtime.env ПОСЛЕ основного конфига
    cat <<EOF > "$HOME/.config/systemd/user/$CPU_SERVICE"
[Unit]
Description=CPU Miner
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
EnvironmentFile=$RUNTIME_ENV
# XMRig явно получает кол-во потоков через переменную.
# --cpu-no-yield помогает на Xeon при активном использовании ПК
ExecStart=/usr/bin/xmrig -o xmr-eu1.nanopool.org:14433 -u \${CPU_WALLET} --proxy=\${PROXY_ADDR} --tls -k --coin monero -t \${CURRENT_CPU_THREADS} --cpu-no-yield
Restart=always
Nice=19
EOF

    # WATCHDOG SCRIPT
    # Исправлено: запись в файл вместо set-environment
    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"
source "$ENV_FILE"

GPU_SRV="miner-gpu.service"
CPU_SRV="miner-cpu.service"
last_state="unknown"

is_video_playing() {
    # Проверка активности декодера/энкодера NVIDIA
    if command -v nvidia-smi &> /dev/null; then
        counts=$(nvidia-smi --query-gpu=utilization.decoder,utilization.encoder --format=csv,noheader,nounits)
        dec=$(echo $counts | cut -d ',' -f 1 | xargs)
        enc=$(echo $counts | cut -d ',' -f 2 | xargs)
        if [ "$dec" -gt 0 ] || [ "$enc" -gt 0 ]; then return 0; else return 1; fi
    else
        return 1
    fi
}

update_cpu_threads() {
    local threads=$1
    # Проверяем, изменилось ли значение, чтобы не перезапускать зря
    current=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" | cut -d'=' -f2)
    if [ "$current" != "$threads" ]; then
        echo "CURRENT_CPU_THREADS=$threads" > "$RUNTIME_ENV"
        [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV
    fi
}

while true; do
    idle_ms=$(xprintidle)
    idle_sec=$((idle_ms / 1000))

    if [ "$idle_sec" -lt "$IDLE_TIMEOUT" ] || is_video_playing; then
        # === ACTIVE MODE (Я за компом) ===
        if [ "$last_state" != "active" ]; then
            # Xeon MSR fix (выключение prefetch для стабильности в играх, опционально)
            sudo wrmsr -a 0x1a4 0x0 2>/dev/null

            # Останавливаем GPU майнинг
            systemctl --user stop $GPU_SRV

            # Меняем потоки CPU на 2 (или сколько указано в конфиге)
            echo "CURRENT_CPU_THREADS=$CPU_THREADS_ACTIVE" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

            last_state="active"
        fi
    else
        # === IDLE MODE (Комп простаивает) ===
        if [ "$last_state" != "idle" ]; then
            # Xeon MSR fix (включение prefetch для хэшрейта)
            sudo wrmsr -a 0x1a4 0xf 2>/dev/null

            # Меняем потоки CPU на максимум
            echo "CURRENT_CPU_THREADS=$CPU_THREADS_IDLE" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

            # Запускаем GPU майнинг
            systemctl --user start $GPU_SRV

            last_state="idle"
        fi
    fi
    sleep 5
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    # WATCHDOG SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$WATCHDOG_SERVICE"
[Unit]
Description=Mining Watchdog
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

# --- 2. ИНТЕРФЕЙС МЕНЮ ---

show_status() {
    echo -e "\n${CYAN}--- СТАТУС СИСТЕМЫ ---${NC}"
    source "$ENV_FILE" 2>/dev/null
    # Читаем текущее кол-во потоков из runtime файла
    cur_threads=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" 2>/dev/null | cut -d'=' -f2)

    echo -e "Прокси: ${YELLOW}${PROXY_ADDR:-НЕТ}${NC}"
    echo -e "Потоки CPU сейчас: ${YELLOW}${cur_threads:-UNKNOWN}${NC} (Active: $CPU_THREADS_ACTIVE / Idle: $CPU_THREADS_IDLE)"

    echo -n "Watchdog: "; systemctl --user is-active --quiet $WATCHDOG_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${RED}ВЫКЛ${NC}"
    echo -n "GPU: "; systemctl --user is-active --quiet $GPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}ОЖИДАНИЕ${NC}"
    echo -n "CPU: "; systemctl --user is-active --quiet $CPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}ОЖИДАНИЕ${NC}"
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v8.1 (FIXED) ===${NC}"
        show_status
        echo "1. Вкл/Выкл Автоматику"
        echo "2. Изменить настройки (Кошельки, Прокси, Потоки)"
        echo "3. Сбросить всё и ПЕРЕУСТАНОВИТЬ"
        echo "4. Логи: Процессор"
        echo "5. Логи: Видеокарта"
        echo "6. Логи: Контроллер (Watchdog)"
        echo "7. Выход"
        echo ""
        read -p "> " choice
        case $choice in
            1) systemctl --user is-active --quiet $WATCHDOG_SERVICE && systemctl --user stop $WATCHDOG_SERVICE $GPU_SERVICE $CPU_SERVICE || systemctl --user start $WATCHDOG_SERVICE ;;
            2) nano "$ENV_FILE" && systemctl --user restart $WATCHDOG_SERVICE ;;
            3) rm -rf "$CONFIG_DIR"; echo "Конфиг удален. Перезапустите скрипт."; exit 0 ;;
            4) journalctl --user -f -u $CPU_SERVICE ;;
            5) journalctl --user -f -u $GPU_SERVICE ;;
            6) journalctl --user -f -u $WATCHDOG_SERVICE ;;
            7) exit 0 ;;
        esac
    done
}

# Запуск
if [ ! -f "$ENV_FILE" ]; then
    install_deps
    setup_config
    create_services
fi
main_menu
