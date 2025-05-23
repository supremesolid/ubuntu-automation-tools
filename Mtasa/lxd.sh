#!/usr/bin/env bash

set -euo pipefail

FILE="mtasa.lxc.tar.gz"
URL="https://media.githubusercontent.com/media/supremesolid/ubuntu-automation-tools/refs/heads/master/LXD/mtasa.lxc.tar.gz"

echo "Baixando imagem..."
wget -O "$FILE" "$URL"

echo "Adicionando diretórios montados..."
mkdir -p /docker/mtasa /home/mtasa

echo "Importando backup do container..."
lxc import "$FILE"

echo "Removendo arquivo temporário..."
rm -f "$FILE"

echo "Iniciando container..."
lxc start mtasa

echo "Container 'mtasa' restaurado e iniciado com sucesso."
