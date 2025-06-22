#!/bin/bash

# Конфигурационные параметры
SCRIPT_NAME="qos-setup"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
CONFIG_PATH="/etc/${SCRIPT_NAME}.conf"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
SYSTEMD_SERVICE="/etc/systemd/system/${SCRIPT_NAME}.service"
SYSTEMD_TIMER="/etc/systemd/system/${SCRIPT_NAME}.timer"

# Константы для настройки QoS
RESERVED_PERCENT=5     # Процент резервной полосы для системы
MIN_CEIL_PERCENT=105   # Процент для ceil (rate * 1.05)
UDP_CONNTRACK_FLAGS="-u" # Флаг для UDP в conntrack
IPV6_MATCH_PREFIX="ip6" # Префикс для IPv6 в фильтрах

# Дефолтные значения конфигурации
DEFAULT_INTERFACE=""
DEFAULT_PROTOCOLS=("tcp" "udp")
DEFAULT_IPV6="n"
DEFAULT_TOTAL_SPEED=100
DEFAULT_MIN_SPEED=5
DEFAULT_DEFAULT_SPEED=1
DEFAULT_PORTS=(80 443)

# Функции проверки ввода
is_number() { [[ $1 =~ ^[0-9]+$ ]]; }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_ip() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ $1 =~ ^([0-9a-fA-F:]+:+)+[0-9a-fA-F]+$ ]]; }

# Функция логирования
log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# Обработка ошибок
error_exit() {
  log "Ошибка: $*" >&2
  exit 1
}

# Функция автоматического определения сетевого интерфейса
detect_interface() {
  # Попытка найти активный интерфейс через маршрут по умолчанию
  # Этот метод наиболее надежен и подходит для большинства систем
  IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
  
  # Если маршрут по умолчанию не найден, ищем среди активных интерфейсов
  if [[ -z "$IFACE" ]]; then
	IFACE=$(ip link show | grep -v "lo" | grep "state UP" | head -n1 | awk '{print $2}' | sed 's/://')
  fi
  
  echo "$IFACE"
}

# Проверка доступа к /proc/net для работы с conntrack
check_proc_net_access() {
  # Проверяем доступ к основным файлам, необходимым для работы conntrack
  # nf_conntrack содержит информацию о текущих соединениях
  # ip_tables_names содержит информацию о таблицах правил
  if ! [ -r "/proc/net/nf_conntrack" ] || ! [ -r "/proc/net/ip_tables_names" ]; then
	log "Предупреждение: Ограниченный доступ к /proc/net. Это может повлиять на работу conntrack."
	read -p "Продолжить выполнение? (y/N): " CONTINUE
	[[ "${CONTINUE,,}" != "y" ]] && error_exit "Отменено пользователем"
  fi
}

# Расширенная проверка поддержки IPv6
check_ipv6_support() {
  if [[ "$USE_IPV6" == "y" ]]; then
	# Проверка загруженности модуля ядра для HTB
	if ! modprobe -n -v sch_htb &>/dev/null; then
	  error_exit "Модуль ядра для HTB не загружен"
	fi
	
	# Проверка наличия маршрута по умолчанию IPv6
	if ! ip -6 route show default &>/dev/null; then
	  error_exit "IPv6 не настроен в системе. Пожалуйста, настройте IPv6 перед продолжением."
	fi
	
	# Проверка необходимых модулей для фильтрации IPv6
	if ! modprobe -n -v ip6_tables &>/dev/null; then
	  log "Предупреждение: Модуль для фильтрации `ip6_tables` не загружен. Убедитесь, что он загружается при запуске системы."
	fi
	
	# Проверка наличия утилит для работы с IPv6
	if ! command -v ip6tables &>/dev/null; then
	  log "Предупреждение: Утилита ip6tables не установлена. Рекомендуется установить пакет ip6tables для продвинутой настройки IPv6."
	fi
  fi
}

# Сохранение конфигурации
save_config() {
  # Сохраняем текущую конфигурацию в файл с ограниченными правами
  # Это позволяет повторно использовать настройки в неинтерактивном режиме
  cat > "$CONFIG_PATH" << EOF
IFACE="$IFACE"
IP_MATCH="$IP_MATCH"
PROTOCOLS=(${PROTOCOLS[@]})
USE_IPV6="$USE_IPV6"
TOTAL="$TOTAL"
MIN="$MIN"
DEFAULT="$DEFAULT"
PORTS=(${PORTS[@]})
SETUP_SYSTEMD="$SETUP_SYSTEMD"
EOF
  chmod 600 "$CONFIG_PATH"
  log "Конфигурация сохранена в $CONFIG_PATH"
}

# Загрузка конфигурации
load_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
	source "$CONFIG_PATH"
	return 0
  fi
  return 1
}

# Очистка старых правил QoS
clear_rules() {
  log "Очистка старых правил..."
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
  tc filter del dev "$IFACE" parent ffff: protocol all 2>/dev/null || true
}

# Проверка и установка необходимых пакетов
check_and_install_packages() {
  local missing_packages=()
  
  # Проверка наличия основных утилит
  for cmd in tc ip conntrack; do
	if ! command -v "$cmd" &>/dev/null; then
	  missing_packages+=("iproute2")
	fi
  done
  
  # Дополнительная проверка для conntrack-tools
  if ! command -v conntrack &>/dev/null; then
	missing_packages+=("conntrack-tools")
  fi
  
  if [[ ${#missing_packages[@]} -gt 0 ]]; then
	echo "Необходимые пакеты не установлены: ${missing_packages[@]}"
	read -p "Хотите установить их сейчас? (y/N): " INSTALL_PACKAGES
	if [[ "${INSTALL_PACKAGES,,}" == "y" ]]; then
	  log "Установка необходимых пакетов..."
	  apt-get update || error_exit "Не удалось обновить список пакетов"
	  apt-get install -y "${missing_packages[@]}" || error_exit "Не удалось установить пакеты"
	else
	  error_exit "Необходимые утилиты не установлены. Установите вручную: ${missing_packages[@]}"
	fi
  fi
}

# Проверка суммарной полосы пропускания
validate_bandwidth() {
  local CLIENT_SPEED=$1
  local CLIENT_COUNT=$2
  
  # Расчет суммарной полосы с учетом всех клиентов и резерва
  local TOTAL_ALLOCATED=$(( CLIENT_SPEED * CLIENT_COUNT + DEFAULT ))
  
  if (( TOTAL_ALLOCATED > TOTAL )); then
	error_exit "Суммарная полоса ($TOTAL_ALLOCATED Mbit/s) превышает общую ($TOTAL Mbit/s)"
  fi
}

# Настройка QoS
setup_qos() {
  # Проверка поддержки IPv6
  check_ipv6_support
  
  # Проверка доступа к /proc/net
  check_proc_net_access
  
  # Очистка старых правил
  clear_rules

  # HTB настройка
  log "Настройка HTB..."
  tc qdisc add dev "$IFACE" root handle 1: htb default 9999 || error_exit "Не удалось создать qdisc"
  tc class add dev "$IFACE" parent 1: classid 1:1 htb rate ${TOTAL}mbit ceil ${TOTAL}mbit || error_exit "Не удалось создать класс"

  # Сбор клиентов
  log "Сбор клиентов..."
  CLIENTS=""
  for proto in "${PROTOCOLS[@]}"; do
	for port in "${PORTS[@]}"; do
	  if [[ "$proto" == "udp" ]]; then
		CONN=$(conntrack -L -p udp --dport "$port" $UDP_CONNTRACK_FLAGS 2>/dev/null)
	  else
		CONN=$(conntrack -L -p tcp --dport "$port" 2>/dev/null)
	  fi
	  
	  if [[ -n "$CONN" ]]; then
		CLIENTS+=$(echo "$CONN" | awk -v m="$IP_MATCH" '
		  {
			for(i=1;i<=NF;i++) {
			  if($i ~ m"=") {
				split($i, a, "="); 
				print a[2]
			  }
			}
		  }')
		CLIENTS+=$'\n'
	  fi
	done
  done

  # Очистка и фильтрация клиентов
  CLIENTS=$(echo "$CLIENTS" | grep -v '^$' | sort -u)
  [[ $USE_IPV6 != y ]] && CLIENTS=$(echo "$CLIENTS" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')

  CLIENT_COUNT=$(echo "$CLIENTS" | wc -l)
  log "Найдено клиентов: $CLIENT_COUNT"

  if (( CLIENT_COUNT == 0 )); then
	log "Нет активных клиентов. Назначаем политику по умолчанию."
	tc class add dev "$IFACE" parent 1:1 classid 1:9999 htb rate ${DEFAULT}mbit ceil ${DEFAULT}mbit || error_exit "Не удалось создать класс по умолчанию"
	tc qdisc add dev "$IFACE" parent 1:9999 handle 9999: sfq || error_exit "Не удалось создать очередь по умолчанию"
	exit 0
  fi

  # Расчет скорости с учетом резерва
  CLIENT_SPEED=$(( (TOTAL * (100 - RESERVED_PERCENT) / 100) / CLIENT_COUNT ))
  
  # Проверка минимальной скорости
  if (( CLIENT_SPEED < MIN )); then
	log "Предупреждение: клиентская скорость меньше минимума. Используется минимум: $MIN"
	CLIENT_SPEED=$MIN
	
	# Проверка суммарной полосы
	validate_bandwidth $CLIENT_SPEED $CLIENT_COUNT
  else
	# Проверка суммарной полосы
	validate_bandwidth $CLIENT_SPEED $CLIENT_COUNT
  fi

  CLASS_ID=10
  for ip in $CLIENTS; do
	if is_ip "$ip" || [[ $USE_IPV6 == y && is_ipv6 "$ip" ]]; then
	  log "Настройка для $ip: ${CLIENT_SPEED}mbit"
	  
	  # Вычисляем ceil с учетом процента
	  CEIL_SPEED=$(( CLIENT_SPEED * MIN_CEIL_PERCENT / 100 ))
	  
	  # Добавляем класс
	  tc class add dev "$IFACE" parent 1:1 classid 1:$CLASS_ID htb rate ${CLIENT_SPEED}mbit ceil ${CEIL_SPEED}mbit || error_exit "Не удалось создать класс для $ip"
	  
	  # Добавляем очередь
	  tc qdisc add dev "$IFACE" parent 1:$CLASS_ID handle $CLASS_ID: sfq perturb 10 || error_exit "Не удалось создать очередь для $ip"
	  
	  # Добавляем фильтр с учётом IP-версии
	  if is_ip "$ip"; then
		tc filter add dev "$IFACE" protocol ip u32 match ip $IP_MATCH $ip flowid 1:$CLASS_ID || log "Предупреждение: не удалось создать фильтр для $ip"
	  elif [[ $USE_IPV6 == y && is_ipv6 "$ip" ]]; then
		# Современная фильтрация IPv6
		tc filter add dev "$IFACE" protocol ipv6 u32 match ${IPV6_MATCH_PREFIX} $IP_MATCH $ip/128 flowid 1:$CLASS_ID || log "Предупреждение: не удалось создать IPv6 фильтр для $ip"
		log "Предупреждение: Для продвинутой IPv6 фильтрации рекомендуется использовать clsact и BPF программы"
	  fi
	  
	  (( CLASS_ID++ ))
	fi
  done

  log "Класс по умолчанию: ${DEFAULT}mbit"
  tc class add dev "$IFACE" parent 1:1 classid 1:9999 htb rate ${DEFAULT}mbit ceil ${DEFAULT}mbit || error_exit "Не удалось создать класс по умолчанию"
  tc qdisc add dev "$IFACE" parent 1:9999 handle 9999: sfq perturb 10 || error_exit "Не удалось создать очередь по умолчанию"

  log "Настройка завершена успешно!"
}

# Создание systemd юнита
setup_systemd() {
  if [[ "$SETUP_SYSTEMD" != "y" ]]; then
	return 0
  fi

  # Проверка наличия systemd
  if ! command -v systemctl &>/dev/null; then
	log "Systemd не найден в системе"
	return 1
  fi

  log "Настройка systemd сервиса..."
  
  # Копирование скрипта
  cp "$0" "$SCRIPT_PATH" || error_exit "Не удалось скопировать скрипт"
  chmod 755 "$SCRIPT_PATH" || error_exit "Не удалось установить права на скрипт"

  # Создание сервисного файла
  cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=QoS Setup Service
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --non-interactive
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
EOF

  # Создание таймера
  cat > "$SYSTEMD_TIMER" << EOF
[Unit]
Description=Run QoS Setup every 10 minutes

[Timer]
OnCalendar=*:*:0/10
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Перезагрузка systemd
  systemctl daemon-reload || error_exit "Не удалось перезагрузить systemd"
  
  # Активация таймера
  systemctl enable "${SCRIPT_NAME}.timer" || error_exit "Не удалось включить таймер"
  systemctl start "${SCRIPT_NAME}.timer" || error_exit "Не удалось запустить таймер"
  
  log "Созданы systemd юнит и таймер"
}

# Основной скрипт
if [[ "$1" == "--non-interactive" ]]; then
  if load_config; then
	setup_qos
  else
	log "Ошибка: конфигурация не найдена"
	exit 1
  fi
else
  # Проверка прав root
  if [[ $EUID -ne 0 ]]; then
	echo "Ошибка: скрипт должен быть запущен с правами root!"
	exit 1
  fi

  # Проверка и установка необходимых пакетов
  check_and_install_packages

  # Автоматическое определение интерфейса
  DEFAULT_INTERFACE=$(detect_interface)
  
  # Выбор интерфейса
  read -p "Введите сетевой интерфейс [${DEFAULT_INTERFACE}]: " IFACE_INPUT
  IFACE=${IFACE_INPUT:-$DEFAULT_INTERFACE}
  [[ -z "$IFACE" ]] && error_exit "Интерфейс не указан"

  # Меню выбора направления
  log "Выберите направление фильтрации:"
  select DIR in "Исходящий (src)" "Входящий (dst)"; do
	case $REPLY in
	  1) IP_MATCH="src"; break ;;
	  2) IP_MATCH="dst"; break ;;
	  *) echo "Выберите 1 или 2." ;;
	esac
  done

  # Множественный выбор протоколов
  echo "Выберите протоколы (через запятую):"
  echo "1) TCP"
  echo "2) UDP"
  read -p "Пример: 1,2 - для выбора обоих [1,2]: " PROTO_CHOICE
  PROTO_CHOICE=${PROTO_CHOICE:-"1,2"}
  IFS=',' read -ra PROTO_NUMBERS <<< "$PROTO_CHOICE"
  PROTOCOLS=()
  for num in "${PROTO_NUMBERS[@]}"; do
	case $num in
	  1) PROTOCOLS+=("tcp") ;;
	  2) PROTOCOLS+=("udp") ;;
	esac
  done
  if [[ ${#PROTOCOLS[@]} -eq 0 ]]; then
	error_exit "Не выбрано ни одного протокола!"
  fi

  # IPv6 включение
  read -p "Включить поддержку IPv6? (y/N) [n]: " USE_IPV6
  USE_IPV6=${USE_IPV6:-"n"}

  # Ввод параметров QoS
  while true; do
	read -p "Общая скорость (Mbit/s) [$DEFAULT_TOTAL_SPEED]: " TOTAL_INPUT
	TOTAL=${TOTAL_INPUT:-$DEFAULT_TOTAL_SPEED}
	is_number "$TOTAL" && (( TOTAL > 0 )) && break
	echo "Введите число > 0"
  done

  while true; do
	read -p "Мин. скорость на клиента (Mbit/s) [$DEFAULT_MIN_SPEED]: " MIN_INPUT
	MIN=${MIN_INPUT:-$DEFAULT_MIN_SPEED}
	is_number "$MIN" && (( MIN > 0 )) && break
	echo "Введите число > 0"
  done

  while true; do
	read -p "Скорость по умолчанию (Mbit/s) [$DEFAULT_DEFAULT_SPEED]: " DEFAULT_INPUT
	DEFAULT=${DEFAULT_INPUT:-$DEFAULT_DEFAULT_SPEED}
	if is_number "$DEFAULT" && (( DEFAULT > 0 && DEFAULT < TOTAL )); then
	  break
	elif ! is_number "$DEFAULT"; then
	  echo "Ошибка: введите число!"
	else
	  echo "Ошибка: должно быть меньше общей скорости!"
	fi
  done

  # Проверка суммарной полосы до начала настройки
  MAX_CLIENT_SPEED=$(( (TOTAL * (100 - RESERVED_PERCENT) / 100) / 1 )) # Максимум на клиента
  MAX_DEFAULT_SPEED=$(( TOTAL * 5 / 100 )) # Максимум для дефолта
  
  if (( DEFAULT > MAX_DEFAULT_SPEED )); then
	log "Предупреждение: Скорость по умолчанию ($DEFAULT Mbit/s) превышает рекомендуемое значение ($MAX_DEFAULT_SPEED Mbit/s)"
	read -p "Продолжить? (y/N): " CONTINUE
	[[ "${CONTINUE,,}" != "y" ]] && error_exit "Отменено пользователем"
  fi

  if (( MIN * 10 > TOTAL )); then
	error_exit "Минимальная скорость ($MIN Mbit/s) не может быть обеспечена для 10 клиентов"
  fi

  while true; do
	read -p "Порты для мониторинга (через запятую) [${DEFAULT_PORTS[*]}]: " PORTS_INPUT
	PORTS_INPUT=${PORTS_INPUT:-"${DEFAULT_PORTS[*]}"}
	PORTS=$(echo "$PORTS_INPUT" | tr ',' '\n' | sed 's/ //g' | sort -u)
	INVALID=()
	for port in "${PORTS[@]}"; do
	  is_port "$port" || INVALID+=("$port")
	done
	[[ ${#INVALID[@]} -eq 0 ]] && break
	echo "Некорректные порты: ${INVALID[*]}"
  done

  # Настройка systemd
  read -p "Настроить автозапуск через systemd? (y/N) [y]: " SETUP_SYSTEMD
  SETUP_SYSTEMD=${SETUP_SYSTEMD:-"y"}

  # Сохранение конфигурации
  save_config

  # Настройка QoS
  setup_qos

  # Настройка systemd
  setup_systemd
fi