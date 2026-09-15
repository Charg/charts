{{/*
Expand the name of the chart.
*/}}
{{- define "technitium-dns-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "technitium-dns-server.fullname" -}}
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
{{- define "technitium-dns-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "technitium-dns-server.labels" -}}
helm.sh/chart: {{ include "technitium-dns-server.chart" . }}
{{ include "technitium-dns-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for the helm test hook pods. Deliberately omits the selector labels: with
podAntiAffinity set to required, a hook pod carrying them is repelled from every node already
running a replica, so it sits Pending forever once replicas equal the number of schedulable
nodes.
*/}}
{{- define "technitium-dns-server.testLabels" -}}
helm.sh/chart: {{ include "technitium-dns-server.chart" . }}
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
{{- define "technitium-dns-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "technitium-dns-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "technitium-dns-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "technitium-dns-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the headless governing Service required by the StatefulSet.
*/}}
{{- define "technitium-dns-server.headlessServiceName" -}}
{{- printf "%s-headless" (include "technitium-dns-server.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of the Secret backing DNS_SERVER_ADMIN_PASSWORD_FILE: the chart-generated Secret when
auth.adminPassword is set, or the operator-supplied auth.existingSecret.name otherwise.
*/}}
{{- define "technitium-dns-server.adminPasswordSecretName" -}}
{{- if .Values.auth.existingSecret.name -}}
{{- .Values.auth.existingSecret.name -}}
{{- else -}}
{{- printf "%s-admin-password" (include "technitium-dns-server.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Key within the admin password Secret holding the password.
*/}}
{{- define "technitium-dns-server.adminPasswordSecretKey" -}}
{{- .Values.auth.existingSecret.key | default "password" -}}
{{- end }}

{{/*
Container path the admin password Secret is mounted at. Not user-configurable: it is an
implementation detail of how the _FILE variable is wired, not something an operator ever needs
to change.
*/}}
{{- define "technitium-dns-server.adminPasswordMountPath" -}}
/etc/technitium-secrets/admin-password
{{- end }}

{{/*
Name of the Secret backing DNS_SERVER_SSO_CLIENT_SECRET_FILE: the chart-generated Secret when
sso.clientSecret is set, or the operator-supplied sso.existingSecret.name otherwise.
*/}}
{{- define "technitium-dns-server.ssoClientSecretName" -}}
{{- if .Values.sso.existingSecret.name -}}
{{- .Values.sso.existingSecret.name -}}
{{- else -}}
{{- printf "%s-sso-client-secret" (include "technitium-dns-server.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Key within the SSO client secret Secret holding the value.
*/}}
{{- define "technitium-dns-server.ssoClientSecretKey" -}}
{{- .Values.sso.existingSecret.key | default "client-secret" -}}
{{- end }}

{{/*
Container path the SSO client secret Secret is mounted at.
*/}}
{{- define "technitium-dns-server.ssoClientSecretMountPath" -}}
/etc/technitium-secrets/sso-client-secret
{{- end }}

{{/*
DNS_SERVER_* environment variables derived from structured values. Technitium's Docker image
reads every one of these only when /etc/dns has no config file yet, i.e. on a replica's first
boot; changing a value and running `helm upgrade` does not reconfigure an already-initialized
server (see the README and NOTES.txt). A value that defaults to null (Booleans, and Integers
where 0 is a meaningful setting rather than "off") or "" (Strings and comma-separated lists) is
treated as unset and produces no entry at all, rather than an empty string: on first boot an
absent variable and an explicitly empty one are not the same thing to Technitium.
*/}}
{{- define "technitium-dns-server.env" -}}
{{- with .Values.server.domain }}
- name: DNS_SERVER_DOMAIN
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.server.preferIPv6) }}
- name: DNS_SERVER_PREFER_IPV6
  value: {{ .Values.server.preferIPv6 | toString | quote }}
{{- end }}
{{- if or .Values.auth.adminPassword .Values.auth.existingSecret.name }}
- name: DNS_SERVER_ADMIN_PASSWORD_FILE
  value: {{ printf "%s/password" (include "technitium-dns-server.adminPasswordMountPath" .) | quote }}
{{- end }}
{{- with (join "," .Values.webService.localAddresses) }}
- name: DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES
  value: {{ . | quote }}
{{- end }}
{{- /*
service.webPort/httpsPort double as both the Kubernetes Service/container port declarations and
the app's first-boot bind port, so there is no separate webService.httpPort value to drift out of
sync with them: whatever the Service exposes is exactly what the container is told to bind.
*/}}
- name: DNS_SERVER_WEB_SERVICE_HTTP_PORT
  value: {{ .Values.service.webPort | toString | quote }}
- name: DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS
  value: {{ .Values.webService.enableHttps | toString | quote }}
{{- if .Values.webService.enableHttps }}
- name: DNS_SERVER_WEB_SERVICE_HTTPS_PORT
  value: {{ .Values.service.httpsPort | toString | quote }}
- name: DNS_SERVER_WEB_SERVICE_USE_SELF_SIGNED_CERT
  value: {{ .Values.webService.useSelfSignedCert | toString | quote }}
{{- end }}
{{- with .Values.webService.tlsCertificatePath }}
- name: DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PATH
  value: {{ . | quote }}
{{- end }}
{{- with .Values.webService.tlsCertificatePassword }}
- name: DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PASSWORD
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.webService.httpToTlsRedirect) }}
- name: DNS_SERVER_WEB_SERVICE_HTTP_TO_TLS_REDIRECT
  value: {{ .Values.webService.httpToTlsRedirect | toString | quote }}
{{- end }}
{{- with (join "," .Values.webService.reverseProxyAddresses) }}
- name: DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.optionalProtocol.dnsOverHttp) }}
- name: DNS_SERVER_OPTIONAL_PROTOCOL_DNS_OVER_HTTP
  value: {{ .Values.optionalProtocol.dnsOverHttp | toString | quote }}
{{- end }}
{{- with .Values.recursion.mode }}
- name: DNS_SERVER_RECURSION
  value: {{ . | quote }}
{{- end }}
{{- with (join "," .Values.recursion.networkAcl) }}
- name: DNS_SERVER_RECURSION_NETWORK_ACL
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.blocking.enabled) }}
- name: DNS_SERVER_ENABLE_BLOCKING
  value: {{ .Values.blocking.enabled | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.blocking.allowTxtBlockingReport) }}
- name: DNS_SERVER_ALLOW_TXT_BLOCKING_REPORT
  value: {{ .Values.blocking.allowTxtBlockingReport | toString | quote }}
{{- end }}
{{- with (join "," .Values.blocking.blockListUrls) }}
- name: DNS_SERVER_BLOCK_LIST_URLS
  value: {{ . | quote }}
{{- end }}
{{- with (join "," .Values.forwarders.servers) }}
- name: DNS_SERVER_FORWARDERS
  value: {{ . | quote }}
{{- end }}
{{- with .Values.forwarders.protocol }}
- name: DNS_SERVER_FORWARDER_PROTOCOL
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.logging.useLocalTime) }}
- name: DNS_SERVER_LOG_USING_LOCAL_TIME
  value: {{ .Values.logging.useLocalTime | toString | quote }}
{{- end }}
{{- with .Values.logging.folderPath }}
- name: DNS_SERVER_LOG_FOLDER_PATH
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.logging.maxLogFileDays) }}
- name: DNS_SERVER_LOG_MAX_LOG_FILE_DAYS
  value: {{ .Values.logging.maxLogFileDays | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.stats.enableInMemoryStats) }}
- name: DNS_SERVER_STATS_ENABLE_IN_MEMORY_STATS
  value: {{ .Values.stats.enableInMemoryStats | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.stats.maxStatFileDays) }}
- name: DNS_SERVER_STATS_MAX_STAT_FILE_DAYS
  value: {{ .Values.stats.maxStatFileDays | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.enabled) }}
- name: DNS_SERVER_SSO_ENABLED
  value: {{ .Values.sso.enabled | toString | quote }}
{{- end }}
{{- with .Values.sso.authority }}
- name: DNS_SERVER_SSO_AUTHORITY
  value: {{ . | quote }}
{{- end }}
{{- with .Values.sso.clientId }}
- name: DNS_SERVER_SSO_CLIENT_ID
  value: {{ . | quote }}
{{- end }}
{{- if or .Values.sso.clientSecret .Values.sso.existingSecret.name }}
- name: DNS_SERVER_SSO_CLIENT_SECRET_FILE
  value: {{ printf "%s/client-secret" (include "technitium-dns-server.ssoClientSecretMountPath" .) | quote }}
{{- end }}
{{- with .Values.sso.metadataAddress }}
- name: DNS_SERVER_SSO_METADATA_ADDRESS
  value: {{ . | quote }}
{{- end }}
{{- with (join "," .Values.sso.scopes) }}
- name: DNS_SERVER_SSO_SCOPES
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.allowSignup) }}
- name: DNS_SERVER_SSO_ALLOW_SIGNUP
  value: {{ .Values.sso.allowSignup | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.sso.allowSignupOnlyForMappedUsers) }}
- name: DNS_SERVER_SSO_ALLOW_SIGNUP_ONLY_FOR_MAPPED_USERS
  value: {{ .Values.sso.allowSignupOnlyForMappedUsers | toString | quote }}
{{- end }}
{{- $groupMapPairs := list }}
{{- range .Values.sso.groupMap }}
{{- $groupMapPairs = append $groupMapPairs (printf "%s:%s" .remote .local) }}
{{- end }}
{{- with (join "," $groupMapPairs) }}
- name: DNS_SERVER_SSO_GROUP_MAP
  value: {{ . | quote }}
{{- end }}
{{- end }}
