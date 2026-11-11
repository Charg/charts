{{/*
Expand the name of the chart.
*/}}
{{- define "anki-sync-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "anki-sync-server.fullname" -}}
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
{{- define "anki-sync-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "anki-sync-server.labels" -}}
helm.sh/chart: {{ include "anki-sync-server.chart" . }}
{{ include "anki-sync-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for the helm test hook pod. Omits the selector labels so the Service never routes
traffic to the test pod itself.
*/}}
{{- define "anki-sync-server.testLabels" -}}
helm.sh/chart: {{ include "anki-sync-server.chart" . }}
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
{{- define "anki-sync-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "anki-sync-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "anki-sync-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "anki-sync-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the PersistentVolumeClaim mounted at /anki_data.
*/}}
{{- define "anki-sync-server.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "anki-sync-server.fullname" .) -}}
{{- end }}

{{/*
The container image reference. An explicit image.digest wins. With image.tag and image.digest
both empty, the appVersion image is pulled by the digest the chart was released with (the
charg.github.io/image-digest annotation), so a tag rebuilt in place cannot change what this
chart version deploys. An explicit image.tag alone pulls that tag as-is: the annotation's digest
belongs to appVersion and would silently override any other tag.
*/}}
{{- define "anki-sync-server.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- $digest := .Values.image.digest -}}
{{- if and (not $digest) (not .Values.image.tag) -}}
{{- $digest = index (.Chart.Annotations | default dict) "charg.github.io/image-digest" | default "" -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s:%s@%s" .Values.image.repository $tag $digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Name of the Secret holding SYNC_USER1..N: the operator's existingSecret, or the chart's own.
*/}}
{{- define "anki-sync-server.usersSecretName" -}}
{{- .Values.existingSecret | default (include "anki-sync-server.fullname" .) -}}
{{- end }}

{{/*
Environment variables derived from structured values. A value that defaults to null or "" is
treated as unset and renders no entry, leaving the server's own default in effect. SYNC_PORT
and SYNC_BASE are fixed by the image and deliberately never rendered.
*/}}
{{- define "anki-sync-server.structuredEnv" -}}
{{- if .Values.passwordsHashed }}
{{- /* The server checks only that PASSWORDS_HASHED is present, so "false" would still enable it. */}}
- name: PASSWORDS_HASHED
  value: "1"
{{- end }}
{{- with .Values.ipHeader }}
- name: SYNC_IP_HEADER
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .Values.maxPayloadMegs) }}
- name: MAX_SYNC_PAYLOAD_MEGS
  value: {{ .Values.maxPayloadMegs | toString | quote }}
{{- end }}
{{- with .Values.logLevel }}
- name: RUST_LOG
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
The container's full environment: the structured variables, then env in key order.
*/}}
{{- define "anki-sync-server.env" -}}
{{- include "anki-sync-server.structuredEnv" . }}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{/*
Template-time validation. Rendered (to nothing) by the Deployment so every failure surfaces on
`helm template` / `helm install` before anything reaches the cluster.
*/}}
{{- define "anki-sync-server.validate" -}}
{{- if and .Values.users .Values.existingSecret }}
{{- fail "set only one of users or existingSecret, not both" }}
{{- end }}
{{- if not (or .Values.users .Values.existingSecret) }}
{{- fail "set users (or existingSecret): the sync server refuses to start without at least one user" }}
{{- end }}
{{- $seen := dict }}
{{- range $i, $user := .Values.users }}
{{- if not (and $user.name $user.password) }}
{{- fail (printf "users[%d] needs both name and password" $i) }}
{{- end }}
{{- if contains ":" (toString $user.name) }}
{{- fail (printf "users[%d].name %q must not contain ':'" $i $user.name) }}
{{- end }}
{{- if hasKey $seen (toString $user.name) }}
{{- fail (printf "users[%d].name %q is listed twice; each user owns a folder under /anki_data" $i $user.name) }}
{{- end }}
{{- $_ := set $seen (toString $user.name) true }}
{{- end }}
{{- $ipSources := list "ConnectInfo" "RightmostXForwardedFor" "RightmostForwarded" "XRealIp" "CfConnectingIp" "TrueClientIp" "FlyClientIp" "CloudFrontViewerAddress" }}
{{- if and .Values.ipHeader (not (has .Values.ipHeader $ipSources)) }}
{{- fail (printf "ipHeader must be one of %s, got %q" (join ", " $ipSources) .Values.ipHeader) }}
{{- end }}
{{- if and .Values.maxPayloadMegs (lt (int .Values.maxPayloadMegs) 1) }}
{{- fail "maxPayloadMegs must be a positive integer" }}
{{- end }}
{{- /*
A key in env that the chart already renders would produce a duplicate variable (the later one
silently wins in Kubernetes); one the image fixes would break the healthcheck or move the data
off the volume; SYNC_USER<n> would collide with the users Secret.
*/}}
{{- $rendered := dict }}
{{- range (include "anki-sync-server.structuredEnv" . | fromYamlArray) }}
{{- $_ := set $rendered .name true }}
{{- end }}
{{- range $name, $_ := .Values.env }}
{{- if or (hasKey $rendered $name) (has $name (list "SYNC_PORT" "SYNC_BASE" "SYNC_HOST" "PASSWORDS_HASHED")) (regexMatch "^SYNC_USER[0-9]+$" $name) }}
{{- fail (printf "env.%s is set by the chart or fixed by the image; use the structured value instead, if there is one" $name) }}
{{- end }}
{{- end }}
{{- end }}
