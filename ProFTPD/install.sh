#!/usr/bin/env bash

set -euo pipefail

apt update

apt install -y proftpd proftpd-mod-mysql proftpd-mod-crypto proftpd-mod-ldap