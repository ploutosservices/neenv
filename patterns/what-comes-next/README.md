# What comes next, and what is left out

Every idea neenv has considered and not yet written up is listed here, with where it stands. When one is written,
it moves to its own page and leaves this list. When one is declined, it stays here with the reason.

**The order of work, as the owner decided it:** first patching ([written](../patching/README.md); scanning
application dependencies is open there), central logs ([written](../central-logs/README.md)), host firewalls ([written](../segmentation/README.md): segmentation without them, and why a
default-deny firewall on the servers at home was declined), disaster recovery
with succession ([written](../disaster-recovery/README.md)), and a second factor for privileged people
([written](../second-factor/README.md)); then the rest. The guide counts as proven when someone
who wrote none of it rebuilds a working copy from it alone.

## Patterns still to write

| Pattern | What it will explain |
|---|---|
| The first day | How the first secret, the root key and the first administrator's device come to exist |
| Machines, network and egress | Provisioning from the catalogue; the private mesh; what may reach what, inward and outward; one server or many, and the reasons to split |
| Certificates for private names | Let's Encrypt by DNS challenge, so a private site carries a publicly trusted certificate, and the cost: the name appears in Certificate Transparency logs |
| Device certificates | A machine proves who it is; the door refuses an administrator without one |
| Agent identity | How each agent proves who it is, the least it may do, and how its credentials are revoked |
| Secrets and tokens | One path per client and environment, read by the reader's own identity; rotation and expiry; break-glass access |
| The door | A sign-in client per tenant and environment; roles given at the door |
| Shared services | The proxy (TLS, limits, floods), databases, object store, scheduler, mail and chat, each one layer every application uses |
| Encryption for few readers | Records only their readers can open: a household's key, customer-supplied keys in the object store |
| Deploys and supply chain | Production changed only by audited steps; where code comes from, pinned and checked; patching |
| Backups and restores | Each store copied off site nightly, a restore proved on a schedule, restoring one tenant, recovery targets, losing a whole site |
| Moving a store of record | An application's database moved to another engine with no replica: one recorded state (old, draining, drained, new); the drain closes writes at the one connection point and compares every row; a service boots on the new store only once drained; rollback without a restore only until the first write on the new store; the old store's binlog, not a table checksum, proves it was left untouched. Built and rehearsed twice by one application |
| Watching and logs | Checks, alerts and the audit log; what logs keep of tenant data, and for how long; per-tenant limits |
| Incidents | What happens when a root, a device, a token or an agent is compromised, end to end |
| Checks, not trust | An agent's work is caught where it lands: the push refuses a commit with no reason, a check refuses what does not match |
| What it costs | The yearly total by kind: hardware, services, subscriptions |

## Enterprise ideas, each with a verdict

A reviewer with no knowledge of this estate read neenv and listed what an enterprise platform has that neenv does
not yet cover. The verdict weighs each against an estate of one decider. *Adopt* means it will be written up as a
pattern with a drill; *consider* means it is open; *declined* means it is not done here, for the reason given.

| Area | Idea | Verdict |
|---|---|---|
| Security | The development machine blocked from production by the machines, not only by credentials | adopt |
| Operations | A one-page incident runbook | adopt |
| Operations | Time synchronisation (chrony against several sources) | adopt |
| Delivery | Build once and promote the same artefact (a version or digest) | adopt |
| Capacity | Disk and growth forecasts, drive health alerts | adopt |
| Information | Retention, deletion and a tenant's departure | adopt, once a tenant outside the family exists |
| Security | Per-agent sandboxes beyond the production block | consider |
| Security | Secret rotation on a schedule (OpenBao leases, dynamic database credentials) | consider |
| Security | A hardware token for the CA keys | consider |
| Reliability | A standby for the CA and the door | consider |
| Reliability | Restoring one tenant without the others | consider |
| Operations | Service objectives and a runbook per alert | consider |
| Delivery | Rollback without losing data; expand-then-contract migrations | consider |
| Information | Masking data copied to staging | consider |
| Capacity | Spares and a replacement plan for the hardware | consider |
| Other | Treating what agents read (mail, web, tenant pages) as untrusted input | consider |
| Security | A default-deny host firewall (nftables) on the servers behind the routers | declined: the routers forward three ports, and bind addresses declared per socket and checked daily do the separating without a second list of ports ([why](../segmentation/README.md)); the machines with public addresses keep theirs |
| Security | A cluster of hardware security modules | declined: a single token covers the need at this size |
| Reliability | Full high availability for every service | declined: a standby for the few single points covers it |
| Delivery | Signed builds and a bill of materials (cosign, SLSA) | declined: pinned dependencies and one promoted artefact give most of the value |
| Information | Formal frameworks (SOC 2, ISO 27001) | declined until a client asks for one |
| Capacity | Cost tracking | declined: the costs are few and fixed |

## Left out of neenv

- **Migrations across tenants.** This estate has none to show; it is written when one happens.
- **What a tenant is promised about its data** (the law that applies, where it is held). That is a promise the firm
  makes to its clients, not a pattern.
