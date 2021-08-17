#!/bin/sh
# Allows customization of openemr credentials, preventing the need for manual setup
#  (Note can force a manual setup by setting MANUAL_SETUP to 'yes')
#  - Required settings for auto installation are MYSQL_HOST and MYSQL_ROOT_PASS
#  -  (note that can force MYSQL_ROOT_PASS to be empty by passing as 'BLANK' variable)
#  - Optional settings for auto installation are:
#    - Setting db parameters MYSQL_USER, MYSQL_PASS, MYSQL_DATABASE
#    - Setting openemr parameters OE_USER, OE_PASS
set -e

. /usr/local/lib/openemr/tools/devtoolsLibrary.source

swarm_wait() {
    if [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-completed ]; then
        # true
        return 0
    else
        # false
        return 1
    fi
}

auto_setup() {
    prepareVariables

    if [ "$(whoami)" = "root" ]; then
        chmod -R 600 .
    fi

    php setup/auto_configure.php -f ${CONFIGURATION} || return 1

    echo "OpenEMR configured."
    CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
    if [ "$CONFIG" = "0" ]; then
        echo "Error in auto-config. Configuration failed."
        exit 2
    fi

    setGlobalSettings
}

if [ "$SWARM_MODE" = "yes" ]; then
    # Check if the shared volumes have been emptied out (persistent volumes in
    # kubernetes seems to do this). If they have been emptied, then restore them.
    if [ ! -f /etc/ssl/openssl.cnf ]; then
        # Restore the emptied /etc/ssl directory
        echo "Restoring empty /etc/ssl directory."
        rsync --owner --group --perms --recursive --links /swarm-pieces/ssl/* /etc/ssl
    fi
    if [ ! -d /var/www/localhost/htdocs/openemr/sites/default ]; then
        # Restore the emptied /var/www/localhost/htdocs/openemr/sites directory
        echo "Restoring empty /var/www/localhost/htdocs/openemr/sites directory."
        rsync --owner --group --perms --recursive --links /swarm-pieces/sites/* /var/www/localhost/htdocs/openemr/sites
    fi

    # Need to support replication for docker orchestration
    if [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-initiated ]; then
        # This docker instance will be the leader and perform configuration
        touch /var/www/localhost/htdocs/openemr/sites/default/docker-initiated
        touch /var/run/openemr/docker-leader
    fi

    if [ ! -f /var/run/openemr/docker-leader ] &&
       [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-completed ]; then
        while swarm_wait; do
            echo "Waiting for the docker-leader to finish configuration before proceeding."
            sleep 10;
        done
    fi
fi

if [ -f /var/run/openemr/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    # ensure a self-signed cert has been generated and is referenced
    if ! [ -f /etc/ssl/private/selfsigned.key.pem ]; then
        openssl req -x509 -newkey rsa:4096 \
        -keyout /etc/ssl/private/selfsigned.key.pem \
        -out /etc/ssl/certs/selfsigned.cert.pem \
        -days 365 -nodes \
        -subj "/C=xx/ST=x/L=x/O=x/OU=x/CN=localhost"
    fi
    if [ ! -f /etc/ssl/docker-selfsigned-configured ]; then
        rm -f /etc/ssl/certs/webserver.cert.pem
        rm -f /etc/ssl/private/webserver.key.pem
        ln -s /etc/ssl/certs/selfsigned.cert.pem /etc/ssl/certs/webserver.cert.pem
        ln -s /etc/ssl/private/selfsigned.key.pem /etc/ssl/private/webserver.key.pem
        touch /etc/ssl/docker-selfsigned-configured
    fi

    if [ "$DOMAIN" != "" ]; then
            if [ "$EMAIL" != "" ]; then
            EMAIL="-m $EMAIL"
        else
            echo "WARNING: SETTING AN EMAIL VIA \$EMAIL is HIGHLY RECOMMENDED IN ORDER TO"
            echo "         RECEIVE ALERTS FROM LETSENCRYPT ABOUT YOUR SSL CERTIFICATE."
        fi
        # if a domain has been set, set up LE and target those certs

        if ! [ -f /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem ]; then
            /usr/sbin/httpd -k start
            sleep 2
            certbot certonly --webroot -n -w /var/www/localhost/htdocs/openemr/ -d "$DOMAIN" "$EMAIL" --agree-tos
            /usr/sbin/httpd -k stop
            echo "1 23  *   *   *   certbot renew -q --post-hook \"httpd -k graceful\"" >> /etc/crontabs/root
        fi

        # run letsencrypt as a daemon and reference the correct cert
        if [ ! -f /etc/ssl/docker-letsencrypt-configured ]; then
            rm -f /etc/ssl/certs/webserver.cert.pem
            rm -f /etc/ssl/private/webserver.key.pem
            ln -s /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem /etc/ssl/certs/webserver.cert.pem
            ln -s /etc/letsencrypt/live/"$DOMAIN"/privkey.pem /etc/ssl/private/webserver.key.pem
            touch /etc/ssl/docker-letsencrypt-configured
        fi
    fi
fi

UPGRADE_YES=false;
if [ -f /var/run/openemr/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    # Figure out if need to do upgrade
    if [ -f /usr/local/share/openemr/tools/docker-version ]; then
        DOCKER_VERSION_ROOT=$(cat /usr/local/share/openemr/tools/docker-version)
    else
        DOCKER_VERSION_ROOT=0
    fi
    if [ -f /var/www/localhost/htdocs/openemr/docker-version ]; then
        DOCKER_VERSION_CODE=$(cat /var/www/localhost/htdocs/openemr/docker-version)
    else
        DOCKER_VERSION_CODE=0
    fi
    if [ -f /var/www/localhost/htdocs/openemr/sites/default/docker-version ]; then
        DOCKER_VERSION_SITES=$(cat /var/www/localhost/htdocs/openemr/sites/default/docker-version)
    else
        DOCKER_VERSION_SITES=0
    fi

    # Only perform upgrade if the sites dir is shared and not entire openemr directory
    if [ "$DOCKER_VERSION_ROOT" = "$DOCKER_VERSION_CODE" ] &&
       [ "$DOCKER_VERSION_ROOT" -gt "$DOCKER_VERSION_SITES" ]; then
        echo "Plan to try an upgrade from $DOCKER_VERSION_SITES to $DOCKER_VERSION_ROOT"
        UPGRADE_YES=true;
    fi
fi

CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
if [ -f /etc/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    if [ "$CONFIG" = "0" ] &&
       [ "$MYSQL_HOST" != "" ] &&
       [ "$MYSQL_ROOT_PASS" != "" ] &&
       [ "$MANUAL_SETUP" != "yes" ]; then

        echo "Running quick setup!"
        while ! auto_setup; do
            echo "Couldn't set up. Any of these reasons could be what's wrong:"
            echo " - You didn't spin up a MySQL container or connect your OpenEMR container to a mysql instance"
            echo " - MySQL is still starting up and wasn't ready for connection yet"
            echo " - The Mysql credentials were incorrect"
            sleep 1;
        done
        echo "Setup Complete!"
    fi
fi

if [ "$CONFIG" = "1" ] &&
   [ "$MANUAL_SETUP" != "yes" ]; then
    # OpenEMR has been configured

    if $UPGRADE_YES; then
        # Need to do the upgrade
        echo "Attempting upgrade"
        c=$DOCKER_VERSION_SITES
        while [ "$c" -le "$DOCKER_VERSION_ROOT" ]; do
            if [ "$c" -gt "$DOCKER_VERSION_SITES" ] ; then
                echo "Start: Processing fsupgrade-$c.sh upgrade script"
                sh /usr/local/lib/openemr/fsupgrade-$c.sh
                echo "Completed: Processing fsupgrade-$c.sh upgrade script"
            fi
            c=$(( c + 1 ))
        done
        echo -n $DOCKER_VERSION_ROOT > /var/www/localhost/htdocs/openemr/sites/default/docker-version
        echo "Completed upgrade"
    fi

    if [ -f auto_configure.php ]; then
        if [ "$(whoami)" = "root" ]; then
            echo "Setting user 'www' as owner of openemr/ and setting file/dir permissions to 400/500"
            #set all directories to 500
            find . -type d -print0 | xargs -0 chmod 500
            #set all file access to 400
            find . -type f -print0 | xargs -0 chmod 400

            echo "Default file permissions and ownership set, allowing writing to specific directories"
            chmod 700 run_openemr.sh
            # Set file and directory permissions
            find sites/default/documents -type d -print0 | xargs -0 chmod 700
            find sites/default/documents -type f -print0 | xargs -0 chmod 700
        fi

        echo "Removing remaining setup scripts"
        #remove all setup scripts
        rm -f setup/*.php
        echo "Setup scripts removed, we should be ready to go now!"
    fi
fi

# ensure the auto_configure.php script has been removed
rm -f setup/auto_configure.php

if [ -f /var/run/openemr/docker-leader ] &&
   [ "$SWARM_MODE" = "yes" ]; then
    # Set flag that the docker-leader configuration is complete
    touch /var/www/localhost/htdocs/openemr/sites/default/docker-completed
fi
