#!/bin/bash
set -euo pipefail

# Cores para mensagens
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"

# Funções de log melhoradas
log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

info() {
  echo -e "${BLUE}[NOTE]${NC} $1"
}

# Função para executar comandos silenciosamente
run_quiet() {
  local cmd="$@"
  $cmd > /dev/null 2>&1
  return $?
}

# Configuração inicial
clear
export DEBIAN_FRONTEND=noninteractive

# 1. Pré-verificações
if [ "$EUID" -ne 0 ]; then
    error "Execute como root: sudo $0"
fi

if command -v webmin &> /dev/null || dpkg -l | grep -q webmin; then
    info "Webmin já está instalado: $(dpkg -l webmin | grep ^ii | awk '{print $3}')"
    exit 0
fi

# 2. Instalação
log "Atualizando pacotes..."
run_quiet apt-get update || error "Falha ao atualizar repositórios"

log "Instalando dependências..."
run_quiet apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    lsb-release || error "Falha ao instalar dependências"

log "Configurando repositório Webmin..."
if ! run_quiet bash <(curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh); then
    error "Falha ao configurar repositório Webmin"
fi

log "Instalando Webmin..."
run_quiet apt-get update || warn "Falha ao atualizar após adição do repositório"
run_quiet apt-get install -y webmin --install-recommends || error "Falha na instalação do Webmin"

# 3. Pós-instalação
WEBMIN_PORT=$(grep ^port= /etc/webmin/miniserv.conf | cut -d= -f2)
WEBMIN_IP=$(hostname -I | awk '{print $1}')

log "Webmin instalado com sucesso!"
info "Acesse: https://${WEBMIN_IP}:${WEBMIN_PORT}"
info "Credenciais: seu usuário/senha do sistema Linux"
info "Para configurar firewall:"
echo -e "  sudo ufw allow ${WEBMIN_PORT}/tcp"
echo -e "  sudo ufw reload"