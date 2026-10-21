{{/*
Expand the name of the chart.
*/}}
{{- define "anythingllm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "anythingllm.fullname" -}}
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
{{- define "anythingllm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "anythingllm.labels" -}}
helm.sh/chart: {{ include "anythingllm.chart" . }}
{{ include "anythingllm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for the helm test hook pod. Omits the selector labels so the Service never routes
traffic to the test pod itself.
*/}}
{{- define "anythingllm.testLabels" -}}
helm.sh/chart: {{ include "anythingllm.chart" . }}
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
{{- define "anythingllm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "anythingllm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "anythingllm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "anythingllm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the PersistentVolumeClaim holding the data volume.
*/}}
{{- define "anythingllm.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "anythingllm.fullname" .) -}}
{{- end }}

{{/*
Where the image expects its storage. Not configurable: the SQLite path is hardcoded in upstream's
Prisma schema as server/storage/anythingllm.db, and the server locates the collector's upload
directory relative to STORAGE_DIR, so any other mount path breaks one or the other.
*/}}
{{- define "anythingllm.storagePath" -}}
/app/server/storage
{{- end }}

{{/*
The .env file the server loads on start and rewrites whenever a setting is saved in the UI.
*/}}
{{- define "anythingllm.envFilePath" -}}
/app/server/.env
{{- end }}

{{/*
The credentials passed as Secret-backed environment variables. Each entry names the variable,
its key in the chart-generated Secret, the inline value the chart turns into that Secret, the
operator-supplied existingSecret alternative, and the value paths used in error messages. Every
template that touches credentials ranges over this one list.
*/}}
{{- define "anythingllm.credentials" -}}
- env: JWT_SECRET
  key: jwt-secret
  value: {{ .Values.auth.jwtSecret | toJson }}
  existingSecret: {{ .Values.auth.jwtSecretExistingSecret | toJson }}
  valuePath: auth.jwtSecret
  existingPath: auth.jwtSecretExistingSecret.name
- env: AUTH_TOKEN
  key: auth-token
  value: {{ .Values.auth.password | toJson }}
  existingSecret: {{ .Values.auth.passwordExistingSecret | toJson }}
  valuePath: auth.password
  existingPath: auth.passwordExistingSecret.name
- env: SIG_KEY
  key: sig-key
  value: {{ .Values.encryption.key | toJson }}
  existingSecret: {{ dict "name" .Values.encryption.existingSecret.name "key" .Values.encryption.existingSecret.keyKey | toJson }}
  valuePath: encryption.key
  existingPath: encryption.existingSecret.name
- env: SIG_SALT
  key: sig-salt
  value: {{ .Values.encryption.salt | toJson }}
  existingSecret: {{ dict "name" .Values.encryption.existingSecret.name "key" .Values.encryption.existingSecret.saltKey | toJson }}
  valuePath: encryption.salt
  existingPath: encryption.existingSecret.name
{{- end }}

{{/*
Name of the chart-generated Secret holding every inline credential value.
*/}}
{{- define "anythingllm.secretName" -}}
{{- include "anythingllm.fullname" . -}}
{{- end }}

{{/*
Whether the chart renders its own Secret, i.e. whether any credential has an inline value.
*/}}
{{- define "anythingllm.hasInlineCredentials" -}}
{{- range (include "anythingllm.credentials" . | fromYamlArray) }}
{{- if .value }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Environment variables the chart sets itself. Credentials are always secretKeyRefs, never literals.
*/}}
{{- define "anythingllm.env" -}}
- name: SERVER_PORT
  value: {{ .Values.containerPort | toString | quote }}
- name: STORAGE_DIR
  value: {{ include "anythingllm.storagePath" . | quote }}
- name: DISABLE_TELEMETRY
  value: {{ .Values.disableTelemetry | toString | quote }}
{{- range (include "anythingllm.credentials" . | fromYamlArray) }}
{{- if .value }}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ include "anythingllm.secretName" $ }}
      key: {{ .key }}
{{- else if .existingSecret.name }}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret.name }}
      key: {{ .existingSecret.key }}
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
{{- define "anythingllm.validate" -}}
{{- range (include "anythingllm.credentials" . | fromYamlArray) }}
{{- if and .value .existingSecret.name }}
{{- fail (printf "set only one of %s or %s, not both" .valuePath .existingPath) }}
{{- end }}
{{- end }}
{{- if and .Values.auth.jwtSecret (lt (len .Values.auth.jwtSecret) 12) }}
{{- fail "auth.jwtSecret must be at least 12 characters" }}
{{- end }}
{{- /*
AnythingLLM regenerates both halves whenever either is missing, so a lone key or salt would
silently rotate the encryption key on every start.
*/}}
{{- if ne (empty .Values.encryption.key) (empty .Values.encryption.salt) }}
{{- fail "encryption.key and encryption.salt must be set together" }}
{{- end }}
{{- /*
A key in env that the chart already renders would produce a duplicate variable (the later one
silently wins in Kubernetes). Credentials are refused even when unset here, so they never end up
as a literal in the pod spec.
*/}}
{{- $reserved := list "SERVER_PORT" "STORAGE_DIR" "DISABLE_TELEMETRY" }}
{{- range (include "anythingllm.credentials" . | fromYamlArray) }}
{{- $reserved = append $reserved .env }}
{{- end }}
{{- range $name, $_ := .Values.env }}
{{- if has $name $reserved }}
{{- fail (printf "env.%s is set by the chart; use its structured value instead (see values.yaml)" $name) }}
{{- end }}
{{- end }}
{{- end }}
