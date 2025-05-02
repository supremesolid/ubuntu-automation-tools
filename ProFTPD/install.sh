#!/bin/bash

# === Variáveis Globais (serão preenchidas pelos argumentos obrigatórios) ===
MYSQL_PROFTPD_USER=""
# MYSQL_PROFTPD_PASSWORD="" # Removido - Não é mais necessário
# *** Host fixo em 'localhost' ***
MYSQL_PROFTPD_HOST="localhost"

# === Constantes ===
MYSQL_PROFTPD_DB="proftpd"
PROFTPD_CONFIG_DIR="/etc/proftpd"
# Certifique-se que esta URL aponte para a VERSÃO CORRIGIDA do create-user.sh (com permissão CREATE)
CREATE_USER_SCRIPT_URL="https://supremesolid.github.io/ubuntu-automation-tools/MySQL/create-user.sh"
SQL_SCHEMA_URL="https://supremesolid.github.io/ubuntu-automation-tools/ProFTPD/proftpd.sql"
CONFIG_BASE_URL="https://supremesolid.github.io/ubuntu-automation-tools/ProFTPD/configs"
PROFTPD_SERVICE_NAME="proftpd" # Nome do serviço
CONFIG_FILES=(
    "geoip.conf"
    "ldap.conf"
    "modules.conf"
    "proftpd.conf"
    "sftp.conf"
    "snmp.conf"
    "sql.conf" # Este será modificado após o download
    "tls.conf"
    "virtuals.conf"
)

# === Funções Auxiliares ===
usage() {
    # Atualizado para remover --password
    echo "Uso: $0 --username=<usuario>"
    echo ""
    echo "Parâmetros Obrigatórios:"
    echo "  --username=<usuario>  Nome do usuário MySQL para o ProFTPD (será configurado com auth_socket)."
    echo ""
    echo "Exemplo: $0 --username=proftpd"
    echo ""
    echo "Nota: O host MySQL está fixo em '$MYSQL_PROFTPD_HOST' e a autenticação usada será 'auth_socket'."
    exit 1
}

check_error() {
    local exit_code=$?
    local command_name=$1
    if [ $exit_code -ne 0 ]; then
        echo "ERRO: Comando '$command_name' falhou com código $exit_code. Abortando script."

        # Restaura backup se falha ocorreu durante download ou ajuste de config
        if [[ -d "$BACKUP_DIR" && ("$STEP" == "CONFIG_DOWNLOAD" || "$STEP" == "ADJUST_SQLCONF" || "$STEP" == "CONFIG_TEST") ]]; then
             echo "Tentando restaurar backup de '$BACKUP_DIR' para '$PROFTPD_CONFIG_DIR'..."
             rm -rf "$PROFTPD_CONFIG_DIR" &> /dev/null
             if [[ -d "$BACKUP_DIR" ]]; then
                 mv "$BACKUP_DIR" "$PROFTPD_CONFIG_DIR"
             else
                 echo "AVISO: Diretório de backup '$BACKUP_DIR' não encontrado para restauração."
             fi
        fi
        if [[ "$STEP" == "CONFIG_TEST" ]]; then
             echo "Tentando parar o serviço $PROFTPD_SERVICE_NAME devido à falha no teste de configuração..."
             systemctl is-active --quiet "$PROFTPD_SERVICE_NAME" && systemctl stop "$PROFTPD_SERVICE_NAME"
        fi
        exit $exit_code
    fi
}

# === Processamento de Argumentos ===
# Removido o processamento de --password
while [[ $# -gt 0 ]]; do
    case "$1" in
        --username=*)
            MYSQL_PROFTPD_USER="${1#*=}"
            shift
            ;;
        # --password=*) # REMOVIDO
            # shift
            # ;;
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
# Removida a validação de --password
MISSING_ARGS=()
if [[ -z "$MYSQL_PROFTPD_USER" ]]; then
    MISSING_ARGS+=("--username")
fi
# if [[ -z "$MYSQL_PROFTPD_PASSWORD" ]]; then # REMOVIDO
#     MISSING_ARGS+=("--password")
# fi

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
for cmd in mysql curl proftpd systemctl sed; do
    if ! command -v $cmd &> /dev/null; then
        echo "INFO: Comando '$cmd' não encontrado. Tentando instalar dependências..."
        apt update > /dev/null
        check_error "apt update"
        case $cmd in
            mysql)      pkg="mysql-client" ;;
            curl)       pkg="curl" ;;
            proftpd)    pkg="proftpd-core" ;;
            systemctl)  pkg="systemd" ;;
            sed)        pkg="sed" ;;
            *)          echo "ERRO: Dependência desconhecida '$cmd'"; exit 1 ;;
        esac
        if [[ "$pkg" != "systemd" && "$pkg" != "sed" ]] || ! command -v $cmd &>/dev/null; then
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
echo "--- Iniciando a configuração do ProFTPD com MySQL (usando auth_socket) ---" # Mensagem atualizada
echo "Usando Configurações MySQL para ProFTPD:"
echo "  Usuário: $MYSQL_PROFTPD_USER"
# echo "  Senha: [OCULTA]" # REMOVIDO
echo "  Host:  $MYSQL_PROFTPD_HOST (Fixo)"
echo "  DB:    $MYSQL_PROFTPD_DB"
echo "  Auth:  auth_socket (sem senha)" # Adicionado
echo "--------------------------------------------------"

# 1. Instalar Módulos Específicos do ProFTPD
STEP="INSTALL_MODULES"
echo "--> 1/8: Instalando módulos ProFTPD (mysql, crypto, ldap)..."
apt install -y proftpd-mod-mysql proftpd-mod-crypto proftpd-mod-ldap
check_error "apt install proftpd-mods"
echo "Módulos ProFTPD instalados com sucesso."

# 2. Criar/Configurar Usuário MySQL para auth_socket
STEP="CREATE_USER"
echo "--> 2/8: Executando script externo para criar/configurar o usuário MySQL '$MYSQL_PROFTPD_USER'@'$MYSQL_PROFTPD_HOST' com auth_socket..."
echo "INFO: Certifique-se que a URL $CREATE_USER_SCRIPT_URL aponta para a versão CORRIGIDA do script (com permissão CREATE)."
echo "INFO: O script externo pode solicitar a senha root do MySQL."
bash <(curl -sSL "$CREATE_USER_SCRIPT_URL") \
    --mysql-user="$MYSQL_PROFTPD_USER" \
    --permission-level=default \
    # --mysql-password="$MYSQL_PROFTPD_PASSWORD" \ # REMOVIDO
    --mysql-host="$MYSQL_PROFTPD_HOST" \
    --database="$MYSQL_PROFTPD_DB" \
    --auth-plugin=auth_socket # ADICIONADO
# Nota: A verificação de erro aqui é limitada
echo "Usuário MySQL '$MYSQL_PROFTPD_USER'@'$MYSQL_PROFTPD_HOST' (provavelmente) criado/configurado com auth_socket. Verifique a saída acima."

# 3. Criar Banco de Dados MySQL
STEP="CREATE_DB"
echo "--> 3/8: Criando o banco de dados MySQL '$MYSQL_PROFTPD_DB' (como root, assumindo auth via socket)..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_PROFTPD_DB\`;"
check_error "mysql create database"
echo "Banco de dados '$MYSQL_PROFTPD_DB' criado (ou já existia)."

# 4. Importar Schema SQL (como root do MySQL)
STEP="IMPORT_SQL"
echo "--> 4/8: Importando schema SQL para o banco de dados '$MYSQL_PROFTPD_DB' (usando root do MySQL)..."
SQL_CONTENT=$(curl -sSL "$SQL_SCHEMA_URL")
if [ $? -ne 0 ] || [ -z "$SQL_CONTENT" ]; then
    echo "ERRO: Falha ao baixar o schema SQL de '$SQL_SCHEMA_URL'."
    exit 1
fi
# Importando como root do MySQL, que pode se autenticar via socket quando o script roda com sudo.
echo "$SQL_CONTENT" | mysql -u root "$MYSQL_PROFTPD_DB"
check_error "mysql import schema"
echo "Schema SQL importado com sucesso."

# 5. Baixar e Aplicar Arquivos de Configuração
STEP="CONFIG_DOWNLOAD"
echo "--> 5/8: Baixando e substituindo arquivos de configuração em '$PROFTPD_CONFIG_DIR'..."
BACKUP_DIR="${PROFTPD_CONFIG_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
echo "INFO: Criando backup de '$PROFTPD_CONFIG_DIR' em '$BACKUP_DIR'..."
mkdir -p "$(dirname "$BACKUP_DIR")"
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

# 6. Ajustar SQLConnectInfo em sql.conf para auth_socket *** MODIFICADO ***
STEP="ADJUST_SQLCONF"
echo "--> 6/8: Ajustando SQLConnectInfo em ${PROFTPD_CONFIG_DIR}/sql.conf para usar auth_socket (sem senha)..."
SQL_CONF_FILE="${PROFTPD_CONFIG_DIR}/sql.conf"
if [[ -f "$SQL_CONF_FILE" ]]; then
    # Substitui toda a linha começando com SQLConnectInfo para ter APENAS db@host user
    sed -i "s#^SQLConnectInfo\s+.*#SQLConnectInfo ${MYSQL_PROFTPD_DB}@${MYSQL_PROFTPD_HOST} ${MYSQL_PROFTPD_USER}#" "$SQL_CONF_FILE"
    check_error "sed adjust sql.conf (auth_socket)"
    echo "SQLConnectInfo atualizado para auth_socket."
else
    # Se o sql.conf não foi baixado por algum motivo, isso é um erro crítico.
    echo "ERRO CRÍTICO: Arquivo '$SQL_CONF_FILE' não encontrado para ajuste."
    check_error "$SQL_CONF_FILE not found" # Força a saída com erro
fi

# 7. Testar Configuração do ProFTPD
STEP="CONFIG_TEST"
echo "--> 7/8: Testando a configuração do ProFTPD..."
proftpd -t
check_error "proftpd -t"
echo "Configuração do ProFTPD parece válida."

# 8. Reiniciar Serviço ProFTPD
STEP="RESTART_SERVICE"
echo "--> 8/8: Reiniciando o serviço ProFTPD (${PROFTPD_SERVICE_NAME})..."
systemctl restart "$PROFTPD_SERVICE_NAME"
check_error "systemctl restart $PROFTPD_SERVICE_NAME"
echo "Serviço ProFTPD reiniciado com sucesso."

STEP="DONE"

# --- Finalização ---
echo ""
echo "--- Configuração e Reinício do ProFTPD concluídos! (usando auth_socket) ---" # Atualizado
echo ""
echo "INFO: O arquivo '$SQL_CONF_FILE' foi atualizado automaticamente para conexão via auth_socket (sem senha):" # Atualizado
echo "      SQLConnectInfo ${MYSQL_PROFTPD_DB}@${MYSQL_PROFTPD_HOST} ${MYSQL_PROFTPD_USER}" # Atualizado
echo ""
echo "Próximos passos recomendados:"
# echo "1. Certifique-se de que a senha fornecida..." # REMOVIDO
echo "1. Confirme que o ProFTPD está rodando como o usuário do SO correto (geralmente 'proftpd') para que o auth_socket funcione."
echo "   (Verifique as diretivas 'User' e 'Group' em '$PROFTPD_CONFIG_DIR/proftpd.conf' ou arquivos incluídos)."
echo "2. Verifique o status detalhado do serviço: sudo systemctl status $PROFTPD_SERVICE_NAME"
echo "3. Monitore os logs em /var/log/proftpd/ e os logs de erro do MySQL (/var/log/mysql/error.log ou similar) para quaisquer avisos ou erros operacionais relacionados à autenticação SQL."

exit 0