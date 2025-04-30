#!/usr/bin/env bash

# ==============================================================================
# Script para Instalar e Configurar MySQL Server em Sistemas Debian/Ubuntu
#
# Funcionalidades:
# - Instala mysql-server e dependências necessárias.
# - Aceita parâmetros de configuração via linha de comando.
# - Impede o início automático do MySQL durante a instalação.
# - Aplica uma configuração personalizada detalhada.
# - Inicia o MySQL após a configuração.
# - Configura autenticação 'auth_socket' para root@localhost.
# - Inclui verificação básica de RAM disponível.
# - Projetado para funcionar em sistemas padrão e containers Docker.
# ==============================================================================

# === Configuração Estrita ===
# -e: Sai imediatamente se um comando falhar.
# -u: Trata variáveis não definidas como erro.
# -o pipefail: O status de saída de um pipeline é o do último comando que falhou.
set -euo pipefail

# === Constantes e Padrões ===
DEFAULT_CONFIG_FILE="/etc/mysql/mysql.conf.d/99-custom-mysqld.cnf"
EXPECTED_MANDATORY_ARGS=4
DEFAULT_INNODB_BUFFER_POOL_SIZE="1G" # Padrão CONSERVADOR. Ajuste conforme necessidade base.

# === Variáveis para Argumentos ===
MYSQL_PORT=""
MYSQL_BIND_ADDRESS=""
MYSQLX_BIND_ADDRESS=""
MYSQLX_PORT=""
MYSQL_INNODB_BUFFER_POOL_SIZE=""

# === Funções ===
error_exit() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} ERRO: $1" >&2
  # Tenta limpar o bloqueio de serviço, se existir
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
    error_exit "Este script precisa ser executado como root."
  fi
  log_info "Verificação de root: OK (Executando como root)."
}

usage() {
  # Mensagem de uso detalhada (mantida da versão anterior)
  echo "Uso: $0 --port=<porta> --bind-address=<ip> --mysqlx-bind-address=<ip> --mysqlx_port=<porta_x> [--innodb_buffer_pool_size=<valorG|M>]"
  echo ""
  echo "Argumentos Obrigatórios:"
  echo "  --port=<porta>                Porta para o protocolo MySQL clássico."
  echo "  --bind-address=<ip>           Endereço IP para escuta do protocolo clássico (0.0.0.0 para todos)."
  echo "  --mysqlx-bind-address=<ip>    Endereço IP para escuta do X Protocol (0.0.0.0 para todos)."
  echo "  --mysqlx_port=<porta_x>         Porta para o X Protocol."
  echo ""
  echo "Argumento Opcional:"
  echo "  --innodb_buffer_pool_size=<valorG|M> Tamanho do InnoDB Buffer Pool (ex: 4G, 512M)."
  echo "                                     Padrão se omitido: ${DEFAULT_INNODB_BUFFER_POOL_SIZE} (Conservador)."
  echo ""
  echo "Exemplo:"
  echo "  $0 --port=3307 --bind-address=0.0.0.0 --mysqlx-bind-address=0.0.0.0 --mysqlx_port=33070 --innodb_buffer_pool_size=40G"
  echo "  $0 --port=3306 --bind-address=127.0.0.1 --mysqlx-bind-address=127.0.0.1 --mysqlx_port=33060"
  exit 1
}

check_ram() {
    # Função check_ram mantida da versão anterior
    local buffer_pool_setting="$1"
    local buffer_pool_value_gb=0
    local recommend_buffer_margin_gb=4

    local numeric_part="${buffer_pool_setting//[^0-9]/}"
    local unit_part="${buffer_pool_setting//[0-9]/}"
    unit_part=$(echo "$unit_part" | tr '[:lower:]' '[:upper:]')

    if [[ -z "$numeric_part" ]]; then
       log_info "AVISO: Valor inválido para innodb_buffer_pool_size ('$buffer_pool_setting'). Não foi possível verificar a RAM."
       return 0
    fi

    if [[ "$unit_part" == "G" ]]; then
        buffer_pool_value_gb=$numeric_part
    elif [[ "$unit_part" == "M" ]]; then
        buffer_pool_value_gb=$((numeric_part / 1024))
    else
        log_info "AVISO: Unidade inválida ('$unit_part') para innodb_buffer_pool_size ('$buffer_pool_setting'). Use G ou M. Não foi possível verificar a RAM."
        return 0
    fi

    # Tenta obter RAM total (funciona na maioria dos Linux, incluindo containers)
    local total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo || echo "")
    if [[ -z "$total_mem_kb" ]]; then
        log_info "AVISO: Não foi possível detectar a memória RAM total automaticamente (/proc/meminfo)."
        return 0
    fi
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    local recommended_total_ram=$((buffer_pool_value_gb + recommend_buffer_margin_gb))

    log_info "Memória RAM Total Detectada: ${total_mem_gb}GB"
    log_info "innodb_buffer_pool_size será configurado para: ${buffer_pool_setting}"

    if (( total_mem_gb < recommended_total_ram )); then
        echo "--------------------------------------------------------------------" >&2
        echo "AVISO IMPORTANTE DE MEMÓRIA:" >&2
        echo "O servidor possui ${total_mem_gb}GB de RAM." >&2
        echo "Configurar 'innodb_buffer_pool_size=${buffer_pool_setting}' pode consumir uma parte" >&2
        echo "significativa da memória, podendo causar instabilidade ou falha ao iniciar o MySQL." >&2
        echo "Recomendado ter pelo menos ~${recommended_total_ram}GB de RAM total para esta configuração." >&2
        # Em um script automatizado, talvez não queiramos um prompt interativo.
        # Considerar remover o 'read' ou torná-lo opcional com outro parâmetro.
        # Por enquanto, mantenho para segurança interativa.
        read -p "Deseja continuar mesmo assim? (s/N): " confirm
        if [[ ! "$confirm" =~ ^[SsYy]$ ]]; then
            error_exit "Instalação cancelada devido a preocupações com memória RAM."
        fi
        echo "--------------------------------------------------------------------" >&2
    else
         log_info "A memória RAM total (${total_mem_gb}GB) parece suficiente para a configuração do buffer pool (${buffer_pool_setting})."
    fi
}


# === Verificação de Root ===
check_root

# === Processamento de Argumentos ===
arg_count=0
# Loop de processamento mantido da versão anterior
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --port=*) MYSQL_PORT="${1#*=}"; arg_count=$((arg_count + 1)); ;;
    --bind-address=*) MYSQL_BIND_ADDRESS="${1#*=}"; arg_count=$((arg_count + 1)); ;;
    --mysqlx-bind-address=*) MYSQLX_BIND_ADDRESS="${1#*=}"; arg_count=$((arg_count + 1)); ;;
    --mysqlx_port=*) MYSQLX_PORT="${1#*=}"; arg_count=$((arg_count + 1)); ;;
    --innodb_buffer_pool_size=*) MYSQL_INNODB_BUFFER_POOL_SIZE="${1#*=}"; ;;
    *) echo "ERRO: Argumento desconhecido: $1"; usage ;;
  esac
  shift
done

# Validações mantidas da versão anterior
if [[ ${arg_count} -ne ${EXPECTED_MANDATORY_ARGS} ]]; then
  error_exit "Faltando um ou mais argumentos obrigatórios. Use --help para ver as opções."
fi
if ! [[ "$MYSQL_PORT" =~ ^[0-9]+$ && "$MYSQLX_PORT" =~ ^[0-9]+$ ]]; then
    error_exit "Os valores para --port e --mysqlx_port devem ser números."
fi
if [[ -z "$MYSQL_INNODB_BUFFER_POOL_SIZE" ]]; then
  MYSQL_INNODB_BUFFER_POOL_SIZE="${DEFAULT_INNODB_BUFFER_POOL_SIZE}"
  log_info "--innodb_buffer_pool_size não fornecido. Usando padrão: ${MYSQL_INNODB_BUFFER_POOL_SIZE}"
fi
if ! [[ "$MYSQL_INNODB_BUFFER_POOL_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
    error_exit "Formato inválido para --innodb_buffer_pool_size ('${MYSQL_INNODB_BUFFER_POOL_SIZE}'). Use número seguido de G ou M (ex: 4G, 512M)."
fi

log_info "--- Argumentos Recebidos/Definidos ---"
log_info "Porta MySQL:                 $MYSQL_PORT"
log_info "Bind Address MySQL:          $MYSQL_BIND_ADDRESS"
log_info "Bind Address MySQLX:         $MYSQLX_BIND_ADDRESS"
log_info "Porta MySQLX:                $MYSQLX_PORT"
log_info "InnoDB Buffer Pool Size:     $MYSQL_INNODB_BUFFER_POOL_SIZE"
log_info "------------------------------------"

# === Verificação de RAM ===
check_ram "$MYSQL_INNODB_BUFFER_POOL_SIZE"

# === Início da Instalação e Configuração ===

# --- 1. Atualização de Pacotes e Instalação de Dependências ---
log_info "[1/7] Atualizando lista de pacotes..."
# Usar -qq para menos output, mas manter || error_exit
if ! apt-get update -qq; then
    error_exit "Falha ao atualizar lista de pacotes (apt-get update). Verifique a conexão de rede e os repositórios."
fi

log_info "[2/7] Instalando dependências essenciais (mysql-client, procps, gnupg)..."
# procps fornece awk/pgrep, mysql-client é necessário para comandos mysql
# gnupg é bom ter para gerenciamento de chaves apt
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq procps mysql-client gnupg || error_exit "Falha ao instalar dependências (mysql-client, procps, gnupg)."
unset DEBIAN_FRONTEND
log_info "Dependências instaladas."

# --- 2. Impedir Início Automático ---
log_info "[3/7] Impedindo início automático do MySQL durante a instalação..."
# Cria o policy-rc.d para bloquear o início do serviço
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# --- 3. Instalar MySQL Server ---
log_info "[4/7] Instalando mysql-server (sem iniciar)..."
export DEBIAN_FRONTEND=noninteractive
if ! apt-get install -y -qq mysql-server; then
    # Limpeza em caso de falha
    rm -f /usr/sbin/policy-rc.d
    unset DEBIAN_FRONTEND
    error_exit "Falha ao instalar mysql-server."
fi
unset DEBIAN_FRONTEND
# Remove o bloqueio imediatamente após a instalação bem-sucedida
rm -f /usr/sbin/policy-rc.d
log_info "mysql-server instalado. Bloqueio de início automático removido."

# --- 4. Ajustes de Permissões e Diretórios ---
log_info "[5/7] Ajustando diretório de dados e permissões..."
# Garante que o diretório de dados exista antes de mudar permissões
mkdir -p /var/lib/mysql
# Ajusta o diretório home do usuário mysql (geralmente feito pelo pacote, mas reforça)
usermod -d /var/lib/mysql/ mysql 2>/dev/null || log_info "AVISO: Comando usermod -d falhou ou não teve efeito (pode ser normal)."
# Define proprietário e permissões estritas para o diretório de dados
chown -R mysql:mysql /var/lib/mysql
chmod 700 /var/lib/mysql
log_info "Permissões do diretório de dados ajustadas."

# --- 5. Criar Arquivo de Configuração ---
log_info "[6/7] Criando arquivo de configuração personalizado (${DEFAULT_CONFIG_FILE})..."
mkdir -p "$(dirname "${DEFAULT_CONFIG_FILE}")"

# Template de configuração (mantido da versão anterior, usando variáveis)
cat <<EOF > "${DEFAULT_CONFIG_FILE}"
# ===============================================================
# Arquivo de Configuração MySQL Personalizado Gerado por Script
# ${timestamp}
# ===============================================================

[mysqld]

# --- Identificação e Caminhos ---
user = mysql
pid-file = /var/run/mysqld/mysqld.pid
socket = /var/run/mysqld/mysqld.sock
datadir = /var/lib/mysql
tmpdir = /tmp

# --- Bindings de Rede (Definidos por Script) ---
port = ${MYSQL_PORT}
bind-address = ${MYSQL_BIND_ADDRESS}
mysqlx-bind-address = ${MYSQLX_BIND_ADDRESS}
mysqlx_port = ${MYSQLX_PORT}

# --- Configurações Gerais ---
default_storage_engine = InnoDB
max_allowed_packet = 256M
mysqlx_max_allowed_packet = 256M
thread_stack = 256K

# --- Threads ---
thread_cache_size = 64
# max_connections = 500 # DESCOMENTE e ajuste se precisar (requer RAM)

# --- MyISAM (Minimizado) ---
key_buffer_size = 64M
myisam-recover-options = BACKUP,FORCE

# --- InnoDB (Otimizações) ---
# *** Valor definido por script (--innodb_buffer_pool_size ou padrão) ***
innodb_buffer_pool_size = ${MYSQL_INNODB_BUFFER_POOL_SIZE}

innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_io_capacity = 2000 # Ajuste baseado no seu disco (IOPS)
innodb_io_capacity_max = 4000
innodb_redo_log_capacity = 2G # Capacidade total do Redo Log

# --- Caches de Tabela ---
table_definition_cache = 2048
table_open_cache = 4096

# --- Tabelas Temporárias ---
tmp_table_size = 64M
max_heap_table_size = 64M

# --- Logs ---
log_error = /var/log/mysql/error.log

# --- Binary Log (Replicação/PITR) ---
log-bin = mysql-bin
log-bin-index = mysql-bin.index
max_binlog_size = 512M
binlog_expire_logs_seconds = 2592000 # 30 dias

# --- Slow Query Log ---
slow_query_log = ON
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = 1
log_queries_not_using_indexes = ON

EOF

chown root:root "${DEFAULT_CONFIG_FILE}"
chmod 644 "${DEFAULT_CONFIG_FILE}"
log_info "Arquivo de configuração ${DEFAULT_CONFIG_FILE} criado."

# --- 6. Iniciar MySQL e Configurar Auth Socket ---
log_info "[7/7] Iniciando o serviço MySQL e configurando auth_socket..."

log_info "Tentando iniciar o serviço MySQL..."
# Tenta iniciar com systemctl ou service
if command -v systemctl &> /dev/null; then
    systemctl start mysql || error_exit "Falha ao iniciar MySQL via systemctl."
else
    service mysql start || error_exit "Falha ao iniciar MySQL via service."
fi

log_info "Aguardando MySQL iniciar (até 15 segundos)..."
# Loop de espera mais robusto
mysql_ready=0
for i in {1..15}; do
    # Tenta executar um comando simples. `-N` suprime cabeçalhos, `-s` modo silencioso.
    if mysql -Nse 'SELECT 1;' --connect-timeout=1 &> /dev/null; then
        mysql_ready=1
        log_info "MySQL respondeu após ${i} segundos."
        break
    fi
    log_info "Aguardando... (${i}/15)"
    sleep 1
done

if [[ ${mysql_ready} -eq 0 ]]; then
    error_exit "MySQL não iniciou ou não respondeu após 15 segundos. Verifique os logs: /var/log/mysql/error.log e a configuração: ${DEFAULT_CONFIG_FILE}"
fi

# Exibe o status (opcional, mas útil para debug)
log_info "Verificando status detalhado do MySQL..."
if command -v systemctl &> /dev/null; then
    systemctl status mysql --no-pager --full || log_info "Não foi possível obter status detalhado via systemctl."
else
    service mysql status || log_info "Não foi possível obter status detalhado via service."
fi

# --- Configuração do auth_socket ---
log_info "Verificando/Configurando plugin auth_socket para root@localhost..."

# Tenta instalar apenas para verificar se já existe (ignora erros comuns)
install_cmd_output=$(mysql -Nse "INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';" --connect-timeout=5 2>&1 || true)
install_exit_code=$?
if [[ ${install_exit_code} -ne 0 ]]; then
    # Analisa a saída de erro
    if echo "$install_cmd_output" | grep -q -E "Plugin 'auth_socket' already exists|ER_PLUGIN_ALREADY_INSTALLED|code: 1125"; then
        log_info "Plugin auth_socket já está instalado/ativo."
    elif echo "$install_cmd_output" | grep -q -E "Can't open shared library|não pode abrir"; then
         error_exit "Falha CRÍTICA: Arquivo 'auth_socket.so' não encontrado ou inacessível. Verifique a integridade da instalação do MySQL. Saída: $install_cmd_output"
    elif echo "$install_cmd_output" | grep -q -E "Plugin 'auth_socket' is not loaded|code: 1688"; then
         log_info "AVISO: Plugin auth_socket não pôde ser carregado dinamicamente ou é built-in. Tentando ALTER USER..."
    else
        # Erro inesperado, mas continua para ALTER USER como última tentativa
        log_info "AVISO: Comando INSTALL PLUGIN falhou com erro inesperado (Código: ${install_exit_code}). Tentando ALTER USER mesmo assim... Saída: $install_cmd_output"
    fi
fi

log_info "Executando ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket..."
# Usa `-Nse` para suprimir output normal, foca em erros.
if ! mysql -Nse "ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket; FLUSH PRIVILEGES;" --connect-timeout=5; then
  # Se falhar aqui, é mais provável que o plugin não esteja realmente ativo
  error_exit "Falha CRÍTICA ao executar ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket. O plugin auth_socket pode não estar ativo/disponível. Verifique os logs do MySQL: /var/log/mysql/error.log"
fi

log_info "Autenticação auth_socket confirmada/configurada com sucesso para root@localhost."

# --- Conclusão ---
echo ""
log_info "======================================================"
log_info " Instalação e Configuração do MySQL Concluída        "
log_info "======================================================"
log_info "Servidor MySQL escutando em:"
log_info "  - Porta Clássica: ${MYSQL_BIND_ADDRESS}:${MYSQL_PORT}"
log_info "  - Porta X Protocol: ${MYSQLX_BIND_ADDRESS}:${MYSQLX_PORT}"
log_info "  - InnoDB Buffer Pool: ${MYSQL_INNODB_BUFFER_POOL_SIZE}"
log_info "Usuário 'root'@'localhost' configurado para usar autenticação via socket."
log_info "Arquivo de configuração personalizado: ${DEFAULT_CONFIG_FILE}"
log_info "Logs de erro: /var/log/mysql/error.log"
log_info "Para conectar como root localmente, use: mysql"
log_info "======================================================"
echo ""

exit 0