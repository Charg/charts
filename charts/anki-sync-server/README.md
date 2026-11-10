# anki-sync-server

[Anki](https://apps.ankiweb.net)'s self-hosted [sync server](https://docs.ankiweb.net/sync-server.html),
which syncs collections, review history and media between Anki desktop, AnkiDroid and AnkiMobile
without AnkiWeb. Deployed as a single-replica Deployment from
[`ghcr.io/charg/containers/anki-sync-server`](https://github.com/Charg/containers/tree/main/images/anki-sync-server),
an image built from upstream source, running as a non-root user and signed with cosign.

## Install

```bash
helm install anki oci://ghcr.io/charg/charts/anki-sync-server \
  --set 'users[0].name=alice' --set 'users[0].password=correct-horse'
```

At least one user is required: the server refuses to start without one, so the chart fails the
template instead. Expose it with `ingress` or `httpRoute`, then point each client at the URL:

- **Anki desktop:** Preferences > Syncing > Self-hosted sync server.
- **AnkiDroid:** Settings > Sync > Custom sync server.
- **AnkiMobile:** Preferences > Syncing > Custom sync server.

Put it behind TLS. Clients send the password on every login.

## Users

Each user gets a separate collection under `/anki_data/<name>`. Supply them in one of two ways,
not both:

- **`users`**: a list of `{name, password}`. The chart renders them into a Secret of its own as
  `SYNC_USER1`, `SYNC_USER2`, ... in list order, and rolls the pod when the list changes.
- **`existingSecret`**: the name of a Secret you manage, with keys `SYNC_USER1`, `SYNC_USER2`, ...
  and `name:password` values. A change to it needs `kubectl rollout restart`, since the server
  reads users only at start.

Either way the Secret is loaded with `envFrom`, so no password appears in the pod spec. Names
must not contain `:` and must be unique; the chart checks both.

Set `passwordsHashed: true` to store PHC-format PBKDF2 hashes instead of plain passwords. The
`helm test` hook logs in as the first user to prove the credentials work end to end, which it
can't do with a hash, so with hashed passwords it only checks `/health`.

Removing a user from the list doesn't delete their folder on the volume.

## Single replica, by design

There is no `replicaCount`. Each collection is a SQLite database on a `ReadWriteOnce` volume,
and sync sessions are held in process memory. A second replica would fail to mount the volume,
or corrupt a collection by writing it from two processes. For the same reason `strategy`
defaults to `Recreate`.

## Large uploads behind a proxy

A full sync uploads the whole collection in one request, and media syncs send batches of files.
The server accepts up to 100 MB per request by default (`maxPayloadMegs`); a proxy in front needs
a body-size limit at least that large, or big syncs fail with 413. For ingress-nginx:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

Set `ipHeader` (usually `RightmostXForwardedFor`) so the server logs client addresses rather than
the proxy's. Only do this when every client goes through that proxy: the server then fails any
sync request missing the header with a 500 (`missing ip`), so `kubectl port-forward` and
in-cluster clients stop working. The `helm test` hook sends the header itself.

Anki serves its endpoints (`/sync`, `/msync`) at the root, so route a whole hostname to it; a
sub-path doesn't work.

## Security

The image runs as distroless' `nonroot` user (65532), and the chart's defaults run it with a
read-only root filesystem, no capabilities, no privilege escalation and the `RuntimeDefault`
seccomp profile. `fsGroup: 65532` makes the data volume writable; `/tmp` is an `emptyDir`.

The image tag follows the Anki version and is rebuilt in place when its base image picks up
security fixes. Pin `image.digest` if you need byte-for-byte reproducible deploys, and verify the
signature with:

```bash
cosign verify ghcr.io/charg/containers/anki-sync-server:26.09.4 \
  --certificate-identity-regexp '^https://github.com/Charg/containers/\.github/workflows/release\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Persistence

`/anki_data` holds every user's collection and media, on a chart-created 5Gi PVC by default.
Media dominates; size it for every user's media folder. The claim carries
`helm.sh/resource-policy: keep`, so `helm uninstall` leaves it behind (`persistence.keep`).
Delete it by hand once the data is genuinely no longer needed.

## Values

See [values.yaml](values.yaml); every value is documented there.
