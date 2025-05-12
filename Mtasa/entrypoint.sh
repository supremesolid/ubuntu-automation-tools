#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Erro: Caminho do executável não fornecido."
    echo "Uso: $0 /caminho/para/mta-server64"
    exit 1
fi

EXECUTAVEL="$1"
LIBZSTD="/usr/lib/x86_64-linux-gnu/libzstd.so.1"
CMD="LD_PRELOAD=$LIBZSTD $EXECUTAVEL -n --child-process"

if [ "$(id -u)" -eq 0 ]; then
    exec su -s /bin/bash mtasa -c "$CMD"
else
    exec bash -c "$CMD"
fi
