#!/usr/bin/env bash

set -euo pipefail

snap install lxd

cat <<EOF | lxd init --preseed
config:
  core.https_address: 192.168.0.230:9999
  images.auto_update_interval: 15
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv6.address: none
EOF

lxc network set lxdbr0 ipv4.address 10.0.0.1/24
lxc storage create storage dir
lxc profile set default security.privileged true
lxc profile set default security.nesting true
lxc profile device add default eth0 nic name=eth0 network=lxdbr0 type=nic
lxc profile device add default root disk path=/ pool=storage