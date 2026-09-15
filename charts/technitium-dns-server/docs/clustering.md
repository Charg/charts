# High availability: native clustering

`replicaCount` gives you independent DNS servers spread across nodes (see the README's
[High availability](../README.md#high-availability) section). Wiring those replicas into a
single Technitium cluster, so config, DNSSEC keys and zones sync between them, is a separate,
manual step that this chart deliberately does not automate.

Technitium's clustering API takes administration credentials. A chart-managed job that called
it on every install or upgrade would mean the chart holds an admin token for your DNS server.
Instead, cluster init and cluster join are one-time operations you run yourself, once, against
a running deployment, the same way you'd run them against bare-metal Technitium installs.

**Requires Technitium v14 or newer.** Earlier versions have no clustering feature at all; HA on
those versions meant scripted backup-and-restore between independent nodes, which is out of
scope for this chart. Check `appVersion` in `Chart.yaml` (or `image.tag` if overridden) before
following this guide.

## Before you start

- `perReplicaService.enabled` must be on (it is by default). Clustering joins nodes by IP
  address, not hostname, and Pod IPs are not stable across restarts, so each replica needs a
  Service-backed address of its own.
- `webService.enableHttps` must be on (it is by default, on `service.httpsPort`, 53443). Cluster
  init and join talk to the primary over the web service's HTTPS API port. If HTTPS were off,
  upstream enables it automatically with a self-signed certificate the moment you call init or
  initJoin, so there's no way to cluster without HTTPS one way or another.
- Find each replica's actual address before you start:

  ```bash
  kubectl get svc -n <namespace> -l "app.kubernetes.io/name=technitium-dns-server,app.kubernetes.io/instance=<release>"
  ```

  Use the addresses these Services were actually assigned (or the ones you requested via
  `perReplicaService.loadBalancerIPs`), not Pod IPs.

## Hostnames vs. IP addresses

Every node-identity parameter in the clustering API (`primaryNodeIpAddresses`,
`secondaryNodeIpAddresses`, `primaryNodeIpAddress`) takes a **literal IP address**, not a
hostname. The only parameter that accepts a hostname is `primaryNodeUrl`, and upstream resolves
that URL's domain name to an IP address itself when `primaryNodeIpAddress` is omitted. Node
identity inside the cluster is by IP, full stop.

This is exactly why `perReplicaService` exists: without a stable, operator-known address per
replica, there is nothing valid to hand to these parameters.

## Console path

1. Log in to the primary replica's web console (the first replica you want to initialize).
2. Under Administration > Cluster, choose Initialize, and supply the cluster domain and this
   node's IP address(es).
3. Log in to each remaining replica's console and choose Join, pointing it at the primary's
   HTTPS URL and credentials.

The console screens are a thin front end over the same API calls below; if a field in the
console isn't obvious, the API parameter names in the next section describe what it sends.

## API path

All calls require `Authorization: Bearer <token>`, where the token comes from Technitium's
`login` or `createToken` API call. Init and join need the Administration: Delete permission;
reading cluster state only needs Administration: View.

**1. Initialize on the first replica** (this node becomes Primary):

```
POST /api/admin/cluster/init?clusterDomain=<fqdn>&primaryNodeIpAddresses=<ip[,ip]>
```

`primaryNodeIpAddresses` is a comma-separated list if the primary itself is reachable at more
than one address.

**2. Join from each remaining replica** (this node becomes Secondary), as a
`application/x-www-form-urlencoded` POST body:

```
POST /api/admin/cluster/initJoin
```

| Parameter | Required | Notes |
| --- | --- | --- |
| `secondaryNodeIpAddresses` | yes | Comma-separated literal IP address(es) of this node. |
| `primaryNodeUrl` | yes | The primary's web service HTTPS URL. Hostname is fine here. |
| `primaryNodeIpAddress` | no | Literal IP. Resolved from `primaryNodeUrl` when omitted. |
| `ignoreCertificateErrors` | no | Only for a self-signed primary on a private network. |
| `primaryNodeUsername` | no | Primary admin username. |
| `primaryNodePassword` | no | Primary admin password. |
| `primaryNodeTotp` | no | Primary admin TOTP code, if 2FA is enabled. |

**3. Inspect cluster state from any node:**

```
GET /api/admin/cluster/state?includeServerIpAddresses=true
```

## Sharp edges

**Joining overwrites the joining node, permanently.** `initJoin` overwrites this server's
Allowed, Blocked, Apps, Settings and Administration sections with the primary's. A secondary is
a read-only replica of the primary's configuration, not a peer with its own independent config.
Do not join a node that already holds configuration you want to keep.

**Zones don't replicate unless you put them in the catalog zone.** Cluster init creates a
Cluster Primary zone for the cluster domain and, alongside it, an auto-created Cluster Catalog
zone at `cluster-catalog.<clusterDomain>`. Only zones added to that catalog zone sync to
secondaries; any other zone stays local to whichever node it was created on.

**Losing the primary blocks configuration changes, not resolution.** DNS queries keep being
answered by whichever secondaries are up. Every secondary already holds a full copy of the
DNSSEC keys, so promoting one to primary is always possible, but nothing does it for you: a
human has to make that call and run the promotion. Until then, no cluster-wide configuration
change can be made.

**DHCP is not clustered.** DHCP scopes and leases are per-node state; clustering does not touch
them. If you need DHCP HA, the workaround is split-scope (dividing the address range between
nodes yourself), not clustering.

**The cluster domain is immutable.** Once you initialize with a `clusterDomain`, it cannot be
changed later. Pick it deliberately.

**Every node in a cluster should run the same Technitium version.** A default rolling update
(`updateStrategy.type: RollingUpdate`) runs a mix of old- and new-version pods for the duration
of the rollout, which is a mixed-version cluster upstream doesn't support across a major
version bump. For a cross-major upgrade of a clustered deployment, set:

```yaml
updateStrategy:
  type: OnDelete
```

`OnDelete` is a real StatefulSet strategy this chart passes through as-is: no pod is replaced
until you delete it yourself, so you control exactly when each node comes down and back up on
the new version, instead of Kubernetes rolling them automatically.

**Configuration values apply on first boot only, still.** Everything in the chart's
[First-boot-only configuration](../README.md#first-boot-only-configuration) section applies here
too: `helm upgrade` after a value change does not reconfigure an already-initialized replica,
clustered or not. Reconfigure through the console or API, on whichever node the setting belongs
to (the primary, for anything that replicates via the catalog zone).
