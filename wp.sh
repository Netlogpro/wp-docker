#!/usr/bin/env bash
#
# Spins up a throwaway WordPress + MySQL stack in Docker, installs WordPress,
# copies plugin .zip archives from plugins/ into the container, then extracts
# and activates them there (host plugins/ stays zip-only). Must-use plugins from
# mu-plugins/ are deployed to wp-content/mu-plugins/ inside the container.
#
# Usage:
#   ./wp.sh          # build/start everything and configure WordPress
#   ./wp.sh down     # stop and remove containers (keeps volumes)
#   ./wp.sh reset    # stop and remove containers AND volumes (full wipe)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

mkdir -p plugins mu-plugins

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created .env from .env.example (edit it to customize ports/credentials)."
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

WORDPRESS_PORT="${WORDPRESS_PORT:-8080}"
WP_SITE_TITLE="${WP_SITE_TITLE:-Test Site}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_PASSWORD="${WP_ADMIN_PASSWORD:-admin}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.com}"

if [ "${1:-}" = "down" ]; then
  echo "==> Stopping containers (volumes kept)..."
  $DC down
  exit 0
fi

if [ "${1:-}" = "reset" ]; then
  echo "==> Stopping containers and deleting volumes (full wipe)..."
  $DC down -v
  exit 0
fi

echo "==> Building and starting containers..."
$DC up -d --build

echo "==> Waiting for the database to become healthy..."
attempts=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$($DC ps -q db)" 2>/dev/null)" = "healthy" ]; do
  attempts=$((attempts + 1))
  if [ "$attempts" -gt 60 ]; then
    echo "Database did not become healthy in time." >&2
    $DC logs db
    exit 1
  fi
  sleep 2
done

echo "==> Waiting for the WordPress container to respond..."
attempts=0
until $DC exec -T wordpress wp --allow-root cli info >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -gt 60 ]; then
    echo "WordPress container did not become ready in time." >&2
    $DC logs wordpress
    exit 1
  fi
  sleep 2
done

echo "==> Checking WordPress core installation..."
if ! $DC exec -T wordpress wp --allow-root core is-installed >/dev/null 2>&1; then
  echo "==> Installing WordPress core..."
  $DC exec -T wordpress wp --allow-root core install \
    --url="http://localhost:${WORDPRESS_PORT}" \
    --title="${WP_SITE_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email
else
  echo "    Already installed, skipping."
fi

echo "==> Setting pretty permalinks..."
$DC exec -T wordpress wp --allow-root rewrite structure '/%postname%/'
$DC exec -T wordpress wp --allow-root rewrite flush --hard

echo "==> Installing/activating plugins from plugins/ ..."
PLUGIN_ZIPS_DIR=/var/plugin-zips
PLUGIN_INSTALL_DIR=/var/www/html/wp-content/plugins

shopt -s nullglob
plugin_entries=(plugins/*)
shopt -u nullglob
if [ ${#plugin_entries[@]} -eq 0 ]; then
  echo "    None found (plugins/ is empty)."
else
  for entry in "${plugin_entries[@]}"; do
    name="$(basename "$entry")"

    # Skip placeholder / hidden entries (e.g. .gitkeep).
    if [[ "$name" == .* ]]; then
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Installing $name from archive (extract inside container)..."
      $DC exec -T wordpress wp --allow-root plugin install "$PLUGIN_ZIPS_DIR/$name" --activate --force \
        || echo "    Warning: could not install '$name' (is it a valid WordPress plugin zip?)."
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.php ]]; then
      echo "    Copying single-file plugin $name into the container..."
      $DC cp "$entry" "wordpress:$PLUGIN_INSTALL_DIR/$name"
      echo "    Activating $name..."
      $DC exec -T wordpress wp --allow-root plugin activate "$name" \
        || echo "    Warning: could not activate '$name'."
      continue
    fi

    if [ -d "$entry" ]; then
      slug="$name"
      echo "    Copying plugin folder $slug into the container..."
      $DC cp "$entry" "wordpress:$PLUGIN_INSTALL_DIR/$slug"

      if [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
        echo "    Installing composer dependencies for $slug..."
        $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
          composer install --no-interaction --no-dev --working-dir="$PLUGIN_INSTALL_DIR/$slug" \
          || echo "    Warning: composer install failed for $slug, continuing anyway."
      fi

      echo "    Activating $slug..."
      $DC exec -T wordpress wp --allow-root plugin activate "$slug" \
        || echo "    Warning: could not activate '$slug' (check it's a valid plugin folder with a main plugin header)."
      continue
    fi

    echo "    Warning: skipping unrecognized entry '$name' (expected .zip, .php, or a plugin folder)."
  done
fi

echo "==> Installing must-use plugins from mu-plugins/ ..."
MU_PLUGIN_ZIPS_DIR=/var/mu-plugin-zips
MU_PLUGIN_INSTALL_DIR=/var/www/html/wp-content/mu-plugins

shopt -s nullglob
mu_plugin_entries=(mu-plugins/*)
shopt -u nullglob
if [ ${#mu_plugin_entries[@]} -eq 0 ]; then
  echo "    None found (mu-plugins/ is empty)."
else
  for entry in "${mu_plugin_entries[@]}"; do
    name="$(basename "$entry")"

    if [[ "$name" == .* ]]; then
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Extracting $name into mu-plugins (inside container)..."
      $DC exec -T wordpress bash -lc \
        "mkdir -p '$MU_PLUGIN_INSTALL_DIR' && unzip -oq '$MU_PLUGIN_ZIPS_DIR/$name' -d '$MU_PLUGIN_INSTALL_DIR'" \
        || echo "    Warning: could not extract '$name' (is it a valid zip archive?)."
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.php ]]; then
      echo "    Copying must-use plugin $name into the container..."
      $DC exec -T wordpress mkdir -p "$MU_PLUGIN_INSTALL_DIR"
      $DC cp "$entry" "wordpress:$MU_PLUGIN_INSTALL_DIR/$name"
      continue
    fi

    if [ -d "$entry" ]; then
      slug="$name"
      echo "    Copying must-use plugin folder $slug into the container..."
      $DC exec -T wordpress mkdir -p "$MU_PLUGIN_INSTALL_DIR"
      $DC cp "$entry" "wordpress:$MU_PLUGIN_INSTALL_DIR/$slug"

      if [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
        echo "    Installing composer dependencies for $slug..."
        $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
          composer install --no-interaction --no-dev --working-dir="$MU_PLUGIN_INSTALL_DIR/$slug" \
          || echo "    Warning: composer install failed for $slug, continuing anyway."
      fi
      continue
    fi

    echo "    Warning: skipping unrecognized entry '$name' (expected .zip, .php, or a plugin folder)."
  done
fi

cat <<EOF

================================================================
 WordPress test environment is ready!

   Site:      http://localhost:${WORDPRESS_PORT}/
   wp-admin:  http://localhost:${WORDPRESS_PORT}/wp-admin/
   Username:  ${WP_ADMIN_USER}
   Password:  ${WP_ADMIN_PASSWORD}

   Must-use plugins:  drop .zip archives, folders, or .php files into mu-plugins/.
                       They are copied/extracted into wp-content/mu-plugins/ inside
                       the container and load automatically (no activation step).

   Plugins:           drop .zip archives into plugins/ and re-run this script.
                       Zips are installed inside the container only — nothing is
                       extracted on the host. Folders and single .php files are
                       copied into the container before activation.

   Useful commands (run from this docker/ directory):
     $DC exec wordpress wp --allow-root cron event list
     $DC exec wordpress wp --allow-root cron event run --due-now
     $DC logs -f wordpress
     ./wp.sh down    # stop containers, keep data
     ./wp.sh reset   # stop containers and wipe all data
================================================================
EOF
