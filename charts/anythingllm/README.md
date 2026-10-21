# anythingllm

[AnythingLLM](https://github.com/Mintplex-Labs/anything-llm), an all-in-one AI workspace (chat,
RAG over your own documents, agents), deployed as a single-replica Deployment with its built-in
SQLite database and LanceDB vector store on one persistent volume. It talks to whatever LLM
provider you point it at; the chart has no opinion beyond passing the settings through.

## Install

```bash
helm install anythingllm oci://ghcr.io/charg/anythingllm \
  --set auth.password=change-me
```

Without `auth.password` (or a password / multi-user mode enabled later in the UI under
Settings > Security), anyone who can reach the URL has full admin access.

## Configuration precedence: the chart wins

AnythingLLM reads its settings from environment variables, which is what this chart renders. The
web UI also lets you change most settings; it saves them to the server's `.env` file
(`/app/server/.env`), which this chart persists on the data volume. On start the server loads that
file **without overriding variables already in its environment**, so:

- A setting the chart sets (anything under `env`, `auth`, `encryption`, or the chart's own
  `SERVER_PORT`, `STORAGE_DIR`, `DISABLE_TELEMETRY`) is declarative: changing it in the UI applies
  until the pod restarts, then reverts to the chart's value.
- A setting the chart leaves alone is owned by the UI, and survives restarts and upgrades.

Pick one place per setting. A common split is to pin the LLM provider, embedder and vector database
here and leave workspaces, agents and per-workspace model choices to the UI.

## Single replica, by design

There is no `replicaCount`. The SQLite database, the LanceDB vector store, uploaded and parsed
documents and the native embedding model all live on one `ReadWriteOnce` volume, and agent chats
hold a WebSocket open to the pod that started them. A second replica would fail to mount the
volume or corrupt the database. For the same reason `strategy` defaults to `Recreate`: the old pod
releases the volume before the new one starts.

## Secrets

AnythingLLM has no `_FILE` variants, so each credential is passed as an environment variable whose
value comes from a Secret (`valueFrom.secretKeyRef`), never as a literal in the pod spec. Give each
one either inline, and the chart renders a Secret for it, or as an `existingSecret` reference.
Setting both for the same credential fails the template.

| Values | Variable | Purpose |
| ------ | -------- | ------- |
| `auth.jwtSecret` / `auth.jwtSecretExistingSecret` | `JWT_SECRET` | Signs login sessions. At least 12 characters. |
| `auth.password` / `auth.passwordExistingSecret` | `AUTH_TOKEN` | The single password in single-user mode. |
| `encryption.key` + `encryption.salt` / `encryption.existingSecret` | `SIG_KEY`, `SIG_SALT` | Encrypt stored data (provider keys saved in the UI, connector credentials). |

None of these is required. Left unset, AnythingLLM generates the JWT secret when a password or
multi-user mode is first enabled, and the encryption pair on first start, saving both to the
persisted `.env`. Setting them here instead puts them in a Secret you can back up separately from
the volume. Set `encryption.key` and `encryption.salt` together or not at all: with only one,
AnythingLLM generates a fresh pair on every start and nothing encrypted earlier decrypts.

Setting `auth.jwtSecret` or `auth.password` also tells AnythingLLM onboarding is complete, so the
first-run wizard is skipped. Configure the LLM through `env` (below) or the settings page.

Provider API keys are not structured values: pass them through `extraEnvVars` (one
`secretKeyRef` each) or `extraEnvFrom` (a whole Secret at once). The template refuses
`JWT_SECRET`, `AUTH_TOKEN`, `SIG_KEY` and `SIG_SALT` as plain `env` entries.

## Choosing the LLM, embedder and vector database

Everything else is a flat `env` map of AnythingLLM's own variable names; upstream's
[`docker/.env.example`](https://github.com/Mintplex-Labs/anything-llm/blob/master/docker/.env.example)
lists them all. For example, chat and embeddings through an OpenAI-compatible
[LiteLLM](https://github.com/BerriAI/litellm) proxy, with the built-in CPU embedder as the
alternative when no embedding model is served:

```yaml
env:
  LLM_PROVIDER: litellm
  LITE_LLM_BASE_PATH: http://litellm:4000
  LITE_LLM_MODEL_PREF: my-chat-model
  LITE_LLM_MODEL_TOKEN_LIMIT: "8192"
  # Embeddings through the same proxy...
  EMBEDDING_ENGINE: litellm
  EMBEDDING_MODEL_PREF: my-embedding-model
  # ...or the native embedder (all-MiniLM-L6-v2 on CPU, downloaded into the data volume on
  # first use):
  # EMBEDDING_ENGINE: native
  VECTOR_DB: lancedb
extraEnvVars:
  - name: LITE_LLM_API_KEY
    valueFrom:
      secretKeyRef:
        name: litellm-api-key
        key: api-key
```

Any other provider works the same way: `LLM_PROVIDER: ollama` with `OLLAMA_BASE_PATH`,
`generic-openai` with `GENERIC_OPEN_AI_BASE_PATH`, a hosted API with its key in `extraEnvVars`,
and so on.

Changing the embedder after documents have been embedded leaves their existing vectors
unusable; re-embed the affected workspaces.

## Exposing it

`ingress` and `httpRoute` both route to the Service's `http` port, which also carries the agent
WebSocket. Document uploads go through the same route, so raise any request body limit your
controller applies (ingress-nginx: `nginx.ingress.kubernetes.io/proxy-body-size`).

## Running unprivileged

The image runs as its own non-root user (1000:1000) and the default `podSecurityContext` keeps it
that way, with `fsGroup` making the data volume writable. Two things stop it going further:

- `readOnlyRootFilesystem` is not supported. The entrypoint runs `prisma generate` into the image's
  `node_modules` on every start.
- The bundled Chromium, used to scrape web pages into documents, wants its sandbox, which upstream
  enables by granting `SYS_ADMIN`. To drop every capability instead, run Chromium without its
  sandbox:

```yaml
env:
  ANYTHINGLLM_CHROMIUM_ARGS: "--no-sandbox,--disable-setuid-sandbox"
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

The `ci/hardened-values.yaml` scenario installs exactly this profile.

## Persistence

The chart lays the volume out as two paths, both prepared by an init container on every start:

| Path in the volume | Mounted at | Holds |
| ------------------ | ---------- | ----- |
| `storage/` | `/app/server/storage` (`STORAGE_DIR`) | SQLite database, LanceDB, documents, embedding model cache |
| `server.env` | `/app/server/.env` | Settings saved in the UI, generated JWT and encryption secrets |

The storage path is not configurable: upstream's Prisma schema hardcodes the SQLite file as
`server/storage/anythingllm.db`, and the server finds the collector's upload directory relative to
`STORAGE_DIR`. The chart-created claim carries `helm.sh/resource-policy: keep` by default, so
`helm uninstall` leaves it behind.

### Adopting an existing volume

Point `persistence.existingClaim` at a claim and arrange its contents as above, e.g. to move a
Docker install onto this chart: copy its storage directory to `storage/` and its `.env` to
`server.env`, owned by 1000:1000. Keep the old `.env`'s `SIG_KEY` and `SIG_SALT` (in `server.env`,
or moved into `encryption`): without them, credentials saved in the UI no longer decrypt.

## Upgrades

`appVersion` tracks upstream's plain `x.y.z` releases on Docker Hub (Renovate opens a PR for each
one), and `image.tag` defaults to it. Database migrations run on every start, which is why the
startup probe allows up to five minutes (`startupProbe.failureThreshold` x `periodSeconds`). Back
up the volume before an upgrade: migrations are not reversible.

## Values

This table is derived from `values.yaml` (its `# --` comments) and must be regenerated by hand
whenever `values.yaml` changes; there is no drift check enforcing that today.

| Key | Default | Description |
| --- | ------- | ----------- |
| `image.repository` | `docker.io/mintplexlabs/anythingllm` | Image repository. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `image.tag` | `""` | Image tag. Defaults to `.Chart.AppVersion` when empty. |
| `imagePullSecrets` | `[]` | References to Secrets holding credentials for a private image registry. |
| `nameOverride` | `""` | Overrides the chart name portion of generated resource names. |
| `fullnameOverride` | `""` | Overrides the fully generated resource name. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the pod. |
| `serviceAccount.automount` | `false` | Automount the ServiceAccount API token into the pod. |
| `serviceAccount.annotations` | `{}` | Annotations added to the ServiceAccount. |
| `serviceAccount.name` | `""` | Name of the ServiceAccount to use. |
| `podAnnotations` | `{}` | Annotations added to the pod. |
| `podLabels` | `{}` | Labels added to the pod. |
| `podSecurityContext` | non-root 1000:1000, `fsGroup: 1000` | Pod-level securityContext. See [Running unprivileged](#running-unprivileged). |
| `securityContext` | `{}` | Container-level securityContext, applied to the init container too. |
| `containerPort` | `3001` | Port the server listens on in the container, sent as `SERVER_PORT`. |
| `service.type` | `ClusterIP` | Service type. |
| `service.port` | `80` | Service port for HTTP and WebSocket traffic. |
| `service.annotations` | `{}` | Annotations added to the Service. |
| `disableTelemetry` | `true` | `DISABLE_TELEMETRY` (Boolean). |
| `auth.jwtSecret` | `""` | `JWT_SECRET`, at least 12 characters. |
| `auth.jwtSecretExistingSecret.name` | `""` | Existing Secret holding `JWT_SECRET` instead. |
| `auth.jwtSecretExistingSecret.key` | `jwt-secret` | Key within `auth.jwtSecretExistingSecret.name`. |
| `auth.password` | `""` | `AUTH_TOKEN`: the single-user password. |
| `auth.passwordExistingSecret.name` | `""` | Existing Secret holding `AUTH_TOKEN` instead. |
| `auth.passwordExistingSecret.key` | `auth-token` | Key within `auth.passwordExistingSecret.name`. |
| `encryption.key` | `""` | `SIG_KEY`. Set together with `encryption.salt`. |
| `encryption.salt` | `""` | `SIG_SALT`. Set together with `encryption.key`. |
| `encryption.existingSecret.name` | `""` | Existing Secret holding both `SIG_KEY` and `SIG_SALT` instead. |
| `encryption.existingSecret.keyKey` | `sig-key` | Key within `encryption.existingSecret.name` holding `SIG_KEY`. |
| `encryption.existingSecret.saltKey` | `sig-salt` | Key within `encryption.existingSecret.name` holding `SIG_SALT`. |
| `env` | `{}` | Any other AnythingLLM setting, as a flat name-to-value map. |
| `extraEnvVars` | `[]` | Additional environment variables (name/value or valueFrom). |
| `extraEnvFrom` | `[]` | envFrom sources added to the container. |
| `ingress.enabled` | `false` | Create an Ingress. |
| `ingress.className` | `""` | IngressClass to use. |
| `ingress.annotations` | `{}` | Annotations added to the Ingress. |
| `ingress.hosts` | see `values.yaml` | Hosts and paths routed to AnythingLLM. |
| `ingress.tls` | `[]` | TLS configuration blocks. |
| `httpRoute.enabled` | `false` | Create a Gateway API HTTPRoute. |
| `httpRoute.annotations` | `{}` | Annotations added to the HTTPRoute. |
| `httpRoute.parentRefs` | `[]` | Gateways the route attaches to. Required when enabled. |
| `httpRoute.hostnames` | `[]` | Hostnames the route matches. |
| `httpRoute.matches` | `PathPrefix /` | Matches for the rule forwarding to the Service. |
| `persistence.enabled` | `true` | Persist the data volume; an emptyDir (data lost on restart) when false. |
| `persistence.existingClaim` | `""` | Use an existing PersistentVolumeClaim. See [Adopting an existing volume](#adopting-an-existing-volume). |
| `persistence.size` | `10Gi` | Size of the PersistentVolumeClaim. |
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
| `resources` | `{}` | Resource requests and limits for the container and init container. |
| `nodeSelector` | `{}` | Node selector for pod scheduling. |
| `tolerations` | `[]` | Tolerations for pod scheduling. |
| `affinity` | `{}` | Affinity rules for pod scheduling. |
| `priorityClassName` | `""` | PriorityClass for the pod. |
| `test.image.*` | see `values.yaml` | Image used by the `helm test` hook. |

See `values.yaml` for the full set of comments; every value there carries one.
