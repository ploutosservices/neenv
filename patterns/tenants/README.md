# Tenants: one declaration, one edge that names them, each application deciding entry

## The problem

Several groups of people share the same applications: a family, a firm, a school. Each application runs in
development, staging and production. Every request has to be served as one tenant's, and the worst failure a shared
system has is serving it as another's: one tenant reading another's pages, files or accounts.

Three things go wrong in practice. The fact "which tenant is this name" is copied into every application and the
copies drift. An application trusts a tenant header that a caller can type. And a name nobody declared lands on
whichever site the proxy happens to list first.

This pattern keeps the tenant in one declaration, lets only the edge proxy tell an application which tenant a request
is for, and leaves the decision about who may enter to each application.

**Words used here.** A *tenant* is a group of people whose data it is; its key names the people (`acme`, `family`),
never an application or a module. A *name* is a host name a person or program calls. *The edge* is the reverse proxy
in front of every application. *The door* is the one sign-in every application shares (OpenID Connect).

## What runs here

**nginx** at the edge, **Keycloak** as the door, and applications that each choose how they keep tenants apart.

### 1. One declaration owns "which tenant is this name"

Every name belongs to exactly one tenant and one application. The tenant is the declaration's fact; which application
serves the name is the catalogue's: one list of every machine, service, name and address, which the other layers
read instead of keeping copies ([The layers](../../README.md#the-layers)). A check holds the two name lists to one set.
Nothing else in the estate may say which tenant a name is: not a vhost row, not an application's settings.

A check runs at every push and refuses the declaration when:

- one name is listed under two tenants, or twice under one;
- a name the edge serves is on no tenant;
- a tenant's child or a group's member is not on the list, or the hierarchy loops;
- a group carries names of its own;
- a key is anything but lower-case letters, digits and hyphens;
- a tenant names a storage destination that is not declared.

Two shapes go beyond a flat list:

- **A parent tenant** has content of its own and `children`. Reach granted over the parent runs down to its children.
  The edge still sends one key; an application that needs the resolved set reads it from the declaration.
- **A group** is a named set of tenants with no names and no content. Because it has no names, it can never reach an
  application as a header value.

One tenant is the platform's own: the system's administration lives there, and the door gives no per-tenant role in
it (its pages open to the administrator role alone).

### 2. The edge sets the tenant header and overwrites any copy

Each name gets its own nginx `server` block, generated from the declaration. Every block that proxies to an
application carries one line:

```nginx
proxy_set_header X-Tenant "acme";
```

When nginx sets a header with `proxy_set_header`, it does not forward the caller's header of the same name, in any
case. A caller can no more choose its tenant than its identity. Two details matter:

- **Leave `underscores_in_headers` off and `ignore_invalid_headers` on** (both nginx's defaults). `proxy_set_header`
  replaces only `X-Tenant` itself; a caller's `X_Tenant: family` is a different header to nginx. Either setting
  changed lets it through beside the edge's `X-Tenant: acme`: `underscores_in_headers on` treats the name as valid,
  `ignore_invalid_headers off` forwards names nginx considers invalid. CGI, PHP and several frameworks then read both
  spellings as the same variable. The drill shows both.
- **A name on no tenant fails the render.** If your vhost list comes from somewhere other than the declaration, make
  the render stop when a name has no tenant. An absent header reads exactly like "no tenant" to an application, and
  must never reach one by accident.

For a content system run by FastCGI, the same rule is a `fastcgi_param HTTP_X_TENANT`; see
[Many tenants' sites from one content system](../cms-tenant/README.md).

### 3. A name nobody declared is refused, on both ports

nginx answers an unmatched name with the port's default server, which is the first block it read unless one is
marked. So each port gets an explicit default that refuses:

```nginx
server { listen 80 default_server;      server_name _; return 404; }
server { listen 443 ssl default_server; server_name _; ssl_reject_handshake on; }
```

Over https there is no name to hold a certificate for, so the handshake is refused (TLS `unrecognized_name`) rather
than completed with some other tenant's certificate. Over plain http the answer is a plain 404 that says nothing about
what lives here.

### 4. Applications are reachable only through the edge

A request that skips the proxy skips the header line, and can carry any `X-Tenant` it likes. So an application that
trusts the header binds to loopback (`127.0.0.1`) on the edge's own machine, and the edge's row for it points there.
An application listening on every address is a hole even with a perfect edge.

### 5. The header says which tenant; each application decides who enters

`X-Tenant` says which tenant a request is *for*. It says nothing about who the caller is or what they may do. Reach is
a property of the caller, decided inside each application, never written in the declaration or in a header.

- **The door proves who a person is.** Roles that depend on the tenant are named `<tenant>:<role>` (`acme:owner`,
  `family:reader`). They are generated at the door from the declaration for every tenant whose names an application
  serves, so a new tenant costs rows, never a release of the application. An application declares which roles it
  gives; it carries no tenant list of its own.
- **The application checks the token** was issued for it, reads the role for the tenant the edge named, and refuses
  everything else. A valid sign-in for `family` is not entry to `acme`.
- A content system that signs readers in per site has **one door client per tenant and environment**
  ([cms-tenant](../cms-tenant/README.md), rule 3).

### 6. The isolation model is chosen per application

The standard terms: *silo* gives each tenant its own copy of the application or store; *pool* serves every tenant from
one shared copy and keeps them apart inside it; *bridge* mixes the two, for example a pooled application whose tenants'
files may sit in separate stores.

| Application | Model | Where the tenant lives | What keeps tenants apart |
|---|---|---|---|
| Content system | pool | one installation; one *context* (site) per tenant | the edge's key picks the context; per-tenant door client; reader groups ([cms-tenant](../cms-tenant/README.md)) |
| A business application with its own database | pool | one database; a `tenants` table whose key is the declaration's key | the application serves only the tenant the edge named, and checks `<tenant>:<role>` |
| The file store | no tenant in the store; a tenant may be given its own backend (silo) | nowhere: the store keeps no tenant at all | each application's own list of which files are a tenant's |
| The door | pool | one realm per environment | per-tenant roles and, where needed, per-tenant clients |

**The file store holds no tenant.** A file may belong to several tenants, and which tenant owns which file is the
application's fact. A caller may name a tenant on upload, but only to choose where the file goes: the store looks the
tenant's `storage_destination` up in the declaration (served read-only to anyone, like DNS), and never writes the
tenant down. Giving one tenant its own backend (its own bucket and credentials) is a move of existing files, not a
flag.

**Object contents are encrypted with a key the store never keeps.** The object store is S3-compatible (Garage)
with customer-supplied keys (SSE-C): the file store sends its key on every request, and the object store uses it and
discards it. What that covers, precisely:

- **Contents only.** Object names (keys), sizes, bucket names and times sit in the object store's metadata in clear.
  Anyone holding its disks sees how many objects there are, how big, when written and what they are called. An
  application that puts meaning into an object's name leaks that meaning.
- **The backup holds ciphertext.** It is one restic snapshot of a tar of the object store's own directories (the
  data blocks, the metadata, and a consistent copy of the metadata database), taken on the object store's machine,
  not read through S3. The object contents in it are still sealed with the SSE-C key. The metadata in it is protected
  only by the restic repository's own password: whoever holds that password reads every name and size, but no
  content.
- **A copy read back through S3 with the key is plaintext.** The restore proof does exactly that: it restores the
  snapshot into a scratch object store, reads every object with the key (and checks that a read without the key is
  refused), and writes the plaintext under a scratch directory on the verifying machine, which it deletes at the end
  of the run, pass or fail. The verifying machine keeps a copy of the key.

The key is one per service, not one per tenant. It separates the contents from the disks and backups that hold
them; it does not separate one tenant from another.

### 7. A tenant arrives

What a new tenant needs, in order, from the declaration outward:

1. A key and its names in the declaration, for every environment. The push check runs.
2. DNS records and a certificate for each name. Whether a name answers from the internet is a separate decision,
   made per name.
3. The edge's rows, rendered from the declaration; the header follows by itself.
4. The door: the per-tenant roles appear on the next run of the door's configuration. A tenant in the content
   system also gets a client per environment, whose secret is written to the secret store before the run that
   names it.
5. The application's own part: a context in the content system, a row in a business application's `tenants` table.

## The declaration, with example values

```yaml
tenants:
  acme:
    what: "a firm's staff"
    names:
      - acme.example.org
      - acme.staging.example.test
      - acme.dev.example.test
    children: [acme-lab]          # reach over acme runs down to acme-lab
  acme-lab:
    what: "one team inside the firm"
    names:
      - lab.acme.example.org
      - lab.acme.staging.example.test
      - lab.acme.dev.example.test
  family:
    what: "a family's private site"
    names:
      - family.example.org
      - family.staging.example.test
      - family.dev.example.test
    storage_destination: family-own # absent means the default backend
groups: {}                        # a group: a set of tenant keys, never names
```

The edge's block for one of those names, as rendered:

```nginx
server {
    listen 443 ssl;
    server_name acme.example.org;
    location / {
        proxy_pass http://127.0.0.1:8080;      # the application, bound to loopback
        proxy_set_header X-Tenant "acme";      # replaces any X-Tenant the caller sent
    }
}
```

## The drill

[`drill-tenants.sh`](drill-tenants.sh) renders a real nginx configuration from a two-tenant declaration, runs it on
loopback in front of a small backend that answers with every tenant header it received, in any spelling, and deletes
everything when it exits. It needs bash, nginx 1.19.4 or later, python3, curl and openssl, and no root and no
credential.

```
./drill-tenants.sh
ok    1 acme.example.test reaches the backend as acme
ok    2 a caller's own X-Tenant: family, sent as two copies, is overwritten (backend saw acme only)
ok    3 a caller's X_Tenant: family never reaches the backend
ok    4 family.dev.example.test reaches the backend as family
ok    5 an undeclared name is refused at the TLS handshake
ok    6 an undeclared name over http gets 404 and reaches no backend
ok    7 a name declared under two tenants is refused (shared.example.test is declared under acme and family; a name belongs to one tenant)
```

Each check is seen to fail with its fix removed. An `ARM` run exits 0 only when exactly the expected checks failed:

```
ARM=noheader ./drill-tenants.sh       # the edge does not set the header
FAIL  1 acme.example.test: backend saw X-Tenant=(none)
FAIL  2 a caller's own X-Tenant: family, sent as two copies: backend saw X-Tenant=family,family
FAIL  3 a caller's X_Tenant: family: backend saw X-Tenant=(none)
FAIL  4 family.dev.example.test: backend saw X-Tenant=(none)
ok    5 ...  ok    6 ...  ok    7 ...
ARM=noheader: exactly checks 1 2 3 4 failed, as they must

ARM=underscores ./drill-tenants.sh    # underscores_in_headers on
FAIL  3 a caller's X_Tenant: family: backend saw X-Tenant=acme,family
ARM=underscores: exactly checks 3 failed, as they must

ARM=invalidheaders ./drill-tenants.sh # ignore_invalid_headers off
FAIL  3 a caller's X_Tenant: family: backend saw X-Tenant=acme,family
ARM=invalidheaders: exactly checks 3 failed, as they must

ARM=nodefault ./drill-tenants.sh      # no default server refusing other names
FAIL  5 an undeclared name over https: curl exit 0, backend saw X-Tenant=acme
FAIL  6 an undeclared name over http: answer 200, backend requests 5 -> 6
ARM=nodefault: exactly checks 5 6 failed, as they must

ARM=nocheck ./drill-tenants.sh        # the renderer lets one name sit under two tenants
FAIL  7 a name declared under two tenants was rendered
ARM=nocheck: exactly checks 7 failed, as they must
```

Check 2 sends the forged header twice, as `X-Tenant` and `x-tenant`, so `family,family` under `ARM=noheader` is
both of the caller's copies arriving untouched. `ARM=nodefault` shows the trap section 3 closes: with no default server, a name nobody declared is served as `acme`,
the first tenant nginx read.

What the drill does not prove: that an application is bound to loopback (section 4), and that it refuses a signed-in
person of another tenant (section 5). Both are the application's own checks, against its own door client, in a
non-production environment.

## What is still open

- **Departure, export and deletion have no written procedure.** Nothing here yet says how a tenant leaves, how its
  data is handed over, or how it is deleted. Because the file store keeps no tenant, both start from each
  application's own list of the tenant's files; what happens to a file two tenants share is undecided.
- **Restoring one tenant.** Backups are taken per store, not per tenant. Restoring one tenant's data without rolling
  back the others in the same pooled database or bucket is not written.
- **Most databases rely on the application.** In a pooled database every query must filter by tenant. One store
  guards its rows in the database itself, with PostgreSQL row-level security on every table; it costs query plans (a
  reader that must scan everything is given its own role that bypasses the policy, read-only). The other pooled
  databases have no database-level guard, and how to give them one is not written.
- **Encryption does not separate tenants.** The object store's key is one per service. A key per tenant, which would
  make deleting a tenant's files as simple as destroying its key, is not designed.
- **Loopback trusts every process on the edge's machine.** Binding to `127.0.0.1` keeps the network out, not the
  machine: any local process (another application, a compromised one, a person with a shell) can call the
  application's port directly and send any `X-Tenant` it likes. Nothing here authenticates the edge to the
  application (a Unix socket readable only by the edge's user, or a client certificate only the edge holds, would);
  the fence is as strong as the machine's least trusted process.
- **Object metadata is not sealed by the object key.** Names, sizes and times of every object are in clear on the
  store's disks, and in its backup behind the restic password alone (section 6). The verifying machine holds the SSE-C
  key permanently and a plaintext copy of every object while a restore proof runs; a run killed outright leaves that
  copy until the next run's cleanup.
- **The loopback fence needs the application on the edge's machine.** An application on another machine needs a
  different fence, such as accepting only the edge's client certificate; that is not written here.
