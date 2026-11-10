<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="mark/neenv.svg"><img src="mark/neenv-dark.svg" width="112" alt="neenv's mark: a stepped stone foundation under the ground line, two walls rising from it, open above"></picture></p>

# neenv

*Neenv* (नींव) is a foundation: the ground prepared before any wall goes up. A door, a file store or a mail
service cannot stand on raw ground. Each needs the same things to be true first: machines that answer, names
that resolve, certificates that every machine trusts, a place to keep secrets, someone watching.

This repository is not software. Neenv is not a product to install. It is the list of what must already be
true on a platform before the applications on it can stand, and what each layer carries for them. Every layer
is a commodity part; what is written here is which parts, and why each one is needed.

## What stands on it

| | Project | What it is | What it needs from neenv |
|---|---|---|---|
| <picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ploutosservices/dvar/main/mark/dvar.svg"><img src="https://raw.githubusercontent.com/ploutosservices/dvar/main/mark/dvar-dark.svg" width="28" alt="dvar's mark"></picture> | [dvar](https://github.com/ploutosservices/dvar) | the front door several applications share: one sign-in | every layer below; it is the first structure on the ground |
| <picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ploutosservices/chowkidar/HEAD/themes/chowkidar/login/resources/img/chowkidar-v2.svg"><img src="https://raw.githubusercontent.com/ploutosservices/chowkidar/HEAD/themes/chowkidar/login/resources/img/chowkidar-dark-v1.svg" width="28" alt="chowkidar's mark"></picture> | [chowkidar](https://github.com/ploutosservices/chowkidar) | the guard inside dvar's sign-in server | what dvar needs |
| <picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ploutosservices/bhandara/main/mark/bhandara.svg"><img src="https://raw.githubusercontent.com/ploutosservices/bhandara/main/mark/bhandara-dark.svg" width="28" alt="bhandara's mark"></picture> | [bhandara](https://github.com/ploutosservices/bhandara) | a file store that every application keeps its files in | PostgreSQL, an S3-style store, certificates, names |
| <picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ploutosservices/dakiya/main/mark/dakiya.svg"><img src="https://raw.githubusercontent.com/ploutosservices/dakiya/main/mark/dakiya-dark.svg" width="28" alt="dakiya's mark"></picture> | [dakiya](https://github.com/ploutosservices/dakiya) | one mail-sending service for every application | PostgreSQL, certificates, names, a secret store |

Anything built later stands on the same ground. Nothing in this table can exist without it.

## The layers

Each layer is a commodity part. The right-hand column is what we run for it; any part that does the same job will do.

| Layer | What it carries | What we run |
|---|---|---|
| **Machines and power** | Servers that stay up, and a UPS under each one that shuts it down cleanly when the battery runs low. | [Debian](https://www.debian.org/) on bare metal, no virtual machines; [NUT](https://networkupstools.org/) watches each UPS |
| **The network** | A private network joining every site and every device, so a phone away from home reaches a service as if it were at home. | [WireGuard](https://www.wireguard.com/), a full mesh between the sites; [Tailscale](https://tailscale.com/) as a second road where no port can be opened inward |
| **DNS** | A name for every service. A name is how a person finds a service, and how the door knows where to send them back. | [Bind9](https://www.isc.org/bind/) on several servers for private names; [Cloudflare](https://www.cloudflare.com/) for public ones; [OctoDNS](https://github.com/octodns/octodns) writes both from files in git |
| **A catalogue** | One list of every machine, service, name and address, which the other layers read instead of keeping their own copies. | [NetBox](https://netbox.dev/), loaded from files in git; [Ansible](https://www.ansible.com/) reads its machines from it |
| **A certificate authority** | One root that every machine trusts. A browser trusts the door, the door trusts a service's back channel, and the proxy trusts a service's certificate, all because of that root. | [step-ca](https://smallstep.com/docs/step-ca/), with ACME for servers and SCEP for phones; the root is limited to our own names (pattern below) |
| **A reverse proxy** | Holds TLS for every name. It verifies a calling service's certificate and tells the service behind it who is calling. | [nginx](https://nginx.org/) |
| **PostgreSQL** | Holds the state of the door and of the services that serve other services. | [PostgreSQL](https://www.postgresql.org/); [MariaDB](https://mariadb.org/) for the older applications |
| **An object store** | Files kept as objects, encrypted with a key the store never sees. | [Garage](https://garagehq.deuxfleurs.fr/) (S3-compatible), with customer-supplied keys |
| **A public domain** | The door's address: the one place a stranger is sent to sign in. | [Keycloak](https://www.keycloak.org/) behind the door's public name |
| **A scheduler** | Every recurring job (backups, checks, renewals) runs in one place, where its last run can be seen. | [Windmill](https://www.windmill.dev/); its jobs live in git |
| **Backups** | Every store copied each night to a second place and a third, off site, and a restore proved on a schedule rather than assumed. | [restic](https://restic.net/) to a [REST server](https://github.com/restic/rest-server) at home and an append-only twin abroad; a nightly job restores and checks |
| **Monitoring** | Every layer and every service is checked, and a failure reaches a person. | [Prometheus](https://prometheus.io/), [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) and [Grafana](https://grafana.com/), with the [blackbox](https://github.com/prometheus/blackbox_exporter) and [node exporters](https://github.com/prometheus/node_exporter); alerts land in [Mattermost](https://mattermost.com/) and by email |
| **Mail** | Mail in for a named list of addresses, kept where a machine reads it; mail out signed so it is not taken for spam. | [Postfix](https://www.postfix.org/) at the edge accepting only the listed addresses, with [OpenDKIM](http://www.opendkim.org/); [Dovecot](https://www.dovecot.org/) stores what arrives (LMTP into Maildir, read by machines, no IMAP served); outgoing mail through [Google Workspace](https://workspace.google.com/) |
| **Chat** | Where people and agents write to each other, and where alerts and job results are posted. | Mattermost, signed in through the door |
| **A secret store** | Passwords and keys live in one store, never in a file beside the service that uses them. | [OpenBao](https://openbao.org/) for machines (each reads with its own certificate); [Vaultwarden](https://github.com/dani-garcia/vaultwarden) for people |
| **Configuration and code** | Every machine is built from text, so a lost one is rebuilt rather than repaired. | Ansible from [Gitea](https://about.gitea.com/); [Gitea Actions](https://docs.gitea.com/usage/actions/overview) runs the checks and the deploys |

## Before building on it

Check that each of these is true first:

- [ ] machines with power protection, and a network joining them;
- [ ] a private network every device can join;
- [ ] DNS for every name the services answer to;
- [ ] a certificate authority whose root every machine trusts;
- [ ] a reverse proxy holding TLS for those names;
- [ ] PostgreSQL and an object store;
- [ ] a public domain for the door;
- [ ] a scheduler, backups that are restored on a schedule, monitoring and a secret store.

For a trial, [dvar's demo](https://github.com/ploutosservices/dvar#2-try-it) prepares a small neenv for you: a
throwaway certificate authority, nginx, PostgreSQL, an S3 store and a mail sink, in one compose file you can
read in one sitting.

## Patterns

How one layer is built well, with drills you can run yourself:

- [A root certificate limited to your own names](patterns/constrained-root/README.md). The certificate
  authority's root vouches only for your private names, so a stolen key cannot forge anyone else's website. It
  covers moving an existing root to it without re-issuing a key.
- [The root of trust](patterns/root-of-trust/README.md). Who signs what, where each key is kept, how the root
  is replaced, and how a certificate is taken back.
- [Names, public and private](patterns/names/README.md). Every name in git, resolvable anywhere, answered only to
  the private network when it is private.
- [Tenants](patterns/tenants/README.md). One declaration of each tenant's names, an edge that tells applications
  which tenant a request is for, and each application deciding who enters.
- [Many tenants' sites from one content system](patterns/cms-tenant/README.md). One installation for every
  tenant, with the edge and the sign-in keeping them apart.
- [Environments](patterns/environments/README.md). Development, staging and production from one declaration, and
  a check that fails on anything two of them share by accident.
- [The dev box](patterns/dev-box/README.md). One person and several AI agents on one machine, each its own user
  and identity, the auditor walled off.
- [Patching](patterns/patching/README.md). Security fixes go in by themselves every night; the full upgrade and
  the reboot once a month, one machine at a time; an alert when either one is stuck.
- [Central logs](patterns/central-logs/README.md). Every server's journal copied, as it is written, to one store
  the sender can add to and never change, through a door that admits only log senders.
- [Walk-through](patterns/walk-through/README.md). One new tenant, from a domain name to a signed-in page.
- [The practice](patterns/the-practice/README.md). The written rules that let agents build and run it.

### What a drill's exit code means

Every drill answers the same way, so a script can run them all:

| Exit | Run without `ARM` | Run with `ARM=<name>` (one fix removed on purpose) |
|---|---|---|
| 0 | every check passed | exactly the checks that arm should break failed, and no others |
| 1 | a check failed | the arm did not break what it should, or broke something else: the drill cannot tell |
| 2 | it could not run: a missing tool, an unknown arm, a setup step that failed | the same |

An arm run that exits 0 is the proof that each check can fail. A check that never fails proves nothing. Three drills
carry their arms inside one command instead: `drill-environments.sh selftest`, the practice's
`drill-done.sh selftest` and `drill-patching.sh rules` run one passing case and several broken ones, and exit 0
only when each comes out as it must.

## Licence

Apache-2.0. Copyright 2026 Ploutos Services LLC.
