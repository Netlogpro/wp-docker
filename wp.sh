#!/usr/bin/env bash
#
# Spins up a throwaway WordPress + MySQL stack in Docker, installs WordPress,
# installs/activates anything dropped into plugins/ (zips, folders, or loose
# .php files), and runs composer install for plugin folders that need it.
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

mkdir -p plugins

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

echo "==> Installing/activating extra plugins from plugins/ ..."
shopt -s nullglob
extra_plugins=(plugins/*)
shopt -u nullglob
if [ ${#extra_plugins[@]} -eq 0 ]; then
  echo "    None found (plugins/ is empty)."
else
  for entry in "${extra_plugins[@]}"; do
    name="$(basename "$entry")"

    # Skip placeholder / hidden entries (e.g. .gitkeep).
    if [[ "$name" == .* ]]; then
      continue
    fi

    plugin_container_path="/var/www/html/wp-content/plugins/$name"

    # A .zip dropped in plugins/ is extracted in place via WP-CLI (which
    # understands normal WordPress.org plugin zip layouts, incl. zips that wrap
    # everything in a single top-level folder) and activated in one step.
    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Unzipping and installing $name..."
      $DC exec -T wordpress wp --allow-root plugin install "$plugin_container_path" --activate --force \
        || echo "    Warning: could not install '$name' (is it a valid WordPress plugin zip?)."
      continue
    fi

    slug="$name"
    if [ -d "$entry" ] && [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
      echo "    Installing composer dependencies for $slug..."
      $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
        composer install --no-interaction --no-dev --working-dir="$plugin_container_path" \
        || echo "    Warning: composer install failed for $slug, continuing anyway."
    fi

    echo "    Activating $slug..."
    $DC exec -T wordpress wp --allow-root plugin activate "$slug" \
      || echo "    Warning: could not activate '$slug' (check it's a valid plugin folder/file with a main plugin header)."
  done
fi

cat <<EOF

================================================================
 WordPress test environment is ready!

   Site:      http://localhost:${WORDPRESS_PORT}/
   wp-admin:  http://localhost:${WORDPRESS_PORT}/wp-admin/
   Username:  ${WP_ADMIN_USER}
   Password:  ${WP_ADMIN_PASSWORD}

   Extra plugins:     drop a plugin .zip, folder, or single-file plugin.php into
                       plugins/ and re-run this script to install/activate it.

   Useful commands (run from this docker/ directory):
     $DC exec wordpress wp --allow-root cron event list
     $DC exec wordpress wp --allow-root cron event run --due-now
     $DC logs -f wordpress
     ./wp.sh down    # stop containers, keep data
     ./wp.sh reset   # stop containers and wipe all data
================================================================
EOF
