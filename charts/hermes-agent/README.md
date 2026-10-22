# hermes-agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent), Nous Research's self-improving AI
agent, deployed as a single-replica Deployment running its gateway: an OpenAI-compatible API
server (so any OpenAI client or chat frontend can talk to it) and, optionally, the web dashboard.
Sessions, memory, skills and settings live on one persistent volume. It talks to whatever LLM
provider you point it at.

## Install

```bash
helm install hermes oci://ghcr.io/charg/hermes-agent \
  --set apiServer.key="$(openssl rand -hex 32)"
```

Without `apiServer.key` the image generates a random key into the `.env` on the data volume on
first start (the install notes print how to read it back). Either way every `/v1` request needs it
as a bearer token. Hermes also needs an LLM before it does anything useful; see
[Choosing the LLM](#choosing-the-llm).

## Configuration precedence: the managed scope wins

Hermes keeps its own `config.yaml` and `.env` in its data directory (`/opt/data`), and both change
at runtime: `hermes config set`, `hermes setup`, the dashboard and the agent itself write to them.
Its `.env` is loaded with override, so it even beats the container's environment. Plain
environment variables would therefore lose to whatever was last saved on the volume.

The chart instead uses Hermes's
[managed scope](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/managed-scope.md):
an init container writes a `config.yaml` and a `.env` into an in-memory volume that the gateway
mounts read-only at `/etc/hermes-managed` (`HERMES_MANAGED_DIR`). Managed values win over the user
files on the volume, leaf by leaf, and `hermes config set` refuses to change them. So:

- Anything under `config`, `managedEnv`, `apiServer` and `dashboard` is declarative: it applies on
  every start and cannot be overridden at runtime.
- Everything else (skills, memory, sessions, settings the chart leaves alone) is owned by Hermes,
  persisted on the volume, and survives restarts and upgrades.
- `env`, `extraEnvVars` and `extraEnvFrom` are plain container variables and lose to the user
  `.env`. Use them only for what the image's init reads before Hermes starts, such as
  `HERMES_UID` / `HERMES_GID` or `TZ`.

`hermes config` inside the pod lists the managed keys:

```bash
kubectl exec deploy/hermes-hermes-agent -- hermes config
```

## Single replica, by design

There is no `replicaCount`. Upstream is explicit that two gateways must never share a data
directory, and the SQLite state, sessions and memory all live on one `ReadWriteOnce` volume. For
the same reason `strategy` defaults to `Recreate`: the old pod releases the volume before the new
one starts.

## Choosing the LLM

`config` is a nested map in upstream's `config.yaml` schema, so any setting Hermes has can be
pinned there. The model is the one that matters first. Hermes speaks to any OpenAI-compatible
endpoint through its `custom` provider; reference the API key with `${VAR}` and supply the
variable through `managedEnv`, so the secret never lands in the ConfigMap:

```yaml
config:
  model:
    provider: custom
    base_url: https://api.openai.com/v1
    default: gpt-5-mini
    api_key: ${OPENAI_API_KEY}
managedEnv:
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef:
        name: openai
        key: api-key
```

Behind a [LiteLLM](https://github.com/BerriAI/litellm) proxy (to mix hosted and local models, or
to keep provider keys out of Hermes entirely), point `base_url` at the proxy instead:

```yaml
config:
  model:
    provider: custom
    base_url: http://litellm.litellm.svc:4000/v1
    default: my-model
    api_key: ${LITELLM_API_KEY}
managedEnv:
  - name: LITELLM_API_KEY
    valueFrom:
      secretKeyRef:
        name: litellm-virtual-key
        key: api-key
```

Hermes is an agent: it calls tools in a loop and sends long contexts, so pick a model with solid
tool calling and a large context window. Small local models tend to struggle.

## Secrets

Credentials never appear as literals in the pod spec or in the gateway's environment. Each is
resolved by Kubernetes into the init container from a Secret (`valueFrom.secretKeyRef`), written
to the in-memory managed `.env`, and read by Hermes from there. Give each one either inline, and
the chart renders a Secret for it, or as an `existingSecret` reference. Setting both for the same
credential fails the template.

| Values | Variable | Purpose |
| ------ | -------- | ------- |
| `apiServer.key` / `apiServer.existingSecret` | `API_SERVER_KEY` | Bearer token for the API. At least 16 characters. |
| `dashboard.basicAuth.password` / `dashboard.basicAuth.existingSecret` | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Dashboard login password. |
| `dashboard.basicAuth.secret` / `dashboard.basicAuth.existingSecret` | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Signs dashboard sessions; without it every login is lost on restart. |

Provider API keys and anything else go in `managedEnv`, one entry each, with a `secretKeyRef`. An
`optional: true` reference that does not resolve is left out of the file. Values are written
double-quoted with backslashes and quotes escaped, which both of Hermes's `.env` parsers read
back verbatim; multi-line values are refused at start. The template refuses names the chart sets
itself (`API_SERVER_*`, the dashboard auth variables, `HERMES_MANAGED_DIR`, `HERMES_HOME`, ...) in
`env` and `managedEnv`.

## The API server

`apiServer` is on by default and listens on `0.0.0.0:8642`, behind the Service's `api` port.
`GET /health` needs no key and backs the probes; everything under `/v1` (chat completions,
responses, models) needs `Authorization: Bearer <key>`. Point any OpenAI client at
`http://<service>:8642/v1`. Set `apiServer.corsOrigins` only if a browser calls Hermes directly.

The API gives full access to Hermes's tools, including its terminal, which runs commands inside
the pod as the `hermes` user (Hermes logs a warning about this on start). Treat the key like a
shell password, keep the Service internal unless you need otherwise, and consider a
`NetworkPolicy` limiting who can reach port 8642.

## The dashboard

`dashboard.enabled` runs the web dashboard on `0.0.0.0:9119`, behind the Service's `dashboard`
port. Bound to a non-loopback address, Hermes refuses to serve it without an auth provider, and
the template refuses to render without one too:

- **Username/password** (`dashboard.basicAuth`): one shared login, which upstream recommends only
  on trusted networks or behind a VPN. To avoid a plaintext password at rest, put a
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` in `managedEnv` instead of `password`.
- **Self-hosted OIDC** (Keycloak, Authentik, ...): `HERMES_DASHBOARD_OIDC_ISSUER` and
  `HERMES_DASHBOARD_OIDC_CLIENT_ID` in `managedEnv`. Suitable for internet-facing use.
- **Nous Portal OAuth**: `HERMES_DASHBOARD_OAUTH_CLIENT_ID` in `managedEnv`.

Behind an Ingress or HTTPRoute, set `dashboard.publicUrl` to the URL users reach it on, so OAuth
callbacks and cookies use the public address. If you rely on forwarded client IPs (the login rate
limit is per IP), list your proxy's address or pod CIDR in `config.dashboard.trusted_proxies`; it
takes exact IPs or bounded CIDRs, never `*` or `0.0.0.0/0`.

The dashboard reads and writes the user `.env`, which holds secrets; anyone who can log in can
read them.

## Exposing it

`ingress` and `httpRoute` route to the Service by port name: each Ingress path carries a `port`
(`api`, the default, or `dashboard`), and `httpRoute.port` picks the one the route forwards to.
Routing to a port that is not enabled fails the template. The API streams responses as
server-sent events, so turn off response buffering on proxies that buffer by default.

## Running with minimal privileges

The image must **start as root**. Its s6-overlay init fixes ownership of the data volume, seeds and
migrates the config, syncs bundled skills, then drops to the `hermes` user (uid 10000) with
`s6-setuidgid` before starting the gateway. Setting `runAsUser` / `runAsNonRoot` does not work:
any uid other than 10000 is refused outright, and 10000 itself boots but skips the config
migration and dependency refresh that upgrades rely on. Use `env.HERMES_UID` / `env.HERMES_GID`
to change the uid Hermes runs as.

What can be locked down is everything around that start. Six capabilities are enough for it, and
the root phase never needs to gain privileges:

```yaml
podSecurityContext:
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETUID
      - SETGID
      - KILL
```

The `ci/hardened-values.yaml` scenario installs exactly this profile. `readOnlyRootFilesystem` is
not supported: s6-overlay and the init write outside the data volume at start (`/run`, and
`/etc/passwd` when remapping the uid).

## Persistence

The data volume is mounted as Hermes's home, `/opt/data`: the user `config.yaml` and `.env`,
`SOUL.md`, sessions, memory, skills, logs and the SQLite state. The path is not configurable; the
image's init prepares exactly that directory. The chart-created claim carries
`helm.sh/resource-policy: keep` by default, so `helm uninstall` leaves it behind.

SQLite runs in WAL mode, which is fine on block storage (local-path, Longhorn, Ceph RBD, ...). On
NFS or SMB, set `config.database.journal_mode: delete`.

`/dev/shm` gets a memory-backed `emptyDir` (`shm`, 1Gi by default) because the bundled Playwright
browser needs more shared memory than the runtime's 64Mi default. Its usage counts against the
container's memory limit. Budget 2-4Gi of memory overall, more with the browser tools in use.

### Adopting an existing volume

Point `persistence.existingClaim` at a claim holding a Hermes home, e.g. a Docker install's
`~/.hermes` (or `/opt/data`) copied in as-is. Ownership is fixed on start. Settings the chart now
manages override the copied ones without touching the files.

## Upgrades

`appVersion` tracks upstream's plain `vX.Y.Z` releases on Docker Hub (Renovate opens a PR for each
one, ignoring `-desktop` builds and release candidates), and `image.tag` defaults to it. Every
start migrates the config and syncs bundled skills before the gateway listens, which is why the
startup probe allows up to five minutes (`startupProbe.failureThreshold` x `periodSeconds`). Back
up the volume before an upgrade: config migrations are not reversible.

## Values

This table is derived from `values.yaml` (its `# --` comments, first sentence) and must be
regenerated by hand whenever `values.yaml` changes; there is no drift check enforcing that today.

| Key | Default | Description |
| --- | ------- | ----------- |
| `image.repository` | `docker.io/nousresearch/hermes-agent` | Image repository. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `image.tag` | `""` | Image tag. |
| `imagePullSecrets` | `[]` | References to Secrets holding credentials for a private image registry. |
| `nameOverride` | `""` | Overrides the chart name portion of generated resource names. |
| `fullnameOverride` | `""` | Overrides the fully generated resource name. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the pod. |
| `serviceAccount.automount` | `false` | Automount the ServiceAccount API token into the pod. |
| `serviceAccount.annotations` | `{}` | Annotations added to the ServiceAccount. |
| `serviceAccount.name` | `""` | Name of the ServiceAccount to use. |
| `podAnnotations` | `{}` | Annotations added to the pod. |
| `podLabels` | `{}` | Labels added to the pod. |
| `podSecurityContext` | `{}` | Pod-level securityContext. |
| `securityContext` | `{}` | Container-level securityContext, applied to the init container too. |
| `config` | `{}` | Hermes `config.yaml` settings the chart enforces, written to the managed config. See [Choosing the LLM](#choosing-the-llm). |
| `apiServer.enabled` | `true` | Run the OpenAI-compatible API server (API_SERVER_ENABLED) on 0.0.0.0, so the Service can reach it. |
| `apiServer.port` | `8642` | Port the API server listens on inside the container (API_SERVER_PORT). |
| `apiServer.key` | `""` | API_SERVER_KEY: the bearer token every /v1 request must carry, at least 16 characters (Hermes refuses a shorter one). |
| `apiServer.existingSecret.name` | `""` | Name of an operator-supplied Secret holding API_SERVER_KEY, instead of key. |
| `apiServer.existingSecret.key` | `api-server-key` | Key within existingSecret.name holding API_SERVER_KEY. |
| `apiServer.corsOrigins` | `""` | API_SERVER_CORS_ORIGINS: comma-separated browser origins allowed to call the API, e.g. a chat frontend's URL. Empty allows none, which is right for server-to-server clients. |
| `apiServer.modelName` | `""` | API_SERVER_MODEL_NAME: the model id advertised on /v1/models. |
| `dashboard.enabled` | `false` | Run the web dashboard (HERMES_DASHBOARD) next to the gateway, bound to 0.0.0.0. |
| `dashboard.port` | `9119` | Port the dashboard listens on inside the container (HERMES_DASHBOARD_PORT). |
| `dashboard.publicUrl` | `""` | HERMES_DASHBOARD_PUBLIC_URL: the URL users reach the dashboard on, e.g. https://hermes.example.com. |
| `dashboard.basicAuth.username` | `""` | HERMES_DASHBOARD_BASIC_AUTH_USERNAME. Setting it (with a password) enables the provider. |
| `dashboard.basicAuth.password` | `""` | HERMES_DASHBOARD_BASIC_AUTH_PASSWORD. Mutually exclusive with existingSecret.name. |
| `dashboard.basicAuth.secret` | `""` | HERMES_DASHBOARD_BASIC_AUTH_SECRET: the key session tokens are signed with. |
| `dashboard.basicAuth.existingSecret.name` | `""` | Name of an operator-supplied Secret holding the password and signing secret, instead of password and secret. |
| `dashboard.basicAuth.existingSecret.passwordKey` | `password` | Key within existingSecret.name holding the password. |
| `dashboard.basicAuth.existingSecret.secretKey` | `secret` | Key within existingSecret.name holding the signing secret. |
| `managedEnv` | `[]` | Further variables for the managed `.env`, as `{name, value}` or `{name, valueFrom}` entries; where provider API keys belong. |
| `env` | `{}` | Plain container environment variables, as a flat map of name to value; the user `.env` wins over these. |
| `extraEnvVars` | `[]` | Additional container environment variables as a list of name/value(From) entries, appended after env above. |
| `extraEnvFrom` | `[]` | envFrom sources (ConfigMaps or Secrets) added to the container. |
| `service.type` | `ClusterIP` | Service type. |
| `service.apiPort` | `8642` | Service port for the API server. |
| `service.dashboardPort` | `9119` | Service port for the dashboard, when enabled. |
| `service.annotations` | `{}` | Annotations added to the Service. |
| `ingress.enabled` | `false` | Create an Ingress. |
| `ingress.className` | `""` | IngressClass to use. |
| `ingress.annotations` | `{}` | Annotations added to the Ingress. |
| `ingress.hosts` | see values.yaml | Hosts and paths. |
| `ingress.tls` | `[]` | TLS configuration blocks, as in a standard networking.k8s.io/v1 Ingress spec. |
| `httpRoute.enabled` | `false` | Create a Gateway API HTTPRoute (gateway.networking.k8s.io/v1). |
| `httpRoute.annotations` | `{}` | Annotations added to the HTTPRoute. |
| `httpRoute.parentRefs` | `[]` | Gateways the route attaches to, e.g. [{name: public, namespace: gateway, sectionName: https}]. |
| `httpRoute.hostnames` | `[]` | Hostnames the route matches. |
| `httpRoute.port` | `api` | Service port the single rule forwards to: api or dashboard. |
| `httpRoute.matches` | `[{path: {type: PathPrefix, value: /}}]` | Matches for the single rule forwarding to the Service, as in an HTTPRoute rule. |
| `persistence.enabled` | `true` | Persist the data directory (/opt/data, HERMES_HOME): sessions, memory, skills, the user config.yaml and .env, logs and the SQLite state. |
| `persistence.existingClaim` | `""` | Use an existing PersistentVolumeClaim instead of creating one. |
| `persistence.size` | `10Gi` | Size of the PersistentVolumeClaim. |
| `persistence.storageClass` | `""` | StorageClass for the PersistentVolumeClaim. |
| `persistence.accessModes` | `[ReadWriteOnce]` | Access modes for the PersistentVolumeClaim. |
| `persistence.annotations` | `{}` | Annotations added to the PersistentVolumeClaim. |
| `persistence.keep` | `true` | Keep the chart-created PersistentVolumeClaim on `helm uninstall` (helm.sh/resource-policy: keep). |
| `shm.enabled` | `true` | Mount a memory-backed emptyDir at /dev/shm. |
| `shm.sizeLimit` | `1Gi` | Size limit of /dev/shm. |
| `extraVolumes` | `[]` | Additional volumes added to the pod. |
| `extraVolumeMounts` | `[]` | Additional volumeMounts added to the container. |
| `strategy` | `{type: Recreate}` | Deployment strategy. |
| `terminationGracePeriodSeconds` | `60` | Seconds the pod gets to shut down after SIGTERM, which s6 passes on to the gateway, before it is killed. |
| `startupProbe.enabled` | `true` | Enable a startup probe that gates the readiness and liveness probes until Hermes is up. |
| `startupProbe.periodSeconds` | `5` | Seconds between startup checks. |
| `startupProbe.timeoutSeconds` | `5` | Seconds before a startup check times out. |
| `startupProbe.failureThreshold` | `60` | Consecutive failures allowed before the container is considered to have failed to start. |
| `readinessProbe.periodSeconds` | `10` | Seconds between readiness checks. |
| `readinessProbe.timeoutSeconds` | `5` | Seconds before a readiness check times out. |
| `readinessProbe.failureThreshold` | `3` | Consecutive failures before the pod is marked not ready. |
| `livenessProbe.periodSeconds` | `20` | Seconds between liveness checks. |
| `livenessProbe.timeoutSeconds` | `5` | Seconds before a liveness check times out. |
| `livenessProbe.failureThreshold` | `6` | Consecutive failures before the container is restarted. |
| `resources` | `{}` | Resource requests and limits for the container (init container included). Budget 2-4Gi of memory. |
| `nodeSelector` | `{}` | Node selector for pod scheduling. |
| `tolerations` | `[]` | Tolerations for pod scheduling. |
| `affinity` | `{}` | Affinity rules for pod scheduling. |
| `priorityClassName` | `""` | PriorityClass for the pod. |
| `test.image.repository` | `curlimages/curl` | Image used by the helm test hook that calls the API server (or dashboard) through the Service. |
| `test.image.tag` | `"8.23.0"` | Tag of the test image. |
| `test.image.pullPolicy` | `IfNotPresent` | Pull policy of the test image. |
