FROM php:7.3-apache

# Base Env
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    sed -i -e "s/security.debian.org/mirrors.tuna.tsinghua.edu.cn/" /etc/apt/sources.list; \
    sed -i -e "s/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/" /etc/apt/sources.list; \
    apt update; \
    apt-get update --fix-missing; \
    apt install -y tzdata curl wget; \
    rm -rf /var/lib/apt/lists/*
# / Base Env

# / Deps
# @see https://github.com/docker-library/wordpress/blob/master/latest/php7.3/apache/Dockerfile
RUN set -ex; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libfreetype6-dev \
		libjpeg-dev \
		libmagickwand-dev \
		libpng-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd \
		--with-freetype-dir=/usr \
		--with-jpeg-dir=/usr \
		--with-png-dir=/usr \
	; \
	docker-php-ext-install -j "$(nproc)" \
		bcmath \
		exif \
		gd \
		zip \
	; \
	pecl install imagick-3.4.4; \
	docker-php-ext-enable imagick; \
	rm -r /tmp/pear; \
	\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
		| awk '/=>/ { print $3 }' \
		| sort -u \
		| xargs -r dpkg-query -S \
		| cut -d: -f1 \
		| sort -u \
		| xargs -rt apt-mark manual; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*
# / Deps

# PHP Config
# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
	docker-php-ext-enable opcache; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging

RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

RUN set -eux; \
	a2enmod rewrite expires; \
	\
# https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html
	a2enmod remoteip; \
	{ \
		echo 'RemoteIPHeader X-Forwarded-For'; \
# these IP ranges are reserved for "private" use and should thus *usually* be safe inside Docker
		echo 'RemoteIPTrustedProxy 10.0.0.0/8'; \
		echo 'RemoteIPTrustedProxy 172.16.0.0/12'; \
		echo 'RemoteIPTrustedProxy 192.168.0.0/16'; \
		echo 'RemoteIPTrustedProxy 169.254.0.0/16'; \
		echo 'RemoteIPTrustedProxy 127.0.0.0/8'; \
	} > /etc/apache2/conf-available/remoteip.conf; \
	a2enconf remoteip; \
# https://github.com/docker-library/wordpress/issues/383#issuecomment-507886512
# (replace all instances of "%h" with "%a" in LogFormat)
	find /etc/apache2 -type f -name '*.conf' -exec sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' '{}' +
# / PHP Config

# / APP
ARG DOKUWIKI_VERSION=2020-07-29
ARG DOKUWIKI_SHASUM=119f3875d023d15070068a6aca1e23acd7f9a19a

RUN set -eux; \
	curl -o dokuwiki-stable.tgz -fL "https://download.dokuwiki.org/src/dokuwiki/dokuwiki-stable.tgz"; \
	echo "$DOKUWIKI_SHASUM  dokuwiki-stable.tgz" | sha1sum -c -; \
	\
# upstream tarballs include ./dokuwiki/ so this gives us /usr/src/dokuwiki
	tar -xvf dokuwiki-stable.tgz -C /usr/src/; \
	rm dokuwiki-stable.tgz; \
    mkdir -p /usr/src/dokuwiki; \
    cp -r /usr/src/dokuwiki-$DOKUWIKI_VERSION/* /usr/src/dokuwiki; \
    rm -rf /usr/src/dokuwiki-$DOKUWIKI_VERSION; \
    # see .htaccess-dist
	[ ! -e /usr/src/dokuwiki/.htaccess ]; \
	{ \
        echo 'Options -Indexes -MultiViews +FollowSymLinks'; \
        echo '  <Files ~ "^([\._]ht|README$|VERSION$|COPYING$)">'; \
        echo '    <IfModule mod_authz_core.c>'; \
        echo '      Require all denied'; \
        echo '    </IfModule>'; \
        echo '    <IfModule !mod_authz_core.c>'; \
        echo '      Order allow,deny'; \
        echo '      Deny from all'; \
        echo '    </IfModule>'; \
        echo '  </Files>'; \
        echo '  <IfModule alias_module>'; \
        echo '    RedirectMatch 404 /\.git'; \
        echo '  </IfModule>'; \

        echo 'RewriteEngine on'; \
        echo 'RewriteRule ^_media/(.*)              lib/exe/fetch.php?media=$1  [QSA,L]'; \
        echo 'RewriteRule ^_detail/(.*)             lib/exe/detail.php?media=$1  [QSA,L]'; \
        echo 'RewriteRule ^_export/([^/]+)/(.*)     doku.php?do=export_$1&id=$2  [QSA,L]'; \
        echo 'RewriteRule ^$                        doku.php  [L]'; \
        echo 'RewriteCond %{REQUEST_FILENAME}       !-f'; \
        echo 'RewriteCond %{REQUEST_FILENAME}       !-d'; \
        echo 'RewriteRule (.*)                      doku.php?id=$1  [QSA,L]'; \
        echo 'RewriteRule ^index.php$               doku.php'; \
        echo 'RewriteBase /'; \
	} > /usr/src/dokuwiki/.htaccess; \
	\
	chown -R www-data:www-data /usr/src/dokuwiki;
# / APP

VOLUME /var/www/html

COPY docker-entrypoint.sh /usr/local/bin/

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]