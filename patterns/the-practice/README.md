# The practice: written rules that let agents build and run it

## The problem

Everything else in neenv is a commodity part. What usually holds the parts together is a team: people who
remember why a thing was built, who check each other's work, and who know which change needs whose word. This
estate has one person who decides and several AI agents who do the work. An agent starts each session with no
memory of the last, writes with the same confidence whether or not it is right, and will build more than was asked
unless something stops it.

The practice is the set of written rules that stands in for the team. Most rules were written after a failure they
would have prevented, and each is short enough for an agent to read before it acts. Where a rule can be enforced by
a machine, it is; the rest rely on the agents reading them, which is why the independent checks below exist.

**Words used here.** *The decider* is the one person who decides what exists. *An agent* is an AI model working in
its own session on the applications it owns. *A door* is an address a program calls, such as an API endpoint. *The
consumer* of a piece of work is whoever uses it.

## Who decides what

- **The decider decides WHAT; the agents decide HOW.** What exists, what it is for, and any date, amount or name the
  work needs come from the decider. How it is built (naming, order, keys, paths) is the agent's. An agent that needs
  a value it was not given asks for it, and never invents one.
- **Each agent owns its own applications.** Work found in another agent's territory is reported to that agent, never
  done in its place. An agent may tell another about work; it may not assign it.
- **Work is authorised in words.** An agent works on what the decider asked for in plain words, or on work recorded
  for it in the shared tracker. A question is answered, not treated as a request to build.
- **The literal words are the scope.** Nothing extra is built, edited or deployed because it seemed useful. If the
  decider's words can be read two ways, the agent names both and does nothing until he says which.

## Evidence

- **A claim about a running system carries the command that produced it**, or the words "not measured". A
  document, a memory or another agent's report is not evidence until it has been checked against the system.
- **A check is evidence only once it has been seen to fail.** A test that cannot go red proves nothing, so every
  check in neenv has a way to make it fail on purpose, and that failure is run at least once.
- **Each fact is written in one place**, and everything else points at it. When two sources disagree, the
  disagreement is reported as a defect; the agent never picks one of the two.

## Done

- **Work is done when its consumer says so.** The consumer, not the builder, marks it done, by using it with its own
  credential at the door it actually calls. A builder never marks its own work done, and a person's signed-in
  session does not stand in for an application's identity.
- **The door must refuse everyone else.** The same call with no credential, and with a valid credential that belongs
  to someone else, must be refused. A door that admits any certificate from the right root admits every tenant.
- **Answers are read strictly.** 401 and 403 are refusals. 404 is a failure, because a promised door that does not
  exist is not reach. Any other answer means the door exists and let the caller in, except a 400 that the proxy
  sends for a missing or bad client certificate, which is a refusal.
- **Anything that serves another program publishes the list of its doors**, generated from its own code, so the
  consumer can find what it was promised and the list cannot drift from the code.

## Development and production

- **An agent develops in development.** It builds and tests on its own machine and its own copy of the data, and
  does not read or probe production while developing.
- **An agent runs its application's machinery, never its business.** On production it may deploy, restart and
  check its own application: the control plane. It never performs the application's real work on production data:
  the data plane. A change to production data is a separate kind of change: the decider's word recorded, a second
  agent's review, a backup, a rehearsal on a copy, and one transaction that commits only if its checks pass.
- **Production changes only through audited steps.** A deploy is a script that takes a snapshot first, records
  what it applied, and can be undone by restoring that snapshot. Nobody edits a production machine by hand.
- **An agent deploys on its own only a change with one right answer**, one any competent agent would make the same
  way, that restores what was agreed or changes nothing anyone sees. It reports the deploy the same day, with how to
  undo it. Everything else waits for the decider's word.

## The independent eye

- **An auditor agent** reads the estate with a read-only account, so it cannot change what it reports on, and with
  no memory of why anything was built. Its value is that it did not do the work.
- **A context-free review** sends a page, a design or a pattern to a fresh model with no conversation behind it and
  asks what a stranger would find wrong. Its findings are answered before the work goes further. This pattern was
  revised after one.

## Records

- **Every change refers to a reason.** A commit names the piece of work it belongs to, or says it is a fix within
  the agent's own authority. The shared repositories refuse, on the server, a commit that names neither.
- **The decider's words are quoted, never paraphrased into a rule.** A rule enters the practice only after it has
  been read back to him in one sentence and he has confirmed it.
- **Nothing is left for later.** Work agreed in a session is recorded before the session ends, and a session that
  stops says exactly what it is waiting for and from whom.

## The drill

[`drill-done.sh`](drill-done.sh) is the "done" rule as a script. The consumer calls the door it was promised with its
own certificate; the same call with no certificate, and with another consumer's valid certificate, must be refused.

```
./drill-done.sh https://api.example.org/v1/things consumer.pem consumer.key other.pem other.key
```

`./drill-done.sh selftest` shows it on a machine with nothing else set up. It makes a throwaway root, two consumer
certificates and three local doors, and removes them all afterwards:

```
-- the promised door, which admits only this consumer: must pass
ok    with the consumer's certificate: 200 (reach)
ok    with no certificate: the TLS handshake refused the certificate (refused)
ok    with another consumer's valid certificate: 403 (refused)
DONE  the consumer reaches the door, and the door refuses everyone else
-- a promised door that does not exist: must fail
FAIL  with the consumer's certificate: 404, a promised door that does not exist
ok    with no certificate: the TLS handshake refused the certificate (refused)
-- a door that admits any certificate from the root: must fail
ok    with the consumer's certificate: 200 (reach)
ok    with no certificate: the TLS handshake refused the certificate (refused)
FAIL  with another consumer's valid certificate: 200, so any certificate from the root gets in
-- a door that asks for no certificate: must fail
ok    with the consumer's certificate: 200 (reach)
FAIL  with no certificate: 200, so the door does not tell the consumer from a stranger
SELFTEST passed: one pass, three failures
```

## What is still open

- **Rules accumulate.** Each failure adds a rule, and a long rule set is read less carefully than a short one. The
  decider merges and shortens rules; an agent proposes, it does not prune.
- **Rules in prose rely on the agents that read them.** The rules reduce mistakes; the independent eye and the
  consumer's check catch the ones that get through.
