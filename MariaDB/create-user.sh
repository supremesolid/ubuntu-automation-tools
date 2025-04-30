#!/usr/bin/env bash

# ==============================================================================
# Script para Criar Usuários no MariaDB Server
# ==============================================================================

set -euo pipefail

# === Variáveis Globais ===
TARGET_MARIADB_USER=""
TARGET_MARIADB_PASSWORD="" # Opcional, depende do plugin
PERMISSION_LEVEL=""
TARGET_DATABASE=""
MARIADB_HOST="localhost"
AUTH_PLUGIN="mysql_native_password" # Padrão se senha for usada, 'unix_socket' é a alternativa principal

# === Funções ===
error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

usage() {
  echo "Uso: ${0} --mariadb-user=<USUARIO> [--mariadb-password=<SENHA>] --permission-level=<NIVEL> [--database=<DB>] [--mariadb-host=<HOST>] [--auth-plugin=<PLUGIN>]"
  echo "  Cria um novo usuário MariaDB com um nível de permissão predefinido."
  echo
  echo "  Parâmetros Obrigatórios:"
  echo "    --mariadb-user=<USUARIO>      Nome do novo usuário MariaDB."
  echo "    --permission-level=<NIVEL>    Nível de permissão ('administrator' ou 'default')."
  echo
  echo "  Parâmetros Condicionais:"
  echo "    --database=<DB>               Banco de dados alvo. OBRIGATÓRIO se --permission-level=default."
  echo
  echo "  Parâmetros Opcionais:"
  echo "    --mariadb-password=<SENHA>    Senha para o novo usuário (não utilizada com unix_socket)."
  echo "    --mariadb-host=<HOST>         Host de onde o novo usuário poderá se conectar (padrão: 'localhost'). Use '%' para qualquer host."
  echo "    --auth-plugin=<PLUGIN>        Plugin de autenticação a ser usado (ex: 'unix_socket', 'mysql_native_password')."
  echo "                                    Padrão implícito: 'mysql_native_password' se senha for fornecida, 'unix_socket' se explicitado."
  echo
  echo "  Níveis de Permissão Definidos:"
  echo "    administrator:  ALL PRIVILEGES ON *.* WITH GRANT OPTION (Acesso total. MUITO CUIDADO!)."
  echo "    default:        SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES no banco de dados especificado (--database)."
  echo
  echo "  Plugins Comuns:"
  echo "    unix_socket:           Autenticação via socket do sistema (sem senha, para usuários locais)."
  echo "    mysql_native_password: Autenticação tradicional baseada em senha."
  echo
  echo "  AVISO DE SEGURANÇA: Passar a senha via argumento é inseguro."
  echo "  REQUISITO: Executar com sudo (para usar autenticação via socket do root)."
  exit 1
}

# === Processamento dos Argumentos ===
if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
  # Renomeado para --mariadb-user para clareza, mas pode manter --mysql-user se preferir compatibilidade
  --mariadb-user=*)
    TARGET_MARIADB_USER="${1#*=}"
    shift
    ;;
  --mariadb-password=*)
    TARGET_MARIADB_PASSWORD="${1#*=}"
    shift
    ;;
  --permission-level=*)
    PERMISSION_LEVEL=$(echo "${1#*=}" | tr '[:upper:]' '[:lower:]') # Converte para minúsculas
    shift
    ;;
  --database=*)
    TARGET_DATABASE="${1#*=}"
    shift
    ;;
  # Renomeado para --mariadb-host
  --mariadb-host=*)
    MARIADB_HOST="${1#*=}"
    shift
    ;;
  --auth-plugin=*)
    AUTH_PLUGIN="${1#*=}"
    shift
    ;;
  # Aceita os nomes antigos por compatibilidade, mapeando para os novos
   --mysql-user=*)
    TARGET_MARIADB_USER="${1#*=}"
    echo "AVISO: Use --mariadb-user em vez de --mysql-user para MariaDB." >&2
    shift
    ;;
   --mysql-host=*)
    MARIADB_HOST="${1#*=}"
     echo "AVISO: Use --mariadb-host em vez de --mysql-host para MariaDB." >&2
    shift
    ;;
   --mysql-password=*)
     TARGET_MARIADB_PASSWORD="${1#*=}"
     echo "AVISO: Use --mariadb-password em vez de --mysql-password para MariaDB." >&2
    shift
    ;;
  *)
    error_exit "Argumento desconhecido: ${1}"
    ;;
  esac
done

# === Validação dos Parâmetros ===
if [[ -z "${TARGET_MARIADB_USER}" ]]; then
  error_exit "Parâmetro --mariadb-user é obrigatório."
fi

# Se o plugin for unix_socket, senha não é necessária (e será ignorada).
# Se o plugin NÃO for unix_socket, a senha É necessária.
if [[ "${AUTH_PLUGIN}" != "unix_socket" && -z "${TARGET_MARIADB_PASSWORD}" ]]; then
  error_exit "Parâmetro --mariadb-password é obrigatório quando não se usa --auth-plugin=unix_socket."
fi

if [[ -z "${PERMISSION_LEVEL}" ]]; then
  error_exit "Parâmetro --permission-level é obrigatório."
fi

# Validar nível de permissão
if [[ "${PERMISSION_LEVEL}" != "administrator" && "${PERMISSION_LEVEL}" != "default" ]]; then
  error_exit "Valor inválido para --permission-level. Use 'administrator' ou 'default'."
fi

# Validar --database se nível for 'default'
if [[ "${PERMISSION_LEVEL}" == "default" && -z "${TARGET_DATABASE}" ]]; then
  error_exit "Parâmetro --database é obrigatório quando --permission-level=default."
fi

# === Verificação de Privilégios ===
if [[ ${EUID} -ne 0 ]]; then
  error_exit "Este script precisa ser executado como root (ou com sudo) para interagir com o MariaDB via socket do root."
fi

# === Aviso adicional para unix_socket ===
if [[ "${AUTH_PLUGIN}" == "unix_socket" ]]; then
  echo ">>> AVISO: Usando auth-plugin=unix_socket. A senha (--mariadb-password) será ignorada se fornecida."
  # Força a senha a ficar vazia para evitar confusão na lógica CREATE USER
  TARGET_MARIADB_PASSWORD=""
fi

# === Lógica Principal ===
echo ">>> Iniciando criação do usuário MariaDB '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}' com nível '${PERMISSION_LEVEL}'..."

# 1. Construir a query CREATE USER baseada no plugin/senha
SQL_CREATE_USER="CREATE USER IF NOT EXISTS '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}'"

if [[ "${AUTH_PLUGIN}" == "unix_socket" ]]; then
  # Usa IDENTIFIED VIA para plugins no MariaDB
  SQL_CREATE_USER="${SQL_CREATE_USER} IDENTIFIED VIA unix_socket;"
elif [[ -n "${TARGET_MARIADB_PASSWORD}" ]]; then
  # Usa IDENTIFIED BY para senhas (plugin padrão de senha será usado)
   SQL_CREATE_USER="${SQL_CREATE_USER} IDENTIFIED BY '${TARGET_MARIADB_PASSWORD}';"
else
    # Situação de erro: plugin não é unix_socket e senha está vazia (deve ter sido pega na validação)
    error_exit "Erro interno: Senha necessária para o plugin '${AUTH_PLUGIN}' mas não fornecida."
fi

echo ">>> Executando: CREATE USER..."
# Usa o cliente 'mariadb'. Assume que o usuário root/sudo pode conectar via socket.
# Adicionado --protocol=socket para ter certeza, usa o socket padrão
SOCKET_PATH=$(mariadb_config --socket 2>/dev/null || echo "/run/mysqld/mysqld.sock") # Tenta detectar socket
if ! mariadb --protocol=socket -S "${SOCKET_PATH}" --execute="${SQL_CREATE_USER}"; then
  error_exit "Falha ao executar CREATE USER. Verifique:"$'\n'"  - Se o usuário já existe com configuração diferente."$'\n'"  - Logs do MariaDB (/var/log/mysql/error.log)."
fi
echo ">>> Usuário '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}' criado ou já existente."

# 2. Conceder permissões baseadas no nível
SQL_GRANT=""
echo ">>> Definindo permissões para nível '${PERMISSION_LEVEL}'..."
case "${PERMISSION_LEVEL}" in
administrator)
  # CUIDADO: ALL PRIVILEGES é extremamente poderoso.
  SQL_GRANT="GRANT ALL PRIVILEGES ON *.* TO '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}' WITH GRANT OPTION;"
  ;;
default)
  # Permissões básicas no banco de dados especificado.
  # Usar backticks ` para segurança do nome do banco de dados.
  SQL_GRANT="GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES ON \`${TARGET_DATABASE}\`.* TO '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}';"
  ;;
esac

# 3. Executar GRANT
if [[ -n "${SQL_GRANT}" ]]; then
  echo ">>> Executando: GRANT..."
  if ! mariadb --protocol=socket -S "${SOCKET_PATH}" --execute="${SQL_GRANT}"; then
    error_exit "Falha ao executar GRANT. Verifique:"$'\n'"  - Se o banco de dados '${TARGET_DATABASE}' existe (para nível default)."$'\n'"  - Logs do MariaDB."
  fi
  echo ">>> Permissões concedidas com sucesso."
else
  error_exit "Falha interna: Nenhuma instrução GRANT foi definida."
fi

# 4. Aplicar privilégios
echo ">>> Executando: FLUSH PRIVILEGES..."
if ! mariadb --protocol=socket -S "${SOCKET_PATH}" --execute="FLUSH PRIVILEGES;"; then
  # FLUSH PRIVILEGES nem sempre é estritamente necessário, mas é boa prática.
  echo "AVISO: Falha ao executar FLUSH PRIVILEGES. As permissões geralmente são aplicadas imediatamente, mas isso pode indicar um problema." >&2
fi

echo ">>> Usuário MariaDB '${TARGET_MARIADB_USER}'@'${MARIADB_HOST}' criado e configurado com sucesso!"
if [[ "${PERMISSION_LEVEL}" == "default" ]]; then
  echo ">>> Permissões (default) aplicadas ao banco de dados: '${TARGET_DATABASE}'"
fi
if [[ "${PERMISSION_LEVEL}" == "administrator" ]]; then
  echo ">>> ATENÇÃO: Usuário criado com privilégios de ADMINISTRADOR TOTAL!"
fi

exit 0