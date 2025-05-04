#!/usr/bin/env bash

set -euo pipefail

FILE="mtasa.lxc.tar.gz"

URL="https://github.com/supremesolid/ubuntu-automation-tools/raw/master/LXD/mtasa.lxc.tar.gz"

echo "Baixando imagem..."

wget -O "$FILE" "$URL"

echo "Importando imagem para o LXD..."
lxc image import "$FILE" --alias mtasa

echo "Criando container 'mtasa' sem iniciar..."

mkdir -p /docker/mtasa

lxc config device add mtasa folder_docker disk source=/docker/mtasa path=/docker/mtasa
lxc config device add mtasa folder_home disk source=/home/mtasa path=/home/mtasa

lxc init mtasa mtasa

echo "Removendo arquivo temporário..."
rm -f "$FILE"

echo "Container 'mtasa' criado. Use 'lxc start mtasa' para iniciar."

lxc config device override mtasa eth0 ipv4.address=10.0.0.2
lxc start mtasa