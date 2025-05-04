#!/usr/bin/env bash

set -euo pipefail

FILE="mtasa.lxc.tar.gz"
URL="https://github.com/supremesolid/ubuntu-automation-tools/raw/master/LXD/mtasa.lxc.tar.gz"

echo "Baixando imagem..."
wget -O "$FILE" "$URL"

echo "Importando backup do container..."
lxc import "$FILE"

echo "Adicionando diretórios montados..."
mkdir -p /docker/mtasa /home/mtasa

echo "Removendo arquivo temporário..."
rm -f "$FILE"

echo "Configurando IP fixo (opcional)..."
lxc config device override mtasa eth0 ipv4.address=10.0.0.2

echo "Iniciando container..."
lxc start mtasa

echo "Container 'mtasa' restaurado e iniciado com sucesso."
