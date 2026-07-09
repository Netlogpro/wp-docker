# Test/dev image for WordPress.
#
# Pinned to WordPress 7.0.0 + PHP 8.2 + Apache. Adds Composer and WP-CLI
# so wp.sh can install plugins and drive WordPress from the host.
ARG WORDPRESS_IMAGE=wordpress:7.0.0-php8.2-apache
FROM ${WORDPRESS_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        unzip \
        less \
        default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# WP-CLI
RUN curl -fsSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp \
    && wp --info --allow-root

WORKDIR /var/www/html
