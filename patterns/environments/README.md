# Development, staging and production from one declaration

## The problem

An application needs somewhere to be built, somewhere to be tried, and somewhere to serve its users. Three copies
of it are easy to start and hard to keep apart. Each copy needs its own host names, its own database, its own
sign-in client and its own keys, and every value typed by hand into one copy is a value that can leak into another.
The failure that matters is quiet: a test site that still sends its users to production's sign-in, or a developer's
copy that writes to production's database, works well enough that nobody notices until it has done damage.

This pattern makes the three environments from **one declaration**. The application says what it needs; the
infrastructure decides where it runs and what every value is, per environment. A check lists everything the
environments still have in common, and fails on anything nobody declared they may share.

**Words used here.** *The door* is the one sign-in every application shares, an OpenID Connect provider with one
realm per environment (see [the walk-through](../walk-through/README.md)). *The mail service* is the estate's one
program that sends outbound mail; applications ask it to send and never hold a mail provider's key themselves. *A
manifest* is a file in each application's repository that declares what the application is and needs.

## What runs here

Six rules:

1. **The application declares what it needs, never where or what value.** The manifest lists the settings the
   application needs (a database, a sign-in client, a public address) and the services it depends on. It names no
   host, no address and no environment. Where it runs, and every value it is given, is the infrastructure's, held
   in one place and rendered per environment. The application never hard-codes a host. It is told one environment
   fact, whether it is production (`IS_PRODUCTION`, yes or no), and may behave more strictly when the answer is no.
   It is never told whether it is staging or development, and needs no other environment name.
2. **A plain value is inherited; a secret is not.** Each plain value (an address, a public name, a flag) is written
   once, for production, and staging or development set their own only where they must differ. A key with no
   override takes production's value, so a new plain setting can never leave an environment without one. A
   **secret reference is never inherited**: every environment names its own, the reference carries the environment
   it belongs to (`secret:notes/staging/sign-in`), and the render refuses an environment that names none or names
   another environment's. A forgotten secret therefore stops the render before anything reaches a machine, instead
   of placing production's secret on a developer's machine for a later check to find. A secret that is meant to be
   the same everywhere says so in its scope (`secret:<app>/every-environment/<name>`) and is still written out in
   each environment.
3. **A branch per environment.** Development work lands on `main`, which deploys to development. Merging into
   `staging` deploys staging; merging `staging` into `production` deploys production. Each deploy ships the tip of
   its branch. A merge that is not a fast-forward makes a new commit, so "production runs what staging ran" is not
   held by the commit hash. Where an application's manifest asks for it, production's deploy holds it by content:
   staging's checks record the commit they passed, and production's deploy refuses a commit unless that recorded
   commit is its ancestor and the two differ only in data files. Elsewhere it rests on the merge alone (see open).
4. **Staging is refreshed from production, and then writes its own values.** A refresh replaces staging's data with
   a copy of production's: every table, every user, every page. Some of an application's settings live in its own
   data (a settings table, a stored callback address), so the copy arrives pointing at production. After every
   restore, and after every deploy, a setup step writes the environment's own values over them and reads them back.
   The database is recreated owned by staging's own login, and production's grants are left out of the copy, so the
   copy does not hand production's logins rights in staging. Where the application's sign-in client exists only in
   each environment's own realm at the door, a skipped write-back makes staging's sign-in fail, because staging's
   client does not exist in production's realm; that visible failure is the signal the step was missed. The content
   system's version of this rule is rule 5 of [Many tenants' sites from one content system](../cms-tenant/README.md).
5. **Developers work on a current copy of production.** A developer's environment is restored from production on
   request; where an application has one restore core, the same code refreshes staging with a different target.
   Production data reaches development only through this restore, and the same write-back follows.
6. **Development and production do not overlap, and a crippled development environment is the accepted cost.** No
   credential, certificate or key that works in production is placed in development or staging by the render.
   Where a feature needs a production-only credential (a payment provider, a third party that issues one key), that
   feature does not work outside production. Two things cut across this rule and are stated under open: a restore
   copies production's data, which carries its own credentials; and the one named exception below. **The named
   exception:** the keys for sending outbound mail are the same in every environment, because outside production
   the mail service redirects every message away from its addressee. The keys live with the mail service, not with
   the applications: an application is given only its own environment's mail service address (`MAIL_SEND_URL`) and
   proves who it is with its own certificate. That guard is what makes the shared key safe, so the guard itself must
   stay tested.

## The declaration, with example values

The drill reads three small files in [`example/`](example/), shown here as they are. The estate's own files are
JSON and YAML; the drill uses one entry per line so it needs nothing but awk.

The application's manifest, [`example/manifest`](example/manifest):

```
# The application's manifest: what it needs. No host, no address, no environment name, no value.
needs: IS_PRODUCTION
needs: PUBLIC_ORIGIN
needs: DATABASE_URL
needs: SIGN_IN_ISSUER
needs: SIGN_IN_CLIENT_ID
needs: SIGN_IN_CLIENT_SECRET
needs: MAIL_SEND_URL
needs: MAP_TILES_URL
```

The infrastructure's values, [`example/values`](example/values). Secrets are references, resolved when the file is
rendered on the machine that runs the application:

```
# The infrastructure's values. Production carries every key. Another environment takes production's value where
# it sets none, EXCEPT a secret reference (secret:<app>/<environment>/<name>): every environment names its own, and
# the render refuses one that is missing or that names another environment.
production   IS_PRODUCTION          yes
production   PUBLIC_ORIGIN          https://notes.example.org
production   DATABASE_URL           postgres://notes@db.example.org/notes
production   SIGN_IN_ISSUER         https://sign-in.example.org/realms/production
production   SIGN_IN_CLIENT_ID      notes
production   SIGN_IN_CLIENT_SECRET  secret:notes/production/sign-in   # pragma: allowlist secret
production   MAIL_SEND_URL          https://mail-send.example.org
production   MAP_TILES_URL          https://tiles.example.net
staging      IS_PRODUCTION          no
staging      PUBLIC_ORIGIN          https://notes.staging.example.test
staging      DATABASE_URL           postgres://notes_stg@db.staging.example.test/notes_staging
staging      SIGN_IN_ISSUER         https://sign-in.example.test/realms/staging
staging      SIGN_IN_CLIENT_SECRET  secret:notes/staging/sign-in   # pragma: allowlist secret
staging      MAIL_SEND_URL          https://mail-send.staging.example.test
development  IS_PRODUCTION          no
development  PUBLIC_ORIGIN          https://notes.dev.example.test
development  DATABASE_URL           postgres://notes@localhost/notes
development  SIGN_IN_ISSUER         https://sign-in.example.test/realms/development
development  SIGN_IN_CLIENT_SECRET  secret:notes/development/sign-in   # pragma: allowlist secret
development  MAIL_SEND_URL          https://mail-send.dev.example.test
```

Where it runs is a separate file, also the infrastructure's: for each application, which machine holds each of its
environments. Moving staging to another machine changes that file and nothing the application owns.

The render, in the template language of whatever writes the file (here Jinja, as Ansible uses it): a plain value
falls back to production's; a secret does not, and must name its own environment.

```jinja
{% macro V(k) %}{{ values[env][k] if (env != 'production' and k in values[env]) else values['production'][k] }}{% endmacro %}
{% macro S(k) %}{% set ref = values[env][k] %}{% if ref.split('/')[1] not in [env, 'every-environment'] %}{{ undefined_secret_for_another_environment }}{% endif %}{{ ref }}{% endmacro %}
SIGN_IN_ISSUER={{ V('SIGN_IN_ISSUER') }}
SIGN_IN_CLIENT_SECRET={{ S('SIGN_IN_CLIENT_SECRET') }}
```

With Ansible's undefined variables set to fail, `S` stops the render both when the environment has no reference of
its own (`values[env][k]` is undefined) and when its reference names another environment.

A value identical in production and another environment is either intended or a mistake, and only the
application's owner can say which. [`example/decisions`](example/decisions) records it, one line per key:

```
# Whether a value may be identical in production and another environment. The application's owner decides.
IS_PRODUCTION          needs-own  the one environment fact the application reads
PUBLIC_ORIGIN          needs-own  each environment answers at its own name
DATABASE_URL           needs-own  a copy must never write to production's database
SIGN_IN_ISSUER         needs-own  a copy must never send its users to production's sign-in
SIGN_IN_CLIENT_SECRET  needs-own  one client per environment at the door
MAIL_SEND_URL          needs-own  each environment's own mail service, which knows which environment it serves
SIGN_IN_CLIENT_ID      inherits   a public name; the realm in SIGN_IN_ISSUER already differs
MAP_TILES_URL          inherits   a public, read-only map service someone else runs
```

- `inherits`: the environments should hold the same value. Not reported as a problem.
- `needs-own`: this environment must have its own, and a shared value is a failure.
- `undecided`: nobody has ruled. A failure, naming who must.

A key absent from the file is a failure too: that is how a new crossing arrives. A check that cannot read its
decisions file must treat every shared value as a failure, never as declared.

## The drill

[`drill-environments.sh`](drill-environments.sh) renders environment files from a manifest and a values file, and
checks a rendered file against production's using a decisions file. It needs only bash and awk.

```
./drill-environments.sh render staging example/manifest example/values > staging.env
./drill-environments.sh check production.env staging.env example/decisions
```

`./drill-environments.sh selftest` renders the example in a temporary directory and shows one pass and four
failures: staging forgetting its own sign-in endpoint (so it inherits production's); a restore from production that
skips the write-back; development naming no secret of its own; and development naming production's secret. The
last two are refused by the render itself, before a file exists:

```
-- the example as declared; staging restored from production and its values written back: must pass
ok    SIGN_IN_CLIENT_ID      identical on purpose: a public name; the realm in SIGN_IN_ISSUER already differs
ok    MAP_TILES_URL          identical on purpose: a public, read-only map service someone else runs
GREEN  6 keys differ, 0 identical key(s) not declared inherits (production.store vs staging.store)
ok    SIGN_IN_CLIENT_ID      identical on purpose: a public name; the realm in SIGN_IN_ISSUER already differs
ok    MAP_TILES_URL          identical on purpose: a public, read-only map service someone else runs
GREEN  6 keys differ, 0 identical key(s) not declared inherits (production.env vs development.env)
-- staging forgets its own sign-in endpoint, so it inherits production's: must fail
FAIL  SIGN_IN_ISSUER         identical, but declared needs-own: a copy must never send its users to production's sign-in
ok    SIGN_IN_CLIENT_ID      identical on purpose: a public name; the realm in SIGN_IN_ISSUER already differs
ok    MAP_TILES_URL          identical on purpose: a public, read-only map service someone else runs
RED   5 keys differ, 1 identical key(s) not declared inherits (production.env vs staging.forgot.env)
-- staging restored from production without writing its own values back: must fail
FAIL  IS_PRODUCTION          identical, but declared needs-own: the one environment fact the application reads
FAIL  PUBLIC_ORIGIN          identical, but declared needs-own: each environment answers at its own name
FAIL  DATABASE_URL           identical, but declared needs-own: a copy must never write to production's database
FAIL  SIGN_IN_ISSUER         identical, but declared needs-own: a copy must never send its users to production's sign-in
ok    SIGN_IN_CLIENT_ID      identical on purpose: a public name; the realm in SIGN_IN_ISSUER already differs
FAIL  SIGN_IN_CLIENT_SECRET  identical, but declared needs-own: one client per environment at the door
FAIL  MAIL_SEND_URL          identical, but declared needs-own: each environment's own mail service, which knows which environment it serves
ok    MAP_TILES_URL          identical on purpose: a public, read-only map service someone else runs
RED   0 keys differ, 6 identical key(s) not declared inherits (production.store vs staging.store)
-- development forgets its own sign-in secret: the render must refuse, not inherit production's
FAIL  render development: SIGN_IN_CLIENT_SECRET names no secret of its own, and a secret is never inherited
-- development names production's sign-in secret: the render must refuse
FAIL  render development: SIGN_IN_CLIENT_SECRET names production's secret (secret:notes/production/sign-in)
SELFTEST passed: one pass, four failures
```

In the estate, the same check reads the rendered files where they are installed, not the templates: the template
is where the decision is made, the installed file is where it lands, and only the installed files can show two
environments holding the same bytes. It runs daily and on demand.

## What is still open

- **The estate's own render still inherits secrets.** Rule 2 is the model, not yet the estate. The estate's main
  application template gives every key, secrets included (session-signing secrets, API tokens, a database
  passphrase), the same fallback to production's value when an environment sets no override. Only the sign-in
  client secrets are looked up per environment. A forgotten override there places production's secret on another
  environment's machine, and the daily check finds it afterwards, not before.
- **A restore places production's credentials in staging and development.** This contradicts rule 6, and the
  contradiction is real. A refresh copies production's data whole: users and whatever credentials the application
  stores for them (password hashes where it keeps any, API tokens, stored third-party secrets) arrive in staging
  and on developers' machines. In the estate's restore scripts, the only things left out are the content system's
  session rows (the table is created empty) and production's database grants. Nothing else is stripped, and the
  data is not masked. Staging keeps production's access rules and is reachable only on the
  private network. This is accepted for this estate, a family's and a small firm's; an organisation holding
  customers' data would have to mask or strip credentials and personal data on the way, and decide what masking
  keeps usable.
- **"Production runs what staging ran" is held by a check on only one application.** Elsewhere the deploy ships
  whatever is on the production branch; nothing compares it with what staging ran, and a merge that is not a
  fast-forward is a commit staging never ran. The one check that exists compares content (an ancestor, then only
  data files may differ), not the commit hash.
- **The mail keys are on every machine that runs the mail service, developers' included.** The applications never
  hold them, but the mail service runs in development too, with the same keys. On a developer's machine the mail
  service believes the caller's stated identity on its loopback address, and the one word that tells it whether it
  is production is a placed value; a machine placed as production would send unredirected. Anyone with access to a
  developer's machine can read the keys and call the mail provider directly, past the redirect.
- **The check sees only rendered settings.** It cannot see two applications hard-coding the same value in code, a
  value stored in a database row or on a shared disk, or an environment nothing declares. The restore write-back
  covers the settings an application keeps in its data only where that application has a setup step that writes
  them; an application without one has no such cover.
- **A refresh drops what the application installed in its database, and replaces what only the target held.** It
  drops and recreates the database, so every grant and row-level policy the application installed is gone until
  the application puts them back: one application re-applies its policies before it verifies them, after a refresh
  once left staging with every row present and none readable. A dump can also leave tables owned by the database
  superuser, so a migration's `GRANT ... ON ALL TABLES` is refused; grant table by table, to the tables the
  application owns. And a refresh replaces data that existed only on the target: a development restore replaced a
  developer's own test rows with production's. Each application should say which tables a refresh owns and which
  it must leave alone; none does yet.
- **Each application spells its restore separately.** Staging refresh and development restore share code within an
  application, but each application's restore (dump, ownership, migrations, write-back) is its own script; there is
  no one restore every application goes through.
