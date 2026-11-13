{{/* ===================================================================
     Names and labels
     =================================================================== */}}

{{- define "glpi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "glpi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "glpi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. Call with (dict "ctx" $ "component" "app") */}}
{{- define "glpi.labels" -}}
helm.sh/chart: {{ include "glpi.chart" .ctx }}
{{ include "glpi.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: glpi
{{- end }}

{{/* Pod template labels. Call with (dict "ctx" $ "component" "app")
     Only labels that stay the same across chart and app versions: any change
     to a pod template restarts its pods, so the chart and version labels stay
     on the Deployment and StatefulSet objects. Otherwise every chart upgrade
     would restart MariaDB even when nothing about it changed. */}}
{{- define "glpi.podLabels" -}}
{{ include "glpi.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: glpi
{{- end }}

{{/* Selector labels. Call with (dict "ctx" $ "component" "app") */}}
{{- define "glpi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "glpi.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* ===================================================================
     Images
     Call with (dict "image" .Values.image "default" .Chart.AppVersion)
     digest wins over tag; tag falls back to "default".
     =================================================================== */}}

{{- define "glpi.imageRef" -}}
{{- $tag := default .default .image.tag -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{/* ===================================================================
     Resource names
     =================================================================== */}}

{{- define "glpi.pvcName" -}}
{{- default (printf "%s-data" (include "glpi.fullname" .)) .Values.persistence.existingClaim -}}
{{- end }}

{{- define "glpi.mariadb.fullname" -}}
{{- printf "%s-mariadb" (include "glpi.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "glpi.mariadb.secretName" -}}
{{- default (include "glpi.mariadb.fullname" .) .Values.mariadb.auth.existingSecret -}}
{{- end }}

{{/* ===================================================================
     Database wiring: single place that decides built-in vs external
     =================================================================== */}}

{{- define "glpi.db.host" -}}
{{- if .Values.mariadb.enabled -}}
{{- include "glpi.mariadb.fullname" . -}}
{{- else -}}
{{- .Values.externalDatabase.host -}}
{{- end -}}
{{- end }}

{{- define "glpi.db.port" -}}
{{- if .Values.mariadb.enabled -}}3306{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end }}

{{- define "glpi.db.database" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.database }}{{- else -}}{{ .Values.externalDatabase.database }}{{- end -}}
{{- end }}

{{- define "glpi.db.username" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.username }}{{- else -}}{{ .Values.externalDatabase.username }}{{- end -}}
{{- end }}

{{- define "glpi.db.secretName" -}}
{{- if .Values.mariadb.enabled -}}{{ include "glpi.mariadb.secretName" . }}{{- else -}}{{ .Values.externalDatabase.existingSecret }}{{- end -}}
{{- end }}

{{- define "glpi.db.passwordKey" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.passwordKey }}{{- else -}}{{ .Values.externalDatabase.passwordKey }}{{- end -}}
{{- end }}

{{/* ===================================================================
     Generated secrets: reuse the in-cluster value if present, otherwise
     generate. Returns the base64-encoded value for a Secret's data field.
     Call with (dict "ctx" $ "name" <secret> "key" <key> "length" 32)
     =================================================================== */}}

{{- define "glpi.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- $data := dict -}}
{{- if $existing -}}{{- $data = default (dict) $existing.data -}}{{- end -}}
{{- if hasKey $data .key -}}
{{- index $data .key -}}
{{- else -}}
{{- randAlphaNum (int .length) | b64enc -}}
{{- end -}}
{{- end }}

{{/* ===================================================================
     Validation: fails the render with a clear message
     =================================================================== */}}

{{- define "glpi.validate" -}}
{{- with .Values.glpi.url -}}
{{- if not (regexMatch "^https?://" .) -}}
{{- fail "glpi.url must start with http:// or https:// (e.g. https://glpi.example.com)" -}}
{{- end -}}
{{- if hasSuffix "/" . -}}
{{- fail "glpi.url must not end with a slash" -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.glpi.uploadLimitMB) 1 -}}
{{- fail "glpi.uploadLimitMB must be a positive number of megabytes" -}}
{{- end -}}
{{- if regexMatch "(?m)^\\s*(upload_max_filesize|post_max_size)\\s*=" .Values.php.extraIni -}}
{{- fail "php.extraIni must not set upload_max_filesize or post_max_size, use glpi.uploadLimitMB" -}}
{{- end -}}
{{- if ne (int .Values.replicaCount) 1 -}}
{{- fail "replicaCount must be 1 (ReadWriteOnce data volume, Recreate strategy)" -}}
{{- end -}}
{{- if lt (int .Values.cron.intervalSeconds) 1 -}}
{{- fail "cron.intervalSeconds must be a positive number of seconds" -}}
{{- end -}}
{{- if not .Values.mariadb.enabled -}}
{{- if not .Values.externalDatabase.host -}}
{{- fail "externalDatabase.host is required when mariadb.enabled=false" -}}
{{- end -}}
{{- if not .Values.externalDatabase.existingSecret -}}
{{- fail "externalDatabase.existingSecret is required when mariadb.enabled=false" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* ===================================================================
     Container env and mounts, shared by the init, php-fpm and cron
     containers so they never drift.
     =================================================================== */}}

{{/* Database connection, read by wait-for-database and migrate. php-fpm and
     cron read config_db.php, which migrate writes from these. */}}
{{- define "glpi.dbEnv" -}}
- name: GLPI_DB_HOST
  value: {{ include "glpi.db.host" . | quote }}
- name: GLPI_DB_PORT
  value: {{ include "glpi.db.port" . | quote }}
- name: GLPI_DB_NAME
  value: {{ include "glpi.db.database" . | quote }}
- name: GLPI_DB_USER
  value: {{ include "glpi.db.username" . | quote }}
- name: GLPI_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "glpi.db.secretName" . }}
      key: {{ include "glpi.db.passwordKey" . }}
{{- end }}

{{/* extraEnvFrom / extraEnv for the GLPI containers. Renders nothing when
     both are empty. Call with (dict "ctx" $ "env" <list of extra EnvVars>) */}}
{{- define "glpi.appEnv" -}}
{{- $v := .ctx.Values -}}
{{- with $v.glpi.extraEnvFrom }}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $env := concat (default (list) .env) $v.glpi.extraEnv }}
{{- with $env }}
env:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "glpi.appMounts" -}}
volumeMounts:
  - { name: data, mountPath: /var/glpi }
  - { name: app-tmp, mountPath: /tmp }
  - { name: php-conf, mountPath: /etc/glpi/php.d, readOnly: true }
  - { name: glpi-conf, mountPath: /var/www/glpi/config/local_define.php, subPath: local_define.php, readOnly: true }
{{- end }}
