#!/bin/bash

set -euo pipefail

apt-get install -y apache2 libapache2-mpm-itk

systemctl restart stop

conf_mpm_itk="/etc/apache2/mods-available/mpm_itk.conf"
conf_ports="/etc/apache2/ports.conf"
conf_vhost_default="/etc/apache2/sites-available/000-default.conf"

a2dismod mpm_itk

echo '<IfModule mpm_itk.c>' > "$conf_mpm_itk"
echo '    LimitUIDRange 0 4294496296' >> "$conf_mpm_itk"
echo '    LimitGIDRange 0 4294496296' >> "$conf_mpm_itk"
echo '</IfModule>' >> "$conf_mpm_itk"

echo 'Listen 127.0.0.1:8080' > "$conf_ports"

echo '<VirtualHost *:8080>' > "$conf_vhost_default"
echo '	ServerAdmin webmaster@localhost' >> "$conf_vhost_default"
echo '	DocumentRoot /var/www/html' >> "$conf_vhost_default"
echo '	ErrorLog ${APACHE_LOG_DIR}/error.log' >> "$conf_vhost_default"
echo '	CustomLog ${APACHE_LOG_DIR}/access.log combined' >> "$conf_vhost_default"
echo '</VirtualHost>' >> "$conf_vhost_default"

a2enmod mpm_itk headers

systemctl restart apache2