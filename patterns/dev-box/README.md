# The dev box: one person, many agents

## The problem

One person works with several AI agents at once: five that each own some applications, an auditor that checks
their work, and a context-free reviewer that reads a design cold. They all develop on one machine, the *dev
box*, often at the same time. [The practice](../the-practice/README.md) sets out who decides what and what counts
as evidence. This pattern covers the machine those rules run on.

Two simple setups fail:

- **Every agent runs as the person.** They all hold the person's secret-store login, keys and history. Commit
  logs and service logs name only the person, so nobody can tell afterwards which agent did what.
- **Every agent is walled off from every other.** Agents lose reads they need. One agent's tooling cannot
  reach another agent's data. Each wall needs its own exception, and most of the work becomes managing
  permissions.

The agents are one kind of model running in several windows, split for context and for parallel work. So on a
dev box they are treated as **one actor**: any agent may read any other agent's work and any dev database. What
stays separate is what proves who is acting, meaning each agent's credentials, and the one agent whose value
depends on separation, the auditor.

**Words used here.** *An agent's tree* is its home directory and everything in it. *A door* is an address a
program calls, such as an API endpoint. *The secret store* is the password manager every credential lives in. *A
ground* is one environment's set of machines: development, staging or production. *A broker* is a small service
on a production machine that answers one kind of question for a named caller, holding the credential itself
and logging who asked. *The hub* is one ordinary server, outside both dev boxes, that holds a directory per
agent for the nightly sync.

## What runs here

**Each agent is an operating-system user.** `app1`, `app2`, `infra` and the others each have a user, a group and
a home. Homes sit under one shared work base, `/srv/work/<agent>`, not under `/home`, so a home reads as a work
area and not as a person. Each agent clones its own repositories, works in its own worktrees and commits as
itself. The commit author and the key that pushes the commit are the same identity. The user has no password.
The person reaches it with `sudo -u <agent>`, so files created for an agent are owned by that agent and not by
the person.

**Nothing an agent needs is installed by hand in its home.** Packages, libraries and command-line tools are
declared once for the box. The agent asks for a missing one by name, and it is added to the declaration. A
library installed into a home directory works until the box is rebuilt, then disappears without any error. Each
application's own dependencies live in that application's tree.

**Trees: readable by every agent, writable by the owner, closed to the auditor.** A group, `agents`, holds every
project agent and not the auditor. Each home is owned by its agent with group `agents` and mode `0750`, so any
agent can open and read another's tree but cannot write in it. Credential files inside a tree stay `0600`: the
secret-store login, the ssh directory and keys, and any file with a password. The auditor's home is `0700`, and
the auditor cannot enter anyone else's.

**Each agent has its own client certificate.** Its common name is `<agent>@dev`: the agent, and the environment it
runs in. It is signed by the estate's workload certificate authority, the one that signs every application's
identity in every environment; the authority that signs people's and devices' certificates is a separate one.
The environment is therefore carried in the name, not in the signer, and a door that admits `app1@production`
must refuse `app1@dev` by reading the name. The key is created on the box, is never copied and can be read by
that agent alone, so one agent cannot present itself as another. The standby box described below runs the same
setup and makes its own `app1@dev` with its own key: the two boxes carry the same names and different keys, and
renewal runs on each box for its own key. A door that admits agents checks the name in the certificate against
the name the caller gives, and refuses the request if they differ. This replaces a shared token that let any
caller type any name.

**Each agent has its own slice of the secret store.** Each agent has its own login and its own collection. The
grants are derived and not requested. A script reads every repository's code and records which secret each
piece of code reads. It then grants each agent the items its own code reads, and nothing else. A secret is
granted to nobody if no code reads it. Grants that the code cannot show, such as a test login an agent uses by
hand, are listed in a declared file, each with a reason. A drift check compares what each agent holds with what
was derived plus what was declared, and reports any difference. One item can sit in several collections, so
sharing a secret never copies it.

**Every dev database is open to every project agent.** Each agent's user has a database login authenticated by
the operating system (peer authentication over the local socket), with full rights on every table of every dev
database. No password exists that could be shared. Each agent may also run the database's own client tools
(`psql`, `pg_dump`, `pg_restore`, `dropdb`, `createdb`) as the operating-system user `postgres`, so it can drop
and reload a dev database from a copy. That is not a narrow grant: `psql` as `postgres` is the database
superuser, which can change any role's rights and run shell commands as the operating-system user `postgres`
(`\!`, `COPY ... TO PROGRAM`). **Every project agent is in effect database superuser and `postgres` on the dev
box.** One agent, the one that maintains the box, has full root on it. Two others that need to test containers
may run the container tool as root, which on a dev box amounts to root.

**The auditor is the one exception.** It has built nothing on the estate, and it should not know the reasons
the builders give for what they did. Its walls stay up:

- It is not in `agents`, so it cannot read another agent's tree.
- It holds no write login on any dev database and no superuser tool. A database login it is given is
  read-only. This wall stops the auditor itself; any project agent, being database superuser, could lift it.
- Its secret-store account can read every collection, production's included, and write none. That is
  deliberate: the auditor may read anything in the store, so it can check what the store holds against what
  the code uses. It is the one account on a dev box that can read a production credential.
- It holds no key that opens a server, so reading a production secret does not let it act on production, and it
  has no access to the hub.
- It has one repository it may write: its own findings.

**The application agents cannot act on staging or production from a dev box.** None of them holds a shell login, a
write credential or an identity for another ground. The infrastructure agent is the exception: it runs the servers,
so it reaches them as a service user (see below). Every certificate on the box names `@dev`, and every run of the
box's setup fails if it finds one that names another environment. Two read-only roads come the other way, both
brokers that answer the agent that owns the application, with that agent's own token, and log the caller:

- **Status.** An agent that needs to know how its production service is running asks a broker on that ground.
  The broker reads the service with the ground's own identity and returns the answer, not the credential.
- **A copy of the data.** An agent reloads its dev database from a dump of its own application's production
  data, served by a broker on the production database machine, read-only on the source and logged with size
  and digest. So a dev box holds a current copy of real production data. Reading production down is allowed;
  writing back is not.

**A second dev box at another site.** The person moves between two sites, so a standby dev box at the second site
is brought to the first box's state every night by two scheduled jobs:

1. **Save**, on the main box: each agent's accumulated state (its memory notes, project settings and plugins) is
   pushed to that agent's own directory on a hub, which accepts each agent's key for that agent's directory
   only. A running session is saved but not interrupted.
2. **Standby**, on the second box: the agent sessions there are stopped, every repository in each agent's tree
   is pulled fast-forward only, and each agent's state is restored from the hub. A repository with a local
   commit is reported and never merged over.

Session transcripts are not synced: they are large and tied to one machine, and the memory notes are what
lasts. The rules files, hooks and settings are not synced either. They come from a repository and are installed
on each box, so nobody edits a box's copy by hand. If someone saved from the standby since the main box last
restored, the next save refuses, so one box's work cannot overwrite the other's. The auditor has no hub and is
left out of the nightly sync.

**The context-free reviewer.** The reviewer is a fresh agent session started with no project memory and no
history. It is given a design, a page or a pattern, and asked what a stranger would find wrong. It runs under
the account of the agent that asked for the review and is handed only the document. The reply, the number of
findings and the reviewer's verdict are recorded on the document, together with how each finding was answered.

**The agent with no project.** One more agent belongs to no project: the person opens it for anything that is not
one of the projects' work (a question, a purchase, a one-off script). It is an operating-system user like the
others, with its own tree, and it is saved and restored with them each night. Its rules are the shared ones; it has
no project rules and owns no application, so it may build nothing that another agent owns and only reports what it
finds.

## The configuration, with example values

The roster, declared once. The setup for users, groups, certificates, database logins and the nightly sync all
reads it:

```yaml
agents:   [infra, app1, app2, app3, app4]   # the project agents: group `agents`, write on every dev database
auditors: [auditor]                         # a user like them, in none of the above and not in the nightly sync
work_base: /srv/work
```

The trees, as the drill checks them:

```
drwxr-x---  app1    agents   /srv/work/app1
-rw-------  app1    app1     /srv/work/app1/.store-login
drwx------  app1    app1     /srv/work/app1/.ssh
drwx------  auditor auditor  /srv/work/auditor
-rw-------  app1    app1     /etc/agent-identity/app1@dev/key.pem
-rw-r--r--  app1    app1     /etc/agent-identity/app1@dev/cert.pem     # CN = app1@dev
```

The database logins, as the drill makes them. In PostgreSQL `GRANT ALL ON DATABASE` gives only connect, create
and temporary tables, so the rights go on the tables, and default privileges carry them to tables made later:

```sql
CREATE ROLE app1 LOGIN;  CREATE ROLE app2 LOGIN;  CREATE ROLE auditor LOGIN;   -- peer auth: OS user = role
ALTER DEFAULT PRIVILEGES FOR ROLE owner IN SCHEMA public GRANT ALL ON TABLES TO app1, app2;
ALTER DEFAULT PRIVILEGES FOR ROLE owner IN SCHEMA public GRANT SELECT ON TABLES TO auditor;
-- tables that already existed before the lines above; the drill makes its table afterwards and needs neither
GRANT ALL ON ALL TABLES IN SCHEMA public TO app1, app2;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO auditor;
```

`owner` is the role that creates the tables. Default privileges cover only tables that role creates, so a table
made by another role needs its own grant. On PostgreSQL 14 or later, `GRANT pg_read_all_data TO auditor` does
the auditor's half for every table in every database. In MariaDB, `GRANT ALL PRIVILEGES ON devdb.* TO
'app1'@'localhost'` with `IDENTIFIED VIA unix_socket` covers present and future tables in one line.

The two privilege grants, as sudoers drop-ins:

```
# every project agent: the database's tools as postgres, on this box only (database superuser, see above)
app1 ALL=(postgres) NOPASSWD: /usr/bin/psql, /usr/bin/pg_dump, /usr/bin/pg_restore, /usr/bin/dropdb, /usr/bin/createdb
# the agent that maintains the box, and no other
infra ALL=(ALL) NOPASSWD: ALL
```

A declared secret-store grant that the code cannot show:

```yaml
grants:
  - { agent: app2, item: "Sign-in door (development) - test user drill@example.test",
      reason: "app2's sign-in drill logs in as this user by hand, so no code names it" }
  - { agent: app3, item: "Storage token (development)",
      reason: "OWNER-UNSTATED", ask: app3 }          # nobody knows why: reported on every run until app3 answers
```

## The drill

[`drill-dev-box.sh`](drill-dev-box.sh) builds a throwaway copy of the model on the machine it runs on: two
project agents, an auditor, their trees, a client certificate each and one dev database. It checks each wall as
the user that wall is meant to stop, then removes everything. It must run as root, and it refuses to start if
any of its users already exists. Run it in a container:

```
docker run --rm -v "$PWD":/d:ro debian:trixie bash -c \
  'apt-get update -qq && apt-get install -y -qq postgresql openssl >/dev/null && /d/drill-dev-box.sh'
```

```
-- the trees
ok    1 app1 reads app2's tree (one actor on a dev box)
ok    2 app1 cannot write into app2's tree
ok    3 app1 cannot read app2's secret-store login
ok    4 the auditor cannot enter any agent's tree
-- the client keys
ok    5 app1 reads its own key
ok    6 app1 cannot read app2's key, so it cannot present itself as app2
ok    7 every identity on the box names the development environment
-- the dev database
ok    8 app1 writes the dev database
ok    9 app2 writes the dev database
ok    10 the auditor reads the dev database (3 rows)
ok    11 the auditor's write is refused by the database (permission denied)
WALLS HOLD: 11 checks
```

Each `ARM` removes one fix, and the drill passes only if the matching check fails and no other does:

```
ARM=open-homes ./drill-dev-box.sh          # trees 0755
FAIL  4 the auditor listed app1's tree, so it can read what the agents hold
ARM open-homes: check 4 failed, as it must, and no other

ARM=shared-key ./drill-dev-box.sh          # client keys readable by the group
FAIL  6 app1 read app2's key, so app1 can present itself as app2

ARM=auditor-writes ./drill-dev-box.sh      # the auditor granted INSERT
FAIL  11 the auditor wrote to the dev database

ARM=foreign-identity ./drill-dev-box.sh    # an app1@production certificate left on the box
FAIL  7 the box holds an identity for another environment: app1@production
```

The drill does not cover the nightly sync, which needs two machines and a hub, or the secret-store grants,
which need the store itself.

## What is still open

- **The tree wall is file modes, not a sandbox.** An agent can loosen a mode on its own files, and every agent
  runs code it did not write. The auditor's separation holds only while every home keeps its mode. The box's
  setup checks those modes each time it runs, but not between runs.
- **Some agents have root.** The agent that maintains the box, and the agents allowed to run containers, can
  read everything on it, including the auditor's home. That is the accepted price of not sending setup work
  back to the person.
- **The standby only follows.** The nightly sync copies one way. State built on the standby must be saved to
  the hub by hand, and the main box must then restore before its next save, which refuses until it does.
  Session transcripts never move between boxes.
- **The auditor's database wall depends on the agents.** Every project agent can become database superuser on
  the dev box, so a read-only login stops the auditor and nothing else. The wall holds only as long as no agent
  lifts it, and nothing checks between setup runs.
- **Production data lives on the dev box.** The dump road brings real data down unmasked, and every project
  agent can read every dev database, so each agent can read every other application's production copy.
- **The infrastructure agent can reach production from the dev box.** It administers the servers, so its
  session on the dev box holds the way in. Its rules say it does not touch production while developing; no
  machine enforces that.
- **The auditor can read production secrets from a dev box.** That is the price of an audit that can read the
  whole store. A stolen auditor session reads them all.
- **A context-free review of this pattern was made, and its findings were answered here.**
- **The person's own account is not in the nightly sync.** It holds state the agents' accounts do not, and
  reconciling the two boxes' copies of it is the person's decision.
