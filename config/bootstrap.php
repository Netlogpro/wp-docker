<?php
/**
 * Loads host-managed wp-config snippets mounted at /docker-config/.
 */

// Trust reverse-proxy HTTPS headers (Caddy). Harmless when not behind a proxy.
if (
    (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')
    || (isset($_SERVER['HTTP_X_FORWARDED_SSL']) && $_SERVER['HTTP_X_FORWARDED_SSL'] === 'on')
) {
    $_SERVER['HTTPS'] = 'on';
}

$extra = __DIR__ . '/wp-config.extra.php';
if (is_readable($extra)) {
    require_once $extra;
}

foreach (glob(__DIR__ . '/wp-config.d/*.php') ?: [] as $snippet) {
    require_once $snippet;
}
