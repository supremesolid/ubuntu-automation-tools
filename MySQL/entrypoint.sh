#!/bin/bash

set -e

echo "[INFO] Iniciando container..."

terminate() {
    echo "[INFO] Recebido sinal de parada. Finalizando MySQL..."
    mysqladmin shutdown || true
    exit 0
}

trap terminate SIGTERM SIGINT

if [ -n "$(ls -A /opt/mysql-default/etc 2>/dev/null)" ]; then
    echo "[INFO] /opt/mysql-default/etc possui arquivos, movendo para /etc/mysql e /var/lib/mysql..."
    mv /opt/mysql-default/etc/* /etc/mysql/
    mv /opt/mysql-default/lib/* /var/lib/mysql/
fi

chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /etc/mysql
chown -R mysql:mysql /var/log/mysql

mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld

echo "[INFO] Iniciando MySQL..."

while true; do
    if [ -f /tmp/disable-mysql ]; then
        echo "[INFO] Reinício do MySQL está desabilitado (/tmp/disable-mysql encontrado). Aguardando..."
        sleep 5
        continue
    fi

    mysqld --user=mysql &
    MYSQL_PID=$!

    echo "[INFO] MySQL iniciado com PID $MYSQL_PID"

    wait $MYSQL_PID
    MYSQL_EXIT_CODE=$?

    echo "[WARN] MySQL foi finalizado com código $MYSQL_EXIT_CODE"

    if [ -f /tmp/disable-mysql ]; then
        echo "[INFO] Reinício desativado. Aguardando reinício manual..."
        while [ -f /tmp/disable-mysql ]; do
            sleep 5
        done
        echo "[INFO] Arquivo de controle removido. Tentando reiniciar MySQL..."
    else
        echo "[ERROR] MySQL parou inesperadamente. Finalizando container."
        exit $MYSQL_EXIT_CODE
    fi
done
