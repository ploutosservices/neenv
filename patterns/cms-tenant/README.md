# Many tenants' sites from one content system

## The problem

Several tenants each want a website: one public, one private to a family, one for a firm's staff. Running a
content system per tenant multiplies upgrades, backups and sign-in wiring. Running one for all of them risks the
worst failure a shared system has: one tenant reading another's pages.

This pattern runs **one installation for every tenant** (the *pool* model of multi-tenancy) and makes crossing
between tenants depend on the edge and the sign-in, never on what a caller sends.

## What runs here

**MODX Revolution**, an open-source PHP content system, behind nginx. MODX has *contexts*: several sites in one
installation, each with its own pages, settings and host names. Each tenant is one context.

Five rules make it safe:

1. **The edge decides the tenant, never the caller.** nginx has one server block per host name, generated from one
   declaration, and each writes that name's tenant key into the FastCGI parameter `HTTP_X_TENANT` in its only
   `location` that runs PHP. A FastCGI parameter of that name replaces any `X-Tenant` header the caller sent. A small
   file that runs before MODX starts picks the context from that key alone; stock MODX would choose by host name. A request
   that arrives with no key gets a fixed 404 before MODX starts, and a host name the declaration does not know is
   refused at the edge.
2. **A private tenant is protected whole.** Every page of a protected context belongs to one resource group, and
   only that tenant's reader group may view it. A plugin on MODX's save event puts a new page into the group in the
   same request that saves it, before the page is published to readers.
3. **The door proves who a person is; the content system decides whether they enter.** Sign-in is OpenID Connect
   at the shared door, with one client per tenant and environment. MODX checks that the token was issued to this
   context's own client (`aud`) and that the door has verified the address (`email_verified`). It then matches the
   address to one of its own users and admits only members of the tenant's reader group. An address it does not
   know is refused, and no user is made for it.
4. **A stranger is told how to sign in.** An anonymous request for a protected page gets a temporary redirect (302)
   to that site's own sign-in page, which starts the OpenID Connect flow with the context's client id and its own
   callback address.
5. **Each environment writes its own values.** Host names, sign-in endpoints and client ids are generated per
   environment (development, staging, production) from the same declaration, and a setup script writes them into
   the installation after every restore and deploy, then reads them back. A copy of production's data therefore
   never points a test site at production's sign-in. If the step is skipped, the site keeps production's values and
   its sign-in fails, which is the visible failure that says the step was missed.

## The declaration, with example values

A tenant is declared once. The edge's view, host name to tenant key:

```yaml
tenants:
  family:
    names:
      - family.example.org          # production
      - family.staging.example.test # staging
      - family.dev.example.test     # development
```

The content system's view of the same tenant. `groups` maps a reader group to the contexts it may read, then to
the users in it:

```json
"contexts": {
  "family": { "name": "Family", "protected": true, "home": "family" }
},
"groups": {
  "familyMember": [["family"], ["family-reader"]]
}
```

The edge, as generated for one of that tenant's names:

```nginx
server {
    server_name family.example.org;
    location ~ \.php$ {
        fastcgi_param HTTP_X_TENANT "family";   # replaces any X-Tenant the caller sent
    }
}
```

## Pages kept in git

Every page is a file in git, named by its address and by its id in production. A new page is declared by an entry
naming its tenant, its parent's address and its title; each environment's deploy creates the page under that
parent. After production has created it, production's id is pulled back into git, and staging is refreshed from
production so that its ids match. If the declared parent no longer exists (because someone renamed it in the
editor), the deploy stops rather than placing the page elsewhere, and the editor's rename must be brought back into
git first.

## The drill

[`drill-tenant.sh`](drill-tenant.sh) checks what a stranger sees, with no credential:

```
OTHER=notes EDGE=192.0.2.10 ./drill-tenant.sh check https://family.example.org/
ok    a stranger is sent to sign in (302 -> https://family.example.org/sso-login)
ok    a forged X-Tenant: notes changes nothing (302)
ok    an undeclared name reaches no tenant (the edge refused the handshake)
```

`OTHER` should be the key of a real *open* tenant: if the edge honoured a forged header, the stranger would be
served that tenant's page instead of being sent to sign in. `arm`, pointed at a page meant to be open, must see that
page served, which proves the drill tells a refusal from a served page; a dead host or any other answer makes `arm`
fail:

```
./drill-tenant.sh arm https://notes.example.org/thoughts
FAIL  a stranger was answered 200 (no redirect), not a 302/307 to https://notes.example.org/sso-login
ARM: check 1 failed because the open page was served, as it must
```

What a stranger cannot see is a member's view: that a member is admitted and a signed-in outsider refused needs test
users at the door in a non-production environment, signing in through the door's own form.

## What is still open

- **Staging holds real data.** It is refreshed from production, so private tenants' pages and users' addresses
  exist in staging. Staging keeps production's access rules and is reachable only on the private network; the
  data is not masked. That is accepted for a family's estate; an organisation holding customers' data would mask
  it on the way.
- **The editor and git can disagree.** A rename in the editor stops the next deploy until git is brought in line.
  The stop is deliberate; bringing the editor's change back is still a manual step.
