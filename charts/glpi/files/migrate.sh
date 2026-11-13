# Install GLPI into an empty database, or update an existing one. Run by the
# chart's migrate init container with `sh -c`, from /var/www/glpi.
#
# config_db.php is rewritten from the GLPI_DB_* environment on every start, so
# the chart values and Secret stay the single source of the connection.
set -eu

tables=$(php -r '
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = new mysqli(getenv("GLPI_DB_HOST"), getenv("GLPI_DB_USER"), getenv("GLPI_DB_PASSWORD"),
        getenv("GLPI_DB_NAME"), (int) getenv("GLPI_DB_PORT"));
    $r = $db->query("SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type = \"BASE TABLE\" AND table_name LIKE \"glpi\\_%\"");
    echo $r->fetch_row()[0];
')

set -- --no-interaction --reconfigure \
    --db-host="$GLPI_DB_HOST" --db-port="$GLPI_DB_PORT" --db-name="$GLPI_DB_NAME" \
    --db-user="$GLPI_DB_USER" --db-password="$GLPI_DB_PASSWORD"

if [ "$tables" = 0 ]; then
    echo "empty database: installing GLPI"
    php bin/console database:install "$@" --default-language="${GLPI_DEFAULT_LANGUAGE:-en_GB}" --no-telemetry
else
    echo "existing database ($tables GLPI tables): updating"
    php bin/console database:configure "$@"
    php bin/console database:update --no-interaction --no-telemetry
fi

if [ -n "${GLPI_URL:-}" ]; then
    php bin/console config:set url_base "$GLPI_URL"
fi
