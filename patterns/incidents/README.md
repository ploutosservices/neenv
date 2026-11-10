# Incidents: a one-page runbook

## The problem

When something is compromised, the first hour decides most of the damage, and it is the worst hour to work out what
to do. Without a page written beforehand, people either do too little (it is probably nothing) or too much
(rotating everything at once breaks more than the incident did).

## The shape, every time

1. **Notice.** An alert, a person, or an agent says something is wrong. Write down the time and what was seen.
2. **Keep the evidence** before acting: copy the journals, the authentication logs and the door's access log for the
   window, before they rotate ([Central logs](../central-logs/README.md) keeps a copy the machine cannot change).
3. **Contain** the one thing that is compromised, with the verb for its kind (below), and nothing else yet.
4. **Record** what was done, by whom and why, as it is done, on the estate's ticket service while it runs, in a
   plain file kept with the recovery notes when it does not ([Disaster recovery](../disaster-recovery/README.md)).
5. **Tell** the people affected: the person whose device or account it was, and any tenant whose data may have been
   read. Whether anyone is owed a formal notice (a data-protection regulator, a client's contract) is the owner's
   to decide, and the clock on those starts at step 1.
6. **Restore** what containment took away (a new device, a new key), once the cause is understood.
7. **Review**: what let it happen, and the one change that stops it next time, written where that change belongs.

**Who decides.** The owner decides anything beyond containment, and rotation above all. His standing rule is to
rotate after a leak, everything on one day, by his own hand, because rotation done piecemeal by whoever noticed
broke more than it protected. If the owner cannot act, the named successor holds his keys and his decisions
([Disaster recovery](../disaster-recovery/README.md)).

## By kind

**A device is lost or stolen** (a laptop, a phone). Here one script (the door's machine register) takes the
machine's certificate name off every door account that held it, ends those accounts' sessions at the door, removes
its private-network peer from both routers, and removes its row from the declared peer list. Commit that list change
at once: a configuration run from the repository before the commit would put the peer back.

```
door-machines.py remove alice-laptop@example --wireguard
```

Without such a script the same four acts are done by hand: remove the certificate's name from the door's account (or
disable the account's certificate credential), end the account's sessions, delete the device's VPN peer on every
router, and remove it from wherever peers are declared.

The door is not all a device holds. **Was its disk encrypted, and was it locked?** If yes, the rest can wait for the
owner's decision; if no, treat everything it held as leaked: the identity provider's sign-in and refresh tokens (end
them at the provider), each application's own sessions, the password manager's cached vault (deauthorise its sessions
there; whether the master password changes is the owner's call), SSH keys (remove from every `authorized_keys`), the
code host's tokens, and any mail app passwords.

The door refuses that certificate from the next request. The certificate itself stays valid until it expires: a
revocation list is published, but not every door checks it yet, so the removal is what protects. The person keeps a
second factor if they have another enrolled machine; otherwise they enroll a new one in person.

**A password or token leaks** (printed in a log, pasted in a chat, sent to the wrong place). Record where it went
and who could have read it. Then the owner decides: rotate now, or record it for his next rotation day. If it waits,
the leak is open until then, and the record says so in those words. Whoever rotates writes the new value into the
password manager first, which keeps the item's previous passwords, so a consumer that breaks can be traced to the
change.

**An agent misbehaves or its credentials are exposed.** Each agent is its own operating-system user with its own
certificate, its own password-manager service account and its own tokens ([The dev box](../dev-box/README.md)), so
each can be stopped alone:

```
usermod -L -e 1 -s /usr/sbin/nologin agent-x    # lock first: password, account expiry and shell (a key login needs all
                                                 # three gone; -L alone still lets an SSH key in)
mv /home/agent-x/.ssh/authorized_keys /home/agent-x/.ssh/authorized_keys.revoked
loginctl disable-linger agent-x; loginctl terminate-user agent-x; pkill -KILL -u agent-x
crontab -r -u agent-x
step ca revoke <serial>                          # on the CA, with the provisioner: no key of the agent's is needed
```

step-ca's revocation is passive by default: it stops the certificate from being renewed, and a door that does not
read the revocation list still accepts it until it expires. So the agent's certificate name also comes off every door
account and allow list, as a lost device's does. Then disable its password-manager service account and revoke its
tokens at the code host and the ticket service.
Its work tree stays, as evidence. A development machine can still reach production's databases at the network level;
only credentials keep it out ([Segmentation](../segmentation/README.md)), so the credentials go first.

**The root of trust is compromised** (the CA's root key leaks). A new root is made, with Name Constraints so that
it can vouch only for the estate's own names. Every machine trusts it beside the old one, every certificate is
re-issued from it, and then the old root is removed from every trust store. The steps are
[The root of trust](../root-of-trust/README.md)'s replacement procedure, done as one change.

**A site is lost** (fire, theft, a long outage). That is not an incident page, it is
[Disaster recovery](../disaster-recovery/README.md).

## The drill

[`drill-lost-device.sh`](drill-lost-device.sh) plays the lost laptop in miniature. A throwaway person CA issues
certificates to two laptops, and an nginx door admits a certificate only if it verifies and its name is on the door's
list of enrolled machines. Bob's laptop is reported lost: its name leaves the list and the door is told. It must be
refused from then on, while Alice's laptop still opens the door, and a certificate from another CA that merely
claims Alice's name is refused throughout. Needs curl, OpenSSL 1.1.1 or later and nginx (`NGINX_BIN=/path` if it is
not on the PATH; Debian's is `/usr/sbin/nginx`, tried by default); runs as any user.

```
$ ./drill-lost-device.sh
door on 127.0.0.1:23992
ok    bob's laptop before anything is lost -> 200
ok    a foreign CA's certificate named alice-laptop -> 403
ok    bob's lost laptop after its removal -> 403
ok    alice's laptop, untouched by bob's loss -> 200
all checks passed
```

With `ARM=noreload` the name is removed from the list but the door is never told. Exactly the lost laptop's refusal
must fail: a removal nobody applied protects nothing.

```
$ ARM=noreload ./drill-lost-device.sh
...
ARM: exactly the lost laptop's refusal failed when the door was not told, as it must
```

## What is still open

- **Revocation is published, not enforced everywhere.** Until every door checks the revocation list, a lost
  device's certificate is refused only where its name was removed.
- **No incident has been run against this page from start to finish.** Pieces have been run on their own: the
  device removal, and the introduction of a new root with Name Constraints beside the old one.
- **Detecting a compromise** is not this page's subject; [Central logs](../central-logs/README.md) and the alerts
  are where one is noticed.
