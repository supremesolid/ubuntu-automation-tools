#!/bin/bash

set -e

NAME="$1"

if [ -z "$1" ]; then
    echo "Erro: O nome não fornecido."
    echo "Uso: $0 nome"
    exit 1
fi

cd /home/mtasa/

wget https://linux.multitheftauto.com/dl/multitheftauto_linux_x64.tar.gz

tar xfs multitheftauto_linux_x64.tar.gz

rm -rf multitheftauto_linux_x64.tar.gz

mv multitheftauto_linux_x64 $NAME

cd $NAME/mods/deathmatch/

wget https://linux.multitheftauto.com/dl/baseconfig.tar.gz

tar xfs baseconfig.tar.gz

cd baseconfig

mv * ../

cd ../

rm -rf baseconfig.tar.gz baseconfig

mkdir resources

cd resources

wget https://mirror-cdn.multitheftauto.com/mtasa/resources/mtasa-resources-latest.zip

unzip mtasa-resources-latest.zip

rm -rf mtasa-resources-latest.zip

cd /home/mtasa

chown -R mtasa:mtasa $NAME

cd /entrypoints/mtasa

mkdir $NAME

cd $NAME

wget https://supremesolid.github.io/ubuntu-automation-tools/Mtasa/entrypoint.sh

chown mtasa:mtasa entrypoint.sh

docker run -i -d \
  --name "$NAME" \
  --network host \
  --workdir "/home/mtasa/$NAME" \
  --user mtasa \
  --entrypoint "/entrypoints/mtasa/$NAME/entrypoint.sh" \
  -v "/home/mtasa/$NAME:/home/mtasa/$NAME" \
  -v "/entrypoints/mtasa/$NAME:/entrypoints/mtasa/$NAME" \
  supremesolid/mtasa:lts \
  "/home/mtasa/$NAME/mta-server64"
