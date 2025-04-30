#!/usr/bin/env bash

# === Configuração Estrita ===
# -e: Sai imediatamente se um comando falhar.
# -u: Trata variáveis não definidas como erro.
# -o pipefail: O status de saída de um pipeline é o do último comando que falhou.
set -euo pipefail

# === Funções ===

error_exit() {
  echo "ERRO: $1" >&2
  exit 1
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root. Use 'sudo $0 ...'"
  fi
}

check_root

echo "[1/4] Atualizando lista de pacotes..."
apt-get update || error_exit "Falha ao atualizar lista de pacotes (apt-get update)."

echo "[2/4] Instalando mysql-server..."

export DEBIAN_FRONTEND=noninteractive
apt-get install -y mysql-server || error_exit "Falha ao instalar mysql-server."
unset DEBIAN_FRONTEND

echo "[3/4] Reiniciando o serviço MySQL para aplicar as configurações..."

service mysql stop
usermod -d /var/lib/mysql/ mysql
service mysql start
service mysql status --no-pager 

# --- 3. Configuração do Plugin auth_socket e Usuário Root ---
echo "[4/4] Configurando autenticação auth_socket para root@localhost..."

echo "Tentando garantir que o plugin auth_socket esteja carregado..."

install_output=$(sudo mysql -e "INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';" 2>&1 || true)
install_exit_code=$? 

if [[ ${install_exit_code} -ne 0 ]]; then

    if echo "$install_output" | grep -q -E "Plugin 'auth_socket' already exists|ER_PLUGIN_ALREADY_INSTALLED|code: 1125"; then
        echo "INFO: Plugin auth_socket já está instalado/ativo (erro esperado ignorado)."

    elif echo "$install_output" | grep -q -E "Can't open shared library|não pode abrir"; then
         error_exit "Falha CRÍTICA ao instalar plugin auth_socket: Arquivo 'auth_socket.so' não encontrado ou inacessível. Verifique a instalação do MySQL. Saída: $install_output"

    elif echo "$install_output" | grep -q -E "Plugin 'auth_socket' is not loaded|code: 1688"; then
         echo "INFO: Plugin auth_socket parece ser built-in ou teve problema na inicialização (verificar logs se ALTER USER falhar). Saída: $install_output"
    else
        error_exit "Falha inesperada ao tentar instalar/carregar plugin auth_socket. Código: ${install_exit_code}. Saída: $install_output"
    fi
else
     echo "Plugin auth_socket instalado/carregado com sucesso."
fi

echo "Configurando 'root'@'localhost' para usar auth_socket..."

if ! mysql <<-EOF; then
    -- Altera o método de autenticação para root@localhost
    ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;

    -- Aplica as alterações de privilégio
    FLUSH PRIVILEGES;
EOF
  # Se este comando falhar, significa que, apesar das tentativas anteriores,
  # o plugin auth_socket não está disponível/ativo para o servidor MySQL.
  error_exit "Falha ao executar ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket. Isso geralmente significa que o plugin auth_socket não está ativo ou disponível no servidor. Verifique a instalação e os logs do MySQL (/var/log/mysql/error.log)."
fi

echo "Autenticação auth_socket configurada com sucesso para root@localhost."


echo "---"
echo "Configuração do MySQL concluída com sucesso!"
