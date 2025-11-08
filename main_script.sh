#!/usr/bin/env bash

BASE_DIR="$(realpath "$(dirname "$0")")"
REPO_DIR="$BASE_DIR/zapret-latest"
REPO_URL="https://github.com/Flowseal/zapret-discord-youtube"
NFQWS_PATH="$BASE_DIR/nfqws"
CONF_FILE="$BASE_DIR/conf.env"
STOP_SCRIPT="$BASE_DIR/stop_and_clean_nft.sh"

DEBUG=false
NOINTERACTIVE=false
SKIP_ZAPRET_BOLVAN=false
SKIP_ZAPRET_FLOWSEAL=false

GAMEMODE_PORTS="12"

_term() {
    sudo /usr/bin/env bash $STOP_SCRIPT
}
_term

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

debug_log() {
    if $DEBUG; then
        echo "[DEBUG] $1"
    fi
}

handle_error() {
    log "Ошибка: $1"
    exit 1
}

check_dependencies() {
    local deps=("git" "nft" "grep" "sed" "curl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            handle_error "Не установлена утилита $dep"
        fi
    done
}

download_latest_zapret_release() {
    log "Загрузка последнего релиза zapret (bol-van/zapret)..."
    local releases_api="https://api.github.com/repos/bol-van/zapret/releases/latest"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local zip_url rar_url download_url archive_file extract_dir
    zip_url=$(curl -s "$releases_api" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n1 | cut -d '"' -f4)
    rar_url=$(curl -s "$releases_api" | grep -o '"browser_download_url": *"[^"]*\.rar"' | head -n1 | cut -d '"' -f4)
    if [ -n "$zip_url" ]; then
        download_url="$zip_url"
    elif [ -n "$rar_url" ]; then
        download_url="$rar_url"
    else
        handle_error "Не найден zip или rar архив в последнем релизе bol-van/zapret"
    fi
    log "Найден архив: $download_url"
    archive_file="$tmp_dir/$(basename "$download_url")"
    curl -L -o "$archive_file" "$download_url" || handle_error "Не удалось скачать архив zapret"
    extract_dir="$tmp_dir/extracted"
    mkdir -p "$extract_dir"
    if [[ "$archive_file" == *.zip ]]; then
        command -v unzip >/dev/null 2>&1 || handle_error "Не установлена утилита unzip"
        unzip -q "$archive_file" -d "$extract_dir" || handle_error "Ошибка при распаковке zip"
    elif [[ "$archive_file" == *.rar ]]; then
        command -v unrar >/dev/null 2>&1 || handle_error "Не установлена утилита unrar"
        unrar x -idq "$archive_file" "$extract_dir" || handle_error "Ошибка при распаковке rar"
    fi
    log "Архив успешно распакован в $extract_dir"
    local nfqws_file
    nfqws_file=$(find "$extract_dir" -type f -path "*/binaries/linux-x86_64/nfqws" | head -n1)
    if [ -z "$nfqws_file" ]; then
        log "Файл nfqws не найден. Список найденных бинарников:"
        find "$extract_dir" -type f -name "nfqws"
        handle_error "Не удалось найти nfqws"
    fi
    cp "$nfqws_file" "$BASE_DIR/nfqws" || handle_error "Не удалось скопировать nfqws"
    chmod +x "$BASE_DIR/nfqws"
    log "Файл nfqws успешно найден и скопирован."
    rm -rf "$tmp_dir"
    log "Временные файлы удалены"
}

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        handle_error "Файл конфигурации $CONF_FILE не найден"
    fi
    source "$CONF_FILE"
    if [ -z "$interface" ] || [ -z "$auto_update" ] || [ -z "$strategy" ]; then
        handle_error "Отсутствуют обязательные параметры в конфигурационном файле"
    fi
    if [ -z "$GAMEMODE_PORTS" ]; then
        GAMEMODE_PORTS="12"
        echo "GAMEMODE_PORTS=\"$GAMEMODE_PORTS\"" >> "$CONF_FILE"
    fi
    if [ -z "$IPSET_MODE" ]; then
        IPSET_MODE="any"
        echo "IPSET_MODE=\"$IPSET_MODE\"" >> "$CONF_FILE"
    fi
}

apply_ipset_mode() {
    local ipset_file="$REPO_DIR/lists/ipset-all.txt"
    local backup_file="$REPO_DIR/lists/ipset-all.txt.backup"
    log "Применение режима IPSET_MODE: $IPSET_MODE"
    case "$IPSET_MODE" in
        any)
            echo -n > "$ipset_file"
            log "Файл $ipset_file очищен (any)"
            ;;
        none)
            echo "203.0.113.113/32" > "$ipset_file"
            log "Файл $ipset_file записан с фиктивным адресом (none)"
            ;;
        loaded)
            if [ -f "$backup_file" ]; then
                cp "$backup_file" "$ipset_file"
                log "Файл $ipset_file восстановлен из backup (loaded)"
            else
                handle_error "Резервный файл $backup_file не найден"
            fi
            ;;
        *) log "Неизвестный IPSET_MODE: $IPSET_MODE" ;;
    esac
}

choose_ipset_mode() {
    if $NOINTERACTIVE; then
        apply_ipset_mode
        return
    fi
    echo
    echo "Выберите режим IPSET:"
    echo "1) any — очистить ipset-all.txt (пустой)"
    echo "2) none — установить 203.0.113.113/32"
    echo "3) loaded — восстановить из ipset-all.txt.backup"
    read -p "Ваш выбор (1/2/3): " choice
    case "$choice" in
        1) IPSET_MODE="any" ;;
        2) IPSET_MODE="none" ;;
        3) IPSET_MODE="loaded" ;;
        *) IPSET_MODE="any" ;;
    esac
    if grep -q '^IPSET_MODE=' "$CONF_FILE"; then
        sed -i "s|^IPSET_MODE=.*|IPSET_MODE=\"$IPSET_MODE\"|" "$CONF_FILE"
    else
        echo "IPSET_MODE=\"$IPSET_MODE\"" >> "$CONF_FILE"
    fi
    log "IPSET_MODE сохранён: $IPSET_MODE"
    apply_ipset_mode
}

choose_gamemode() {
    if $NOINTERACTIVE; then return; fi
    echo
    read -p "Включить gamemode (1024–65535)? (y/n): " gm_choice
    if [[ "$gm_choice" =~ ^[Yy]$ ]]; then
        GAMEMODE_PORTS="1024-65535"
    else
        GAMEMODE_PORTS="12"
    fi
    if grep -q '^GAMEMODE_PORTS=' "$CONF_FILE"; then
        sed -i "s|^GAMEMODE_PORTS=.*|GAMEMODE_PORTS=\"$GAMEMODE_PORTS\"|" "$CONF_FILE"
    else
        echo "GAMEMODE_PORTS=\"$GAMEMODE_PORTS\"" >> "$CONF_FILE"
    fi
    log "GAMEMODE_PORTS сохранён: $GAMEMODE_PORTS"
}

setup_repository() {
    log "Обновление zapret-latest из репозитория..."
    if [ -d "$REPO_DIR" ]; then
        sudo chown -R "$(whoami):$(whoami)" "$REPO_DIR" 2>/dev/null || true
        sudo chmod -R u+rwX "$REPO_DIR" 2>/dev/null || true
        rm -rf "$REPO_DIR" || sudo rm -rf "$REPO_DIR"
    fi
    mkdir -p "$REPO_DIR"
    TMP_DIR="$(mktemp -d)"
    git clone --depth=1 "$REPO_URL" "$TMP_DIR" || handle_error "Ошибка при клонировании"
    mkdir -p "$REPO_DIR/bin" "$REPO_DIR/lists"
    find "$TMP_DIR" -maxdepth 1 -type f -name "*.bat" -exec cp {} "$REPO_DIR" \;
    [ -d "$TMP_DIR/bin" ] && cp -r "$TMP_DIR/bin/"* "$REPO_DIR/bin/" 2>/dev/null || true
    [ -d "$TMP_DIR/lists" ] && cp -r "$TMP_DIR/lists/"* "$REPO_DIR/lists/" 2>/dev/null || true
    rm -rf "$TMP_DIR"
    log "zapret-latest успешно обновлён"
}

find_bat_files() {
    local pattern="$1"
    find "." -type f -name "$pattern" -print0
}

select_strategy() {
    cd "$REPO_DIR" || handle_error "Не удалось перейти в $REPO_DIR"
    if $NOINTERACTIVE; then
        if [ ! -f "$strategy" ]; then
            handle_error "Стратегия $strategy не найдена"
        fi
        parse_bat_file "$strategy"
        cd ..
        return
    fi
    local IFS=$'\n'
    local bat_files=($(find_bat_files "general*.bat" | xargs -0 -n1 echo) $(find_bat_files "discord.bat" | xargs -0 -n1 echo))
    if [ ${#bat_files[@]} -eq 0 ]; then
        cd ..
        handle_error "Не найдены .bat файлы"
    fi
    echo "Доступные стратегии:"
    select strategy in "${bat_files[@]}"; do
        if [ -n "$strategy" ]; then
            log "Выбрана стратегия: $strategy"
            cd ..
            break
        fi
        echo "Неверный выбор."
    done
    parse_bat_file "$REPO_DIR/$strategy"
}

parse_bat_file() {
    local file="$1"
    local queue_num=0
    local bin_path="bin/"
    while IFS= read -r line; do
        [[ "$line" =~ ^[:space:]*:: || -z "$line" ]] && continue
        line="${line//%BIN%/$bin_path}"
        line="${line//%GameFilter%/$GAMEMODE_PORTS}"
        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]](.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"
            nfqws_args="${nfqws_args//%LISTS%/lists/}"
            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            nfqws_params+=("$nfqws_args")
            ((queue_num++))
        fi
    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')
}

setup_nftables() {
    local interface="$1"
    local table_name="inet zapretunix"
    local chain_name="output"
    log "Настройка nftables..."
    if sudo nft list tables | grep -q "$table_name"; then
        sudo nft flush chain $table_name $chain_name
        sudo nft delete chain $table_name $chain_name
        sudo nft delete table $table_name
    fi
    sudo nft add table $table_name
    sudo nft add chain $table_name $chain_name { type filter hook output priority 0\; }
    local oif_clause=""
    if [ -n "$interface" ] && [ "$interface" != "any" ]; then
        oif_clause="oifname \"$interface\""
    fi
    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule $table_name $chain_name $oif_clause ${nft_rules[$queue_num]} comment \"Added by zapret script\" ||
        handle_error "Ошибка при добавлении правила nftables"
    done
}

start_nfqws() {
    log "Запуск nfqws..."
    sudo pkill -f nfqws
    cd "$REPO_DIR" || handle_error "Не удалось перейти в $REPO_DIR"
    for queue_num in "${!nfqws_params[@]}"; do
        eval "sudo $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}" ||
        handle_error "Ошибка при запуске nfqws"
    done
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -debug) DEBUG=true; shift ;;
            -nointeractive) NOINTERACTIVE=true; shift; load_config ;;
            -skipzapret) SKIP_ZAPRET_BOLVAN=true; shift ;;
            -skipflowseal) SKIP_ZAPRET_FLOWSEAL=true; shift ;;
            *) break ;;
        esac
    done
    check_dependencies
    if ! $SKIP_ZAPRET_BOLVAN; then
        if ! $NOINTERACTIVE; then
            echo
            read -p "Скачать последний релиз zapret (bol-van/zapret)? (y/n): " zapret_choice
            if [[ "$zapret_choice" =~ ^[Yy]$ ]]; then
                download_latest_zapret_release
            else
                log "Пропуск скачивания bol-van/zapret."
            fi
        else
            download_latest_zapret_release
        fi
    else
        log "Пропуск bol-van/zapret по флагу."
    fi
    if ! $SKIP_ZAPRET_FLOWSEAL; then
        if ! $NOINTERACTIVE; then
            echo
            read -p "Обновить zapret-latest из Flowseal? (y/n): " flowseal_choice
            if [[ "$flowseal_choice" =~ ^[Yy]$ ]]; then
                setup_repository
            else
                log "Пропуск обновления Flowseal/zapret-discord-youtube."
            fi
        else
            setup_repository
        fi
    else
        log "Пропуск Flowseal по флагу."
    fi
    load_config
    choose_ipset_mode
    choose_gamemode
    select_strategy
    if $NOINTERACTIVE; then
        setup_nftables "$interface"
    else
        local interfaces=("any" $(ls /sys/class/net))
        echo "Доступные интерфейсы:"
        select interface in "${interfaces[@]}"; do
            [ -n "$interface" ] && break
        done
        setup_nftables "$interface"
    fi
    start_nfqws
    log "Настройка успешно завершена"
}

main "$@"
trap _term SIGINT
sleep infinity &
wait
