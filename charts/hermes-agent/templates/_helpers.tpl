{{/*
Expand the name of the chart.
*/}}
{{- define "hermes-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "hermes-agent.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hermes-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hermes-agent.labels" -}}
helm.sh/chart: {{ include "hermes-agent.chart" . }}
{{ include "hermes-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for the helm test hook pod. Omits the selector labels so the Service never routes
traffic to the test pod itself.
*/}}
{{- define "hermes-agent.testLabels" -}}
helm.sh/chart: {{ include "hermes-agent.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: test
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hermes-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hermes-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "hermes-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "hermes-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the PersistentVolumeClaim holding the data volume.
*/}}
{{- define "hermes-agent.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "hermes-agent.fullname" .) -}}
{{- end }}

{{/*
The image's HERMES_HOME. Not configurable: the image's init seeds, chowns and migrates exactly
this path before the gateway starts.
*/}}
{{- define "hermes-agent.dataPath" -}}
/opt/data
{{- end }}

{{/*
Where the managed scope is mounted (HERMES_MANAGED_DIR). Upstream's default, /etc/hermes, already
holds files baked into the image, so the chart mounts its own directory instead of shadowing it.
*/}}
{{- define "hermes-agent.managedDir" -}}
/etc/hermes-managed
{{- end }}

{{/*
The credentials the chart resolves from Secrets. Each entry names the managed .env variable, its
key in the chart-generated Secret, the inline value the chart turns into that Secret, the
operator-supplied existingSecret alternative, whether the feature using it is enabled, and the
value paths used in error messages. Every template that touches credentials ranges over this one
list.
*/}}
{{- define "hermes-agent.credentials" -}}
- env: API_SERVER_KEY
  key: api-server-key
  enabled: {{ .Values.apiServer.enabled }}
  value: {{ .Values.apiServer.key | toJson }}
  existingSecret: {{ .Values.apiServer.existingSecret | toJson }}
  optional: false
  valuePath: apiServer.key
  existingPath: apiServer.existingSecret.name
- env: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  key: dashboard-password
  enabled: {{ .Values.dashboard.enabled }}
  value: {{ .Values.dashboard.basicAuth.password | toJson }}
  existingSecret: {{ dict "name" .Values.dashboard.basicAuth.existingSecret.name "key" .Values.dashboard.basicAuth.existingSecret.passwordKey | toJson }}
  optional: false
  valuePath: dashboard.basicAuth.password
  existingPath: dashboard.basicAuth.existingSecret.name
- env: HERMES_DASHBOARD_BASIC_AUTH_SECRET
  key: dashboard-secret
  enabled: {{ .Values.dashboard.enabled }}
  value: {{ .Values.dashboard.basicAuth.secret | toJson }}
  existingSecret: {{ dict "name" .Values.dashboard.basicAuth.existingSecret.name "key" .Values.dashboard.basicAuth.existingSecret.secretKey | toJson }}
  {{- /* The signing secret is optional upstream, so an existingSecret may leave it out. */}}
  optional: true
  valuePath: dashboard.basicAuth.secret
  existingPath: dashboard.basicAuth.existingSecret.name
{{- end }}

{{/*
Whether the chart supplies the API server key, as opposed to leaving the image to generate one.
*/}}
{{- define "hermes-agent.hasApiKey" -}}
{{- if and .Values.apiServer.enabled (or .Values.apiServer.key .Values.apiServer.existingSecret.name) }}true{{ end }}
{{- end }}

{{/*
Name of the chart-generated Secret holding every inline credential value.
*/}}
{{- define "hermes-agent.secretName" -}}
{{- include "hermes-agent.fullname" . -}}
{{- end }}

{{/*
Whether the chart renders its own Secret, i.e. whether any enabled credential has an inline value.
*/}}
{{- define "hermes-agent.hasInlineCredentials" -}}
{{- range (include "hermes-agent.credentials" . | fromYamlArray) }}
{{- if and .enabled .value }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Every variable written to the managed .env, in order: the chart's own, then managedEnv. Each is a
Kubernetes env entry; the init container resolves them and writes the file.
*/}}
{{- define "hermes-agent.managedEnv" -}}
{{- if .Values.apiServer.enabled }}
- name: API_SERVER_ENABLED
  value: "true"
- name: API_SERVER_HOST
  value: 0.0.0.0
- name: API_SERVER_PORT
  value: {{ .Values.apiServer.port | toString | quote }}
{{- with .Values.apiServer.corsOrigins }}
- name: API_SERVER_CORS_ORIGINS
  value: {{ . | quote }}
{{- end }}
{{- with .Values.apiServer.modelName }}
- name: API_SERVER_MODEL_NAME
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- if .Values.dashboard.enabled }}
{{- with .Values.dashboard.publicUrl }}
- name: HERMES_DASHBOARD_PUBLIC_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.dashboard.basicAuth.username }}
- name: HERMES_DASHBOARD_BASIC_AUTH_USERNAME
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- range (include "hermes-agent.credentials" . | fromYamlArray) }}
{{- if .enabled }}
{{- if .value }}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ include "hermes-agent.secretName" $ }}
      key: {{ .key }}
{{- else if .existingSecret.name }}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret.name }}
      key: {{ .existingSecret.key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- with .Values.managedEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Plain container environment variables the chart sets itself. These are read by the image's s6
scripts before Hermes loads any .env, so they cannot live in the managed scope.
*/}}
{{- define "hermes-agent.env" -}}
- name: HERMES_MANAGED_DIR
  value: {{ include "hermes-agent.managedDir" . | quote }}
{{- if .Values.dashboard.enabled }}
- name: HERMES_DASHBOARD
  value: "1"
- name: HERMES_DASHBOARD_HOST
  value: 0.0.0.0
- name: HERMES_DASHBOARD_PORT
  value: {{ .Values.dashboard.port | toString | quote }}
{{- end }}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{/*
The endpoint the probes and the helm test target: the API server's public /health when it runs,
otherwise the dashboard's public /api/status. Empty when neither runs.
*/}}
{{- define "hermes-agent.probe" -}}
{{- if .Values.apiServer.enabled }}
port: api
path: /health
{{- else if .Values.dashboard.enabled }}
port: dashboard
path: /api/status
{{- end }}
{{- end }}

{{/*
Whether any HTTP port is exposed, i.e. whether a Service makes sense.
*/}}
{{- define "hermes-agent.hasPorts" -}}
{{- if or .Values.apiServer.enabled .Values.dashboard.enabled }}true{{ end }}
{{- end }}

{{/*
The Service port number for a named port (api or dashboard). Fails on an unknown or disabled one,
so a route can never point at a port the Service does not have.
*/}}
{{- define "hermes-agent.servicePort" -}}
{{- $ctx := index . 0 }}
{{- $port := index . 1 }}
{{- $where := index . 2 }}
{{- if eq $port "api" }}
{{- if not $ctx.Values.apiServer.enabled }}
{{- fail (printf "%s routes to the api port, but apiServer.enabled is false" $where) }}
{{- end }}
{{- $ctx.Values.service.apiPort }}
{{- else if eq $port "dashboard" }}
{{- if not $ctx.Values.dashboard.enabled }}
{{- fail (printf "%s routes to the dashboard port, but dashboard.enabled is false" $where) }}
{{- end }}
{{- $ctx.Values.service.dashboardPort }}
{{- else }}
{{- fail (printf "%s must be api or dashboard, got %q" $where (toString $port)) }}
{{- end }}
{{- end }}

{{/*
Template-time validation. Rendered (to nothing) by the Deployment so every failure surfaces on
`helm template` / `helm install` before anything reaches the cluster.
*/}}
{{- define "hermes-agent.validate" -}}
{{- range (include "hermes-agent.credentials" . | fromYamlArray) }}
{{- if and .value .existingSecret.name }}
{{- fail (printf "set only one of %s or %s, not both" .valuePath .existingPath) }}
{{- end }}
{{- end }}
{{- $api := .Values.apiServer }}
{{- if and $api.enabled $api.key (lt (len $api.key) 16) }}
{{- fail "apiServer.key must be at least 16 characters: Hermes refuses to start the API server with a shorter one" }}
{{- end }}
{{- /*
A name the chart writes itself would appear twice in the managed .env (or twice in the container
env), and which copy wins is not something to leave to chance.
*/}}
{{- $reserved := list "API_SERVER_ENABLED" "API_SERVER_HOST" "API_SERVER_PORT" "API_SERVER_KEY" "API_SERVER_CORS_ORIGINS" "API_SERVER_MODEL_NAME" "HERMES_DASHBOARD_PUBLIC_URL" "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "HERMES_DASHBOARD_BASIC_AUTH_SECRET" "HERMES_MANAGED_DIR" "HERMES_HOME" "HERMES_DASHBOARD" "HERMES_DASHBOARD_HOST" "HERMES_DASHBOARD_PORT" }}
{{- range $name, $_ := .Values.env }}
{{- if has $name $reserved }}
{{- fail (printf "env.%s is set by the chart; use its structured value instead (see values.yaml)" $name) }}
{{- end }}
{{- end }}
{{- $managedNames := list }}
{{- range $i, $entry := .Values.managedEnv }}
{{- if not (kindIs "map" $entry) }}
{{- fail (printf "managedEnv[%d] must be a {name, value} or {name, valueFrom} entry" $i) }}
{{- end }}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (toString ($entry.name | default ""))) }}
{{- fail (printf "managedEnv[%d].name must be a valid environment variable name" $i) }}
{{- end }}
{{- if has $entry.name $reserved }}
{{- fail (printf "managedEnv %s is set by the chart; use its structured value instead (see values.yaml)" $entry.name) }}
{{- end }}
{{- if has $entry.name $managedNames }}
{{- fail (printf "managedEnv %s is listed more than once" $entry.name) }}
{{- end }}
{{- if not (or (hasKey $entry "value") $entry.valueFrom) }}
{{- fail (printf "managedEnv %s needs a value or a valueFrom" $entry.name) }}
{{- end }}
{{- $managedNames = append $managedNames $entry.name }}
{{- end }}
{{- $basic := .Values.dashboard.basicAuth }}
{{- $basicPassword := or $basic.password $basic.existingSecret.name (has "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" $managedNames) }}
{{- if and .Values.dashboard.enabled $basic.username (not $basicPassword) }}
{{- fail "dashboard.basicAuth.username needs a password: dashboard.basicAuth.password, dashboard.basicAuth.existingSecret.name or a HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH managedEnv entry" }}
{{- end }}
{{- if and .Values.dashboard.enabled (or $basic.password $basic.existingSecret.name) (not $basic.username) }}
{{- fail "dashboard.basicAuth.username is required when a basic-auth password is set" }}
{{- end }}
{{- /*
Bound to 0.0.0.0, the dashboard refuses to start without an auth provider. Catch the missing
provider here rather than as a crash loop.
*/}}
{{- if .Values.dashboard.enabled }}
{{- $dashboardConfig := get (.Values.config | default dict) "dashboard" | default dict }}
{{- $hasProvider := or (and $basic.username $basicPassword) (has "HERMES_DASHBOARD_OAUTH_CLIENT_ID" $managedNames) (has "HERMES_DASHBOARD_OIDC_ISSUER" $managedNames) (and (kindIs "map" $dashboardConfig) (or (hasKey $dashboardConfig "basic_auth") (hasKey $dashboardConfig "oauth"))) }}
{{- if not $hasProvider }}
{{- fail "dashboard.enabled needs an auth provider: set dashboard.basicAuth, or HERMES_DASHBOARD_OAUTH_CLIENT_ID / HERMES_DASHBOARD_OIDC_ISSUER in managedEnv, or config.dashboard.basic_auth / config.dashboard.oauth (see README.md)" }}
{{- end }}
{{- end }}
{{- end }}
