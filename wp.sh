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
#   ./wp.sh local-ssl        # start with HTTPS via Caddy local CA (dev)
#   ./wp.sh global-ssl       # start with HTTPS via Let's Encrypt (public DNS)
#   ./wp.sh trust-ssl        # re-export/trust the Caddy local CA on this machine
#   ./wp.sh down             # stop and remove containers (keeps volumes)
#   ./wp.sh reset            # stop and remove containers AND volumes (full wipe)
#   ./wp.sh exec <cmd ...>   # run a command in the WordPress container
#   ./wp.sh wp [args ...]    # run WP-CLI (wp --allow-root) in the container
#   ./wp.sh shell            # open an interactive shell in the container
#   ./wp.sh sync             # re-apply plugins, mu-plugins, themes, wp-config, uploads perms
#   ./wp.sh phpmyadmin       # same as ./wp.sh, plus start phpMyAdmin
#   ./wp.sh logs             # follow WordPress container logs
#   ./wp.sh help             # show usage
#
# local-ssl and global-ssl are mutually exclusive. They may be combined with
# phpmyadmin, e.g. ./wp.sh phpmyadmin local-ssl
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
PHPMYADMIN_PORT="${PHPMYADMIN_PORT:-8081}"
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

# ============================================================================
# SSL support (additive) — everything above stays the original, unchanged flow.
#   local-ssl  → Caddy reverse proxy with a local CA (dev / .local domains)
#   global-ssl → Caddy reverse proxy with Let's Encrypt (public DNS)
# The two are mutually exclusive and only take effect when starting the stack.
# ============================================================================
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
SSL_MODE_FILE=".ssl-mode"
SITE_HOST=""

# Pull local-ssl / global-ssl out of the argument list (position-independent).
SSL_MODE_ARG=""
SSL_PARSED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    local-ssl)
      if [ -n "$SSL_MODE_ARG" ]; then
        echo "Error: local-ssl and global-ssl cannot be used together. Pick one." >&2
        exit 1
      fi
      SSL_MODE_ARG=local
      ;;
    global-ssl)
      if [ -n "$SSL_MODE_ARG" ]; then
        echo "Error: local-ssl and global-ssl cannot be used together. Pick one." >&2
        exit 1
      fi
      SSL_MODE_ARG=global
      ;;
    *)
      SSL_PARSED_ARGS+=("$arg")
      ;;
  esac
done
if [ ${#SSL_PARSED_ARGS[@]} -gt 0 ]; then
  set -- "${SSL_PARSED_ARGS[@]}"
else
  set --
fi

# Effective SSL mode:
#   - starting the stack (no subcommand, or "phpmyadmin"): the CLI flag decides
#   - other subcommands (down/logs/sync/...): reuse the last started mode so the
#     unchanged `$DC` commands keep managing the Caddy proxy too
case "${1:-}" in
  ""|phpmyadmin)
    SSL_MODE="$SSL_MODE_ARG"
    ;;
  *)
    if [ -f "$SSL_MODE_FILE" ]; then
      SSL_MODE="$(tr -d '[:space:]' < "$SSL_MODE_FILE")"
    else
      SSL_MODE=""
    fi
    ;;
esac

# When SSL is active, layer the Caddy compose file over the base one so every
# existing `$DC ...` invocation transparently includes the proxy — no changes
# to the individual subcommand handlers required.
if [ -n "$SSL_MODE" ]; then
  export COMPOSE_FILE="docker-compose.yml:docker-compose.ssl.yml"
fi

# Host portion of WP_SITE_URL (no scheme/port/path). Used for the Caddyfile.
extract_site_host() {
  local url="${1#*://}"
  url="${url%%/*}"
  url="${url%%:*}"
  printf '%s' "$url"
}

# Force https:// (and HTTPS_PORT) for the resolved site URL when SSL is on.
resolve_ssl_site_url() {
  SITE_HOST="$(extract_site_host "$WP_SITE_URL")"
  if [ "$HTTPS_PORT" = "443" ]; then
    WP_SITE_URL_RESOLVED="https://${SITE_HOST}"
  else
    WP_SITE_URL_RESOLVED="https://${SITE_HOST}:${HTTPS_PORT}"
  fi
}

validate_ssl_mode() {
  [ -z "$SSL_MODE" ] && return 0

  if [ -z "${WP_SITE_URL:-}" ]; then
    echo "Error: SSL requires WP_SITE_URL in .env (e.g. newsite.local or example.com)." >&2
    exit 1
  fi

  local host
  host="$(extract_site_host "$WP_SITE_URL")"
  if [ -z "$host" ] || [ "$host" = "localhost" ]; then
    echo "Error: SSL requires a hostname in WP_SITE_URL (not bare localhost)." >&2
    echo "Example: WP_SITE_URL=newsite.local   or   WP_SITE_URL=example.com" >&2
    exit 1
  fi

  if [ "$HTTP_PORT" = "$HTTPS_PORT" ]; then
    echo "Error: HTTP_PORT (${HTTP_PORT}) and HTTPS_PORT (${HTTPS_PORT}) must differ." >&2
    exit 1
  fi

  if [ "$SSL_MODE" = "global" ]; then
    if [ -z "${WP_ADMIN_EMAIL:-}" ] || [ "$WP_ADMIN_EMAIL" = "admin@example.com" ]; then
      echo "Error: global-ssl requires a real WP_ADMIN_EMAIL in .env (used for Let's Encrypt)." >&2
      echo "The default 'admin@example.com' is not accepted by Let's Encrypt." >&2
      exit 1
    fi
    case "$host" in
      *.local|*.test|*.localhost)
        echo "Error: global-ssl needs a public DNS hostname (not .local / .test)." >&2
        echo "For local HTTPS, use: ./wp.sh local-ssl" >&2
        exit 1
        ;;
    esac
  fi
}

write_caddyfile() {
  mkdir -p config
  if [ "$SSL_MODE" = "local" ]; then
    cat > config/Caddyfile <<EOF
# Generated by wp.sh (local-ssl). Do not edit by hand.
# TLS is terminated entirely inside the Caddy container using its own local CA.

{
	local_certs
}

${SITE_HOST} {
	tls internal
	encode gzip
	reverse_proxy wordpress:80
}
EOF
  elif [ "$SSL_MODE" = "global" ]; then
    cat > config/Caddyfile <<EOF
# Generated by wp.sh (global-ssl). Do not edit by hand.

{
	email ${WP_ADMIN_EMAIL}
}

${SITE_HOST} {
	encode gzip
	reverse_proxy wordpress:80
}
EOF
  fi
}

# After Caddy is up: copy its in-container local CA onto the host so the
# browser can be taught to trust it (TLS still terminates only in Caddy).
CADDY_ROOT_CA_FILE="caddy-root.crt"
CADDY_ROOT_CA_CER="caddy-root.cer"
LOCAL_SSL_TRUST_STATUS=""

is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

export_caddy_local_ca() {
  local attempts=0
  local container_ca="/data/caddy/pki/authorities/local/root.crt"

  echo "==> Exporting Caddy local CA from the container..."
  until $DC exec -T caddy test -f "$container_ca" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 30 ]; then
      echo "    Warning: Caddy local CA not ready yet; skipping host trust step." >&2
      return 1
    fi
    # Touch HTTPS once so Caddy materializes the local PKI if needed.
    curl -sk --resolve "${SITE_HOST}:443:127.0.0.1" "https://${SITE_HOST}/" >/dev/null 2>&1 || true
    sleep 1
  done

  $DC cp "caddy:${container_ca}" "$CADDY_ROOT_CA_FILE"
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CADDY_ROOT_CA_FILE" -outform DER -out "$CADDY_ROOT_CA_CER" 2>/dev/null \
      || cp "$CADDY_ROOT_CA_FILE" "$CADDY_ROOT_CA_CER"
  else
    cp "$CADDY_ROOT_CA_FILE" "$CADDY_ROOT_CA_CER"
  fi
  echo "    Saved ${CADDY_ROOT_CA_FILE} (and ${CADDY_ROOT_CA_CER})."
}

windows_ca_already_trusted() {
  powershell.exe -NoProfile -Command \
    "if (Get-ChildItem Cert:\\CurrentUser\\Root -ErrorAction SilentlyContinue | Where-Object { \$_.Subject -like '*Caddy Local Authority*' }) { exit 0 } else { exit 1 }" \
    >/dev/null 2>&1
}

trust_caddy_local_ca_windows() {
  local win_path
  local desk_win
  local desk_wsl

  if windows_ca_already_trusted; then
    echo "    Windows already trusts the Caddy Local Authority CA."
    LOCAL_SSL_TRUST_STATUS="trusted"
    return 0
  fi

  # Prefer a native Windows path (Desktop) — WSL UNC paths break certutil.
  desk_win="$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("Desktop")' 2>/dev/null | tr -d '\r')"
  if [ -n "$desk_win" ]; then
    desk_wsl="$(wslpath "$desk_win" 2>/dev/null || true)"
  fi
  if [ -n "$desk_wsl" ] && [ -d "$desk_wsl" ]; then
    cp -f "$CADDY_ROOT_CA_CER" "$desk_wsl/caddy-root.cer"
    win_path="${desk_win}\\caddy-root.cer"
  else
    win_path="$(wslpath -w "$(pwd)/${CADDY_ROOT_CA_CER}" 2>/dev/null | tr -d '\r')"
  fi

  echo "    Importing Caddy CA into Windows Current User Trusted Root store..."
  echo "    If a Security Warning dialog appears, click Yes."
  if powershell.exe -NoProfile -Command "certutil -user -addstore Root '$win_path'" >/tmp/wp-ssl-trust.out 2>&1; then
    if windows_ca_already_trusted; then
      echo "    Windows trust store updated."
      LOCAL_SSL_TRUST_STATUS="trusted"
      return 0
    fi
  fi

  # Fallback: Import-Certificate (also may prompt)
  if powershell.exe -NoProfile -Command \
      "Import-Certificate -FilePath '$win_path' -CertStoreLocation Cert:\\CurrentUser\\Root | Out-Null" \
      >/tmp/wp-ssl-trust.out 2>&1 \
      && windows_ca_already_trusted; then
    echo "    Windows trust store updated."
    LOCAL_SSL_TRUST_STATUS="trusted"
    return 0
  fi

  echo "    Warning: could not auto-import the CA (dialog cancelled or blocked)." >&2
  echo "    Manual: double-click ${win_path} → Install Certificate → Current User" >&2
  echo "            → Trusted Root Certification Authorities → Finish → Yes." >&2
  LOCAL_SSL_TRUST_STATUS="manual"
  return 1
}

trust_caddy_local_ca_macos() {
  if security find-certificate -c "Caddy Local Authority" >/dev/null 2>&1; then
    echo "    macOS already trusts the Caddy Local Authority CA."
    LOCAL_SSL_TRUST_STATUS="trusted"
    return 0
  fi
  echo "    Adding Caddy CA to the login keychain (may prompt for your password)..."
  if security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" \
       "$CADDY_ROOT_CA_FILE" 2>/tmp/wp-ssl-trust.out; then
    LOCAL_SSL_TRUST_STATUS="trusted"
    echo "    macOS trust store updated."
    return 0
  fi
  LOCAL_SSL_TRUST_STATUS="manual"
  echo "    Warning: could not trust the CA automatically. Import ${CADDY_ROOT_CA_FILE} via Keychain Access." >&2
  return 1
}

trust_caddy_local_ca_linux() {
  local dest="/usr/local/share/ca-certificates/caddy-local-authority.crt"
  if [ -f "$dest" ]; then
    echo "    Linux system CA already has a Caddy entry at ${dest}."
    LOCAL_SSL_TRUST_STATUS="trusted"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    echo "    Installing Caddy CA into the system trust store..."
    sudo cp "$CADDY_ROOT_CA_FILE" "$dest"
    if sudo update-ca-certificates >/tmp/wp-ssl-trust.out 2>&1; then
      LOCAL_SSL_TRUST_STATUS="trusted"
      echo "    Linux trust store updated."
      return 0
    fi
  fi
  LOCAL_SSL_TRUST_STATUS="manual"
  echo "    Warning: need sudo to install into the system CA store." >&2
  echo "    Run:  sudo cp ${CADDY_ROOT_CA_FILE} ${dest} && sudo update-ca-certificates" >&2
  return 1
}

ensure_windows_hosts_entry() {
  local host="$1"
  local ps

  [ -z "$host" ] && return 0
  is_wsl || return 0

  ps="\$hosts='C:\\Windows\\System32\\drivers\\etc\\hosts'; \$line='127.0.0.1  ${host}'; if (Select-String -Path \$hosts -Pattern ([regex]::Escape('${host}')) -Quiet) { exit 0 }; try { Add-Content -Path \$hosts -Value \$line -ErrorAction Stop; exit 0 } catch { exit 1 }"
  if powershell.exe -NoProfile -Command "$ps" >/dev/null 2>&1; then
    echo "    Windows hosts already contains (or was updated with) ${host}."
    return 0
  fi
  echo "    Note: could not write Windows hosts (needs Admin). Ensure this line exists:" >&2
  echo "      127.0.0.1  ${host}" >&2
  echo "    File: C:\\Windows\\System32\\drivers\\etc\\hosts" >&2
  return 1
}

# Export Caddy's CA and teach the host browser OS to trust it.
trust_local_ssl_on_host() {
  LOCAL_SSL_TRUST_STATUS="skipped"
  export_caddy_local_ca || return 1

  echo "==> Trusting Caddy local CA on this machine (so the browser shows Secure)..."
  if is_wsl && command -v powershell.exe >/dev/null 2>&1; then
    ensure_windows_hosts_entry "$SITE_HOST" || true
    trust_caddy_local_ca_windows || true
  elif [ "$(uname -s)" = "Darwin" ]; then
    trust_caddy_local_ca_macos || true
  else
    trust_caddy_local_ca_linux || true
  fi
}

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

# Write PHP upload / size limits from .env into config/php-uploads.ini, which is
# mounted into the WordPress container at /usr/local/etc/php/conf.d/zz-uploads.ini.
# post_max_size defaults to upload_max_filesize when left blank.
write_php_ini_from_env() {
  local upload="${PHP_UPLOAD_MAX_FILESIZE:-64M}"
  local post="${PHP_POST_MAX_SIZE:-}"
  local files="${PHP_MAX_FILE_UPLOADS:-20}"
  local exec_time="${PHP_MAX_EXECUTION_TIME:-300}"
  local input_time="${PHP_MAX_INPUT_TIME:-300}"
  local mem="${PHP_MEMORY_LIMIT:-}"

  if [ -z "$post" ]; then
    post="$upload"
  fi

  mkdir -p config
  {
    echo "; Generated by wp.sh from .env — do not edit by hand."
    echo "; Re-run ./wp.sh or ./wp.sh sync after changing PHP_* values."
    echo "upload_max_filesize = ${upload}"
    echo "post_max_size = ${post}"
    echo "max_file_uploads = ${files}"
    echo "max_execution_time = ${exec_time}"
    echo "max_input_time = ${input_time}"
    if [ -n "$mem" ]; then
      echo "memory_limit = ${mem}"
    fi
  } > config/php-uploads.ini
}

sync_php_ini() {
  echo "==> Syncing PHP upload limits from .env ..."
  write_php_ini_from_env
  echo "    upload_max_filesize=${PHP_UPLOAD_MAX_FILESIZE:-64M}  post_max_size=${PHP_POST_MAX_SIZE:-${PHP_UPLOAD_MAX_FILESIZE:-64M}}"
  echo "    max_file_uploads=${PHP_MAX_FILE_UPLOADS:-20}  max_execution_time=${PHP_MAX_EXECUTION_TIME:-300}  max_input_time=${PHP_MAX_INPUT_TIME:-300}"
  if [ -n "${PHP_MEMORY_LIMIT:-}" ]; then
    echo "    memory_limit=${PHP_MEMORY_LIMIT}"
  fi

  # Apache/PHP only picks up conf.d changes after a reload.
  if $DC ps --status running --services 2>/dev/null | grep -qx wordpress; then
    $DC exec -T wordpress apache2ctl graceful >/dev/null 2>&1 \
      || $DC exec -T wordpress apachectl graceful >/dev/null 2>&1 \
      || echo "    Warning: could not reload Apache; restart the wordpress container to apply PHP ini changes."
  fi
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
  # WP-CLI is available as soon as the container starts, but on a fresh volume the
  # official image entrypoint still needs time to copy core files and generate
  # wp-config.php from WORDPRESS_* env vars. Wait for both before core install.
  until $DC exec -T wordpress wp --allow-root cli info >/dev/null 2>&1 \
    && $DC exec -T wordpress test -f /var/www/html/wp-config.php; do
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

# WordPress (Apache) runs as www-data; uploads and upgrade must be writable by that user.
# Create the directories if missing, then enforce owner/group and mode 755.
ensure_uploads_permissions() {
  echo "==> Ensuring wp-content/uploads and wp-content/upgrade are owned by www-data:www-data (mode 755)..."
  $DC exec -T wordpress bash -lc '
    for dir in /var/www/html/wp-content/uploads /var/www/html/wp-content/upgrade; do
      mkdir -p "$dir"
      chown -R www-data:www-data "$dir"
      chmod 755 "$dir"
    done
  ' || echo "    Warning: could not set uploads/upgrade permissions."
}

run_sync() {
  sync_wp_config
  sync_php_ini
  sync_plugins
  sync_mu_plugins
  sync_themes
  sync_default_theme
  ensure_uploads_permissions
}

show_usage() {
  cat <<'EOF'
Usage:
  ./wp.sh                  Build/start and configure WordPress
  ./wp.sh local-ssl        Start with HTTPS (Caddy local CA — for .local domains)
  ./wp.sh global-ssl       Start with HTTPS (Let's Encrypt — public DNS required)
  ./wp.sh trust-ssl        Re-export/trust the Caddy local CA on this machine
  ./wp.sh down             Stop containers (keep volumes)
  ./wp.sh reset            Stop containers and delete volumes
  ./wp.sh exec <cmd ...>   Run a command in the WordPress container
  ./wp.sh wp [args ...]    Run WP-CLI (wp --allow-root) in the container
  ./wp.sh shell            Open an interactive shell in the container
  ./wp.sh sync             Re-apply plugins, mu-plugins, themes, wp-config, and uploads perms
  ./wp.sh phpmyadmin       Full WordPress setup plus phpMyAdmin
  ./wp.sh logs             Follow WordPress container logs
  ./wp.sh help             Show this help

SSL notes:
  local-ssl and global-ssl are mutually exclusive.
  Combine with phpMyAdmin:  ./wp.sh phpmyadmin local-ssl
  SSL requires WP_SITE_URL in .env. global-ssl also needs a real WP_ADMIN_EMAIL.
  local-ssl exports Caddy's CA and trusts it on the host (WSL→Windows / macOS / Linux)
  so the browser can show a Secure padlock. Without an SSL flag, previous SSL is cleared.

Examples:
  ./wp.sh sync
  ./wp.sh shell
  ./wp.sh local-ssl
  ./wp.sh trust-ssl
  ./wp.sh global-ssl
  ./wp.sh phpmyadmin local-ssl
  ./wp.sh logs
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

if [ "${1:-}" = "logs" ]; then
  $DC logs -f wordpress
  exit 0
fi

if [ "${1:-}" = "sync" ]; then
  echo "==> Ensuring containers are running..."
  write_php_ini_from_env
  $DC up -d db wordpress
  wait_for_database
  wait_for_wordpress
  run_sync
  echo "==> Sync complete."
  exit 0
fi

if [ "${1:-}" = "trust-ssl" ]; then
  if [ -n "$SSL_MODE_ARG" ]; then
    echo "Error: trust-ssl does not take local-ssl/global-ssl flags." >&2
    exit 1
  fi
  if [ "${SSL_MODE:-}" != "local" ]; then
    echo "Error: no local-ssl stack is active. Start with: ./wp.sh local-ssl" >&2
    exit 1
  fi
  if [ -z "${SITE_HOST:-}" ]; then
    if [ -n "${WP_SITE_URL:-}" ]; then
      SITE_HOST="$(extract_site_host "$WP_SITE_URL")"
    else
      echo "Error: WP_SITE_URL is required for trust-ssl." >&2
      exit 1
    fi
  fi
  if ! $DC ps --status running --services 2>/dev/null | grep -qx caddy; then
    echo "Error: Caddy is not running. Start with: ./wp.sh local-ssl" >&2
    exit 1
  fi
  trust_local_ssl_on_host
  exit 0
fi

WITH_PHPMYADMIN=false
if [ "${1:-}" = "phpmyadmin" ]; then
  WITH_PHPMYADMIN=true
fi

# Prepare SSL (additive): validate, generate the Caddyfile, force the https URL,
# and persist the mode so later subcommands keep managing the proxy.
if [ -n "$SSL_MODE" ]; then
  validate_ssl_mode
  resolve_ssl_site_url
  write_caddyfile
  printf '%s\n' "$SSL_MODE" > "$SSL_MODE_FILE"
  echo "==> SSL mode: ${SSL_MODE} (https via Caddy → ${SITE_HOST})"
else
  rm -f "$SSL_MODE_FILE" config/Caddyfile
fi

if [ "$WITH_PHPMYADMIN" = true ]; then
  if [ "$PHPMYADMIN_PORT" = "$WORDPRESS_PORT" ]; then
    echo "Error: PHPMYADMIN_PORT (${PHPMYADMIN_PORT}) must differ from WORDPRESS_PORT (${WORDPRESS_PORT})." >&2
    echo "Set a free port in .env, e.g. PHPMYADMIN_PORT=8081" >&2
    exit 1
  fi
fi

# PHP conf.d snippet must exist before compose bind-mounts it.
write_php_ini_from_env

echo "==> Building and starting containers..."
if [ "$WITH_PHPMYADMIN" = true ] && [ -n "$SSL_MODE" ]; then
  $DC up -d --build --remove-orphans db wordpress caddy phpmyadmin
elif [ "$WITH_PHPMYADMIN" = true ]; then
  $DC up -d --build db wordpress phpmyadmin
elif [ -n "$SSL_MODE" ]; then
  $DC up -d --build --remove-orphans db wordpress caddy
else
  $DC up -d --build db wordpress
fi

wait_for_database
wait_for_wordpress

if [ -n "$SSL_MODE" ]; then
  echo "==> Waiting for Caddy..."
  ssl_attempts=0
  until $DC exec -T caddy caddy version >/dev/null 2>&1; do
    ssl_attempts=$((ssl_attempts + 1))
    if [ "$ssl_attempts" -gt 30 ]; then
      echo "Caddy did not become ready in time." >&2
      $DC logs caddy
      exit 1
    fi
    sleep 1
  done
  if [ "$SSL_MODE" = "local" ]; then
    trust_local_ssl_on_host || true
  fi
fi

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
$(if [ "$WITH_PHPMYADMIN" = true ]; then echo ""; echo "   phpMyAdmin:  http://localhost:${PHPMYADMIN_PORT}/"; fi)
$(if [ -n "$SSL_MODE" ]; then
  echo ""
  echo "   SSL:       ${SSL_MODE} (Caddy reverse proxy)"
  if [ "$SSL_MODE" = "global" ]; then
    echo "   Cert:      Let's Encrypt (${WP_ADMIN_EMAIL})"
  else
    echo "   Cert:      Caddy internal CA (in-container)"
    case "${LOCAL_SSL_TRUST_STATUS:-}" in
      trusted) echo "   Trust:     host trust store updated — restart the browser, then open the site" ;;
      manual)  echo "   Trust:     auto-import needs confirmation — see messages above / run ./wp.sh trust-ssl" ;;
      *)       echo "   Trust:     run ./wp.sh trust-ssl if the browser still shows Not secure" ;;
    esac
  fi
fi)

   Site:      ${WP_SITE_URL_RESOLVED}/
   wp-admin:  ${WP_SITE_URL_RESOLVED}/wp-admin/
   Username:  ${WP_ADMIN_USER}
   Password:  ${WP_ADMIN_PASSWORD}
$(if [ "$WITH_PHPMYADMIN" = true ]; then
  echo ""
  echo "   phpMyAdmin login:"
  echo "   Server:    db"
  echo "   Username:  root"
  echo "   Password:  ${MYSQL_ROOT_PASSWORD:-root}"
  echo ""
  echo "   WordPress DB user (optional):"
  echo "   Username:  ${WORDPRESS_DB_USER:-wordpress}"
  echo "   Password:  ${WORDPRESS_DB_PASSWORD:-wordpress}"
fi)
$(if [ -n "${WP_SITE_URL:-}" ] && [[ "$WP_SITE_URL_RESOLVED" != *"localhost"* ]]; then
  echo ""
  echo "   Hosts file:  map the domain on your machine, e.g."
  echo "                127.0.0.1  $(echo "$WP_SITE_URL_RESOLVED" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')"
fi)
$(if [ "$SSL_MODE" = "local" ]; then
  echo ""
  echo "   TLS terminates in the Caddy container. ./wp.sh local-ssl also exports"
  echo "   the CA and trusts it on this machine (Windows via WSL / macOS / Linux)."
  echo "   Fully quit and reopen the browser after a successful trust step."
  echo "   Re-run trust only:  ./wp.sh trust-ssl"
fi)
$(if [ "$SSL_MODE" = "global" ]; then
  echo ""
  echo "   Let's Encrypt: DNS for ${SITE_HOST} must point here, and"
  echo "   ports ${HTTP_PORT}/tcp and ${HTTPS_PORT}/tcp must be reachable."
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

   PHP uploads:       set PHP_UPLOAD_MAX_FILESIZE / PHP_POST_MAX_SIZE / etc. in
                       .env and run ./wp.sh sync (reloads Apache).

   Useful commands (run from this docker/ directory):
     ./wp.sh sync        # re-apply plugins, mu-plugins, themes, wp-config, uploads perms
     ./wp.sh shell       # interactive shell in the container
     ./wp.sh local-ssl   # start with local HTTPS
     ./wp.sh global-ssl  # start with Let's Encrypt HTTPS
     ./wp.sh phpmyadmin  # full setup plus phpMyAdmin
     ./wp.sh wp plugin list
     ./wp.sh exec ls -la /var/www/html/wp-content/plugins
     ./wp.sh logs        # follow WordPress container logs
     ./wp.sh down    # stop containers, keep data
     ./wp.sh reset   # stop containers and wipe all data
     ./wp.sh help    # show all commands
================================================================
EOF
