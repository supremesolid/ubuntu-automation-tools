#!/usr/bin/env bash

# ==============================================================================
# Script para Instalar e Configurar MariaDB Server em Sistemas Debian/Ubuntu
#
# Funcionalidades:
# - Instala mariadb-server e dependências necessárias.
# - Aceita parâmetros de configuração via linha de comando.
# - Impede o início automático do MariaDB durante a instalação.
# - Aplica uma configuração personalizada detalhada.
# - Detecta systemd vs SysVinit/service para gerenciar o serviço.
# - Inicia o MariaDB após a configuração.
# - Configura autenticação 'unix_socket' para root@localhost.
# - Inclui verificação básica de RAM disponível.
# - Projetado para funcionar em sistemas padrão e containers Docker.
# ==============================================================================

# === Configuração Estrita ===
set -euo pipefail

# === Constantes e Padrões ===
# Usar /etc/mysql/conf.d/ é comum mesmo para MariaDB em sistemas Debian/Ubuntu
DEFAULT_CONFIG_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
EXPECTED_MANDATORY_ARGS=4
DEFAULT_INNODB_BUFFER_POOL_SIZE="1G" # Padrão CONSERVADOR.

# === Variáveis para Argumentos ===
MARIADB_PORT=""
MARIADB_BIND_ADDRESS=""
# MariaDB não tem um protocolo X separado como MySQL, então esses são removidos/ignorados
# Se precisar de configuração específica do listener X (raro no MariaDB), precisaria de ajustes
# Mantendo as variáveis para compatibilidade de argumentos, mas não serão usadas na config MariaDB
MYSQLX_BIND_ADDRESS_UNUSED="" # Argumento mantido por compatibilidade, mas não usado
MYSQLX_PORT_UNUSED=""         # Argumento mantido por compatibilidade, mas não usado
MARIADB_INNODB_BUFFER_POOL_SIZE=""

# === Variáveis de Controle de Serviço ===
# O nome do serviço geralmente ainda é 'mysql' para compatibilidade
SERVICE_NAME="mariadb"
START_CMD=""
STATUS_CMD=""
IS_ACTIVE_CMD=""

# === Funções ===
error_exit() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} ERRO: $1" >&2
  if [[ -f /usr/sbin/policy-rc.d ]]; then
      rm -f /usr/sbin/policy-rc.d
      echo "${timestamp} INFO: Arquivo policy-rc.d removido." >&2
  fi
  exit 1
}

log_info() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} INFO: $1"
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root ou com 'sudo'."
  fi
  log_info "Verificação de root: OK."
}

usage() {
  echo "Uso: sudo $0 --port=<porta> --bind-address=<ip> [--mysqlx-bind-address=<ip>] [--mysqlx_port=<porta_x>] [--innodb_buffer_pool_size=<valorG|M>]"
  echo "       (Argumentos mysqlx-* são ignorados para MariaDB mas aceitos por compatibilidade)"
  echo ""
  echo "Argumentos Obrigatórios:"
  echo "  --port=<porta>                Porta para o protocolo MariaDB."
  echo "  --bind-address=<ip>           Endereço IP para escuta (0.0.0.0 para todos)."
  echo ""
  echo "Argumentos Opcionais:"
  echo "  --innodb_buffer_pool_size=<valorG|M> Tamanho do InnoDB/XtraDB Buffer Pool (ex: 4G, 512M)."
  echo "                                     Padrão se omitido: ${DEFAULT_INNODB_BUFFER_POOL_SIZE}."
  echo "  --mysqlx-bind-address=<ip>    (IGNORADO PARA MARIADB)"
  echo "  --mysqlx_port=<porta_x>         (IGNORADO PARA MARIADB)"
  echo ""
  echo "Exemplo:"
  echo "  sudo $0 --port=3306 --bind-address=0.0.0.0 --innodb_buffer_pool_size=4G"
  echo "  sudo $0 --port=3307 --bind-address=127.0.0.1"
  exit 1
}

check_ram() {
    # (Função check_ram mantida idêntica à versão anterior)
    local buffer_pool_setting="$1"
    local buffer_pool_value_gb=0
    local recommend_buffer_margin_gb=2 # Margem pode ser um pouco menor para MariaDB talvez, mas 4 é seguro

    local numeric_part="${buffer_pool_setting//[^0-9]/}"
    local unit_part="${buffer_pool_setting//[0-9]/}"
    unit_part=$(echo "$unit_part" | tr '[:lower:]' '[:upper:]')

    if [[ -z "$numeric_part" ]]; then log_info "AVISO: Valor inválido para innodb_buffer_pool_size ('$buffer_pool_setting')."; return 0; fi

    if [[ "$unit_part" == "G" ]]; then buffer_pool_value_gb=$numeric_part;
    elif [[ "$unit_part" == "M" ]]; then buffer_pool_value_gb=$((numeric_part / 1024));
    else log_info "AVISO: Unidade inválida ('$unit_part') para innodb_buffer_pool_size."; return 0; fi

    local total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo || echo "")
    if [[ -z "$total_mem_kb" ]]; then log_info "AVISO: Não detectado RAM total."; return 0; fi
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    local recommended_total_ram=$((buffer_pool_value_gb + recommend_buffer_margin_gb))

    log_info "RAM Total Detectada: ${total_mem_gb}GB"
    log_info "innodb_buffer_pool_size: ${buffer_pool_setting}"

    if (( total_mem_gb < recommended_total_ram )); then
        echo "--------------------------------------------------------------------" >&2
        echo "AVISO IMPORTANTE DE MEMÓRIA:" >&2
        echo "RAM: ${total_mem_gb}GB. Configurar buffer pool=${buffer_pool_setting} pode ser arriscado." >&2
        echo "Recomendado ter ~${recommended_total_ram}GB RAM total." >&2
        read -p "Continuar mesmo assim? (s/N): " confirm
        if [[ ! "$confirm" =~ ^[SsYy]$ ]]; then error_exit "Instalação cancelada (RAM)."; fi
        echo "--------------------------------------------------------------------" >&2
    else
         log_info "RAM total (${total_mem_gb}GB) parece suficiente."
    fi
}


# === Determinar Sistema de Gerenciamento de Serviço ===
log_info "Detectando sistema de gerenciamento de serviço..."
if command -v systemctl &> /dev/null && [[ -S /run/systemd/private ]]; then
    log_info "Systemd detectado. Usando 'systemctl' para o serviço '${SERVICE_NAME}'."
    START_CMD="systemctl start ${SERVICE_NAME}"
    STATUS_CMD="systemctl status ${SERVICE_NAME} --no-pager --full"
    IS_ACTIVE_CMD="systemctl is-active --quiet ${SERVICE_NAME}"
elif command -v service &> /dev/null; then
    log_info "Usando 'service' para o serviço '${SERVICE_NAME}'."
    START_CMD="service ${SERVICE_NAME} start"
    STATUS_CMD="service ${SERVICE_NAME} status"
    IS_ACTIVE_CMD="service ${SERVICE_NAME} status"
else
    error_exit "Não encontrado 'systemctl' ou 'service'."
fi
log_info "Comando de início: '${START_CMD}'"
log_info "Comando de status: '${STATUS_CMD}'"
log_info "Comando de verificação: '${IS_ACTIVE_CMD}'"


# === Verificação de Root ===
check_root

# === Processamento de Argumentos ===
# Ajustado para ignorar mysqlx args mas manter a contagem obrigatória para os outros
arg_count_mandatory=0
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --port=*) MARIADB_PORT="${1#*=}"; arg_count_mandatory=$((arg_count_mandatory + 1)); ;;
    --bind-address=*) MARIADB_BIND_ADDRESS="${1#*=}"; arg_count_mandatory=$((arg_count_mandatory + 1)); ;;
    --mysqlx-bind-address=*) MYSQLX_BIND_ADDRESS_UNUSED="${1#*=}"; ;; # Ignorado
    --mysqlx_port=*) MYSQLX_PORT_UNUSED="${1#*=}"; ;;                 # Ignorado
    --innodb_buffer_pool_size=*) MARIADB_INNODB_BUFFER_POOL_SIZE="${1#*=}"; ;; # Opcional
    *) echo "ERRO: Argumento desconhecido: $1"; usage ;;
  esac
  shift
done

# Validar se os argumentos OBRIGATÓRIOS foram fornecidos (agora são 2)
EXPECTED_MANDATORY_ARGS=2 # Apenas --port e --bind-address são mandatórios para MariaDB aqui
if [[ ${arg_count_mandatory} -ne ${EXPECTED_MANDATORY_ARGS} ]]; then
  error_exit "Faltando argumentos obrigatórios (--port, --bind-address)."
fi

# Validar porta
if ! [[ "$MARIADB_PORT" =~ ^[0-9]+$ ]]; then
    error_exit "O valor para --port deve ser um número."
fi

# Definir padrão para innodb_buffer_pool_size
if [[ -z "$MARIADB_INNODB_BUFFER_POOL_SIZE" ]]; then
  MARIADB_INNODB_BUFFER_POOL_SIZE="${DEFAULT_INNODB_BUFFER_POOL_SIZE}"
  log_info "Usando InnoDB buffer pool padrão: ${MARIADB_INNODB_BUFFER_POOL_SIZE}"
fi

# Validar formato do buffer pool size
if ! [[ "$MARIADB_INNODB_BUFFER_POOL_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
    error_exit "Formato inválido para --innodb_buffer_pool_size ('${MARIADB_INNODB_BUFFER_POOL_SIZE}')."
fi

log_info "--- Argumentos Recebidos/Definidos (MariaDB) ---"
log_info "Porta MariaDB:             $MARIADB_PORT"
log_info "Bind Address MariaDB:      $MARIADB_BIND_ADDRESS"
log_info "InnoDB Buffer Pool Size:   $MARIADB_INNODB_BUFFER_POOL_SIZE"
log_info "-------------------------------------------"

# === Verificação de RAM ===
check_ram "$MARIADB_INNODB_BUFFER_POOL_SIZE"

# === Início da Instalação e Configuração ===

# --- 1. Atualização e Dependências ---
log_info "[1/7] Atualizando lista de pacotes..."
if ! apt-get update -qq; then error_exit "Falha ao atualizar pacotes."; fi

log_info "[2/7] Instalando dependências (mariadb-client, procps, gnupg)..."
export DEBIAN_FRONTEND=noninteractive
# Instala mariadb-client em vez de mysql-client
apt-get install -y -qq procps mariadb-client gnupg || error_exit "Falha ao instalar dependências."
unset DEBIAN_FRONTEND
log_info "Dependências instaladas."

# --- 2. Impedir Início Automático ---
log_info "[3/7] Impedindo início automático do MariaDB..."
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# --- 3. Instalar MariaDB Server ---
log_info "[4/7] Instalando mariadb-server (sem iniciar)..."
export DEBIAN_FRONTEND=noninteractive
# Instala mariadb-server
if ! apt-get install -y -qq mariadb-server; then
    rm -f /usr/sbin/policy-rc.d
    unset DEBIAN_FRONTEND
    error_exit "Falha ao instalar mariadb-server."
fi
unset DEBIAN_FRONTEND
rm -f /usr/sbin/policy-rc.d
log_info "mariadb-server instalado. Bloqueio removido."

# --- 4. Ajustes de Permissões ---
log_info "[5/7] Ajustando diretório de dados e permissões (/var/lib/mysql)..."
# MariaDB geralmente usa /var/lib/mysql por padrão em Debian/Ubuntu
mkdir -p /var/lib/mysql
usermod -d /var/lib/mysql/ mysql 2>/dev/null || log_info "AVISO: usermod -d falhou ou não teve efeito."
chown -R mysql:mysql /var/lib/mysql
chmod 700 /var/lib/mysql
log_info "Permissões do diretório de dados ajustadas."

# --- 5. Criar Arquivo de Configuração ---
log_info "[6/7] Criando arquivo de configuração MariaDB (${DEFAULT_CONFIG_FILE})..."
mkdir -p "$(dirname "${DEFAULT_CONFIG_FILE}")"

# Template de configuração adaptado levemente (removido mysqlx)
cat <<EOF > "${DEFAULT_CONFIG_FILE}"
# ===============================================================
# Arquivo de Configuração MariaDB Personalizado Gerado por Script
# $(date)
# ===============================================================

[mariadb]
# Para MariaDB 10.4+, [mariadb] é um alias para [mysqld] e recomendado
# Se usar versões mais antigas, pode precisar de [mysqld]

# --- Identificação e Caminhos ---
user = mysql
pid-file = /run/mysqld/mysqld.pid # Caminho padrão pode mudar para /run/ em sistemas mais novos
socket = /run/mysqld/mysqld.sock # Caminho padrão pode mudar para /run/ em sistemas mais novos
datadir = /var/lib/mysql
tmpdir = /tmp

# --- Bindings de Rede (Definidos por Script) ---
port = ${MARIADB_PORT}
bind-address = ${MARIADB_BIND_ADDRESS}

# --- Configurações Gerais ---
# default_storage_engine = InnoDB # InnoDB é padrão na maioria das versões recentes
max_allowed_packet = 256M
# thread_stack = 256K # Geralmente OK, descomente se necessário

# --- Threads ---
thread_cache_size = 64 # Bom ponto de partida
# max_connections = 500 # Descomente e ajuste se precisar (requer RAM)

# --- MyISAM (Minimizado) ---
key_buffer_size = 64M
# myisam_recover_options = BACKUP,FORCE # Nome da opção pode variar ligeiramente

# --- InnoDB/XtraDB (Otimizações) ---
# *** Valor definido por script (--innodb_buffer_pool_size ou padrão) ***
innodb_buffer_pool_size = ${MARIADB_INNODB_BUFFER_POOL_SIZE}

innodb_flush_log_at_trx_commit = 1
# innodb_flush_method = O_DIRECT # Use com cautela, fsync é padrão e geralmente seguro
innodb_io_capacity = 2000 # Ajuste baseado no seu disco (IOPS)
innodb_io_capacity_max = 4000
# innodb_redo_log_capacity = 2G # Para versões mais recentes (ex: 10.5+)

# --- Caches de Tabela ---
table_definition_cache = 2048
table_open_cache = 4096

# --- Tabelas Temporárias ---
tmp_table_size = 64M
max_heap_table_size = 64M # Geralmente igual a tmp_table_size

# --- Logs ---
log_error = /var/log/mysql/error.log # Caminho padrão

# --- Binary Log (Replicação/PITR) ---
# log-bin = mysql-bin # Descomente para ativar binlogs
# binlog_format = ROW # ROW é recomendado e padrão em versões recentes
# expire_logs_days = 30 # Método mais antigo para expirar binlogs
# binlog_expire_logs_seconds = 2592000 # Método mais novo (ex: 30 dias)

# --- Slow Query Log ---
# slow_query_log = 1 # Descomente para ativar
# slow_query_log_file = /var/log/mysql/mariadb-slow.log
# long_query_time = 1 # Segundos
# log_slow_admin_statements = 1 # Logar comandos admin lentos
# log_slow_rate_limit = 1000 # Limitar queries lentas logadas por segundo
# log_slow_verbosity = query_plan,explain # Mais detalhes no log lento

EOF

# Ajusta caminhos de pid e socket se necessário (algumas versões de MariaDB usam /run/mysqld/)
# Tenta detectar o caminho padrão do socket do pacote instalado
SOCKET_PATH=$(mariadb_config --socket 2>/dev/null || echo "/run/mysqld/mysqld.sock")
PID_PATH="${SOCKET_PATH%/*}/mysqld.pid" # Assume pid no mesmo dir do socket

# Atualiza o arquivo se os caminhos detectados forem diferentes dos escritos
if ! grep -q "socket *= *${SOCKET_PATH}" "${DEFAULT_CONFIG_FILE}"; then
    log_info "Atualizando caminho do socket no config para: ${SOCKET_PATH}"
    sed -i "s|socket *=.*|socket = ${SOCKET_PATH}|" "${DEFAULT_CONFIG_FILE}"
fi
if ! grep -q "pid-file *= *${PID_PATH}" "${DEFAULT_CONFIG_FILE}"; then
    log_info "Atualizando caminho do pid-file no config para: ${PID_PATH}"
    sed -i "s|pid-file *=.*|pid-file = ${PID_PATH}|" "${DEFAULT_CONFIG_FILE}"
fi

chown root:root "${DEFAULT_CONFIG_FILE}"
chmod 644 "${DEFAULT_CONFIG_FILE}"
log_info "Arquivo de configuração MariaDB ${DEFAULT_CONFIG_FILE} criado/atualizado."

# --- 6. Iniciar MariaDB e Configurar Auth Socket ---
log_info "[7/7] Iniciando o serviço MariaDB (${SERVICE_NAME}) e configurando unix_socket..."

log_info "Tentando iniciar o serviço MariaDB com: '${START_CMD}'"
if ! ${START_CMD} > /dev/null 2>&1; then
    log_info "Falha ao iniciar o serviço. Verificando logs recentes..."
    tail -n 50 /var/log/mysql/error.log || log_info "Não foi possível ler /var/log/mysql/error.log"
    error_exit "Falha ao executar o comando de início: '${START_CMD}'."
fi

log_info "Aguardando MariaDB iniciar (até 15 segundos)..."
mariadb_ready=0
# Usa mariadb-admin ping que é mais específico
for i in {1..15}; do
    # Tenta pingar o servidor via socket
    if mariadb-admin ping --silent --protocol=socket -S "${SOCKET_PATH}" --connect-timeout=1 &> /dev/null; then
        mariadb_ready=1
        log_info "MariaDB respondeu ao ping via socket (${SOCKET_PATH}) após ${i} segundos."
        break
    fi
    log_info "Aguardando ping via socket... (${i}/15)"
    sleep 1
done

if [[ ${mariadb_ready} -eq 0 ]]; then
    log_info "Falha no ping via socket. Verificando logs recentes..."
    tail -n 50 /var/log/mysql/error.log || log_info "Não foi possível ler /var/log/mysql/error.log"
    error_exit "MariaDB não iniciou ou não respondeu ao ping via socket (${SOCKET_PATH}) após 15 segundos."
fi

log_info "Verificando status do serviço MariaDB com: '${IS_ACTIVE_CMD}'"
if ! ${IS_ACTIVE_CMD} > /dev/null 2>&1; then
   log_info "Serviço MariaDB inativo. Exibindo status detalhado:"
   ${STATUS_CMD} || true
   error_exit "Serviço MariaDB reportou como inativo."
fi
log_info "Serviço MariaDB parece estar ativo."
# ${STATUS_CMD} || log_info "Não foi possível exibir status detalhado."


# --- Configuração do unix_socket ---
log_info "Verificando/Configurando plugin unix_socket para root@localhost..."

# O plugin unix_socket é geralmente built-in, então a instalação não é necessária.
# Apenas garantimos que o usuário root o utilize.

log_info "Executando ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket..."
# Conecta via socket padrão detectado
# Usa 'mariadb' como comando cliente
if ! mariadb -Nse "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket; FLUSH PRIVILEGES;" --protocol=socket -S "${SOCKET_PATH}" --connect-timeout=5; then
  error_exit "Falha CRÍTICA ao executar ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket. Verifique os logs: /var/log/mysql/error.log"
fi

log_info "Autenticação unix_socket confirmada/configurada com sucesso para root@localhost."

# --- Conclusão ---
echo ""
log_info "======================================================"
log_info " Instalação e Configuração do MariaDB Concluída       "
log_info "======================================================"
log_info "Servidor MariaDB escutando em:"
log_info "  - Porta: ${MARIADB_BIND_ADDRESS}:${MARIADB_PORT}"
log_info "  - Socket: ${SOCKET_PATH}"
log_info "  - InnoDB Buffer Pool: ${MARIADB_INNODB_BUFFER_POOL_SIZE}"
log_info "Usuário 'root'@'localhost' configurado para usar autenticação via socket (unix_socket)."
log_info "Arquivo de configuração personalizado: ${DEFAULT_CONFIG_FILE}"
log_info "Logs de erro: /var/log/mysql/error.log"
log_info "Para conectar como root localmente, use: sudo mariadb"
log_info "======================================================"
echo ""

exit 0