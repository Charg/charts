{{/*
Expand the name of the chart.
*/}}
{{- define "vaultwarden.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "vaultwarden.fullname" -}}
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
{{- define "vaultwarden.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "vaultwarden.labels" -}}
helm.sh/chart: {{ include "vaultwarden.chart" . }}
{{ include "vaultwarden.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for the helm test hook pod. Omits the selector labels so the Service never routes
traffic to the test pod itself.
*/}}
{{- define "vaultwarden.testLabels" -}}
helm.sh/chart: {{ include "vaultwarden.chart" . }}
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
{{- define "vaultwarden.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vaultwarden.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "vaultwarden.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "vaultwarden.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the PersistentVolumeClaim mounted at /data.
*/}}
{{- define "vaultwarden.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "vaultwarden.fullname" .) -}}
{{- end }}

{{/*
URL path prefix every Vaultwarden route lives under: the path component of domain, without a
trailing slash, or empty when domain has none. Mirrors upstream's own docker/healthcheck.sh,
which derives the /alive URL from DOMAIN the same way.
*/}}
{{- define "vaultwarden.basePath" -}}
{{- regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://[^/]*" .Values.domain "" | trimSuffix "/" -}}
{{- end }}

{{/*
Container path the credential files are projected into. Not user-configurable: it is an
implementation detail of how the _FILE variables are wired.
*/}}
{{- define "vaultwarden.secretsMountPath" -}}
/run/secrets/vaultwarden
{{- end }}

{{/*
The credentials Vaultwarden reads from files. Each entry names the environment variable (the
chart renders <env>_FILE), the file name under the secrets mount, the inline value the chart
turns into its own Secret, and the operator-supplied existingSecret alternative. Every
template that touches credentials ranges over this one list, so adding a credential is a
single edit here plus its values.
*/}}
{{- define "vaultwarden.credentials" -}}
- env: ADMIN_TOKEN
  file: admin-token
  value: {{ .Values.admin.token | toJson }}
  existingSecret: {{ .Values.admin.existingSecret | toJson }}
  path: admin
  field: token
- env: DATABASE_URL
  file: database-url
  value: {{ .Values.database.url | toJson }}
  existingSecret: {{ .Values.database.existingSecret | toJson }}
  path: database
  field: url
- env: SMTP_PASSWORD
  file: smtp-password
  value: {{ .Values.smtp.password | toJson }}
  existingSecret: {{ .Values.smtp.existingSecret | toJson }}
  path: smtp
  field: password
- env: PUSH_INSTALLATION_KEY
  file: push-installation-key
  value: {{ .Values.push.installationKey | toJson }}
  existingSecret: {{ .Values.push.existingSecret | toJson }}
  path: push
  field: installationKey
- env: SSO_CLIENT_SECRET
  file: sso-client-secret
  value: {{ .Values.sso.clientSecret | toJson }}
  existingSecret: {{ .Values.sso.existingSecret | toJson }}
  path: sso
  field: clientSecret
{{- end }}

{{/*
Name of the chart-generated Secret holding every inline credential value.
*/}}
{{- define "vaultwarden.secretName" -}}
{{- include "vaultwarden.fullname" . -}}
{{- end }}

{{/*
Whether any credential is configured at all, i.e. whether the secrets volume is needed.
*/}}
{{- define "vaultwarden.hasCredentials" -}}
{{- range (include "vaultwarden.credentials" . | fromYamlArray) }}
{{- if or .value .existingSecret.name }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Whether the chart renders its own Secret, i.e. whether any credential has an inline value.
*/}}
{{- define "vaultwarden.hasInlineCredentials" -}}
{{- range (include "vaultwarden.credentials" . | fromYamlArray) }}
{{- if .value }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Environment variables derived from structured values. A value that defaults to null (Booleans,
Integers) or "" / [] (Strings, lists) is treated as unset and renders no entry at all, leaving
Vaultwarden's own default in effect.
*/}}
{{- define "vaultwarden.env" -}}
- name: ROCKET_PORT
  value: {{ .Values.containerPort | toString | quote }}
{{- with .Values.domain }}
- name: DOMAIN
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.signups.allowed) }}
- name: SIGNUPS_ALLOWED
  value: {{ .Values.signups.allowed | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.signups.verify) }}
- name: SIGNUPS_VERIFY
  value: {{ .Values.signups.verify | toString | quote }}
{{- end }}
{{- with (join "," .Values.signups.domainsWhitelist) }}
- name: SIGNUPS_DOMAINS_WHITELIST
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.invitations.allowed) }}
- name: INVITATIONS_ALLOWED
  value: {{ .Values.invitations.allowed | toString | quote }}
{{- end }}
{{- with .Values.invitations.orgName }}
- name: INVITATION_ORG_NAME
  value: {{ . | quote }}
{{- end }}
{{- with .Values.smtp.host }}
- name: SMTP_HOST
  value: {{ . | quote }}
{{- end }}
{{- with .Values.smtp.from }}
- name: SMTP_FROM
  value: {{ . | quote }}
{{- end }}
{{- with .Values.smtp.fromName }}
- name: SMTP_FROM_NAME
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.smtp.port) }}
- name: SMTP_PORT
  value: {{ .Values.smtp.port | toString | quote }}
{{- end }}
{{- with .Values.smtp.security }}
- name: SMTP_SECURITY
  value: {{ . | quote }}
{{- end }}
{{- with .Values.smtp.username }}
- name: SMTP_USERNAME
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.push.enabled) }}
- name: PUSH_ENABLED
  value: {{ .Values.push.enabled | toString | quote }}
{{- end }}
{{- with .Values.push.installationId }}
- name: PUSH_INSTALLATION_ID
  value: {{ . | quote }}
{{- end }}
{{- with .Values.push.relayUri }}
- name: PUSH_RELAY_URI
  value: {{ . | quote }}
{{- end }}
{{- with .Values.push.identityUri }}
- name: PUSH_IDENTITY_URI
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.enabled) }}
- name: SSO_ENABLED
  value: {{ .Values.sso.enabled | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.only) }}
- name: SSO_ONLY
  value: {{ .Values.sso.only | toString | quote }}
{{- end }}
{{- with .Values.sso.authority }}
- name: SSO_AUTHORITY
  value: {{ . | quote }}
{{- end }}
{{- with .Values.sso.clientId }}
- name: SSO_CLIENT_ID
  value: {{ . | quote }}
{{- end }}
{{- with (join " " .Values.sso.scopes) }}
- name: SSO_SCOPES
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.pkce) }}
- name: SSO_PKCE
  value: {{ .Values.sso.pkce | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.signupsMatchEmail) }}
- name: SSO_SIGNUPS_MATCH_EMAIL
  value: {{ .Values.sso.signupsMatchEmail | toString | quote }}
{{- end }}
{{- range (include "vaultwarden.credentials" . | fromYamlArray) }}
{{- if or .value .existingSecret.name }}
- name: {{ printf "%s_FILE" .env }}
  value: {{ printf "%s/%s" (include "vaultwarden.secretsMountPath" $) .file | quote }}
{{- end }}
{{- end }}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{/*
Template-time validation. Rendered (to nothing) by the Deployment so every failure surfaces on
`helm template` / `helm install` before anything reaches the cluster.
*/}}
{{- define "vaultwarden.validate" -}}
{{- range (include "vaultwarden.credentials" . | fromYamlArray) }}
{{- if and .value .existingSecret.name }}
{{- fail (printf "%s: set only one of %s or existingSecret.name, not both" .path .field) }}
{{- end }}
{{- end }}
{{- if and .Values.domain (not (regexMatch "^https?://[^/]+" .Values.domain)) }}
{{- fail (printf "domain must be a full URL starting with http:// or https://, got %q" .Values.domain) }}
{{- end }}
{{- if and .Values.smtp.security (not (has .Values.smtp.security (list "starttls" "force_tls" "off"))) }}
{{- fail (printf "smtp.security must be one of starttls, force_tls, off, got %q" .Values.smtp.security) }}
{{- end }}
{{- if and .Values.smtp.host (not .Values.smtp.from) }}
{{- fail "smtp.from is required when smtp.host is set" }}
{{- end }}
{{- if and .Values.push.enabled (not (and .Values.push.installationId (or .Values.push.installationKey .Values.push.existingSecret.name))) }}
{{- fail "push.enabled requires push.installationId and one of push.installationKey or push.existingSecret.name" }}
{{- end }}
{{- if and .Values.sso.enabled (not (and .Values.sso.authority .Values.sso.clientId)) }}
{{- fail "sso.enabled requires sso.authority and sso.clientId" }}
{{- end }}
{{- /*
A key in env that the chart already renders would produce a duplicate variable (the later one
silently wins in Kubernetes), and the plain form of a file-mounted credential would make
Vaultwarden panic at start ("You should not define both X and X_FILE"). Catch both here.
*/}}
{{- $counts := dict }}
{{- range (include "vaultwarden.env" . | fromYamlArray) }}
{{- $_ := set $counts .name (add1 (get $counts .name | default 0)) }}
{{- end }}
{{- range (include "vaultwarden.credentials" . | fromYamlArray) }}
{{- if or .value .existingSecret.name }}
{{- $_ := set $counts .env 2 }}
{{- end }}
{{- end }}
{{- range $name, $_ := .Values.env }}
{{- if gt (int (get $counts $name)) 1 }}
{{- fail (printf "env.%s conflicts with a variable the chart already sets from a structured value; set it there instead" $name) }}
{{- end }}
{{- end }}
{{- end }}
