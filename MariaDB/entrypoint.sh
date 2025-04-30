#!/bin/bash

# ==============================================================================
# Docker Entrypoint Script for MariaDB Server
# - Handles initial setup (moving defaults, setting permissions).
# - Starts the MariaDB daemon using exec.
# ==============================================================================

# Exit on error, treat unset variables as error, exit on pipefail
set -euo pipefail

# --- Initial Setup ---

# Check if a directory with default/initial data exists and move it
# The actual source path depends on how the Docker image is built.
DEFAULT_DATA_SOURCE_ETC="/opt/mariadb-defaults/etc"
DEFAULT_DATA_SOURCE_LIB="/opt/mariadb-defaults/lib"
FIRST_RUN_DETECTED=false

if [ -d "${DEFAULT_DATA_SOURCE_ETC}" ] && [ -n "$(ls -A ${DEFAULT_DATA_SOURCE_ETC} 2>/dev/null)" ]; then
    echo "[INFO] ${DEFAULT_DATA_SOURCE_ETC} possui arquivos, movendo para /etc/mysql..."
    # Ensure target exists
    mkdir -p /etc/mysql
    # Move contents, overwrite if necessary (adjust cp/mv flags as needed)
    # Using cp and rm might be safer than mv if target dir exists with content
    cp -a "${DEFAULT_DATA_SOURCE_ETC}"/* /etc/mysql/
    rm -rf "${DEFAULT_DATA_SOURCE_ETC}"/* # Clean up source after copy
    FIRST_RUN_DETECTED=true
elif [ -d "${DEFAULT_DATA_SOURCE_ETC}" ]; then
     # If the directory exists but is empty, remove it to avoid confusion
     rm -rf "${DEFAULT_DATA_SOURCE_ETC}"
fi

if [ -d "${DEFAULT_DATA_SOURCE_LIB}" ] && [ -n "$(ls -A ${DEFAULT_DATA_SOURCE_LIB} 2>/dev/null)" ]; then
    echo "[INFO] ${DEFAULT_DATA_SOURCE_LIB} possui arquivos, movendo para /var/lib/mysql..."
    # Ensure target exists
    mkdir -p /var/lib/mysql
    # Move contents
    cp -a "${DEFAULT_DATA_SOURCE_LIB}"/* /var/lib/mysql/
    rm -rf "${DEFAULT_DATA_SOURCE_LIB}"/* # Clean up source
    # Ensure the main data dir exists even if source was empty
    FIRST_RUN_DETECTED=true # Consider this part of first run too
elif [ -d "${DEFAULT_DATA_SOURCE_LIB}" ]; then
    rm -rf "${DEFAULT_DATA_SOURCE_LIB}"
fi

# Always ensure the main directories exist, even if not first run
mkdir -p /var/lib/mysql /etc/mysql /var/log/mysql /run/mysqld

# Set ownership. Crucial for MariaDB to be able to write data/logs/pid.
# These paths are typically standard for MariaDB packages on Debian/Ubuntu.
echo "[INFO] Definindo permissões para diretórios MariaDB..."
chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /etc/mysql # Config files might need read by mysql user
chown -R mysql:mysql /var/log/mysql
chown -R mysql:mysql /run/mysqld

# If it looks like the first run (data moved) and the data dir is empty,
# MariaDB might need to initialize the database structure.
# Starting the server usually handles this automatically if datadir is empty or missing key files.
# No explicit 'mariadb-install-db' is typically needed here when starting the daemon.

# --- Start MariaDB ---

# Use 'exec' to replace the script process with the MariaDB daemon process.
# This allows Docker to directly manage the daemon and receive signals correctly.
# Pass any command-line arguments passed to the entrypoint script ("$@") to the daemon.
# Common daemon name in MariaDB packages is still often 'mysqld' for compatibility.
# If 'mariadbd' is the primary executable in your image, change 'mysqld' below.
echo "[INFO] Iniciando MariaDB Server via exec..."
exec mysqld --user=mysql "$@"

# The script will not reach here if exec is successful.