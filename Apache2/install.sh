#!/bin/bash

set -euo pipefail

apt-get install -y apache2 libapache2-mpm-itk

mpm_itk="/etc/apache2/mods-available/mpm_itk.conf"

echo '<IfModule mpm_itk.c>' > "$mpm_itk"
echo '    LimitUIDRange 0 4294496296' >> "$mpm_itk"
echo '    LimitGIDRange 0 4294496296' >> "$mpm_itk"
echo '</IfModule>' >> "$mpm_itk"

a2dismod mpm_itk
a2enmod mpm_itk headers

ports="/etc/apache2/ports.conf"

echo 'Listen 127.0.0.1:80' > "$ports"
echo '' >> "$ports"
echo '<IfModule ssl_module>' >> "$ports"
echo '	Listen 127.0.0.1:443' >> "$ports"
echo '</IfModule>' >> "$ports"
echo '' >> "$ports"
echo '<IfModule mod_gnutls.c>' >> "$ports"
echo '	Listen 127.0.0.1:443' >> "$ports"
echo '</IfModule>' >> "$ports"

systemctl restart apache2