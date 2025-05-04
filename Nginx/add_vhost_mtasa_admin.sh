#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Constantes ===
readonly NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly NGINX_LOG_DIR="/var/log/nginx"

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
  echo "Cria um VirtualHost Nginx com proxy reverso para um serviço web (ex: painel MTASA, API, etc.)."
  echo ""
  echo -e "${BLUE}Opções:${RESET}"
  echo "  --vhost-server-ip=<IP>         Endereço IP para o Nginx escutar (ex: 0.0.0.0)."
  echo "  --vhost-server-port=<PORTA>    Porta para o Nginx escutar (ex: 443, 80)."
  echo "  --vhost-server-domain=<DOMAIN> Nome do domínio ou subdomínio (ex: status.meudominio.com)."
  echo "  --vhost-proxy-target=<TARGET>  Alvo do proxy (IP:PORTA ou HOST:PORTA do serviço web)."
  echo "                                 ${YELLOW}ATENÇÃO:${RESET} Use a porta do serviço ${YELLOW}HTTP/HTTPS${RESET}, não a porta UDP do jogo/query!"
  echo "  --vhost-proxy-ssl=<yes|no>     O serviço alvo (backend) usa HTTPS? (Padrão: no)."
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
  local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
  if ! [[ "${domain}" =~ ${domain_regex} ]]; then
    error_exit "Formato de domínio inválido: ${domain}"
  fi
}

# Valida formato do alvo do proxy (básico)
validate_proxy_target() {
  local target="${1}"
  if [[ -z "$target" ]]; then
    error_exit "Alvo do proxy (--vhost-proxy-target) não pode ser vazio."
  fi
  # Validação simples, Nginx fará a validação final.
  # Ex: verifica se contém ':' para host:port ou IP:port
  if ! [[ "$target" =~ : || "$target" =~ ^unix: ]]; then
     error_exit "Formato do alvo do proxy '--vhost-proxy-target=${target}' inválido. Deve ser no formato IP:PORTA ou HOST:PORTA."
  fi
  # Aviso específico sobre portas comuns de MTASA UDP
  if [[ "$target" =~ :(22003|22005|22126)$ ]]; then
      warn "A porta no alvo do proxy (${target}) parece ser uma porta padrão UDP do MTASA (jogo, query, http server list)."
      warn "Este script configura um proxy HTTP/HTTPS. Certifique-se de que '${target}' é realmente um serviço web (HTTP/HTTPS)."
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
VHOST_PROXY_SSL="no" # Valor padrão alterado para 'no'

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
validate_proxy_ssl "${VHOST_PROXY_SSL}" # Valida a opção
validate_proxy_target "${VHOST_PROXY_TARGET}" # Validar por último para incluir o aviso de porta se necessário

log "Parâmetros validados com sucesso."

# Determina o protocolo para o proxy_pass e configura opções SSL do backend
PROXY_PROTOCOL="http"
PROXY_SSL_BACKEND_CONFIG="" # Bloco de configuração SSL para o backend
if [[ "$(echo "$VHOST_PROXY_SSL" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
  PROXY_PROTOCOL="https"
  PROXY_SSL_BACKEND_CONFIG=$(
    cat <<EOF

        # --- Tratamento de SSL para o Backend (quando --vhost-proxy-ssl=yes) ---
        # ATENÇÃO: 'proxy_ssl_verify off' DESABILITA a validação do certificado do backend.
        # Necessário se o backend usa certificado auto-assinado. É MENOS SEGURO.
        # Se possível, use um certificado válido no backend ou importe o CA via 'proxy_ssl_trusted_certificate'.
        proxy_ssl_verify off;
        # Passa o nome do servidor para o backend (importante para SNI se o backend suportar)
        proxy_ssl_server_name on;
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
    # Opcional: Fazer backup antes de sobrescrever
    # cp "${vhost_file_path}" "${vhost_file_path}.bak_$(date +%F_%T)" || warn "Falha ao criar backup."
  fi

  log "Criando arquivo de configuração Nginx para ${VHOST_SERVER_DOMAIN} (Proxy Reverso)..."

  # Cria o diretório de logs Nginx se não existir
  mkdir -p "${NGINX_LOG_DIR}" || error_exit "Falha ao criar diretório de logs: ${NGINX_LOG_DIR}"

  # Heredoc para criar o arquivo de configuração
  # Usamos printf para inserir o bloco de configuração SSL do backend condicionalmente
  printf "# Configuração de Proxy Reverso para ${VHOST_SERVER_DOMAIN}\n" > "${vhost_file_path}" || error_exit "Falha ao escrever no arquivo de configuração ${vhost_file_path}"
  printf "# Gerado por script em %s\n" "$(date)" >> "${vhost_file_path}"
  printf "# Alvo do Proxy: %s://%s\n\n" "${PROXY_PROTOCOL}" "${VHOST_PROXY_TARGET}" >> "${vhost_file_path}"

  cat >>"${vhost_file_path}" <<EOF || error_exit "Falha ao escrever no arquivo de configuração ${vhost_file_path}"
server {
    listen ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT};
    server_name ${VHOST_SERVER_DOMAIN};

    # Logs específicos
    access_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.access.log;
    error_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.error.log warn;

    # Aumentar o tamanho máximo do corpo da solicitação (ajuste conforme necessário)
    client_max_body_size 20m;

    # --- Bloco Principal do Proxy Reverso ---
    location / {
        proxy_pass ${PROXY_PROTOCOL}://${VHOST_PROXY_TARGET};

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme; # Informa ao backend se a conexão original foi HTTP ou HTTPS

        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
        send_timeout          60s;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
%s # Inserção condicional da configuração SSL do backend

        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-Content-Type-Options nosniff always;
        # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always; 
    }

    location ~ /\. {
        deny all;
    }
}
EOF

  # Substitui o placeholder %s pelo conteúdo de PROXY_SSL_BACKEND_CONFIG
  # Nota: Usar printf ou sed para inserção segura é melhor que expansão direta no heredoc
  local temp_file="${vhost_file_path}.tmp"
  printf "$(cat "${vhost_file_path}")" "${PROXY_SSL_BACKEND_CONFIG}" > "${temp_file}" && mv "${temp_file}" "${vhost_file_path}" \
    || error_exit "Falha ao finalizar arquivo de configuração com detalhes SSL."


  log "Arquivo ${vhost_file_path} criado."

  info "Ativando o site (criando link simbólico)..."
  # Criar link simbólico -f força a substituição se já existir
  ln -sf "${vhost_file_path}" "${vhost_symlink_path}" || error_exit "Falha ao criar link simbólico em ${NGINX_SITES_ENABLED}."
  log "Site ${VHOST_SERVER_DOMAIN} ativado."

  info "Testando configuração do Nginx..."
  if nginx -t; then
    log "Configuração do Nginx OK."
    info "Recarregando configuração do Nginx..."
    if systemctl reload nginx; then
      log "Nginx recarregado com sucesso."
    else
      # Tentar restart como fallback, pode ser necessário em algumas situações
      warn "Falha ao recarregar (reload), tentando reiniciar (restart)..."
      if systemctl restart nginx; then
          log "Nginx reiniciado com sucesso."
      else
          error_exit "Falha ao recarregar e reiniciar o Nginx (systemctl reload/restart nginx)."
      fi
    fi
  else
    error_exit "Teste de configuração do Nginx falhou. Verifique os erros acima e o arquivo ${vhost_file_path}."
  fi

  echo ""
  log "VirtualHost (Proxy Reverso) para ${VHOST_SERVER_DOMAIN} configurado com sucesso!"
  info "Detalhes:"
  info "  - Nginx Escutando em: ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT}"
  info "  - Domínio Configurado: ${VHOST_SERVER_DOMAIN}"
  info "  - Alvo do Proxy (Backend): ${PROXY_PROTOCOL}://${VHOST_PROXY_TARGET}"
  info "  - Arquivo Conf: ${vhost_file_path}"
  info "  - Link Ativo: ${vhost_symlink_path}"
  info "  - Logs: ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.*"
  echo ""

  # Aviso sobre porta do backend se for uma porta suspeita de ser UDP
  if [[ "${VHOST_PROXY_TARGET}" =~ :(22003|22005|22126)$ ]]; then
      warn "REFORÇANDO AVISO: O alvo do proxy (${VHOST_PROXY_TARGET}) usa uma porta frequentemente associada a protocolos UDP no MTASA."
      warn "Este script configura um proxy ${YELLOW}HTTP/HTTPS${RESET}. Se '${VHOST_PROXY_TARGET}' não for um serviço web respondendo em HTTP/HTTPS,"
      warn "o proxy ${RED}não funcionará${RESET}. Para proxy UDP, use o módulo 'stream' do Nginx (configuração diferente)."
      echo ""
  fi

  if [[ "$(echo "$VHOST_PROXY_SSL" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
    info "${YELLOW}AVISO DE SEGURANÇA:${RESET} A opção 'proxy_ssl_verify off' foi usada (porque --vhost-proxy-ssl=yes)."
    info "Isso permite a conexão Nginx -> Backend via HTTPS mesmo se o backend usar um certificado inválido/auto-assinado."
    info "Considere usar um certificado válido no serviço de backend (${VHOST_PROXY_TARGET}) para maior segurança."
    echo ""
  fi

  # Determina a URL de acesso ao Nginx
  local access_protocol="http"
  if [[ "${VHOST_SERVER_PORT}" == "443" ]]; then
    access_protocol="https"
    info "${YELLOW}AVISO:${RESET} A porta ${VHOST_SERVER_PORT} foi usada para o Nginx escutar, sugerindo HTTPS."
    info "No entanto, este script ${YELLOW}NÃO${RESET} configura certificados SSL para o Nginx (${VHOST_SERVER_DOMAIN})."
    info "Você precisará configurar manualmente (ex: com Certbot/Let's Encrypt) o SSL neste VHost Nginx para que ${access_protocol}://${VHOST_SERVER_DOMAIN} funcione corretamente."
  fi

  local access_url="${access_protocol}://${VHOST_SERVER_DOMAIN}"
  # Adicionar porta à URL se não for padrão (80 para http, 443 para https)
  if [[ "${access_protocol}" == "http" && "${VHOST_SERVER_PORT}" != "80" ]] || \
     [[ "${access_protocol}" == "https" && "${VHOST_SERVER_PORT}" != "443" ]]; then
    access_url+=":${VHOST_SERVER_PORT}"
  fi
  info "${YELLOW}Acesse o serviço através do Nginx (após configurar DNS/hosts se necessário):${RESET} ${access_url}"

}

# === Execução ===
main "$@"

exit 0