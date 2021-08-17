#!/bin/sh
# to be run with OpenEMR root dir as the CWD

export MYSQL_ROOT_PASS
export MYSQL_USER
export MYSQL_PASS
export OE_USER
export OE_PASS

MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-$(cat "${MYSQL_ROOT_PASSWORD_FILE:-/var/run/secrets/mariadb/mariadb-root-password}")}"
MYSQL_USER="${MYSQL_USER:-$(cat "${MYSQL_USER_FILE:-/var/run/secrets/mariadb/mariadb-username}")}"
MYSQL_PASS="${MYSQL_PASS:-$(cat "${MYSQL_PASS_FILE:-/var/run/secrets/mariadb/mariadb-password}")}"
OE_USER="${OE_USER:-$(cat "${OE_USER_FILE:-/var/run/secrets/openemr/admin-username}")}"
OE_PASS="${OU_PASS:-$(cat "${OE_PASS_FILE:-/var/run/secrets/openemr/admin-password}")}"

j2tmpl /etc/apache2/conf.d/openemr.conf -o /etc/apache2/conf.d/openemr.conf

sh autoconfig.sh

echo ""
echo "Love OpenEMR? You can now support the project via the open collective:"
echo " > https://opencollective.com/openemr/donate"
echo ""

if [ "$(whoami)" = "root" ] && [ ! "${OE_DISABLE_CRON}" = "true" ]; then
    echo "Starting cron daemon!"
    crond
else
    echo "Warning: Cron is not being started because it was either explicitly disabled or you are not root."
    echo "         You will have to start your own cron container if you need scheduled jobs."
fi

echo "Starting apache!"
/usr/sbin/httpd -D FOREGROUND
