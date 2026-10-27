#!/bin/bash

# ============================================
#  Автообновление Xray-core внутри контейнера
#  Репозиторий: https://github.com/bilbo111/rw-nod-x-updat
# ============================================

set -e

CONTAINER_NAME="remnanode"
INSTALL_DIR="/opt/remnanode"
SCRIPT_PATH="$INSTALL_DIR/update_xray.sh"
TEMP_DIR="/tmp/xray_update"
DOCKER_BIN_PATH="/usr/local/bin/xray"
LOG_FILE="/var/log/xray_cron_update.log"
REPO_RAW="https://raw.githubusercontent.com/bilbo111/rw-nod-x-updat/main/update_xray.sh"

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Автообновление Xray-core (remnanode) ===${NC}"
echo

# --------------------------------------------
# 0. Самоустановка скрипта (если запущен через curl)
# --------------------------------------------
if [[ "$0" == "bash" || "$0" == "/dev/fd/"* || ! -f "$SCRIPT_PATH" ]]; then
    echo -e "${YELLOW}Скрипт ещё не установлен. Устанавливаю...${NC}"
    
    mkdir -p "$INSTALL_DIR"
    
    # Скачиваем актуальную версию себя
    if ! curl -fsSL "$REPO_RAW" -o "$SCRIPT_PATH"; then
        echo -e "${RED}Ошибка: не удалось скачать скрипт с GitHub.${NC}"
        exit 1
    fi
    
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}Скрипт установлен: $SCRIPT_PATH${NC}"
    echo
fi

# --------------------------------------------
# 1. Определение архитектуры
# --------------------------------------------
ARCH=$(uname -m)

case "$ARCH" in
    x86_64|amd64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    armv7l|armhf)
        XRAY_ARCH="arm32-v7a"
        ;;
    *)
        echo -e "${RED}Ошибка: Неподдерживаемая архитектура: $ARCH${NC}"
        exit 1
        ;;
esac

echo "Архитектура: $ARCH → Xray-linux-${XRAY_ARCH}.zip"

# --------------------------------------------
# 2. Получение последней версии
# --------------------------------------------
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name": "\K[^"]+')

if [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}Ошибка: Не удалось получить версию из GitHub API.${NC}"
    exit 1
fi

echo "Последняя версия на GitHub: $LATEST_VERSION"

# --------------------------------------------
# 3. Проверка текущей версии
# --------------------------------------------
NEED_UPDATE=true

if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
    CURRENT_VERSION=$(docker exec "$CONTAINER_NAME" xray -version 2>/dev/null | head -n 1 | awk '{print $2}')
    
    if [ -n "$CURRENT_VERSION" ]; then
        echo "Текущая версия в контейнере: v$CURRENT_VERSION"
        
        if [ "v$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
            echo -e "${GREEN}Уже установлена актуальная версия. Обновление не требуется.${NC}"
            NEED_UPDATE=false
        fi
    else
        echo -e "${YELLOW}Не удалось определить текущую версию. Будем обновлять...${NC}"
    fi
else
    echo -e "${YELLOW}Контейнер $CONTAINER_NAME не запущен. Будем обновлять...${NC}"
fi

# --------------------------------------------
# 4–9. Обновление (если нужно)
# --------------------------------------------
if [ "$NEED_UPDATE" = true ]; then
    echo -e "${YELLOW}Начинаем обновление до $LATEST_VERSION...${NC}"
    
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    echo "Скачивание: $URL"
    
    if ! wget -q --show-progress "$URL" -O "$TEMP_DIR/xray.zip"; then
        echo -e "${RED}Ошибка скачивания архива.${NC}"
        exit 1
    fi
    
    if ! command -v unzip &> /dev/null; then
        echo "Устанавливаю unzip..."
        apt-get update -y && apt-get install -y unzip
    fi
    
    unzip -q "$TEMP_DIR/xray.zip" -d "$TEMP_DIR"
    
    if [ ! -f "$TEMP_DIR/xray" ]; then
        echo -e "${RED}Бинарник xray не найден после распаковки.${NC}"
        exit 1
    fi
    
    echo "Копирую бинарник в контейнер..."
    docker cp "$TEMP_DIR/xray" "${CONTAINER_NAME}:${DOCKER_BIN_PATH}"
    
    echo "Выставляю права и перезапускаю контейнер..."
    docker exec -u 0 "$CONTAINER_NAME" chmod +x "$DOCKER_BIN_PATH"
    docker restart "$CONTAINER_NAME"
    
    rm -rf "$TEMP_DIR"
    
    echo -e "${GREEN}=== Обновление успешно завершено! ===${NC}"
fi

echo

# --------------------------------------------
# 10. Предложение добавить в cron
# --------------------------------------------
if crontab -l 2>/dev/null | grep -q "update_xray.sh"; then
    echo -e "${GREEN}Автозапуск уже добавлен в cron.${NC}"
else
    echo -e "${YELLOW}Хотите добавить автоматическую проверку обновлений?${NC}"
    echo "1) Да, каждый день в 04:00"
    echo "2) Да, каждое воскресенье в 04:00"
    echo "3) Нет"
    echo
    read -p "Ваш выбор [1/2/3]: " choice
    
    case "$choice" in
        1)
            CRON_LINE="0 4 * * * $SCRIPT_PATH >> $LOG_FILE 2>&1"
            ;;
        2)
            CRON_LINE="0 4 * * 0 $SCRIPT_PATH >> $LOG_FILE 2>&1"
            ;;
        *)
            echo "Автозапуск не добавлен."
            exit 0
            ;;
    esac
    
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    
    echo -e "${GREEN}Задача добавлена в cron:${NC}"
    echo "$CRON_LINE"
    echo "Логи: $LOG_FILE"
fi
