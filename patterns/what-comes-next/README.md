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
| Delivery | Build once and promote the same artefact (a version or digest) | adopt |
| Information | Retention, deletion and a tenant's departure | adopt: there are tenants outside the family |
| Security | Per-agent sandboxes beyond the production block | declined: each agent is already its own operating-system user with its own work tree and identity ([The dev box](../dev-box/README.md)) |
| Security | Secret rotation on a schedule (OpenBao leases, dynamic database credentials) | declined: the owner rotates after a leak, all at once on one day, not on a calendar; scheduled rotation broke more than it protected here. Where secrets live and who reads them is in [The root of trust](../root-of-trust/README.md) |
| Security | A hardware token for the CA keys | declined by the owner's ruling: no offline root and no separate custody to remember; the root key is an item in the password manager, written back only to mint an intermediate and removed again ([Disaster recovery](../disaster-recovery/README.md)) |
| Reliability | A standby for the CA and the door | adopt (the door has a cold standby abroad; the CA has none) |
| Reliability | Restoring one tenant without the others | adopt: there are tenants outside the family |
| Operations | Service objectives (SLOs) | declined: one decider, no contracts that promise an availability figure; the alerts say what is broken and what to do |
| Delivery | Rollback without losing data; expand-then-contract migrations | declined from neenv: how an application changes its own schema is each application owner's practice, not the foundation's |
| Information | Masking data copied to staging | declined by the owner's ruling: developers work against current production data, the outside tenants' included. The cost is stated, not hidden: a development machine holds real tenant data. That is one reason development machines are not log senders, and why keeping them out of production's stores by the machines themselves, not only by credentials, is an adopted idea |
| Capacity | Spares and a replacement plan for the hardware | declined: the hardware is a prototype the owner replaces when funded, and may not replace like for like; what it cannot do meanwhile is listed, and any server is rebuilt from declarations onto whatever machine is next ([Disaster recovery](../disaster-recovery/README.md)) |
| Other | Treating what agents read (mail, web, tenant pages) as untrusted input | adopt |
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
