#!/bin/bash

# --- Default values ---
VHOST_DOMAIN=""
VHOST_DOC_ROOT=""
APACHE_LISTEN_IP="127.0.0.1" 
APACHE_LISTEN_PORT="8080" 
APACHE_USER="mtasa" 
APACHE_GROUP="mtasa" 
APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_LOG_DIR_VAR="\${APACHE_LOG_DIR}"

# --- Usage Function ---
usage() {
  echo "Uso: $0 --vhost-server-domain=<DOMAIN> --vhost-document-root=<PATH>"
  exit 1
}

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --vhost-server-domain=*)
      VHOST_DOMAIN="${1#*=}"
      ;;
    --vhost-document-root=*)
      VHOST_DOC_ROOT="${1#*=}"
      ;;
    *)
      echo "Erro: Parâmetro desconhecido: $1"
      usage
      ;;
  esac
  shift
done

# --- Validation ---
if [[ -z "$VHOST_DOMAIN" || -z "$VHOST_DOC_ROOT" ]]; then
  echo "Erro: Parâmetros obrigatórios ausentes."
  usage
fi

# --- Check for root privileges (necessário para escrever em /etc/apache2 e usar a2ensite/reload) ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Erro: Este script precisa ser executado como root."
  exit 1
fi

# --- Define Output File ---
CONFIG_FILENAME="${VHOST_DOMAIN}.conf"
OUTPUT_FILE="$APACHE_SITES_AVAILABLE/${CONFIG_FILENAME}"

# --- Check if file already exists ---
if [[ -f "$OUTPUT_FILE" ]]; then
    echo "Aviso: O arquivo de configuração '$OUTPUT_FILE' já existe."
    read -p "Sobrescrever? (s/N): " -n 1 -r
    echo 
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Operação cancelada."
        exit 1
    fi
    echo "Sobrescrevendo '$OUTPUT_FILE'..."
fi

# --- Generate Configuration using Here Document ---
echo "Gerando arquivo de configuração em '$OUTPUT_FILE'..."

cat << EOF > "$OUTPUT_FILE"
# Virtual Host para MTA:SA Files - Gerado por script
<VirtualHost ${APACHE_LISTEN_IP}:${APACHE_LISTEN_PORT}>
    ServerName ${VHOST_DOMAIN}
    ServerAdmin webmaster@${VHOST_DOMAIN}

    <IfModule mpm_itk_module>
        AssignUserId ${APACHE_USER} ${APACHE_GROUP}
    </IfModule>

    DocumentRoot "${VHOST_DOC_ROOT}"

    <Directory "${VHOST_DOC_ROOT}">
        Options FollowSymLinks
        AllowOverride None
        Require all granted

        <FilesMatch ".*">
            ForceType application/octet-stream
            Header set Content-Disposition attachment
        </FilesMatch>

    </Directory>

    KeepAlive On
    MaxKeepAliveRequests 100
    KeepAliveTimeout 10

    ErrorLog ${APACHE_LOG_DIR_VAR}/${VHOST_DOMAIN}-error.log
    CustomLog ${APACHE_LOG_DIR_VAR}/${VHOST_DOMAIN}-access.log combined
    LogLevel warn
</VirtualHost>
EOF

# --- Verifica se o arquivo foi criado ---
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao criar o arquivo de configuração '$OUTPUT_FILE'."
    exit 1
fi
echo "Arquivo de configuração '$OUTPUT_FILE' criado com sucesso."

# --- Habilitar o site com a2ensite ---
echo "Habilitando o site ${CONFIG_FILENAME} com a2ensite..."
a2ensite "${CONFIG_FILENAME}"
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao habilitar o site com 'a2ensite ${CONFIG_FILENAME}'."
    echo "Verifique se o Apache2 está instalado corretamente e se o arquivo foi criado."
    # Não precisa remover o arquivo de sites-available necessariamente
    exit 1
fi
echo "Site ${CONFIG_FILENAME} habilitado."

# --- Testar configuração do Apache ---
echo "Testando configuração do Apache..."
apache2ctl configtest
if [[ $? -ne 0 ]]; then
    echo "-----------------------------------------------------"
    echo "[ERRO] Teste de configuração do Apache FALHOU (apache2ctl configtest)!"
    echo "Verifique a sintaxe em '$OUTPUT_FILE' e os logs do Apache."
    echo "O Apache NÃO será recarregado para evitar problemas."
    echo "Desabilitando o site recém-habilitado: ${CONFIG_FILENAME}"
    # Tenta desabilitar o site que causou o erro
    a2dissite "${CONFIG_FILENAME}" > /dev/null 2>&1 # Suprime a saída normal de a2dissite
    echo "-----------------------------------------------------"
    exit 1 # Sai com erro para indicar que a configuração não foi aplicada
fi
echo "Configuração do Apache válida."

# --- Recarregar Apache ---
echo "Recarregando Apache para aplicar as alterações..."
systemctl reload apache2
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao recarregar o Apache (systemctl reload apache2)."
    echo "Verifique o status do serviço Apache: systemctl status apache2"
    # O site ainda está habilitado, mas o reload falhou. O admin precisa intervir.
    exit 1
fi
echo "Apache recarregado com sucesso."

# --- Mensagem Final ---
echo "-----------------------------------------------------"
echo "Configuração de virtual host do Apache criada e ativada com sucesso!"
echo "Arquivo:      $OUTPUT_FILE"
echo "Site Habilitado: ${CONFIG_FILENAME}"
echo "Servidor:     http://${VHOST_DOMAIN}/ (na porta ${APACHE_LISTEN_PORT} do servidor Apache)"
echo "Document Root: ${VHOST_DOC_ROOT}"
echo "-----------------------------------------------------"
echo "Lembre-se que este VirtualHost escuta em ${APACHE_LISTEN_IP}:${APACHE_LISTEN_PORT}."
echo "Se estiver usando um proxy reverso (como Nginx), configure-o para encaminhar"
echo "requisições para http://${APACHE_LISTEN_IP}:${APACHE_LISTEN_PORT}."
echo "-----------------------------------------------------"

exit 0