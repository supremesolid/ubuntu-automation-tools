#!/usr/bin/env bash

set -euo pipefail

FILE="mtasa.lxc.tar.gz"

URL="https://github.com/supremesolid/ubuntu-automation-tools/raw/refs/heads/master/LXD/mtasa.lxc.tar.gz?download="

echo "Baixando imagem..."

wget -O "$FILE" "$URL"

echo "Importando imagem para o LXD..."
lxc image import "$FILE" --alias mtasa

echo "Criando container 'mtasa' sem iniciar..."
lxc init mtasa mtasa

echo "Removendo arquivo temporário..."
rm -f "$FILE"

echo "Container 'mtasa' criado. Use 'lxc start mtasa' para iniciar."

lxc config device override mtasa eth0 ipv4.address=10.0.0.2
lxc start mtasa