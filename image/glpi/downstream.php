<?php

// Data paths for this image. GLPI loads this file after the environment and
// config/local_define.php, so either of those can still override a path.
defined('GLPI_CONFIG_DIR')      || define('GLPI_CONFIG_DIR', '/var/glpi/config');
defined('GLPI_VAR_DIR')         || define('GLPI_VAR_DIR', '/var/glpi/files');
defined('GLPI_LOG_DIR')         || define('GLPI_LOG_DIR', '/var/glpi/logs');
defined('GLPI_MARKETPLACE_DIR') || define('GLPI_MARKETPLACE_DIR', '/var/glpi/marketplace');
