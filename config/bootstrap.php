<?php
/**
 * Loads host-managed wp-config snippets mounted at /docker-config/.
 */

$extra = __DIR__ . '/wp-config.extra.php';
if (is_readable($extra)) {
    require_once $extra;
}

foreach (glob(__DIR__ . '/wp-config.d/*.php') ?: [] as $snippet) {
    require_once $snippet;
}
