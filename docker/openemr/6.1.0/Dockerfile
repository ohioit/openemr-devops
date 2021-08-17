FROM alpine:3.13

#Install dependencies and fix issue in apache
RUN apk --no-cache upgrade
RUN apk add --no-cache \
    apache2 apache2-ssl git php8 php8-tokenizer php8-ctype php8-session php8-apache2 \
    php8-json php8-pdo php8-pdo_mysql php8-curl php8-ldap php8-openssl php8-iconv \
    php8-xml php8-xsl php8-gd php8-zip php8-soap php8-mbstring php8-zlib \
    php8-mysqli php8-sockets php8-xmlreader php8-redis php8-simplexml php8-xmlwriter php8-phar php8-fileinfo \
    php8-sodium php8-calendar php8-intl \
    perl mysql-client tar curl imagemagick npm \
    python2 python3 openssl py-pip openssl-dev dcron \
    rsync shadow ncurses \
    && sed -i '|^Listen 80$|d' /etc/apache2/httpd.conf \
    && rm /etc/apache2/conf.d/ssl.conf

ARG J2TMPL_VERSION=0.0.13
ARG J2TMPL_HASH="5bbca0488eb0e892868ae2a7fd975c65cfb03fe8d1199dfa8717d16326b6aee0"
RUN curl -L -o /usr/local/bin/j2tmpl "https://github.com/ikogan/j2tmpl/releases/download/v${J2TMPL_VERSION}/j2tmpl" && \
    test "$(sha256sum /usr/local/bin/j2tmpl | awk '{ print $1 }')" = "${J2TMPL_HASH}" && \
    chmod +x /usr/local/bin/j2tmpl

    # Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
RUN usermod -u 1000 apache

#BELOW LINE NEEDED TO SUPPORT PHP8 ON ALPINE 3.13; SHOULD BE ABLE TO REMOVE THIS IN FUTURE ALPINE VERSIONS
RUN cp /usr/bin/php8 /usr/bin/php
# Install composer for openemr package building
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

# Below line is needed to avoid breaking the raspberry pi builds
# TODO - intermittently remove this line to see if the error (failed to fetch
#        https://github.com/rust-lang/crates.io-index... ) has gone away.
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

ARG OPENEMR_INSTALL_PATH=/var/www/localhost/htdocs/openemr
ARG OPENEMR_SHARE_PATH=/usr/local/share/openemr
ARG OPENEMR_TOOLS_PATH=${OPENEMR_SHARE_PATH}/tools
ARG OPENEMR_TOOL_LIB_PATH=/usr/local/lib/openemr

RUN apk add --no-cache git build-base libffi-dev python3-dev cargo \
    && git clone https://github.com/openemr/openemr.git --depth 1 \
    && rm -rf openemr/.git \
    && cd openemr \
    && composer install --no-dev \
    && npm install --unsafe-perm \
    && npm run build \
    && cd ccdaservice \
    && npm install --unsafe-perm \
    && cd ../ \
    && composer global require phing/phing \
    && /root/.composer/vendor/bin/phing vendor-clean \
    && /root/.composer/vendor/bin/phing assets-clean \
    && composer global remove phing/phing \
    && composer dump-autoload -o \
    && composer clearcache \
    && npm cache clear --force \
    && rm -fr node_modules \
    && cd ../ \
    && chmod 666 openemr/sites/default/sqlconf.php \
    && chown -R apache openemr/ \
    && mv openemr $(dirname ${OPENEMR_INSTALL_PATH}) \
    && git clone https://github.com/letsencrypt/letsencrypt --depth 1 /opt/certbot \
    && pip install --upgrade pip \
    && pip install -e /opt/certbot/acme -e /opt/certbot/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    && apk del --no-cache git build-base libffi-dev python3-dev cargo
WORKDIR ${OPENEMR_INSTALL_PATH}
VOLUME [ "/etc/letsencrypt/", "/etc/ssl", "${OPENEMR_INSTALL_PATH}/sites" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php8/php.ini
COPY openemr.conf.jinja /etc/apache2/conf.d/openemr.conf
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY run_openemr.sh autoconfig.sh ${OPENEMR_INSTALL_PATH}
COPY auto_configure.php ${OPENEMR_INSTALL_PATH}/setup/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh ${OPENEMR_TOOLS_PATH}/
#bring in pieces used for automatic upgrade process
COPY upgrade/docker-version \
    upgrade/fsupgrade-1.sh \
    upgrade/fsupgrade-2.sh \
    ${OPENEMR_TOOLS_PATH}/
#Copy dev tools library to root
COPY utilities/devtoolsLibrary.source ${OPENEMR_TOOLS_LIB_PATH}/

RUN chmod 500 ${OPENEMR_INSTALL_PATH}/run_openemr.sh ${OPENEMR_INSTALL_PATH}/autoconfig.sh \
    && chown apache:root /etc/apache2/conf.d/openemr.conf ${OPENEMR_INSTALL_PATH}/setup/* \
    && mkdir ${OPENEMR_INSTALL_PATH}/setup \
    && for FILE in \
        admin.php \
        acl_upgrade.php \
        setup.php \
        sql_patch.php \
        ippf_upgrade.php; \
        do \
       mv ${FILE} ${OPENEMR_INSTALL_PATH}/setup; \
    done \
    && chown -R apache:root setup \
    && chmod -R u+rwX,g-rwx,o-rwx setup \
    && chmod -R u+rwX,g-rwx,o-rwx setup \
    && sed -i 's|dirname(__FILE__)|dirname(__DIR__, 1)|g' ${OPENEMR_INSTALL_PATH}/setup/*.php \
    && chmod 600 /etc/apache2/conf.d/openemr.conf \
    && chmod 500 \
        ${OPENEMR_TOOLS_PATH}/fsupgrade-1.sh \
        ${OPENEMR_TOOLS_PATH}/fsupgrade-2.sh \
    && chown -R root:root ${OPENEMR_SHARE_PATH} ${OPENEMR_TOOLS_LIB_PATH} \
    && chmod -R u+rwX,g+rX,g-w,o+rX,o-w ${OPENEMR_SHARE_PATH} ${OPENEMR_TOOLS_LIB_PATH} \
    && chmod 000 ${OPENEMR_TOOLS_PATH}/unlock_admin.php \
    && chmod 500 ${OPENEMR_TOOLS_PATH}/unlock_admin.sh \
    && mkdir /var/run/openemr \
    && chown apache:root /var/run/openemr \
    && chmod 700 /var/run/openemr

#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2

#Ensure swarm/orchestration pieces are available if needed
RUN mkdir /swarm-pieces \
    && rsync --owner --group --perms --delete --recursive --links /etc/ssl /swarm-pieces/ \
    && rsync --owner --group --perms --delete --recursive --links ${OPENEMR_INSTALL_PATH}/sites /swarm-pieces/ \
    && chown -R apache:root /swarm-pieces/ssl /swam-pieces/sites \
    && chmod -R u+rwX,g-rwx,o-rwx /swarm-pieces/ssl /swarm-pieces/sites
#go
CMD [ "./run_openemr.sh" ]

EXPOSE 80 443
