#!/bin/bash

# === Variáveis Globais (serão preenchidas pelos argumentos obrigatórios) ===
MYSQL_PROFTPD_USER=""
MYSQL_PROFTPD_PASSWORD=""
MYSQL_PROFTPD_HOST=""

# === Constantes ===
MYSQL_PROFTPD_DB="proftpd" 
PROFTPD_CONFIG_DIR="/etc/proftpd"
CREATE_USER_SCRIPT_URL="https://supremesolid.github.io/ubuntu-automation-tools/MySQL/create-user.sh"
SQL_SCHEMA_URL="https://supremesolid.github.io/ubuntu-automation-tools/ProFTPD/proftpd.sql"
CONFIG_BASE_URL="https://supremesolid.github.io/ubuntu-automation-tools/ProFTPD/configs"
PROFTPD_SERVICE_NAME="proftpd" # Nome do serviço pode variar em alguns sistemas, mas geralmente é este
CONFIG_FILES=(
    "geoip.conf"
    "ldap.conf"
    "modules.conf"
    "proftpd.conf"
    "sftp.conf"
    "snmp.conf"
    "sql.conf"
    "tls.conf"
    "virtuals.conf"
)

# === Funções Auxiliares ===
usage() {
    echo "Uso: $0 --username=<usuario> --password=<senha> --host=<host>"
    echo ""
    echo "Parâmetros Obrigatórios:"
    echo "  --username=<usuario>  Nome do usuário MySQL para o ProFTPD"
    echo "  --password=<senha>    Senha do usuário MySQL para o ProFTPD"
    echo "  --host=<host>         Host do servidor MySQL (ex: 127.0.0.1, localhost)"
    echo ""
    echo "Exemplo: $0 --username=proftpd --password=SenhaSegura123 --host=127.0.0.1"
    exit 1
}

check_error() {
    local exit_code=$?
    local command_name=$1 
    if [ $exit_code -ne 0 ]; then
        echo "ERRO: Comando '$command_name' falhou com código $exit_code. Abortando script."
       
        if [[ -d "$BACKUP_DIR" && "$STEP" == "CONFIG_DOWNLOAD" ]]; then
             echo "Tentando restaurar backup de '$BACKUP_DIR' para '$PROFTPD_CONFIG_DIR'..."
             rm -rf "$PROFTPD_CONFIG_DIR" &> /dev/null
             mv "$BACKUP_DIR" "$PROFTPD_CONFIG_DIR"
        fi
        exit $exit_code
    fi
}

# === Processamento de Argumentos ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        --username=*)
            MYSQL_PROFTPD_USER="${1#*=}"
            shift
            ;;
        --password=*)
            MYSQL_PROFTPD_PASSWORD="${1#*=}"
            shift
            ;;
        --host=*)
            MYSQL_PROFTPD_HOST="${1#*=}"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "ERRO: Opção desconhecida: $1"
            usage
            ;;
    esac
done

# === Validação de Argumentos Obrigatórios ===
MISSING_ARGS=()
if [[ -z "$MYSQL_PROFTPD_USER" ]]; then
    MISSING_ARGS+=("--username")
fi
if [[ -z "$MYSQL_PROFTPD_PASSWORD" ]]; then
    MISSING_ARGS+=("--password")
fi
if [[ -z "$MYSQL_PROFTPD_HOST" ]]; then
    MISSING_ARGS+=("--host")
fi

if [[ ${#MISSING_ARGS[@]} -ne 0 ]]; then
    echo "ERRO: Os seguintes parâmetros obrigatórios não foram fornecidos: ${MISSING_ARGS[*]}"
    echo ""
    usage
fi


# === Verificações Iniciais ===
if [[ $EUID -ne 0 ]]; then
   echo "ERRO: Este script precisa ser executado como root (ou usando sudo)."
   exit 1
fi

# Verifica dependências
for cmd in mysql curl proftpd systemctl; do
    if ! command -v $cmd &> /dev/null; then
        echo "INFO: Comando '$cmd' não encontrado. Tentando instalar dependências..."
        # Silenciar saída do apt update para limpeza
        apt update > /dev/null
        check_error "apt update"
        # Instala o pacote necessário (pode precisar de ajustes se o nome do pacote for diferente)
        case $cmd in
            mysql)      pkg="mysql-client" ;;
            curl)       pkg="curl" ;;
            proftpd)    pkg="proftpd-core" ;; # Instala o core se proftpd -t não for encontrado
            systemctl)  pkg="systemd" ;; # Normalmente já presente
            *)          echo "ERRO: Dependência desconhecida '$cmd'"; exit 1 ;;
        esac
        # Evita reinstalar systemd desnecessariamente
        if [[ "$pkg" != "systemd" ]] || ! systemctl --version &>/dev/null; then
             echo "Instalando $pkg..."
             apt install -y "$pkg"
             check_error "apt install $pkg"
        fi

        if ! command -v $cmd &> /dev/null; then
            echo "ERRO: Falha ao instalar ou encontrar o comando '$cmd' após a instalação."
            exit 1
        fi
    fi
done


# === Início da Execução ===
echo "--- Iniciando a configuração do ProFTPD com MySQL ---"
echo "Usando Configurações MySQL para ProFTPD:"
echo "  Usuário: $MYSQL_PROFTPD_USER"
echo "  Senha: [OCULTA]"
echo "  Host:  $MYSQL_PROFTPD_HOST"
echo "  DB:    $MYSQL_PROFTPD_DB"
echo "--------------------------------------------------"

# 1. Instalar Módulos Específicos do ProFTPD
STEP="INSTALL_MODULES"
echo "--> 1/7: Instalando módulos ProFTPD (mysql, crypto, ldap)..."
# apt update já foi feito na checagem de dependências se necessário
apt install -y proftpd-mod-mysql proftpd-mod-crypto proftpd-mod-ldap
check_error "apt install proftpd-mods"
echo "Módulos ProFTPD instalados com sucesso."

# 2. Criar Usuário MySQL
STEP="CREATE_USER"
echo "--> 2/7: Executando script externo para criar o usuário MySQL '$MYSQL_PROFTPD_USER'..."
echo "INFO: O script externo pode solicitar a senha root do MySQL se não conseguir usar socket."
bash <(curl -sSL "$CREATE_USER_SCRIPT_URL") \
    --mysql-user="$MYSQL_PROFTPD_USER" \
    --permission-level=default \
    --mysql-password="$MYSQL_PROFTPD_PASSWORD" \
    --mysql-host="$MYSQL_PROFTPD_HOST" \
    --database="$MYSQL_PROFTPD_DB"
# Nota: A verificação de erro aqui é limitada pela natureza do bash <()
echo "Usuário MySQL '$MYSQL_PROFTPD_USER' (provavelmente) criado. Verifique a saída acima."

# 3. Criar Banco de Dados MySQL
STEP="CREATE_DB"
echo "--> 3/7: Criando o banco de dados MySQL '$MYSQL_PROFTPD_DB' (como root, assumindo auth via socket)..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_PROFTPD_DB\`;"
check_error "mysql create database"
echo "Banco de dados '$MYSQL_PROFTPD_DB' criado (ou já existia)."

# 4. Importar Schema SQL
STEP="IMPORT_SQL"
echo "--> 4/7: Importando schema SQL para o banco de dados '$MYSQL_PROFTPD_DB'..."
SQL_CONTENT=$(curl -sSL "$SQL_SCHEMA_URL")
if [ $? -ne 0 ] || [ -z "$SQL_CONTENT" ]; then
    echo "ERRO: Falha ao baixar o schema SQL de '$SQL_SCHEMA_URL'."
    exit 1
fi
echo "$SQL_CONTENT" | mysql -u "$MYSQL_PROFTPD_USER" -p"$MYSQL_PROFTPD_PASSWORD" -h "$MYSQL_PROFTPD_HOST" "$MYSQL_PROFTPD_DB"
check_error "mysql import schema"
echo "Schema SQL importado com sucesso."

# 5. Baixar e Aplicar Arquivos de Configuração
STEP="CONFIG_DOWNLOAD"
echo "--> 5/7: Baixando e substituindo arquivos de configuração em '$PROFTPD_CONFIG_DIR'..."
BACKUP_DIR="${PROFTPD_CONFIG_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
echo "INFO: Criando backup de '$PROFTPD_CONFIG_DIR' em '$BACKUP_DIR'..."
cp -a "$PROFTPD_CONFIG_DIR" "$BACKUP_DIR"
check_error "cp backup"

for file in "${CONFIG_FILES[@]}"; do
    TARGET_FILE="$PROFTPD_CONFIG_DIR/$file"
    SOURCE_URL="$CONFIG_BASE_URL/$file"
    echo "   Baixando '$SOURCE_URL' para '$TARGET_FILE'..."
    curl -fsSL -o "$TARGET_FILE" "$SOURCE_URL"
    check_error "curl download $file"
done
echo "Arquivos de configuração baixados e aplicados."

# 6. Testar Configuração do ProFTPD
STEP="CONFIG_TEST"
echo "--> 6/7: Testando a configuração do ProFTPD..."
proftpd -t
check_error "proftpd -t"
echo "Configuração do ProFTPD parece válida."

# 7. Reiniciar Serviço ProFTPD
STEP="RESTART_SERVICE"
echo "--> 7/7: Reiniciando o serviço ProFTPD (${PROFTPD_SERVICE_NAME})..."
systemctl restart "$PROFTPD_SERVICE_NAME"
check_error "systemctl restart $PROFTPD_SERVICE_NAME"
echo "Serviço ProFTPD reiniciado com sucesso."

STEP="DONE"

# --- Finalização ---
echo ""
echo "--- Configuração e Reinício do ProFTPD concluídos! ---"
echo ""
echo "Próximos passos recomendados:"
echo "1. Revise os arquivos de configuração em '$PROFTPD_CONFIG_DIR', especialmente 'sql.conf' para garantir que as credenciais MySQL (usuário '$MYSQL_PROFTPD_USER', host '$MYSQL_PROFTPD_HOST', senha [OCULTA]) estejam corretas e seguras."
echo "2. Certifique-se de que a senha fornecida para o usuário '$MYSQL_PROFTPD_USER' no MySQL é segura."
echo "3. Verifique o status detalhado do serviço: sudo systemctl status $PROFTPD_SERVICE_NAME"
echo "4. Monitore os logs em /var/log/proftpd/ para quaisquer avisos ou erros operacionais."

exit 0