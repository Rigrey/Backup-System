#!/bin/bash

# Проверка прав администратора
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ОШИБКА: Этот скрипт должен запускаться с правами root (sudo)!" >&2
        exit 1
    fi
}

# Проверка перед выполнением основных команд
case "$1" in
    start|stop|status)
        check_root
        ;;
    help|--help|-h)
        # Помощь можно показывать без прав root
        ;;
    *)
        # Для неизвестных команд тоже проверяем права
        check_root
        ;;
esac

# Конфигурационный файл
CONFIG_FILE="/etc/backup_system.conf"
LOG_FILE="/var/log/backup_system.log"
PID_FILE="/var/run/backup_system.pid"
DEFAULT_BACKUP_RETENTION=1  # Значение по умолчанию, если не указано в конфиге

# Проверка существования конфигурационного файла
check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Ошибка: конфигурационный файл $CONFIG_FILE не найден"
        echo "Создайте файл конфигурации или используйте существующий"
        show_help
        exit 1
    fi

    if [ ! -s "$CONFIG_FILE" ]; then
        echo "Ошибка: конфигурационный файл $CONFIG_FILE пуст"
        show_help
        exit 1
    fi
}


# Функция для вывода справки
show_help() {
cat << EOF
Система автоматического резервного копирования

Использование: $0 {start|stop|status|help}

Команды:
start     - запуск системы бэкапа в фоновом режиме
stop      - остановка системы бэкапа
status    - проверка статуса работы системы бэкапа
help      - показать эту справку

Формат конфигурационного файла ($CONFIG_FILE):
Каждая строка содержит параметры, разделенные символом '|':
исходная_директория|директория_бэкапов|пароль|расписание|[retention]

Параметры:
исходная_директория - путь к директории для бэкапа
директория_бэкапов  - где хранить резервные копии
пароль              - пароль для шифрования бэкапа
расписание          - когда делать бэкап (форматы:
HH:MM - конкретное время
hourly - каждый час
daily - ежедневно в 00:00
weekly - еженедельно в понедельник в 00:00)
retention           - (опционально) сколько копий хранить (по умолчанию 1)

Примеры строк конфигурации:
/home/user|/backups|secret123|daily|3
/var/www|/backups|qwerty|weekly|5
/etc|/backups|adminpass|12:00|7
/data|/backups|mypass|hourly    # будет использовано retention=1 (по умолчанию)

Поддерживаемые архиваторы: pigz, gzip, xz, bzip2, zip, tar (автовыбор)
Шифрование: GPG с алгоритмом AES256

Создайте файл $CONFIG_FILE с нужными настройками перед запуском.
EOF
}

# Функция для определения доступных архиваторов
detect_archivers() {
ARCHIVERS=()

# Проверяем доступные архиваторы в порядке предпочтения
if command -v pigz &>/dev/null; then
    ARCHIVERS+=("pigz" "pigz -c" "tar.gz" "gzip")
fi

if command -v gzip &>/dev/null; then
    ARCHIVERS+=("gzip" "gzip -c" "tar.gz" "gzip")
fi

if command -v xz &>/dev/null; then
    ARCHIVERS+=("xz" "xz -c" "tar.xz" "xz")
fi

if command -v bzip2 &>/dev/null; then
    ARCHIVERS+=("bzip2" "bzip2 -c" "tar.bz2" "bzip2")
fi

# Добавляем поддержку обычного tar (без сжатия)
ARCHIVERS+=("tar" "cat" "tar" "tar")

# Добавляем поддержку zip (отдельная обработка)
if command -v zip &>/dev/null; then
    ARCHIVERS+=("zip" "" "zip" "zip")
fi

if [ ${#ARCHIVERS[@]} -eq 0 ]; then
    log "Ошибка: не найден ни один архиватор (gzip/pigz/xz/bzip2/zip/tar)"
    exit 1
fi

# Выбираем первый доступный архиватор
for ((i=0; i<${#ARCHIVERS[@]}; i+=4)); do
    if command -v "${ARCHIVERS[i]}" &>/dev/null || [ "${ARCHIVERS[i]}" == "tar" ]; then
        COMPRESSOR=${ARCHIVERS[i]}
        COMPRESSOR_CMD=${ARCHIVERS[i+1]}
        EXT=${ARCHIVERS[i+2]}
        ARCHIVER_TYPE=${ARCHIVERS[i+3]}
        break
    fi
done

log "Используется архиватор: $COMPRESSOR (расширение .$EXT)"
}

# Функция логирования
log() {
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция создания архива
create_archive() {
local src_dir="$1"
local backup_file="$2"
local password="$3"
local backup_retention="$4"

case $ARCHIVER_TYPE in
gzip|xz|bzip2|tar)
# Для tar/gzip/xz/bzip2 используем пайплайн через tar
tar cf - -C "$(dirname "$src_dir")" "$(basename "$src_dir")" | \
$COMPRESSOR_CMD | \
gpg --batch --yes --passphrase "$password" --cipher-algo AES256 --symmetric -o "$backup_file"
;;
zip)
# Для zip используем отдельную обработку
(cd "$(dirname "$src_dir")" && \
zip -r -P "$password" - "$(basename "$src_dir")" | \
gpg --batch --yes --passphrase "$password" --cipher-algo AES256 --symmetric -o "$backup_file")
;;
*)
log "Неизвестный тип архиватора: $ARCHIVER_TYPE"
return 1
;;
esac

if tar cf - -C "$(dirname "$src_dir")" "$(basename "$src_dir")" | \
$COMPRESSOR_CMD | \
gpg --batch --yes --passphrase "$password" --cipher-algo AES256 --symmetric -o "$backup_file"; then
log "Бэкап успешно создан: $backup_file"

# Удаляем старые бэкапы с учетом индивидуального retention для каждой записи
(cd "$(dirname "$backup_file")" && \
find . -maxdepth 1 -name "backup_$(basename "$src_dir")_*.${EXT}.gpg" -printf "%T@ %p\n" | \
sort -rn | cut -d' ' -f2- | tail -n +$((backup_retention + 1)) | xargs -r rm -f)
else
log "Ошибка при создании бэкапа $backup_file"
return 1
fi
}

# Функция создания бэкапа
create_backup() {
local src_dir="$1"
local backup_dir="$2"
local password="$3"
local backup_retention="$4"

if [ ! -d "$src_dir" ]; then
    log "Ошибка: исходная директория $src_dir не существует"
    return 1
fi

mkdir -p "$backup_dir" || {
log "Ошибка: не удалось создать директорию для бэкапов $backup_dir"
return 1
}

# Создаем имя файла с timestamp
local timestamp
timestamp=$(date '+%Y%m%d_%H%M%S')
local backup_name
backup_name="backup_$(basename "$src_dir")_${timestamp}.${EXT}.gpg"

log "Создание бэкапа backup_name с использованием $COMPRESSOR, retention=$backup_retention"

# Создаем архив
create_archive "$src_dir" "$backup_name" "$password" "$backup_retention"
}

# Функция для парсинга конфига
parse_config_line() {
local line="$1"

# Пропускаем комментарии и пустые строки
[[ "$line" =~ ^# ]] || [[ -z "$line" ]] && return 1

# Разбираем строку конфига
IFS='|' read -r src_dir backup_dir password schedule retention <<< "$line"

# Удаляем лишние пробелы
src_dir=$(echo "$src_dir" | xargs)
backup_dir=$(echo "$backup_dir" | xargs)
password=$(echo "$password" | xargs)
schedule=$(echo "$schedule" | xargs)
retention=$(echo "$retention" | xargs)

# Если retention не указан, используем значение по умолчанию
if [[ -z "$retention" ]]; then
    retention=$DEFAULT_BACKUP_RETENTION
fi

# Проверяем, что retention - это число
if ! [[ "$retention" =~ ^[0-9]+$ ]]; then
    log "Ошибка: неправильное значение retention '$retention' для директории $src_dir. Используется значение по умолчанию $DEFAULT_BACKUP_RETENTION"
    retention=$DEFAULT_BACKUP_RETENTION
fi

echo "$src_dir|$backup_dir|$password|$schedule|$retention"
}

# Функция для запуска по расписанию
run_scheduled_backups() {
while read -r line; do
    # Парсим строку конфига
    parsed_line=$(parse_config_line "$line")
    [ -z "$parsed_line" ] && continue

    IFS='|' read -r src_dir backup_dir password schedule retention <<< "$parsed_line"

    # Проверяем расписание
    current_hour=$(date '+%H:%M')
    current_day=$(date '+%A')

    case "$schedule" in
    [0-9][0-9]:[0-9][0-9])
    if [ "$current_hour" = "$schedule" ]; then
        create_backup "$src_dir" "$backup_dir" "$password" "$retention"
    fi
    ;;
    "hourly")
    create_backup "$src_dir" "$backup_dir" "$password" "$retention"
    ;;
    "daily")
    if [ "$current_hour" = "00:00" ]; then
        create_backup "$src_dir" "$backup_dir" "$password" "$retention"
    fi
    ;;
    "weekly")
    if [ "$current_hour" = "00:00" ] && [ "$current_day" = "Monday" ]; then
        create_backup "$src_dir" "$backup_dir" "$password" "$retention"
    fi
    ;;
    *)
    log "Неизвестное расписание: $schedule для директории $src_dir"
    ;;
esac
done < "$CONFIG_FILE"
}

# Функция демонизации
daemonize() {
# Перенаправляем вывод
exec 1>>"$LOG_FILE"
exec 2>>"$LOG_FILE"

# Удаляем старый PID-файл
rm -f "$PID_FILE"

# Пишем PID текущего процесса
echo $$ > "$PID_FILE"

# Основной цикл демона
while true; do
    run_scheduled_backups
    sleep 60  # Проверяем каждую минуту
done
}


# Основной код
case "$1" in
    start)
        check_config_file  # Добавлена проверка конфига
        echo "Запуск системы бэкапа"
        detect_archivers
        daemonize &
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill "$(cat "$PID_FILE")"
            rm -f "$PID_FILE"
            echo "Система бэкапа остановлена"
        else
            echo "Система бэкапа не запущена"
        fi
        ;;
    status)
        if [ -f "$PID_FILE" ]; then
            echo "Система бэкапа работает (PID: $(cat "$PID_FILE"))"
        else
            echo "Система бэкапа не запущена"
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Использование: $0 {start|stop|status|help}"
        exit 1
        ;;
esac

exit 0
