<?php
/**
 * Dependency health probe, used three ways:
 *
 *  - web role:       an exact `location = /healthz` in nginx, served from outside the docroot
 *  - scheduler role: the router script of PHP's built-in server, so it answers every path
 *  - entrypoint:     run from the CLI, where it exits non-zero instead of printing a status
 *
 * It deliberately does not boot Symfony: a kernel.response listener in this app rewrites
 * every response status to 200, so no application route can report a broken database.
 */

function pms_probe(): array
{
    $url = getenv('DATABASE_URL');
    if ($url === false || $url === '') {
        $url = $_ENV['DATABASE_URL'] ?? $_SERVER['DATABASE_URL'] ?? '';
    }

    if ($url === '') {
        return [false, 'no-database-url'];
    }

    $parts = parse_url($url);
    if ($parts === false || !isset($parts['host'])) {
        return [false, 'bad-database-url'];
    }

    $name = isset($parts['path']) ? ltrim($parts['path'], '/') : '';
    $dsn  = sprintf(
        'mysql:host=%s;port=%d;charset=utf8mb4%s',
        $parts['host'],
        (int) ($parts['port'] ?? 3306),
        $name !== '' ? ';dbname=' . $name : ''
    );

    try {
        $pdo = new PDO(
            $dsn,
            isset($parts['user']) ? rawurldecode($parts['user']) : '',
            isset($parts['pass']) ? rawurldecode($parts['pass']) : '',
            [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_TIMEOUT            => 5,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_NUM,
            ]
        );
        $pdo->query('SELECT 1')->fetch();
    } catch (Throwable $e) {
        return [false, 'database-unavailable'];
    }

    return [true, 'ok'];
}

[$healthy, $status] = pms_probe();

if (PHP_SAPI === 'cli') {
    fwrite($healthy ? STDOUT : STDERR, $status . "\n");
    exit($healthy ? 0 : 1);
}

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');
if (!$healthy) {
    http_response_code(503);
}
echo $status . "\n";
