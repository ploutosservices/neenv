# neenv

*Neenv* (नींव) is a foundation: the ground prepared before any wall goes up. A door, a file store or a mail
service cannot stand on raw ground. Each needs the same things to be true first: machines that answer, names
that resolve, certificates that every machine trusts, a place to keep secrets, someone watching.

This repository is not software. Neenv is not a product to install. It is the list of what must already be
true on a platform before the applications on it can stand, and what each layer carries for them. Every layer
is a commodity part; what is written here is which parts, and why each one is needed.

## What stands on it

| Project | What it is | What it needs from neenv |
|---|---|---|
| [dvar](https://github.com/ploutosservices/dvar) | the front door several applications share: one sign-in | every layer below; it is the first structure on the ground |
| [chowkidar](https://github.com/ploutosservices/chowkidar) | the guard inside dvar's sign-in server | what dvar needs |
| [bhandara](https://github.com/ploutosservices/bhandara) | a file store that every application keeps its files in | PostgreSQL, an S3-style store, certificates, names |
| [dakiya](https://github.com/ploutosservices/dakiya) | one mail-sending service for every application | PostgreSQL, certificates, names, a secret store |

Anything built later stands on the same ground. Nothing in this table can exist without it.

## The layers

| Layer | What it carries |
|---|---|
| **Machines and power** | Servers that stay up, and a UPS under each one that shuts it down cleanly when the battery runs low. |
| **The network** | A private network joining every site and every device (WireGuard, for example), so a phone away from home reaches a service as if it were at home. |
| **DNS** | A name for every service. A name is how a person finds a service, and how the door knows where to send them back. |
| **A certificate authority** | One root that every machine trusts. A browser trusts the door, the door trusts a service's back channel, and the proxy trusts a service's certificate, all because of that root. |
| **A reverse proxy** | Holds TLS for every name. It verifies a calling service's certificate and tells the service behind it who is calling. |
| **PostgreSQL** | Holds the state of the door and of the services that serve other services. |
| **A public domain** | The door's address: the one place a stranger is sent to sign in. |
| **A scheduler** | Every recurring job (backups, checks, renewals) runs in one place, where its last run can be seen. |
| **Monitoring** | Every layer and every service is checked, and a failure reaches a person. |
| **A secret store** | Passwords and keys live in one store, never in a file beside the service that uses them. |

## Before building on it

Check that each of these is true first:

- [ ] machines with power protection, and a network joining them;
- [ ] a private network every device can join;
- [ ] DNS for every name the services answer to;
- [ ] a certificate authority whose root every machine trusts;
- [ ] a reverse proxy holding TLS for those names;
- [ ] PostgreSQL;
- [ ] a public domain for the door;
- [ ] a scheduler, monitoring and a secret store.

For a trial, [dvar's demo](https://github.com/ploutosservices/dvar#2-try-it) prepares a small neenv for you: a
throwaway certificate authority, nginx, PostgreSQL, an S3 store and a mail sink, in one compose file you can
read in one sitting.

## Licence

Apache-2.0. Copyright 2026 Ploutos Services LLC.
