# Tailscale Multi-Tenant ACL Isolation

## Problem

In a multi-tenant k8s cluster, any namespace can create a Service with the Tailscale egress annotation:

```yaml
annotations:
  tailscale.com/tailnet-fqdn: frank.shark-puffin.ts.net
```

The Tailscale operator will create an egress proxy for it, and that proxy gets the cluster-wide tag (e.g., `tag:cluster01`). There is no way to distinguish in the Tailscale ACL whether traffic comes from `awx-prod` or `teamb` — both appear as `tag:cluster01`.

## Why ProxyClass Doesn't Fully Solve It

ProxyClass allows assigning per-proxy tags (e.g., `tag:cluster01-awx`). But:
- ProxyClass resources are namespace-scoped
- Any team with namespace access can create a ProxyClass requesting any tag
- Without admission control (Kyverno/OPA), teamB can create a ProxyClass in their namespace with `tag:cluster01-awx` and get the same ACL permissions as AWX

## Current State

- SSH ACL uses `tag:cluster01` — all cluster01 egress proxies can SSH to managed hosts as `zemadmin`
- This is acceptable given that creating egress proxies requires namespace-level k8s access, not arbitrary internet access
- True per-namespace Tailscale identity isolation is not yet supported by the operator

## Mitigations (not yet implemented)

1. **Kyverno policy** — restrict ProxyClass resources to the `tailscale` namespace only, preventing arbitrary tag assignment by tenants
2. **Wait for upstream** — the Tailscale k8s operator does not currently support namespace-scoped tag authorization; track the tailscale/tailscale repo for operator multi-tenancy improvements

## References

- [Tailscale cluster egress docs](https://tailscale.com/docs/features/kubernetes-operator/how-to/cluster-egress)
- [ProxyClass docs](https://tailscale.com/docs/features/kubernetes-operator/how-to/proxyclass)
