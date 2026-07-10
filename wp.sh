#!/usr/bin/env bash
#
# Spins up a throwaway WordPress + MySQL stack in Docker, installs WordPress,
# copies plugin .zip archives from plugins/ into the container, then extracts
# and activates them there (host plugins/ stays zip-only). Must-use plugins from
# mu-plugins/ are deployed to wp-content/mu-plugins/ inside the container.
# Themes from themes/ are installed inside the container; set WP_DEFAULT_THEME
# in .env to activate a specific theme slug after install. wp-config is managed
# via .env constants and config/wp-config.extra.php (see sync_wp_config).
#
# Usage:
#   ./wp.sh                  # build/start everything and configure WordPress
#   ./wp.sh down             # stop and remove containers (keeps volumes)
#   ./wp.sh reset            # stop and remove containers AND volumes (full wipe)
#   ./wp.sh exec <cmd ...>   # run a command in the WordPress container
#   ./wp.sh wp [args ...]    # run WP-CLI (wp --allow-root) in the container
#   ./wp.sh shell            # open an interactive shell in the container
#   ./wp.sh sync             # re-apply plugins, mu-plugins, themes, and wp-config
#   ./wp.sh help             # show usage
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

mkdir -p plugins mu-plugins themes config/wp-config.d

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created .env from .env.example (edit it to customize ports/credentials)."
fi

if [ ! -f config/wp-config.extra.php ]; then
  cp config/wp-config.extra.php.example config/wp-config.extra.php
  echo "==> Created config/wp-config.extra.php from config/wp-config.extra.php.example."
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

# Resolved site URL: explicit WP_SITE_URL or localhost fallback.
if [ -n "${WP_SITE_URL:-}" ]; then
  WP_SITE_URL_RESOLVED="${WP_SITE_URL%/}"
  if [[ "$WP_SITE_URL_RESOLVED" != *://* ]]; then
    WP_SITE_URL_RESOLVED="http://${WP_SITE_URL_RESOLVED}"
  fi
  # Append WORDPRESS_PORT when omitted and not the default HTTP port.
  if [[ ! "$WP_SITE_URL_RESOLVED" =~ ^https?://[^/:]+:[0-9]+ ]] && [ "$WORDPRESS_PORT" != "80" ]; then
    if [[ "$WP_SITE_URL_RESOLVED" =~ ^(https?://[^/]+)(/.*)$ ]]; then
      WP_SITE_URL_RESOLVED="${BASH_REMATCH[1]}:${WORDPRESS_PORT}${BASH_REMATCH[2]}"
    else
      WP_SITE_URL_RESOLVED="${WP_SITE_URL_RESOLVED}:${WORDPRESS_PORT}"
    fi
  fi
else
  WP_SITE_URL_RESOLVED="http://localhost:${WORDPRESS_PORT}"
fi

set_wp_config_from_env() {
  local env_var="$1"
  local constant="$2"
  local value="${!env_var:-}"

  if [ -z "$value" ]; then
    return 0
  fi

  case "$constant" in
    WP_DEBUG|WP_DEBUG_LOG|WP_DEBUG_DISPLAY|DISALLOW_FILE_EDIT)
      case "${value,,}" in
        true|1|yes|on) value=true ;;
        false|0|no|off) value=false ;;
      esac
      $DC exec -T wordpress wp --allow-root config set "$constant" "$value" --raw --type=constant \
        || echo "    Warning: could not set ${constant}."
      ;;
    WP_POST_REVISIONS)
      $DC exec -T wordpress wp --allow-root config set "$constant" "$value" --raw --type=constant \
        || echo "    Warning: could not set ${constant}."
      ;;
    *)
      $DC exec -T wordpress wp --allow-root config set "$constant" "$value" --type=constant \
        || echo "    Warning: could not set ${constant}."
      ;;
  esac
}

ensure_wp_config_bootstrap() {
  $DC exec -T wordpress bash -lc '
    WP_CONFIG=/var/www/html/wp-config.php
    if ! grep -q "/docker-config/bootstrap.php" "$WP_CONFIG" 2>/dev/null; then
      sed -i "/That'\''s all, stop editing!/i if (is_readable('\''/docker-config/bootstrap.php'\'')) { require_once '\''/docker-config/bootstrap.php'\''; }" "$WP_CONFIG"
    fi
  '
}

sync_wp_config() {
  echo "==> Syncing wp-config from .env and config/ ..."
  ensure_wp_config_bootstrap
  set_wp_config_from_env WP_DEBUG WP_DEBUG
  set_wp_config_from_env WP_DEBUG_LOG WP_DEBUG_LOG
  set_wp_config_from_env WP_DEBUG_DISPLAY WP_DEBUG_DISPLAY
  set_wp_config_from_env WP_MEMORY_LIMIT WP_MEMORY_LIMIT
  set_wp_config_from_env WP_MAX_MEMORY_LIMIT WP_MAX_MEMORY_LIMIT
  set_wp_config_from_env DISALLOW_FILE_EDIT DISALLOW_FILE_EDIT
  set_wp_config_from_env WP_POST_REVISIONS WP_POST_REVISIONS
}

wait_for_database() {
  echo "==> Waiting for the database to become healthy..."
  local attempts=0
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$($DC ps -q db)" 2>/dev/null)" = "healthy" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 60 ]; then
      echo "Database did not become healthy in time." >&2
      $DC logs db
      exit 1
    fi
    sleep 2
  done
}

wait_for_wordpress() {
  echo "==> Waiting for the WordPress container to respond..."
  local attempts=0
  until $DC exec -T wordpress wp --allow-root cli info >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 60 ]; then
      echo "WordPress container did not become ready in time." >&2
      $DC logs wordpress
      exit 1
    fi
    sleep 2
  done
}

sync_plugins() {
  echo "==> Syncing plugins from plugins/ ..."
  local plugin_zips_dir=/var/plugin-zips
  local plugin_install_dir=/var/www/html/wp-content/plugins

  shopt -s nullglob
  local plugin_entries=(plugins/*)
  shopt -u nullglob
  if [ ${#plugin_entries[@]} -eq 0 ]; then
    echo "    None found (plugins/ is empty)."
    return 0
  fi

  for entry in "${plugin_entries[@]}"; do
    local name
    name="$(basename "$entry")"

    if [[ "$name" == .* ]]; then
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Installing $name from archive (extract inside container)..."
      $DC exec -T wordpress wp --allow-root plugin install "$plugin_zips_dir/$name" --activate --force \
        || echo "    Warning: could not install '$name' (is it a valid WordPress plugin zip?)."
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.php ]]; then
      echo "    Copying single-file plugin $name into the container..."
      $DC cp "$entry" "wordpress:$plugin_install_dir/$name"
      echo "    Activating $name..."
      $DC exec -T wordpress wp --allow-root plugin activate "$name" \
        || echo "    Warning: could not activate '$name'."
      continue
    fi

    if [ -d "$entry" ]; then
      local slug="$name"
      echo "    Syncing plugin folder $slug into the container..."
      $DC exec -T wordpress rm -rf "$plugin_install_dir/$slug"
      $DC cp "$entry" "wordpress:$plugin_install_dir/$slug"

      if [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
        echo "    Installing composer dependencies for $slug..."
        $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
          composer install --no-interaction --no-dev --working-dir="$plugin_install_dir/$slug" \
          || echo "    Warning: composer install failed for $slug, continuing anyway."
      fi

      echo "    Activating $slug..."
      $DC exec -T wordpress wp --allow-root plugin activate "$slug" \
        || echo "    Warning: could not activate '$slug' (check it's a valid plugin folder with a main plugin header)."
      continue
    fi

    echo "    Warning: skipping unrecognized entry '$name' (expected .zip, .php, or a plugin folder)."
  done
}

sync_mu_plugins() {
  echo "==> Syncing must-use plugins from mu-plugins/ ..."
  local mu_plugin_zips_dir=/var/mu-plugin-zips
  local mu_plugin_install_dir=/var/www/html/wp-content/mu-plugins

  shopt -s nullglob
  local mu_plugin_entries=(mu-plugins/*)
  shopt -u nullglob
  if [ ${#mu_plugin_entries[@]} -eq 0 ]; then
    echo "    None found (mu-plugins/ is empty)."
    return 0
  fi

  for entry in "${mu_plugin_entries[@]}"; do
    local name
    name="$(basename "$entry")"

    if [[ "$name" == .* ]]; then
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Extracting $name into mu-plugins (inside container)..."
      $DC exec -T wordpress bash -lc \
        "mkdir -p '$mu_plugin_install_dir' && unzip -oq '$mu_plugin_zips_dir/$name' -d '$mu_plugin_install_dir'" \
        || echo "    Warning: could not extract '$name' (is it a valid zip archive?)."
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.php ]]; then
      echo "    Copying must-use plugin $name into the container..."
      $DC exec -T wordpress mkdir -p "$mu_plugin_install_dir"
      $DC cp "$entry" "wordpress:$mu_plugin_install_dir/$name"
      continue
    fi

    if [ -d "$entry" ]; then
      local slug="$name"
      echo "    Syncing must-use plugin folder $slug into the container..."
      $DC exec -T wordpress mkdir -p "$mu_plugin_install_dir"
      $DC exec -T wordpress rm -rf "$mu_plugin_install_dir/$slug"
      $DC cp "$entry" "wordpress:$mu_plugin_install_dir/$slug"

      if [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
        echo "    Installing composer dependencies for $slug..."
        $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
          composer install --no-interaction --no-dev --working-dir="$mu_plugin_install_dir/$slug" \
          || echo "    Warning: composer install failed for $slug, continuing anyway."
      fi
      continue
    fi

    echo "    Warning: skipping unrecognized entry '$name' (expected .zip, .php, or a plugin folder)."
  done
}

sync_themes() {
  echo "==> Syncing themes from themes/ ..."
  local theme_zips_dir=/var/theme-zips
  local theme_install_dir=/var/www/html/wp-content/themes

  shopt -s nullglob
  local theme_entries=(themes/*)
  shopt -u nullglob
  if [ ${#theme_entries[@]} -eq 0 ]; then
    echo "    None found (themes/ is empty)."
    return 0
  fi

  for entry in "${theme_entries[@]}"; do
    local name
    name="$(basename "$entry")"

    if [[ "$name" == .* ]]; then
      continue
    fi

    if [ -f "$entry" ] && [[ "$name" == *.zip ]]; then
      echo "    Installing $name from archive (extract inside container)..."
      $DC exec -T wordpress wp --allow-root theme install "$theme_zips_dir/$name" --force \
        || echo "    Warning: could not install '$name' (is it a valid WordPress theme zip?)."
      continue
    fi

    if [ -d "$entry" ]; then
      local slug="$name"
      echo "    Syncing theme folder $slug into the container..."
      $DC exec -T wordpress rm -rf "$theme_install_dir/$slug"
      $DC cp "$entry" "wordpress:$theme_install_dir/$slug"

      if [ -f "$entry/composer.json" ] && [ ! -d "$entry/vendor" ]; then
        echo "    Installing composer dependencies for $slug..."
        $DC exec -T -e COMPOSER_ALLOW_SUPERUSER=1 wordpress \
          composer install --no-interaction --no-dev --working-dir="$theme_install_dir/$slug" \
          || echo "    Warning: composer install failed for $slug, continuing anyway."
      fi
      continue
    fi

    echo "    Warning: skipping unrecognized entry '$name' (expected .zip or a theme folder)."
  done
}

sync_default_theme() {
  if [ -n "${WP_DEFAULT_THEME:-}" ]; then
    echo "==> Activating default theme: ${WP_DEFAULT_THEME} ..."
    $DC exec -T wordpress wp --allow-root theme activate "$WP_DEFAULT_THEME" \
      || echo "    Warning: could not activate theme '${WP_DEFAULT_THEME}' (check the slug matches the theme folder name)."
  else
    echo "==> Skipping theme activation (WP_DEFAULT_THEME is not set)."
  fi
}

run_sync() {
  sync_wp_config
  sync_plugins
  sync_mu_plugins
  sync_themes
  sync_default_theme
}

show_usage() {
  cat <<'EOF'
Usage:
  ./wp.sh                  Build/start and configure WordPress
  ./wp.sh down             Stop containers (keep volumes)
  ./wp.sh reset            Stop containers and delete volumes
  ./wp.sh exec <cmd ...>   Run a command in the WordPress container
  ./wp.sh wp [args ...]    Run WP-CLI (wp --allow-root) in the container
  ./wp.sh shell            Open an interactive shell in the container
  ./wp.sh sync             Re-apply plugins, mu-plugins, themes, and wp-config
  ./wp.sh help             Show this help

Examples:
  ./wp.sh sync
  ./wp.sh shell
  ./wp.sh wp plugin list
  ./wp.sh exec ls -la /var/www/html/wp-content/plugins
EOF
}

require_container() {
  if ! $DC ps --status running --services 2>/dev/null | grep -qx wordpress; then
    echo "WordPress container is not running. Start it with: ./wp.sh" >&2
    exit 1
  fi
}

container_exec() {
  require_container
  if [ -t 0 ] && [ -t 1 ]; then
    $DC exec wordpress "$@"
  else
    $DC exec -T wordpress "$@"
  fi
}

open_shell() {
  require_container
  $DC exec wordpress bash
}

if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_usage
  exit 0
fi

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

if [ "${1:-}" = "exec" ]; then
  shift
  if [ $# -eq 0 ]; then
    echo "Usage: ./wp.sh exec <command...>" >&2
    echo "For an interactive shell, use: ./wp.sh shell" >&2
    exit 1
  fi
  container_exec "$@"
  exit 0
fi

if [ "${1:-}" = "wp" ]; then
  shift
  if [ $# -eq 0 ]; then
    echo "Usage: ./wp.sh wp <wp-cli-args...>" >&2
    echo "Example: ./wp.sh wp plugin list" >&2
    exit 1
  fi
  container_exec wp --allow-root "$@"
  exit 0
fi

if [ "${1:-}" = "shell" ]; then
  open_shell
  exit 0
fi

if [ "${1:-}" = "sync" ]; then
  echo "==> Ensuring containers are running..."
  $DC up -d
  wait_for_database
  wait_for_wordpress
  run_sync
  echo "==> Sync complete."
  exit 0
fi

echo "==> Building and starting containers..."
$DC up -d --build

wait_for_database
wait_for_wordpress

echo "==> Checking WordPress core installation..."
if ! $DC exec -T wordpress wp --allow-root core is-installed >/dev/null 2>&1; then
  echo "==> Installing WordPress core..."
  $DC exec -T wordpress wp --allow-root core install \
    --url="${WP_SITE_URL_RESOLVED}" \
    --title="${WP_SITE_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email
else
  echo "    Already installed, skipping."
  if [ -n "${WP_SITE_URL:-}" ]; then
    echo "==> Updating WordPress site URL to ${WP_SITE_URL_RESOLVED} ..."
    $DC exec -T wordpress wp --allow-root option update siteurl "$WP_SITE_URL_RESOLVED"
    $DC exec -T wordpress wp --allow-root option update home "$WP_SITE_URL_RESOLVED"
  fi
fi

echo "==> Setting pretty permalinks..."
$DC exec -T wordpress wp --allow-root rewrite structure '/%postname%/'
$DC exec -T wordpress wp --allow-root rewrite flush --hard

run_sync

cat <<EOF

================================================================
 WordPress test environment is ready!

   Site:      ${WP_SITE_URL_RESOLVED}/
   wp-admin:  ${WP_SITE_URL_RESOLVED}/wp-admin/
   Username:  ${WP_ADMIN_USER}
   Password:  ${WP_ADMIN_PASSWORD}
$(if [ -n "${WP_SITE_URL:-}" ] && [[ "$WP_SITE_URL_RESOLVED" != *"localhost"* ]]; then
  echo ""
  echo "   Hosts file:  map the domain on your machine, e.g."
  echo "                127.0.0.1  $(echo "$WP_SITE_URL_RESOLVED" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')"
fi)

   Themes:            drop .zip archives or theme folders into themes/ and run
                       ./wp.sh sync (or ./wp.sh) to apply changes.
                       Set WP_DEFAULT_THEME in .env to the theme slug (folder name)
                       to activate one; leave blank to keep the current theme.

   Must-use plugins:  drop .zip archives, folders, or .php files into mu-plugins/.
                       They are copied/extracted into wp-content/mu-plugins/ inside
                       the container and load automatically (no activation step).

   Plugins:           drop .zip archives into plugins/ and run ./wp.sh sync (or
                       ./wp.sh) to apply. Zips are installed inside the container
                       only — nothing is extracted on the host.

   wp-config:         set common constants in .env (WP_DEBUG, WP_MEMORY_LIMIT,
                       etc.) and run ./wp.sh sync. For advanced PHP overrides,
                       edit config/wp-config.extra.php or add snippets under
                       config/wp-config.d/.

   Useful commands (run from this docker/ directory):
     ./wp.sh sync    # re-apply plugins, mu-plugins, themes, and wp-config
     ./wp.sh shell   # interactive shell in the container
     ./wp.sh wp plugin list
     ./wp.sh exec ls -la /var/www/html/wp-content/plugins
     $DC logs -f wordpress
     ./wp.sh down    # stop containers, keep data
     ./wp.sh reset   # stop containers and wipe all data
     ./wp.sh help    # show all commands
================================================================
EOF
