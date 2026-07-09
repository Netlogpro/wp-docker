# Test/dev image for WordPress.
#
# Extends the official WordPress image (Apache + PHP 8.2) with Composer and
# WP-CLI so wp.sh can install plugins and drive WordPress from the host
# without anything else installed locally besides Docker.
FROM wordpress:php8.2-apache

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
