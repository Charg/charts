# technitium-dns-server

Self-hosted authoritative and recursive DNS server with a web console, DNSSEC, and ad/malware
blocking, deployed as a StatefulSet.

## First-boot-only configuration

Most of the values under `server`, `auth`, `webService`, `optionalProtocol`, `recursion`,
`blocking`, `forwarders`, `logging`, `stats` and `sso` map to `DNS_SERVER_*` environment
variables on Technitium's Docker image. Upstream is explicit about when these are read:

> These environment variables are read by the DNS server only when the DNS config file does not
> exists i.e. when the DNS server starts for the first time.

They are bootstrap configuration, not desired state. Editing one of these values and running
`helm upgrade` does **not** reconfigure a server that has already initialized; the new value
only takes effect on a replica that boots against an empty `/etc/dns` volume (a fresh PVC, or an
existing one wiped deliberately). This chart does not work around that with a reconciliation
job. Reconfigure a running server through its web console or HTTP API, and treat these values as
what a *new* replica's data volume gets seeded with, not as ongoing config drift protection.

Every value in this category carries a `# --` comment in `values.yaml` calling this out, and it
is repeated in the output of `helm install`/`helm upgrade` (see `templates/NOTES.txt`).

## Install

```bash
helm install my-dns oci://ghcr.io/charg/technitium-dns-server
```

## Quickstart with a bootstrap admin password

```bash
helm install my-dns oci://ghcr.io/charg/technitium-dns-server \
  --set auth.adminPassword=change-me
```

Leaving `auth.adminPassword` and `auth.existingSecret.name` both unset installs cleanly and
falls back to whatever default admin credentials Technitium itself creates on first boot; that
is fine for a scratch install but log in and set a real password before relying on it.

## Secrets: admin password and SSO client secret

`auth.adminPassword` and `sso.clientSecret` are never rendered as plain environment variables.
Upstream ships `DNS_SERVER_ADMIN_PASSWORD_FILE` and `DNS_SERVER_SSO_CLIENT_SECRET_FILE`
specifically so these values do not appear in the container's process environment, and that is
the only form this chart renders. Each credential can come from either a value the chart turns
into a Secret, or an existing Secret you manage yourself; setting both for the same credential
fails the template:

```yaml
auth:
  adminPassword: "change-me"        # chart creates a Secret from this
  # existingSecret:
  #   name: my-admin-password       # or point at one you already manage
  #   key: password

sso:
  clientSecret: ""
  existingSecret:
    name: my-oidc-client-secret
    key: client-secret
```

Both secrets are mounted read-only with `defaultMode: 0400`.

## HTTPS console and clustering

`webService.enableHttps` defaults to `true`, with `webService.useSelfSignedCert` also on by
default, so the console works out of the box on `service.httpsPort` (53443) without extra
configuration. This is deliberate: Technitium's native clustering (v14+) talks to peers over the
HTTPS API port, so a deployment installed with HTTPS off cannot be clustered later without a
first-boot reset on every replica. Replace the self-signed certificate with a real one via
`webService.tlsCertificatePath` / `webService.tlsCertificatePassword` before exposing the console
outside the cluster.

## Optional listener ports

DNS-over-TLS, DNS-over-QUIC, DNS-over-HTTPS and DHCP are off by default and individually
toggleable under `optionalListeners`. Enabling a toggle only opens the port at the Kubernetes
level (container, headless Service, primary Service, and each per-replica Service); the protocol
itself still needs enabling in Technitium's web console or HTTP API, since none of these have a
first-boot environment variable in this chart other than DNS-over-HTTP.

Upstream's own documentation disagrees on which port `DNS_SERVER_OPTIONAL_PROTOCOL_DNS_OVER_HTTP`
opens: `DockerEnvironmentVariables.md` says TCP 80, the `docker-compose.yml` comment in the same
repo says TCP 8053. This chart exposes both port toggles (`dnsOverHttpPort80`,
`dnsOverHttpPort8053`) and does not assert which one the flag actually opens on your version.

| Port | Protocol | Purpose | Toggle |
| ---- | -------- | ------- | ------ |
| 853 | TCP | DNS-over-TLS | `optionalListeners.dnsOverTls.enabled` |
| 853 | UDP | DNS-over-QUIC | `optionalListeners.dnsOverQuic.enabled` |
| 443 | TCP | DNS-over-HTTPS (HTTP/1.1, HTTP/2) | `optionalListeners.dnsOverHttps.enabled` |
| 443 | UDP | DNS-over-HTTPS (HTTP/3) | `optionalListeners.dnsOverHttp3.enabled` |
| 80 | TCP | DNS-over-HTTP (reverse proxy or certbot renewal) | `optionalListeners.dnsOverHttpPort80.enabled` |
| 8053 | TCP | DNS-over-HTTP (reverse proxy) | `optionalListeners.dnsOverHttpPort8053.enabled` |
| 67 | UDP | DHCP | `optionalListeners.dhcp.enabled` |

## Ingress

`ingress.enabled` puts only the web console's HTTP Service port behind an Ingress. The DNS ports
(53, and everything under `optionalListeners`) are never routed through Ingress: Ingress is an
HTTP-routing concept and DNS traffic is not HTTP.

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: dns.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls:
    - secretName: dns-example-com-tls
      hosts:
        - dns.example.com
```

## High availability

`replicaCount` scales independent DNS servers, not shards of one cluster: Technitium keeps
per-node state under `/etc/dns` with no shared-filesystem design. `perReplicaService.enabled`
(on by default) gives each replica a stable address of its own, since Technitium's native
clustering (v14+) joins nodes by IP address rather than hostname, and Pod IPs are not stable
across restarts. `podAntiAffinity` defaults to `required` and `podDisruptionBudget` is enabled by
default, both spreading and protecting replicas across nodes.

## Values

This table is derived from `values.yaml` (its `# --` comments) and must be regenerated by hand
whenever `values.yaml` changes; there is no drift check enforcing that today.

| Key | Default | Description |
| --- | ------- | ----------- |
| `replicaCount` | `1` | Number of StatefulSet replicas. |
| `image.repository` | `docker.io/technitium/dns-server` | Image repository. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `image.tag` | `""` | Image tag. Defaults to `.Chart.AppVersion` when empty. |
| `imagePullSecrets` | `[]` | References to Secrets holding credentials for a private image registry. |
| `nameOverride` | `""` | Overrides the chart name portion of generated resource names. |
| `fullnameOverride` | `""` | Overrides the fully generated resource name. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the pod. |
| `serviceAccount.automount` | `true` | Automount the ServiceAccount API token into the pod. |
| `serviceAccount.annotations` | `{}` | Annotations added to the ServiceAccount. |
| `serviceAccount.name` | `""` | Name of the ServiceAccount to use. |
| `podAnnotations` | `{}` | Annotations added to the pod. |
| `podLabels` | `{}` | Labels added to the pod. |
| `podSecurityContext` | `{}` | Pod-level securityContext. |
| `securityContext` | `{}` | Container-level securityContext. |
| `service.type` | `ClusterIP` | Service type for the DNS and web console ports. |
| `service.dnsPort` | `53` | Port the DNS service listens on, both UDP and TCP. |
| `service.webPort` | `5380` | Web console port (plain HTTP). Also sets `DNS_SERVER_WEB_SERVICE_HTTP_PORT`. First-boot only. |
| `service.httpsPort` | `53443` | Web console port over HTTPS, while `webService.enableHttps` is true. Also sets `DNS_SERVER_WEB_SERVICE_HTTPS_PORT`. First-boot only. |
| `service.annotations` | `{}` | Annotations added to the Service. |
| `service.externalTrafficPolicy` | `Local` | externalTrafficPolicy for the aggregate Service. Emitted only for LoadBalancer and NodePort. |
| `perReplicaService.enabled` | `true` | Create one Service per StatefulSet replica. |
| `perReplicaService.type` | `LoadBalancer` | Service type for each per-replica Service. |
| `perReplicaService.loadBalancerIPs` | `[]` | Index-aligned addresses, one per replica. |
| `perReplicaService.loadBalancerClass` | `""` | loadBalancerClass for each per-replica Service. |
| `perReplicaService.annotations` | `[]` | Index-aligned annotations, one map per replica. |
| `perReplicaService.externalTrafficPolicy` | `Local` | externalTrafficPolicy for each per-replica Service. |
| `server.domain` | `""` | `DNS_SERVER_DOMAIN`. First-boot only. |
| `server.preferIPv6` | `null` | `DNS_SERVER_PREFER_IPV6` (Boolean). First-boot only. |
| `auth.adminPassword` | `""` | Admin password; chart generates a Secret from this when set. |
| `auth.existingSecret.name` | `""` | Name of an existing Secret holding the admin password instead. |
| `auth.existingSecret.key` | `password` | Key within `auth.existingSecret.name`. |
| `webService.localAddresses` | `[]` | `DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES` (comma separated). First-boot only. |
| `webService.enableHttps` | `true` | `DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS` (Boolean). First-boot only. |
| `webService.useSelfSignedCert` | `true` | `DNS_SERVER_WEB_SERVICE_USE_SELF_SIGNED_CERT` (Boolean). First-boot only. |
| `webService.tlsCertificatePath` | `""` | `DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PATH`. First-boot only. |
| `webService.tlsCertificatePassword` | `""` | `DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PASSWORD`. First-boot only. |
| `webService.httpToTlsRedirect` | `null` | `DNS_SERVER_WEB_SERVICE_HTTP_TO_TLS_REDIRECT` (Boolean). First-boot only. |
| `webService.reverseProxyAddresses` | `[]` | `DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES` (ACL, comma separated). First-boot only. |
| `optionalProtocol.dnsOverHttp` | `null` | `DNS_SERVER_OPTIONAL_PROTOCOL_DNS_OVER_HTTP` (Boolean). First-boot only. |
| `recursion.mode` | `""` | `DNS_SERVER_RECURSION`: one of `Allow`, `Deny`, `AllowOnlyForPrivateNetworks`, `UseSpecifiedNetworkACL`. First-boot only. |
| `recursion.networkAcl` | `[]` | `DNS_SERVER_RECURSION_NETWORK_ACL` (ACL, comma separated). Only valid with `mode: UseSpecifiedNetworkACL`. First-boot only. |
| `blocking.enabled` | `null` | `DNS_SERVER_ENABLE_BLOCKING` (Boolean). First-boot only. |
| `blocking.allowTxtBlockingReport` | `null` | `DNS_SERVER_ALLOW_TXT_BLOCKING_REPORT` (Boolean). First-boot only. |
| `blocking.blockListUrls` | `[]` | `DNS_SERVER_BLOCK_LIST_URLS` (comma separated). First-boot only. |
| `forwarders.servers` | `[]` | `DNS_SERVER_FORWARDERS` (comma separated). First-boot only. |
| `forwarders.protocol` | `""` | `DNS_SERVER_FORWARDER_PROTOCOL`: one of `Udp`, `Tcp`, `Tls`, `Https`, `HttpsJson`. First-boot only. |
| `logging.useLocalTime` | `null` | `DNS_SERVER_LOG_USING_LOCAL_TIME` (Boolean). First-boot only. |
| `logging.folderPath` | `""` | `DNS_SERVER_LOG_FOLDER_PATH`. First-boot only. |
| `logging.maxLogFileDays` | `null` | `DNS_SERVER_LOG_MAX_LOG_FILE_DAYS` (Integer, 0 disables auto-delete). First-boot only. |
| `stats.enableInMemoryStats` | `null` | `DNS_SERVER_STATS_ENABLE_IN_MEMORY_STATS` (Boolean). First-boot only. |
| `stats.maxStatFileDays` | `null` | `DNS_SERVER_STATS_MAX_STAT_FILE_DAYS` (Integer, 0 disables auto-delete). First-boot only. |
| `sso.enabled` | `null` | `DNS_SERVER_SSO_ENABLED` (Boolean). First-boot only. |
| `sso.authority` | `""` | `DNS_SERVER_SSO_AUTHORITY`. First-boot only. |
| `sso.clientId` | `""` | `DNS_SERVER_SSO_CLIENT_ID`. First-boot only. |
| `sso.clientSecret` | `""` | OIDC client secret; chart generates a Secret from this when set. |
| `sso.existingSecret.name` | `""` | Name of an existing Secret holding the OIDC client secret instead. |
| `sso.existingSecret.key` | `client-secret` | Key within `sso.existingSecret.name`. |
| `sso.metadataAddress` | `""` | `DNS_SERVER_SSO_METADATA_ADDRESS`. First-boot only. |
| `sso.scopes` | `[]` | `DNS_SERVER_SSO_SCOPES` (comma separated); `openid`/`profile` are added by Technitium itself. First-boot only. |
| `sso.allowSignup` | `null` | `DNS_SERVER_SSO_ALLOW_SIGNUP` (Boolean). First-boot only. |
| `sso.allowSignupOnlyForMappedUsers` | `null` | `DNS_SERVER_SSO_ALLOW_SIGNUP_ONLY_FOR_MAPPED_USERS` (Boolean). First-boot only. |
| `sso.groupMap` | `[]` | List of `{remote, local}` pairs, rendered as `DNS_SERVER_SSO_GROUP_MAP`. First-boot only. |
| `optionalListeners.*.enabled` | `false` | See [Optional listener ports](#optional-listener-ports). |
| `ingress.enabled` | `false` | Create an Ingress for the web console. |
| `ingress.className` | `""` | IngressClass to use. |
| `ingress.annotations` | `{}` | Annotations added to the Ingress. |
| `ingress.hosts` | see `values.yaml` | Hosts and paths routed to the web console. |
| `ingress.tls` | `[]` | TLS configuration blocks. |
| `persistence.size` | `1Gi` | Size of the volumeClaimTemplate. |
| `persistence.storageClass` | `""` | StorageClass for the volumeClaimTemplate. |
| `persistence.accessModes` | `[ReadWriteOnce]` | Access modes for the volumeClaimTemplate. |
| `persistence.annotations` | `{}` | Annotations added to the volumeClaimTemplate. |
| `persistence.mountPath` | `/etc/dns` | Container path the data volume is mounted at. |
| `persistence.retentionPolicy.whenDeleted` | `Retain` | Fate of each replica's PVC when the StatefulSet is deleted. |
| `persistence.retentionPolicy.whenScaled` | `Retain` | Fate of a replica's PVC when the StatefulSet is scaled down. |
| `readinessProbe.*` | see `values.yaml` | Readiness probe path, port and timing. |
| `livenessProbe.*` | see `values.yaml` | Liveness probe port and timing. |
| `startupProbe.*` | see `values.yaml` | Startup probe path, port and timing. |
| `resources` | `{}` | Resource requests and limits for the container. |
| `extraEnvVars` | `[]` | Additional environment variables, appended after every structured variable above. |
| `nodeSelector` | `{}` | Node selector for pod scheduling. |
| `tolerations` | `[]` | Tolerations for pod scheduling. |
| `priorityClassName` | `""` | PriorityClass for the pods. Consider `system-cluster-critical`. |
| `affinity` | `{}` | Affinity rules; overrides `podAntiAffinity` entirely when set. |
| `podAntiAffinity` | `required` | Anti-affinity mode: `required`, `preferred`, or `""`. |
| `podDisruptionBudget.enabled` | `true` | Create a PodDisruptionBudget. |
| `podDisruptionBudget.maxUnavailable` | `1` | Maximum unavailable replicas. Mutually exclusive with `minAvailable`. |
| `podDisruptionBudget.minAvailable` | `""` | Minimum available replicas. Mutually exclusive with `maxUnavailable`. |
| `updateStrategy.type` | `RollingUpdate` | StatefulSet update strategy. |
| `test.image.*` | see `values.yaml` | Image used by the `helm test` hook that calls the unauthenticated `GET /api/status` endpoint. |
| `test.dnsImage.*` | see `values.yaml` | Image used by the `helm test` hook that resolves a name; needs a DNS client rather than curl. |
| `test.recursion.enabled` | `false` | Run a helm test that resolves a public name to prove recursion works. Off by default: needs egress to the public internet. |
| `test.recursion.queryName` | `example.com` | Name the recursion test resolves. |

See `values.yaml` for the full set of comments; every value there carries one.

## High availability clustering

Standing up Technitium's native clustering (v14+) across replicas is a manual, one-time step by
design: see [docs/clustering.md](docs/clustering.md) for the console and API paths, and the
sharp edges that come with it.
