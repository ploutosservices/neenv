# Walk-through: one new tenant, from a domain name to a signed-in page

This walk-through follows one tenant through every layer, in the order the work is done. Each step names the pattern
that explains it in full. The tenant is a family that wants one private site where its members find what is sent to
them. A public site follows the same steps without the private-network parts of steps 2 to 4.

The example names: the tenant key is `family`, its production name is `family.example.org`, and the environments are
production, staging and development. Here this took one working day, done by two AI agents: one that owns the
infrastructure (steps 1 to 5) and one that owns the content system (steps 6 to 8).

**Words used here.** *The door* is the one sign-in every application shares (Keycloak). *The content system* is one
MODX installation serving every tenant; a tenant there is a *context*. *The consumer* is whoever uses the finished
work.

## 1. Declare the tenant once

One entry in the tenant declaration gives the tenant its key and every name it answers to, in every environment.
Every configuration file below that spells the name is generated from this entry or checked against it.

```yaml
tenants:
  family:
    names:
      production:  [family.example.org]
      staging:     [family.staging.example.test]
      development: [family.dev.example.test]
```

**Patterns:** *Tenants*; *Environments*.

## 2. Give the names somewhere to point

The production name is a record in the public zone, written by OctoDNS from a zone file in git. Because the site is
private, the record points at an address on the private network: anyone can look the name up, but only a machine on
the private network (at home or through the tunnel) can connect to it. The staging and development names live in the
private zone. Two costs: the record discloses an internal address, and a home router with DNS-rebinding protection
drops such answers, so devices at home use the estate's own resolvers.

**Pattern:** *Names, public and private*.

## 3. Give the name a certificate

The site is private, so no public certificate authority can reach it to check it. Let's Encrypt's DNS challenge
proves control of the name through a DNS record instead of over HTTP, and the site gets a publicly trusted
certificate without being reachable from the internet. The cost: the name appears in the public Certificate Transparency logs. Staging and development names get
certificates from the estate's own constrained root, which a device trusts once that root is installed on it.

**Patterns:** *Certificates for private names*; *The root of trust*.

## 4. Let the edge recognise the tenant

The proxy configuration is generated from the declaration: one server block per name, refusing any caller from
outside the private network, and writing the tenant key into the `X-Tenant` value the application reads. The proxy
replaces any `X-Tenant` a caller sends, and the application listens only for the proxy, so a caller cannot set it.

**Patterns:** *Tenants*; *Shared services* (the proxy).

## 5. Give the tenant a client at the door

Sign-in is the shared door, and each tenant gets its own OpenID Connect client in each environment's realm, with
only its own sign-in callback allowed as a return address. The client's secret is written to the secret store under a
path per environment and client, readable only by the identities that need it.

**Patterns:** *The door*; *Secrets and tokens*.

Check before going further: the door's authorisation endpoint answers for the new client with its own callback, and
refuses an unknown client and a foreign return address.

## 6. Build the site in development

In the content system, the tenant is a new context: protected as a whole, a reader group holding the people who may
read it, and its first pages declared in git. Development's own values (names, door endpoints, client id) are written
into the installation from the declaration, and the site is built and checked there first.

**Pattern:** *Many tenants' sites from one content system* (`cms-tenant`).

The stranger's view is checked with [`drill-tenant.sh`](../cms-tenant/drill-tenant.sh), forging the key of `notes`, an open
tenant: if the proxy honoured the forged header, the stranger would be served the open tenant's page instead of the
same redirect.

```
OTHER=notes ./drill-tenant.sh check https://family.dev.example.test/
ok    a stranger is sent to sign in (302 -> https://family.dev.example.test/sso-login)
ok    a forged X-Tenant: notes changes nothing (302)
```

## 7. Promote through staging to production

The site's pages and settings are merged to the staging branch, which deploys them; then the same commit to the
production branch. The context itself is created on each environment by an audited step that takes a snapshot first.
Pages are created after their context exists. Production's page ids are the ones kept: they are pulled back into
git, and staging is refreshed from production so that its ids match.

**Patterns:** *Deploys and supply chain*; *Environments*.

What went wrong here, and what each taught:

- **The order matters.** The first production deploy ran before the context existed there. Its access step refused
  to half-apply and rolled itself back, so nothing was exposed; the deploy waited for the context.
- **People rename things.** A page renamed in the editor after it was created stopped the next deploy, which could
  no longer find the parent its declaration named. The fix was to bring the rename back into git.
- **Staging numbers its own pages.** Pages that staging and production created separately had different ids;
  refreshing staging from production made them agree. That refresh copies the family's private pages into staging,
  which keeps production's access rules and is reachable only on the private network; the data is not masked.

## 8. The consumer says it is done

The site is done when the people it is for can use it. A member signs in through the door and reads the pages; a
stranger is sent to sign in; a signed-in person outside the reader group is refused. The stranger's part is the
drill; the member's and the outsider's parts need someone to sign in: the family itself in production, or test
users at the door in staging. Those two checks are not yet scripted.

**Pattern:** *The practice* (done when the consumer says so).
