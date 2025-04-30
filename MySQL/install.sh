#!/usr/bin/env bash

# === Configuração Estrita ===
# -e: Sai imediatamente se um comando falhar.
# -u: Trata variáveis não definidas como erro.
# -o pipefail: O status de saída de um pipeline é o do último comando que falhou.
set -euo pipefail

# === Constantes ===
readonly MYSQL_CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"
# Default values (optional, could be removed if args are always required)
DEFAULT_BIND_ADDRESS="127.0.0.1"
DEFAULT_BIND_PORT="3306"
DEFAULT_MYSQLX_PORT="33060"

# === Variáveis (serão definidas pelos argumentos) ===
BIND_ADDRESS=""
BIND_PORT=""
MYSQLX_PORT=""

# === Funções ===

# Exibe mensagem de uso e sai
usage() {
  echo "Uso: $0 --ip=<bind-address-ip> --port=<bind-port> [--mysqlx_port=<mysqlx-port>]"
  echo "Exemplo: $0 --ip=192.168.1.100 --port=3307 --mysqlx_port=33070"
  echo "Exemplo (usando padrão para mysqlx_port): $0 --ip=0.0.0.0 --port=3306"
  echo "Opções:"
  echo "  --ip=<ip>         Endereço IP para o MySQL escutar (obrigatório)."
  echo "  --port=<porta>    Porta TCP/IP para o MySQL escutar (obrigatório)."
  echo "  --mysqlx_port=<porta> Porta para o Plugin X (opcional, padrão: ${DEFAULT_MYSQLX_PORT})."
  exit 1
}

# Exibe mensagem de erro e sai
error_exit() {
  echo "ERRO: $1" >&2
  exit 1
}

# Verifica se o script está sendo executado como root
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root. Use 'sudo $0 ...'"
  fi
}

# Valida se uma porta é um número válido entre 1 e 65535
validate_port() {
  local port_num="$1"
  local port_name="$2"
  if ! [[ "${port_num}" =~ ^[0-9]+$ ]] || [[ "${port_num}" -lt 1 ]] || [[ "${port_num}" -gt 65535 ]]; then
    error_exit "Porta inválida para ${port_name}: '${port_num}'. Deve ser um número entre 1 e 65535."
  fi
}

# === Processamento de Argumentos ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip=*)
      BIND_ADDRESS="${1#*=}"
      shift # remove --ip=...
      ;;
    --port=*)
      BIND_PORT="${1#*=}"
      shift # remove --port=...
      ;;
    --mysqlx_port=*)
      MYSQLX_PORT="${1#*=}"
      shift # remove --mysqlx_port=...
      ;;
    *)
      echo "ERRO: Opção desconhecida: $1"
      usage
      ;;
  esac
done

# === Validação de Argumentos Obrigatórios ===
if [[ -z "${BIND_ADDRESS}" ]]; then
  echo "ERRO: O argumento --ip é obrigatório."
  usage
fi
if [[ -z "${BIND_PORT}" ]]; then
  echo "ERRO: O argumento --port é obrigatório."
  usage
fi

# Define o valor padrão para mysqlx_port se não foi fornecido
if [[ -z "${MYSQLX_PORT}" ]]; then
  MYSQLX_PORT="${DEFAULT_MYSQLX_PORT}"
  echo "INFO: Usando porta padrão para MySQL X Plugin: ${MYSQLX_PORT}"
fi

# Validação dos valores das portas
validate_port "${BIND_PORT}" "MySQL"
validate_port "${MYSQLX_PORT}" "MySQL X Plugin"

# Torna as variáveis de configuração read-only após validação
readonly BIND_ADDRESS
readonly BIND_PORT
readonly MYSQLX_PORT

# === Verificação de Privilégios ===
check_root

# === Início da Execução ===
echo "Iniciando a configuração do MySQL Server..."
echo "  Endereço de Bind: ${BIND_ADDRESS}"
echo "  Porta de Bind:    ${BIND_PORT}"
echo "  Porta MySQL X:    ${MYSQLX_PORT}"

# --- 1. Instalação do MySQL Server ---
echo "[1/5] Atualizando lista de pacotes..."
apt-get update || error_exit "Falha ao atualizar lista de pacotes (apt-get update)."

echo "[2/5] Instalando mysql-server..."
# Usar DEBIAN_FRONTEND=noninteractive para evitar prompts durante a instalação
export DEBIAN_FRONTEND=noninteractive
apt-get install -y mysql-server || error_exit "Falha ao instalar mysql-server."
unset DEBIAN_FRONTEND

# --- 2. Configuração do Bind Address, Porta e Porta MySQL X ---
echo "[3/5] Configurando bind-address, port e mysqlx-port em ${MYSQL_CONFIG_FILE}..."

if [[ ! -f "${MYSQL_CONFIG_FILE}" ]]; then
  error_exit "Arquivo de configuração do MySQL não encontrado: ${MYSQL_CONFIG_FILE}"
fi

# Comenta configurações existentes de bind-address, port e mysqlx-port dentro da seção [mysqld]
# Isso evita duplicatas e garante que nossas configurações sejam usadas.
sed -i \
  -e "/^\s*\[mysqld\]/,/^\s*\[/s/^\(\s*bind-address\s*=\)/#\1/" \
  -e "/^\s*\[mysqld\]/,/^\s*\[/s/^\(\s*port\s*=\)/#\1/" \
  -e "/^\s*\[mysqld\]/,/^\s*\[/s/^\(\s*mysqlx-port\s*=\)/#\1/" \
  "${MYSQL_CONFIG_FILE}" ||
  error_exit "Falha ao comentar configurações existentes no arquivo ${MYSQL_CONFIG_FILE}."

# Adiciona as novas configurações logo após a linha [mysqld]
# Usamos um marcador único para evitar problemas se BIND_ADDRESS contiver barras '/'
readonly SED_INSERT_MARKER="##MYSQL_CONFIG_INSERT_POINT##"
# Adiciona o marcador
sed -i "/^\s*\[mysqld\]/a ${SED_INSERT_MARKER}" "${MYSQL_CONFIG_FILE}"
# Substitui o marcador pelas novas configurações
# Usamos | como delimitador no sed por causa das barras em BIND_ADDRESS
# Usamos \\n para inserir novas linhas literais
sed -i "s|${SED_INSERT_MARKER}|bind-address = ${BIND_ADDRESS}\\nport         = ${BIND_PORT}\\nmysqlx-port  = ${MYSQLX_PORT}|" "${MYSQL_CONFIG_FILE}" ||
  error_exit "Falha ao adicionar novas configurações (bind-address/port/mysqlx-port) em ${MYSQL_CONFIG_FILE}."


echo "[4/5] Reiniciando o serviço MySQL para aplicar as configurações..."
systemctl restart mysql || error_exit "Falha ao reiniciar o serviço MySQL."
systemctl status mysql --no-pager # Mostra o status para verificação rápida

# --- 3. Configuração do Plugin auth_socket e Usuário Root ---
echo "[5/5] Configurando autenticação auth_socket para root@localhost..."

# Nota: Em muitas instalações recentes do MySQL no Ubuntu, o auth_socket
# já é o padrão para root@localhost e o plugin já está ativo/compilado.
# Estes comandos garantem o estado desejado. O comando INSTALL PLUGIN pode
# falhar se o plugin já estiver ativo ou for built-in, o que geralmente é seguro ignorar
# nesse contexto específico, pois o objetivo final é usar o ALTER USER.

# Usamos um Here Document para passar os comandos SQL para o cliente mysql
# Executamos como root do sistema, que geralmente pode se conectar via socket sem senha
if ! sudo mysql <<-EOF; then
    -- Tenta instalar/carregar o plugin. Pode falhar se já ativo/built-in (geralmente OK).
    -- Em caso de erro aqui, verificar os logs do MySQL se a autenticação falhar depois.
    INSTALL PLUGIN IF NOT EXISTS auth_socket SONAME 'auth_socket.so';

    -- Altera o método de autenticação para root@localhost
    ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;

    -- Aplica as alterações de privilégio
    FLUSH PRIVILEGES;
EOF
  error_exit "Falha ao executar comandos SQL para configurar auth_socket. Verifique os logs do MySQL (/var/log/mysql/error.log)."
fi

echo "---"
echo "Configuração do MySQL concluída com sucesso!"
echo "O servidor MySQL está escutando em ${BIND_ADDRESS}:${BIND_PORT}."
echo "O Plugin X do MySQL está escutando na porta ${MYSQLX_PORT} (se habilitado)."
echo "O usuário 'root'@'localhost' está configurado para usar autenticação via socket (auth_socket)."
echo "Você pode se conectar como root usando: sudo mysql"
exit 0