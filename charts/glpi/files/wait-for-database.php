<?php
// Wait until the database accepts a login, so the install or update does not
// start against a server that is still initialising. The chart runs this with
// `php -r`. It reads the same GLPI_DB_* environment as the migrate step.
//
// Retries connection failures until WAIT_TIMEOUT seconds have passed. Fails at
// once on errors that waiting cannot fix: bad credentials or a missing database.

$timeout = (int) (getenv('WAIT_TIMEOUT') ?: 300);
$deadline = time() + $timeout;
$host = getenv('GLPI_DB_HOST') ?: 'localhost';
$port = (int) (getenv('GLPI_DB_PORT') ?: 3306);
$name = getenv('GLPI_DB_NAME') ?: '';

// MySQL/MariaDB server error codes that are permanent.
$fatal = [
    1044 => 'access denied to the database',
    1045 => 'access denied (check the username and password)',
    1049 => 'unknown database',
];

mysqli_report(MYSQLI_REPORT_OFF);
$attempt = 0;
$last = '';
while (true) {
    $attempt++;
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
    if (@$db->real_connect($host, getenv('GLPI_DB_USER') ?: '', getenv('GLPI_DB_PASSWORD') ?: '', $name, $port)) {
        fwrite(STDOUT, "database {$host}:{$port}/{$name} is ready (attempt {$attempt})\n");
        exit(0);
    }
    $code = $db->connect_errno;
    $message = (string) $db->connect_error;
    if (isset($fatal[$code])) {
        fwrite(STDERR, "database {$host}:{$port}/{$name}: {$fatal[$code]}: {$message}\n");
        exit(1);
    }
    // Log the first failure, any change, and every 15th attempt (~30 s).
    if ($message !== $last || $attempt % 15 === 1) {
        fwrite(STDERR, "waiting for database {$host}:{$port}: {$message}\n");
        $last = $message;
    }
    if (time() >= $deadline) {
        fwrite(STDERR, "database {$host}:{$port} not ready after {$timeout}s, giving up\n");
        exit(1);
    }
    sleep(2);
}
