# vaultwarden

[Vaultwarden](https://github.com/dani-garcia/vaultwarden), the unofficial Bitwarden-compatible
password manager server, deployed as a single-replica Deployment with the web vault, the admin
panel, SSO, SMTP and mobile push all configurable from values.

## Install

```bash
helm install vault oci://ghcr.io/charg/charts/vaultwarden \
  --set domain=https://vault.example.com
```

Set `domain` to the exact URL clients reach the server at. WebAuthn/passkeys, attachment
downloads and every link in an email are derived from it, and the browser only exposes the
crypto APIs the web vault needs over `https://` (or `localhost`), so put it behind TLS
(`ingress` or `httpRoute`) before relying on it.

## Configuration precedence: the admin panel wins

Vaultwarden reads its settings from environment variables, which is what this chart renders.
Settings saved through the admin panel (`/admin`) are written to `/data/config.json`, and
Vaultwarden gives **that file priority over the environment**. Once a value has been saved in
the panel, changing it here and running `helm upgrade` has no effect until the override is reset
in the panel (or `config.json` removed).

Pick one source of truth. Either manage settings here and use the admin panel only to look,
or leave `admin.token` unset, which disables the panel entirely, Vaultwarden's own behaviour when
there is no admin token. The same warning is printed after every install and upgrade.

## Single replica, by design

There is no `replicaCount`. The default SQLite database sits on a `ReadWriteOnce` volume,
attachments and sends are written to that same `/data` volume even with an external database,
and live sync notifications (WebSocket) are held in process memory. A second replica would
fail to mount the volume, or serve stale state to whichever clients land on it. For the same
reason `strategy` defaults to `Recreate`: the old pod releases the volume before the new one
starts.

## Secrets

Every credential is mounted as a file and passed as Vaultwarden's `<NAME>_FILE` variant, never
as a plain environment variable, so it does not appear in the pod spec or in the process
environment (`kubectl exec ... env`, crash dumps):

| Value | Existing Secret alternative | Variable |
| ----- | --------------------------- | -------- |
| `admin.token` | `admin.existingSecret` | `ADMIN_TOKEN_FILE` |
| `database.url` | `database.existingSecret` | `DATABASE_URL_FILE` |
| `smtp.password` | `smtp.existingSecret` | `SMTP_PASSWORD_FILE` |
| `push.installationKey` | `push.existingSecret` | `PUSH_INSTALLATION_KEY_FILE` |
| `sso.clientSecret` | `sso.existingSecret` | `SSO_CLIENT_SECRET_FILE` |

Each credential comes from either an inline value (the chart puts it in a Secret of its own) or
an existing Secret you manage (`name` and `key`), never both: setting both fails the template.
Inline and existing sources can be mixed freely across credentials. When an inline value
changes, the pod rolls automatically. A change to an existing Secret needs a manual
`kubectl rollout restart`, because Vaultwarden reads these files only at start.

Use an Argon2 PHC string for `admin.token`, not a plain token. Generate one with
`docker run --rm -it vaultwarden/server /vaultwarden hash`. The `$` characters need no escaping
here (unlike in a docker-compose file), since the value is written to a file, not interpolated.

```yaml
admin:
  existingSecret:
    name: vaultwarden-admin
    key: token
smtp:
  host: smtp.example.com
  from: vault@example.com
  username: vault@example.com
  existingSecret:
    name: vaultwarden-smtp
    key: password
```

## Database

Leaving `database.url` and `database.existingSecret` unset uses SQLite at
`/data/db.sqlite3`, Vaultwarden's default and right for most installs. For PostgreSQL or
MySQL, supply the full connection URL. With CloudNativePG, the operator's generated
`<cluster>-app` Secret already carries one:

```yaml
database:
  existingSecret:
    name: vaultwarden-db-app
    key: uri
```

Switching an existing install from SQLite to another database is a data migration, not a
values change. Vaultwarden does not move data between backends on its own.

## Any other setting

The structured values cover what most installs need. Every other Vaultwarden setting (see
upstream's [`.env.template`](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template))
goes in `env` as a flat map:

```yaml
env:
  DISABLE_ICON_DOWNLOAD: "true"
  IP_HEADER: X-Forwarded-For
  LOG_LEVEL: warn
```

A key in `env` that the chart already renders from a structured value (`DOMAIN`,
`SIGNUPS_ALLOWED`, ...) fails the template, so the two can never silently disagree. So does the
plain form of a credential the chart mounts as a file (e.g. `ADMIN_TOKEN` alongside
`admin.token`): Vaultwarden refuses to start when both `X` and `X_FILE` are set. Use
`extraEnvVars` for `valueFrom` references and `extraEnvFrom` to load a whole ConfigMap or Secret.

## Serving under a sub-path

Give `domain` a path (`https://example.com/vault`) and Vaultwarden serves every route under it.
The chart's probes and `helm test` follow the same prefix automatically. Route the matching
path to the Service with `ingress` or `httpRoute`.

## Exposing it

`ingress` renders a standard `networking.k8s.io/v1` Ingress. `httpRoute` renders a Gateway API
`HTTPRoute` (requires the Gateway API CRDs). Both target the one HTTP Service port, which also
carries WebSocket notifications (Vaultwarden 1.29+ serves both on the same port, so no separate
`/notifications/hub` route is needed).

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public
      namespace: gateway
      sectionName: https
  hostnames:
    - vault.example.com
```

## Running unprivileged

The chart runs Vaultwarden unprivileged by default, meeting the `restricted`
[Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/):
uid/gid `1000`, no capabilities, no privilege escalation, `RuntimeDefault` seccomp and a
read-only root filesystem. Upstream's image runs as root, but works as any user: the container
listens on `8080` (sent as `ROCKET_PORT`), which needs no privileges, and the only writable paths
it needs are `/data` and `/tmp` (an `emptyDir` the chart always mounts).

`fsGroup` is what makes both the data volume and the mounted credential files (mode `0440`,
owned by root) readable by the non-root user. Storage that ignores `fsGroup` (hostPath-backed
provisioners such as `local-path`) needs the volume's ownership fixed by hand first.

### Upgrading from 0.1.x

Chart versions before 0.2.0 ran the image as root. On an existing install, either:

- let `fsGroup` re-own the volume: on storage that honours it, the first pod after the upgrade
  makes `/data` group-writable by gid `1000`, and nothing else is needed; or
- on storage that ignores `fsGroup`, `chown -R 1000:1000` the volume's contents once (for
  instance from a throwaway root pod mounting the claim) before upgrading; or
- keep running as root by setting `podSecurityContext: null` and `securityContext: null`. It has
  to be `null`: Helm merges a map from your values into the chart's defaults, so `{}` changes
  nothing.

Remove any `/tmp` entry from `extraVolumes`/`extraVolumeMounts` that the old hardened example
added: the chart now mounts its own, and refuses to render a second one.

## Network policy

`networkPolicy.enabled` renders a NetworkPolicy that admits traffic only to the HTTP port. Narrow
the sources with `ingressFrom`, typically to your ingress controller or Gateway namespace:

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Egress is left open unless `restrictEgress` is set, because Vaultwarden calls out to SMTP, the
push relay, the SSO provider, icon sites and an external database, all of which depend on your
configuration. With it set, only DNS is allowed; add an `extraEgress` rule for each of those.

## Persistence

`/data` holds the SQLite database, attachments, sends, the RSA signing keys, the icon cache and
`config.json`. The chart-created claim carries `helm.sh/resource-policy: keep` by default, so
`helm uninstall` leaves it behind; delete it by hand once it is genuinely no longer needed.

### Adopting an existing volume

Point `persistence.existingClaim` at a claim that already holds a Vaultwarden `/data` directory,
e.g. when moving an install that was set up some other way onto this chart:

```yaml
persistence:
  existingClaim: vaultwarden
```

Data written by a root-run image is owned by root: see [Upgrading from 0.1.x](#upgrading-from-01x)
for making it writable by the chart's default non-root user. Back up `/data` (or the database) before the first upgrade onto this chart either way.

## Upgrades

`appVersion` tracks upstream's releases (Renovate opens a PR for each one), and `image.tag`
defaults to it. Vaultwarden runs any database migrations at start, which is why the startup
probe allows up to five minutes by default (`startupProbe.failureThreshold` x `periodSeconds`).
Append `-alpine` to `image.tag` for the Alpine build of the same release.

Each chart version pins the image it was tested with by digest (the `charg.github.io/image-digest`
annotation in `Chart.yaml`), so the deployed image cannot change under you if upstream re-pushes
a tag. Setting `image.tag` opts out and pulls that tag as-is; set `image.digest` as well to pin it.

## Values

This table is derived from `values.yaml` (its `# --` comments) and must be regenerated by hand
whenever `values.yaml` changes; there is no drift check enforcing that today.

| Key | Default | Description |
| --- | ------- | ----------- |
| `image.repository` | `docker.io/vaultwarden/server` | Image repository. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `image.tag` | `""` | Image tag. Defaults to `.Chart.AppVersion` when empty. Setting it opts out of the pinned digest. |
| `image.digest` | `""` | Image digest. Empty, with `image.tag` also empty, uses the digest pinned in `Chart.yaml`. |
| `imagePullSecrets` | `[]` | References to Secrets holding credentials for a private image registry. |
| `nameOverride` | `""` | Overrides the chart name portion of generated resource names. |
| `fullnameOverride` | `""` | Overrides the fully generated resource name. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the pod. |
| `serviceAccount.automount` | `false` | Automount the ServiceAccount API token into the pod. |
| `serviceAccount.annotations` | `{}` | Annotations added to the ServiceAccount. |
| `serviceAccount.name` | `""` | Name of the ServiceAccount to use. |
| `podAnnotations` | `{}` | Annotations added to the pod. |
| `podLabels` | `{}` | Labels added to the pod. |
| `podSecurityContext` | uid/gid `1000`, `fsGroup` `1000`, `RuntimeDefault` seccomp | Pod-level securityContext. See [Running unprivileged](#running-unprivileged). |
| `securityContext` | no capabilities, no privilege escalation, read-only root filesystem | Container-level securityContext. |
| `containerPort` | `8080` | Port Vaultwarden listens on in the container, sent as `ROCKET_PORT`. |
| `service.type` | `ClusterIP` | Service type. |
| `service.port` | `80` | Service port for HTTP and WebSocket traffic. |
| `service.annotations` | `{}` | Annotations added to the Service. |
| `domain` | `""` | `DOMAIN`: full public URL including scheme, optionally with a sub-path. |
| `signups.allowed` | `null` | `SIGNUPS_ALLOWED` (Boolean). |
| `signups.verify` | `null` | `SIGNUPS_VERIFY` (Boolean). Requires SMTP. |
| `signups.domainsWhitelist` | `[]` | `SIGNUPS_DOMAINS_WHITELIST` (comma separated). |
| `invitations.allowed` | `null` | `INVITATIONS_ALLOWED` (Boolean). |
| `invitations.orgName` | `""` | `INVITATION_ORG_NAME`. |
| `admin.token` | `""` | Admin panel token (Argon2 PHC string recommended); the panel is disabled when unset. |
| `admin.existingSecret.name` | `""` | Existing Secret holding the admin token instead. |
| `admin.existingSecret.key` | `admin-token` | Key within `admin.existingSecret.name`. |
| `database.url` | `""` | `DATABASE_URL`; SQLite on `/data` when unset. |
| `database.existingSecret.name` | `""` | Existing Secret holding the database URL instead. |
| `database.existingSecret.key` | `database-url` | Key within `database.existingSecret.name`. |
| `smtp.host` | `""` | `SMTP_HOST`. |
| `smtp.from` | `""` | `SMTP_FROM`. Required when `smtp.host` is set. |
| `smtp.fromName` | `""` | `SMTP_FROM_NAME`. |
| `smtp.port` | `null` | `SMTP_PORT` (Integer). |
| `smtp.security` | `""` | `SMTP_SECURITY`: one of `starttls`, `force_tls`, `off`. |
| `smtp.username` | `""` | `SMTP_USERNAME`. |
| `smtp.password` | `""` | SMTP password. |
| `smtp.existingSecret.name` | `""` | Existing Secret holding the SMTP password instead. |
| `smtp.existingSecret.key` | `smtp-password` | Key within `smtp.existingSecret.name`. |
| `push.enabled` | `null` | `PUSH_ENABLED` (Boolean). Requires `installationId` and an installation key. |
| `push.installationId` | `""` | `PUSH_INSTALLATION_ID`. |
| `push.installationKey` | `""` | Push installation key. |
| `push.existingSecret.name` | `""` | Existing Secret holding the installation key instead. |
| `push.existingSecret.key` | `push-installation-key` | Key within `push.existingSecret.name`. |
| `push.relayUri` | `""` | `PUSH_RELAY_URI`. |
| `push.identityUri` | `""` | `PUSH_IDENTITY_URI`. |
| `sso.enabled` | `null` | `SSO_ENABLED` (Boolean). Requires `authority` and `clientId`. |
| `sso.only` | `null` | `SSO_ONLY` (Boolean). |
| `sso.authority` | `""` | `SSO_AUTHORITY`. |
| `sso.clientId` | `""` | `SSO_CLIENT_ID`. |
| `sso.clientSecret` | `""` | OIDC client secret. |
| `sso.existingSecret.name` | `""` | Existing Secret holding the OIDC client secret instead. |
| `sso.existingSecret.key` | `sso-client-secret` | Key within `sso.existingSecret.name`. |
| `sso.scopes` | `[]` | `SSO_SCOPES` (space separated). |
| `sso.pkce` | `null` | `SSO_PKCE` (Boolean). |
| `sso.signupsMatchEmail` | `null` | `SSO_SIGNUPS_MATCH_EMAIL` (Boolean). |
| `env` | `{}` | Any other Vaultwarden setting, as a flat name-to-value map. |
| `extraEnvVars` | `[]` | Additional environment variables (name/value or valueFrom). |
| `extraEnvFrom` | `[]` | envFrom sources added to the container. |
| `ingress.enabled` | `false` | Create an Ingress. |
| `ingress.className` | `""` | IngressClass to use. |
| `ingress.annotations` | `{}` | Annotations added to the Ingress. |
| `ingress.hosts` | see `values.yaml` | Hosts and paths routed to Vaultwarden. |
| `ingress.tls` | `[]` | TLS configuration blocks. |
| `httpRoute.enabled` | `false` | Create a Gateway API HTTPRoute. |
| `httpRoute.annotations` | `{}` | Annotations added to the HTTPRoute. |
| `httpRoute.parentRefs` | `[]` | Gateways the route attaches to. Required when enabled. |
| `httpRoute.hostnames` | `[]` | Hostnames the route matches. |
| `httpRoute.matches` | `PathPrefix /` | Matches for the rule forwarding to the Service. |
| `networkPolicy.enabled` | `false` | Create a NetworkPolicy for the pod (needs an enforcing CNI). |
| `networkPolicy.ingressFrom` | `[]` | Peers allowed to reach the HTTP port. Empty admits any source, to that port only. The chart's helm test pod is always admitted. |
| `networkPolicy.extraIngress` | `[]` | Additional ingress rules. |
| `networkPolicy.restrictEgress` | `false` | Allow only DNS egress plus `extraEgress`. SMTP, push, SSO and an external database then each need a rule. |
| `networkPolicy.extraEgress` | `[]` | Additional egress rules, used with `restrictEgress`. |
| `persistence.enabled` | `true` | Persist `/data`; an emptyDir (data lost on restart) when false. |
| `persistence.existingClaim` | `""` | Use an existing PersistentVolumeClaim. |
| `persistence.size` | `1Gi` | Size of the PersistentVolumeClaim. |
| `persistence.storageClass` | `""` | StorageClass; empty uses the cluster default. |
| `persistence.accessModes` | `[ReadWriteOnce]` | Access modes for the PersistentVolumeClaim. |
| `persistence.annotations` | `{}` | Annotations added to the PersistentVolumeClaim. |
| `persistence.keep` | `true` | Keep the claim on `helm uninstall`. |
| `extraVolumes` | `[]` | Additional volumes added to the pod. |
| `extraVolumeMounts` | `[]` | Additional volumeMounts added to the container. |
| `strategy` | `{type: Recreate}` | Deployment strategy. |
| `startupProbe.*` | see `values.yaml` | Startup probe toggle and timing. |
| `readinessProbe.*` | see `values.yaml` | Readiness probe timing. |
| `livenessProbe.*` | see `values.yaml` | Liveness probe timing. |
| `resources` | `{}` | Resource requests and limits for the container. |
| `nodeSelector` | `{}` | Node selector for pod scheduling. |
| `tolerations` | `[]` | Tolerations for pod scheduling. |
| `affinity` | `{}` | Affinity rules for pod scheduling. |
| `priorityClassName` | `""` | PriorityClass for the pod. |
| `test.image.*` | see `values.yaml` | Image used by the `helm test` hook. |

See `values.yaml` for the full set of comments; every value there carries one.
