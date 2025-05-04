#!/bin/bash

# --- Default values ---
VHOST_IP=""
VHOST_PORT=""
VHOST_DOMAIN=""
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available" 

# --- Usage Function ---
usage() {
  echo "Uso: $0 --vhost-server-ip=<Ipv4> --vhost-server-port=<PORT> --vhost-server-domain=<DOMAIN>"
  exit 1
}

# Percorre todos os argumentos passados para o script
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    # Verifica se o argumento começa com --vhost-server-ip=
    --vhost-server-ip=*)
      # Extrai o valor após o '='
      VHOST_IP="${1#*=}"
      ;;
    # Verifica se o argumento começa com --vhost-server-port=
    --vhost-server-port=*)
      # Extrai o valor após o '='
      VHOST_PORT="${1#*=}"
      ;;
    # Verifica se o argumento começa com --vhost-server-domain=
    --vhost-server-domain=*)
      # Extrai o valor após o '='
      VHOST_DOMAIN="${1#*=}"
      ;;
    # Se o argumento não corresponder a nenhum dos padrões conhecidos
    *)
      echo "Erro: Parâmetro desconhecido: $1"
      usage
      ;;
  esac
  # Passa para o próximo argumento
  shift
done

# --- Validation ---
# Verifica se alguma das variáveis obrigatórias está vazia
if [[ -z "$VHOST_IP" || -z "$VHOST_PORT" || -z "$VHOST_DOMAIN" ]]; then
  echo "Erro: Parâmetros obrigatórios ausentes."
  usage
fi

# --- Check for root privileges (necessário para escrever em /etc/nginx) ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Erro: Este script precisa ser executado como root para escrever em $NGINX_SITES_AVAILABLE."
  exit 1
fi

# --- Define Output File ---
# Cria o nome do arquivo de configuração baseado no domínio, com a extensão .conf
OUTPUT_FILE="$NGINX_SITES_AVAILABLE/${VHOST_DOMAIN}.conf"

# --- Check if file already exists ---
if [[ -f "$OUTPUT_FILE" ]]; then
    echo "Aviso: O arquivo de configuração '$OUTPUT_FILE' já existe."
    # Pede confirmação para sobrescrever
    read -p "Sobrescrever? (s/N): " -n 1 -r
    echo # Pula para uma nova linha após a resposta
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Operação cancelada."
        exit 1
    fi
    echo "Sobrescrevendo '$OUTPUT_FILE'..."
fi


# --- Generate Configuration using Here Document ---
echo "Gerando arquivo de configuração em '$OUTPUT_FILE'..."
cat << EOF > "$OUTPUT_FILE"
server {
    listen ${VHOST_IP}:${VHOST_PORT};

    server_name ${VHOST_DOMAIN};
    access_log off;
    autoindex off;

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
        send_timeout          60s;

        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-Content-Type-Options nosniff always; 
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }
}
EOF

# --- Verifica se o arquivo foi criado ---
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao criar o arquivo de configuração '$OUTPUT_FILE'."
    exit 1
fi

echo "Arquivo de configuração '$OUTPUT_FILE' criado com sucesso."

# --- Criar link simbólico ---

SYMLINK_TARGET="/etc/nginx/sites-enabled/$(basename "$OUTPUT_FILE")"
echo "Criando link simbólico: $SYMLINK_TARGET"

ln -sf "$OUTPUT_FILE" "$SYMLINK_TARGET"
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao criar o link simbólico em '$SYMLINK_TARGET'."
    exit 1
fi
echo "Link simbólico criado com sucesso."

echo "Testando configuração do Nginx..."
nginx -t
if [[ $? -ne 0 ]]; then
    echo "-----------------------------------------------------"
    echo "[ERRO] Teste de configuração do Nginx FALHOU!"
    echo "Verifique a sintaxe em '$OUTPUT_FILE' e os logs do Nginx."
    echo "O Nginx NÃO será recarregado para evitar problemas."
    echo "Removendo link simbólico problemático: $SYMLINK_TARGET"
    # Tenta remover o link que provavelmente causou o erro no teste
    rm -f "$SYMLINK_TARGET"
    echo "-----------------------------------------------------"
    exit 1 
fi
echo "Configuração do Nginx válida."

# --- Recarregar Nginx ---
echo "Recarregando Nginx para aplicar as alterações..."
systemctl reload nginx

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao recarregar o Nginx (systemctl reload nginx)."
    echo "Verifique o status do serviço Nginx: systemctl status nginx"
    exit 1 
fi
echo "Nginx recarregado com sucesso."

# --- Mensagem Final ---
echo "-----------------------------------------------------"
echo "Configuração de virtual host do Nginx criada e ativada com sucesso!"
echo "Arquivo: $OUTPUT_FILE"
echo "Ativado em: $SYMLINK_TARGET"
echo "-----------------------------------------------------"

exit 0