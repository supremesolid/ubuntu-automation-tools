#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Constantes ===
readonly NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly NGINX_LOG_DIR="/var/log/nginx"
readonly KEEPALIVE_COUNT=32 # Valor do Keepalive para o upstream

# === Cores para Terminal ===
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# === Funções de Log ===
log() { echo -e "${GREEN}[✔]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1" >&2; }
error_exit() {
  echo -e "${RED}[✖]${RESET} $1" >&2
  exit 1
}
info() { echo -e "${BLUE}[ℹ]${RESET} $1"; }

# === Funções Auxiliares ===

# Exibe mensagem de ajuda
usage() {
  echo -e "${YELLOW}Uso:${RESET} $0 --vhost-server-ip=<IP> --vhost-server-port=<PORTA> --vhost-server-domain=<DOMAIN> --vhost-proxy-target=<TARGET> [--vhost-proxy-ssl=<yes|no>]"
  echo ""
  echo "Cria um VirtualHost Nginx com proxy reverso e upstream keepalive para um serviço web (ex: painel MTASA, API, etc.)."
  echo ""
  echo -e "${BLUE}Opções:${RESET}"
  echo "  --vhost-server-ip=<IP>         Endereço IP para o Nginx escutar (ex: 0.0.0.0, 192.168.0.230)."
  echo "  --vhost-server-port=<PORTA>    Porta para o Nginx escutar (ex: 80, 443)."
  echo "  --vhost-server-domain=<DOMAIN> Nome do domínio ou subdomínio (ex: mta-admin.meudominio.com)."
  echo "  --vhost-proxy-target=<TARGET>  Alvo do proxy (IP:PORTA do serviço web backend)."
  echo "                                 ${YELLOW}ATENÇÃO:${RESET} Use a porta do serviço ${YELLOW}HTTP/HTTPS${RESET}, não a porta UDP do jogo/query!"
  echo "  --vhost-proxy-ssl=<yes|no>     O serviço alvo (backend) usa HTTPS? (Padrão: no)."
  echo "                                 Se 'yes', adiciona config para validar SSL (proxy_ssl_verify off)."
  echo "  -h, --help                     Exibe esta mensagem de ajuda."
  exit 0
}

# Valida formato de IP v4
validate_ipv4() {
  local ip="${1}"
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  # Permitir 0.0.0.0 como IP válido
  if [[ "${ip}" == "0.0.0.0" ]]; then
    return 0
  fi
  if ! [[ "${ip}" =~ ${ip_regex} ]]; then
    error_exit "Formato de endereço IP inválido: ${ip}. Use o formato X.X.X.X ou 0.0.0.0."
  fi
  local IFS='.'
  read -ra octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    if ! [[ "${octet}" =~ ^[0-9]+$ ]] || ((octet < 0 || octet > 255)); then
      error_exit "Endereço IP inválido: ${ip}. Octeto '${octet}' fora do intervalo 0-255."
    fi
  done
  IFS=' '
}

# Valida formato da porta
validate_port() {
  local port="${1}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    error_exit "Porta inválida: ${port}. Use um número entre 1 e 65535."
  fi
}

# Valida formato do domínio (básico)
validate_domain() {
  local domain="${1}"
  # Regex um pouco mais permissiva para domínios locais/internos se necessário, mas mantendo padrão geral
  local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
  if ! [[ "${domain}" =~ ${domain_regex} ]]; then
      # Tenta validar como IP (para casos de teste sem domínio real)
      validate_ipv4 "${domain}" || error_exit "Formato de domínio inválido: ${domain}"
      warn "Usando endereço IP '${domain}' como server_name. Para produção, use um nome de domínio válido."
  fi
}


# Valida formato do alvo do proxy (básico)
validate_proxy_target() {
  local target="${1}"
  if [[ -z "$target" ]]; then
    error_exit "Alvo do proxy (--vhost-proxy-target) não pode ser vazio."
  fi
  # Validação simples: IP:PORTA ou HOST:PORTA
  local target_regex='^([a-zA-Z0-9.-]+):([0-9]{1,5})$'
  if ! [[ "$target" =~ $target_regex ]]; then
     error_exit "Formato do alvo do proxy '--vhost-proxy-target=${target}' inválido. Deve ser no formato IP:PORTA ou HOSTNAME:PORTA."
  fi
  local target_port="${BASH_REMATCH[2]}"
  validate_port "$target_port" # Valida a porta extraída

  # Aviso específico sobre portas comuns de MTASA UDP
  if [[ "$target_port" == "22003" || "$target_port" == "22005" || "$target_port" == "22126" ]]; then
      warn "A porta ${target_port} no alvo do proxy (${target}) é frequentemente usada para protocolos ${YELLOW}UDP${RESET} no MTASA (jogo, query, http server list)."
      warn "Este script configura um proxy ${YELLOW}HTTP/HTTPS${RESET}. Certifique-se de que '${target}' é realmente um serviço web respondendo via HTTP/HTTPS nessa porta."
  fi
}

# Valida opção SSL
validate_proxy_ssl() {
  local ssl_option="${1}"
  case "$(echo "$ssl_option" | tr '[:upper:]' '[:lower:]')" in
  yes | no) return 0 ;; # Válido
  *) error_exit "Valor inválido para --vhost-proxy-ssl: '${ssl_option}'. Use 'yes' ou 'no'." ;;
  esac
}

# === Verificação Inicial ===
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root (ou com sudo)."
  fi
}

check_nginx_installed() {
  if ! command -v nginx &>/dev/null; then
    error_exit "Comando 'nginx' não encontrado. O Nginx está instalado e no PATH?"
  fi
}

# === Processamento dos Argumentos ===
VHOST_SERVER_IP=""
VHOST_SERVER_PORT=""
VHOST_SERVER_DOMAIN=""
VHOST_PROXY_TARGET=""
VHOST_PROXY_SSL="no" # Valor padrão

# Se nenhum argumento for passado, exibe ajuda
if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
  --vhost-server-ip=*)
    VHOST_SERVER_IP="${1#*=}"
    shift
    ;;
  --vhost-server-port=*)
    VHOST_SERVER_PORT="${1#*=}"
    shift
    ;;
  --vhost-server-domain=*)
    VHOST_SERVER_DOMAIN="${1#*=}"
    shift
    ;;
  --vhost-proxy-target=*)
    VHOST_PROXY_TARGET="${1#*=}"
    shift
    ;;
  --vhost-proxy-ssl=*)
    VHOST_PROXY_SSL="${1#*=}"
    shift
    ;;
  --help | -h)
    usage
    ;;
  *)
    error_exit "Argumento desconhecido: ${1}"
    ;;
  esac
done

# === Validação dos Parâmetros ===
info "Validando parâmetros..."
if [[ -z "${VHOST_SERVER_IP}" || -z "${VHOST_SERVER_PORT}" || -z "${VHOST_SERVER_DOMAIN}" || -z "${VHOST_PROXY_TARGET}" ]]; then
  error_exit "Os parâmetros --vhost-server-ip, --vhost-server-port, --vhost-server-domain, e --vhost-proxy-target são obrigatórios."
fi

validate_ipv4 "${VHOST_SERVER_IP}"
validate_port "${VHOST_SERVER_PORT}"
validate_domain "${VHOST_SERVER_DOMAIN}"
validate_proxy_ssl "${VHOST_PROXY_SSL}"
validate_proxy_target "${VHOST_PROXY_TARGET}" 

log "Parâmetros validados com sucesso."

# Define o nome do upstream baseado no domínio (mais seguro que um nome fixo)
# Substitui caracteres inválidos (ponto, hífen) por underscore
UPSTREAM_NAME="${VHOST_SERVER_DOMAIN//[.-]/_}_backend"

# Define o protocolo real para comentários (não usado diretamente no proxy_pass com upstream)
BACKEND_PROTOCOL="http"
# Bloco de configuração SSL para o backend (adicionado somente se --vhost-proxy-ssl=yes)
PROXY_SSL_BACKEND_CONFIG_BLOCK=""
if [[ "$(echo "$VHOST_PROXY_SSL" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
  BACKEND_PROTOCOL="https"
  # Gera o bloco de texto com indentação correta
  PROXY_SSL_BACKEND_CONFIG_BLOCK=$(cat <<EOF

        # --- Tratamento de SSL para o Backend (opção --vhost-proxy-ssl=yes) ---
        # Permite conexão com backend HTTPS com certificado auto-assinado/inválido.
        # MENOS SEGURO. Se possível, use certificado válido no backend.
        proxy_ssl_verify off;
        proxy_ssl_server_name on; # Envia o SNI para o backend
EOF
)
fi

# === Lógica Principal ===
main() {
  check_root
  check_nginx_installed

  local vhost_file_name="${VHOST_SERVER_DOMAIN}.conf"
  local vhost_file_path="${NGINX_SITES_AVAILABLE}/${vhost_file_name}"
  local vhost_symlink_path="${NGINX_SITES_ENABLED}/${vhost_file_name}"

  info "Verificando se o arquivo de configuração já existe: ${vhost_file_path}"
  if [[ -f "${vhost_file_path}" ]]; then
    warn "Arquivo de configuração ${vhost_file_path} já existe. Ele será sobrescrito."
    # Opcional: Backup
    # cp "${vhost_file_path}" "${vhost_file_path}.bak_$(date +%F_%T)" || warn "Falha ao criar backup."
  fi

  log "Criando arquivo de configuração Nginx para ${VHOST_SERVER_DOMAIN} com Upstream Keepalive..."

  # Cria o diretório de logs Nginx se não existir
  mkdir -p "${NGINX_LOG_DIR}" || error_exit "Falha ao criar diretório de logs: ${NGINX_LOG_DIR}"

  # Cria o arquivo de configuração usando printf para controle de formatação
  # e inserção segura do bloco SSL condicional.
  # Usamos %s como placeholders para as variáveis.

  printf "# Configuração Nginx para %s (Proxy Reverso com Upstream)\n" "${VHOST_SERVER_DOMAIN}" > "${vhost_file_path}" || error_exit "Falha ao escrever no arquivo de configuração ${vhost_file_path}"
  printf "# Gerado por script em %s\n" "$(date)" >> "${vhost_file_path}"
  printf "# Backend Target: %s://%s\n\n" "${BACKEND_PROTOCOL}" "${VHOST_PROXY_TARGET}" >> "${vhost_file_path}" # Comentário informativo

  # Bloco Upstream
  printf "upstream %s {\n" "${UPSTREAM_NAME}" >> "${vhost_file_path}"
  printf "    server %s;\n" "${VHOST_PROXY_TARGET}" >> "${vhost_file_path}"
  printf "    keepalive %d;\n" "${KEEPALIVE_COUNT}" >> "${vhost_file_path}"
  printf "}\n\n" >> "${vhost_file_path}"

  # Bloco Server
  printf "server {\n" >> "${vhost_file_path}"
  printf "    listen %s:%s;\n" "${VHOST_SERVER_IP}" "${VHOST_SERVER_PORT}" >> "${vhost_file_path}"
  printf "    server_name %s;\n\n" "${VHOST_SERVER_DOMAIN}" >> "${vhost_file_path}"

  # Logs
  printf "    access_log %s/%s.access.log;\n" "${NGINX_LOG_DIR}" "${VHOST_SERVER_DOMAIN}" >> "${vhost_file_path}"
  printf "    error_log %s/%s.error.log warn;\n\n" "${NGINX_LOG_DIR}" "${VHOST_SERVER_DOMAIN}" >> "${vhost_file_path}"

  # Configurações Gerais
  printf "    client_max_body_size 20m;\n\n" >> "${vhost_file_path}" # Exemplo, pode precisar ajustar

  # Bloco Location /
  printf "    location / {\n" >> "${vhost_file_path}"
  # Proxy Pass para o Upstream (sempre http:// aqui, Nginx resolve)
  printf "        proxy_pass http://%s;\n\n" "${UPSTREAM_NAME}" >> "${vhost_file_path}"

  # Cabeçalhos Essenciais do Proxy
  printf "        proxy_set_header Host \$host;\n" >> "${vhost_file_path}"
  printf "        proxy_set_header X-Real-IP \$remote_addr;\n" >> "${vhost_file_path}"
  printf "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n" >> "${vhost_file_path}"
  printf "        proxy_set_header X-Forwarded-Proto \$scheme;\n\n" >> "${vhost_file_path}"

  # Configurações HTTP para Keepalive com Upstream
  printf "        proxy_http_version 1.1;\n" >> "${vhost_file_path}"
  printf "        proxy_set_header Connection \"\"; # Limpa Connection header para keepalive\n\n" >> "${vhost_file_path}" # IMPORTANTE

  # Timeouts
  printf "        proxy_connect_timeout 60s;\n" >> "${vhost_file_path}"
  printf "        proxy_send_timeout    60s;\n" >> "${vhost_file_path}"
  printf "        proxy_read_timeout    60s;\n" >> "${vhost_file_path}"
  printf "        send_timeout          60s;\n" >> "${vhost_file_path}"

  # Inserção Condicional do Bloco SSL do Backend
  # Se PROXY_SSL_BACKEND_CONFIG_BLOCK não estiver vazio, adiciona-o
  if [[ -n "${PROXY_SSL_BACKEND_CONFIG_BLOCK}" ]]; then
      printf "%s\n" "${PROXY_SSL_BACKEND_CONFIG_BLOCK}" >> "${vhost_file_path}"
  fi
  printf "\n" >> "${vhost_file_path}" # Linha extra após bloco SSL ou timeouts

  # Cabeçalhos de Segurança Adicionais
  printf "        add_header X-Frame-Options SAMEORIGIN always;\n" >> "${vhost_file_path}"
  printf "        add_header X-Content-Type-Options nosniff always;\n" >> "${vhost_file_path}"
  # printf "        add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always; # Apenas se Nginx frontend usar HTTPS\n" >> "${vhost_file_path}"

  printf "    }\n\n" >> "${vhost_file_path}" # Fim location /

  # Bloco Location para arquivos ocultos
  printf "    location ~ /\\. {\n" >> "${vhost_file_path}"
  printf "        deny all;\n" >> "${vhost_file_path}"
  printf "    }\n" >> "${vhost_file_path}"

  printf "}\n" >> "${vhost_file_path}" # Fim server

  log "Arquivo ${vhost_file_path} criado no formato desejado."

  # --- Restante do script (ativação, teste, reload) ---

  info "Ativando o site (criando link simbólico)..."
  ln -sf "${vhost_file_path}" "${vhost_symlink_path}" || error_exit "Falha ao criar link simbólico em ${NGINX_SITES_ENABLED}."
  log "Site ${VHOST_SERVER_DOMAIN} ativado."

  info "Testando configuração do Nginx..."
  if nginx -t; then
    log "Configuração do Nginx OK."
    info "Recarregando configuração do Nginx..."
    # Usar 'systemctl reload nginx' é preferível
    if systemctl reload nginx; then
      log "Nginx recarregado com sucesso."
    else
      warn "Falha ao recarregar (reload), tentando reiniciar (restart)..."
      if systemctl restart nginx; then
          log "Nginx reiniciado com sucesso."
      else
          error_exit "Falha ao recarregar e reiniciar o Nginx (systemctl reload/restart nginx). Verifique os logs do Nginx."
      fi
    fi
  else
    error_exit "Teste de configuração do Nginx falhou. Verifique os erros acima e o arquivo ${vhost_file_path}."
  fi

  echo ""
  log "VirtualHost (Proxy Reverso com Upstream) para ${VHOST_SERVER_DOMAIN} configurado com sucesso!"
  info "Detalhes:"
  info "  - Nginx Escutando em: ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT}"
  info "  - Domínio Configurado: ${VHOST_SERVER_DOMAIN}"
  info "  - Upstream Name: ${UPSTREAM_NAME}"
  info "  - Alvo do Backend: ${BACKEND_PROTOCOL}://${VHOST_PROXY_TARGET}"
  info "  - Keepalive: ${KEEPALIVE_COUNT}"
  info "  - Arquivo Conf: ${vhost_file_path}"
  info "  - Link Ativo: ${vhost_symlink_path}"
  info "  - Logs: ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.*"
  echo ""

  # Reitera o aviso sobre a porta UDP se aplicável
  local target_port
  target_port=$(echo "${VHOST_PROXY_TARGET}" | cut -d: -f2)
  if [[ "$target_port" == "22003" || "$target_port" == "22005" || "$target_port" == "22126" ]]; then
      warn "${YELLOW}REFORÇANDO AVISO:${RESET} A porta ${target_port} no alvo do proxy (${VHOST_PROXY_TARGET}) é suspeita de ser UDP."
      warn "Este script configura um proxy ${YELLOW}HTTP/HTTPS${RESET}. Se o serviço não responder via HTTP/HTTPS nesta porta,"
      warn "o proxy ${RED}não funcionará${RESET}. Verifique a porta correta do serviço web."
      echo ""
  fi

  if [[ "$(echo "$VHOST_PROXY_SSL" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
    info "${YELLOW}AVISO DE SEGURANÇA:${RESET} A opção '--vhost-proxy-ssl=yes' foi usada."
    info "As diretivas 'proxy_ssl_verify off;' foram adicionadas para permitir conexão"
    info "com backend HTTPS que usa certificado auto-assinado/inválido."
    info "Para maior segurança, configure um certificado SSL válido no serviço de backend (${VHOST_PROXY_TARGET})."
    echo ""
  fi

  # Determina a URL de acesso ao Nginx
  local access_protocol="http"
  if [[ "${VHOST_SERVER_PORT}" == "443" ]]; then
    access_protocol="https"
    info "${YELLOW}AVISO:${RESET} O Nginx está escutando na porta 443, sugerindo HTTPS."
    info "Este script ${YELLOW}NÃO${RESET} configura certificados SSL para o ${VHOST_SERVER_DOMAIN} no Nginx."
    info "Você precisará configurar SSL manualmente (ex: com Certbot) para ${access_protocol}://${VHOST_SERVER_DOMAIN} funcionar."
  fi

  local access_url="${access_protocol}://${VHOST_SERVER_DOMAIN}"
  if [[ "${access_protocol}" == "http" && "${VHOST_SERVER_PORT}" != "80" ]] || \
     [[ "${access_protocol}" == "https" && "${VHOST_SERVER_PORT}" != "443" ]]; then
    access_url+=":${VHOST_SERVER_PORT}"
  fi
  info "${YELLOW}Acesse o serviço através do Nginx (após configurar DNS/hosts):${RESET} ${access_url}"

}

# === Execução ===
main "$@"

exit 0