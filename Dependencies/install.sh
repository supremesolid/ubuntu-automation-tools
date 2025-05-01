#!/usr/bin/env bash

set -euo pipefail

# Upgrade
apt update
apt upgrade -y

# Dependencies
apt install -y software-properties-common
apt install -y iptables-persistent


# Basic
sudo apt install -y language-pack-gnome-pt language-pack-gnome-pt-base \
    language-pack-pt language-pack-pt-base \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libbz2-dev \
    libsqlite3-dev \
    libffi-dev \
    liblzma-dev \
    uuid-dev \
    libxml2-dev \
    libxmlsec1-dev \
    build-essential \
    curl \
    wget \
    git \
    vim \
    nano \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    net-tools zip tar cgroup-tools dnsutils

# Language Config
dpkg-reconfigure tzdata