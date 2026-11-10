# A second factor for privileged people

## The problem

A privileged account opened by a password alone is opened by whoever has the password: a phishing page, a
password reused elsewhere, a note left on a screen. A second factor makes the password insufficient. It is
something the person has (a key held on a device) as well as something they know.

The hard part is not turning it on. It is deciding where a second factor is checked, so that every privileged path
passes through a check, and saying plainly where one does not yet.

## What runs here

**The door: the person's own machine is the second factor.** Every application signs in through one shared door
(Keycloak, published as dvar). An administrator signs in with their identity provider (a Google, Microsoft or GitHub
account). An application that needs administrator rights asks the door for a higher **level of authentication**
(an `acr` value, step-up). The door reaches that level only when the browser presents a certificate issued to **one
of that person's named machines**, their laptop or their phone, and the certificate's subject names the same person
as the account (`CN=<person>-<machine>@<door>`, read by a regular expression). The machine made its own key when it
was enrolled, and the key stays on the machine. The person CA's key stays on the CA's server; no laptop holds a CA
key. The reverse proxy in front of the door passes the verified certificate on, and drops any certificate header a
caller sends. Without the certificate, the account signs in at the ordinary level, and the application refuses the
administrator page. A stolen password, or even a stolen provider session, opens nothing privileged from a machine the
person does not own.

**What a machine certificate is and is not.** It is something the person has. Unlike a code typed from a phone, it
cannot be relayed by a phishing page, because the TLS handshake binds it to the real door. But a key held in software
can be copied off the machine, malware on the machine can use both the key and the session, and a browser can be set
to present a certificate without asking. The stronger form is a key that cannot leave the hardware (a TPM, Apple's
Secure Enclave, a PIV token); on the machines here the keys are where each platform's enrolment puts them, and which
of them are hardware-bound is not measured.

**The door also offers passkeys and security keys.** A person can sign in with a passkey instead of a password, and
can enroll a security key as a second factor after a password. Neither replaces the machine certificate for the
administrator role.

**Machines and agents prove who they are by certificates, not passwords.** Every server presents an SSH host
certificate. Every agent and service calls other services with a certificate whose key was made on its own machine.
There is no shared password to phish, and the key never travels.

**The password manager: the owner's own step.** The password manager (Vaultwarden) holds every other credential.
Until this pattern was written, the owner's account opened with its master password and nothing else: the estate's
largest single point, one phished password away from everything. Only the owner can enroll their own device, so the
fix was his act, and he made it: two-step login with an authenticator app is on. A passkey or security key would be
stronger, because a code typed from an app can be relayed by a phishing page and a key cannot. The recovery code
belongs with the other carried secrets ([Disaster recovery](../disaster-recovery/README.md)), so the successor can
still get in.

**Service accounts log in with API keys, and are scoped instead.** The programs that read the password manager log
in with their own accounts and API keys, each able to read only its own collection. An API-key login does not ask
for the second factor at all, so turning two-step login on protects the owner's interactive login and not an API key:
the owner's own API key, if one was ever made, must be rotated or deleted when two-step login is turned on. And the
organisation policy that requires two-step login removes members who have none, which is every program's account; so
here it is turned on per person, not by policy.

## The configuration, with example values

The shape of the rule, in nginx terms. This is a stand-in for the door, small enough to run anywhere; the drill runs
exactly this, and it does not test the door's own flow. The password is the first factor, a certificate from the
person CA naming the same person the second, and either one alone is refused:

```nginx
server {
    listen 443 ssl;
    server_name admin.home.arpa;
    ssl_certificate         /etc/ssl/admin.home.arpa/fullchain.pem;
    ssl_certificate_key     /etc/ssl/admin.home.arpa/privkey.pem;
    ssl_client_certificate  /etc/ssl/person-ca.crt;          # only the person CA, not the service CA
    ssl_verify_client       optional_no_ca;                  # a foreign certificate reaches the rule below
    location /admin/ {
        if ($ssl_client_verify != SUCCESS) { return 403; }   # the second factor: a machine the person CA vouches for
        if ($cert_mismatch) { return 403; }                  # ... and it is this person's machine
        auth_basic           "admin";                        # the first factor
        auth_basic_user_file /etc/nginx/admin.htpasswd;
    }
}
# in http {}: the person a certificate names, and whether it differs from the user signing in
map $ssl_client_s_dn $cert_user { "~CN=(?<p>[a-z]+)-" $p; default ""; }
map "$cert_user:$remote_user" $cert_mismatch { "~^([a-z]*):\1$" 0; "~^[a-z]*:$" 0; default 1; }
```

Both `if` lines run in nginx's rewrite phase, before `auth_basic` runs in the access phase. So a missing, foreign or
wrong person's certificate is answered 403 without the password ever being asked for, and a valid one falls through
to the password (401 until it is given). `$remote_user` is read from the request before the password is checked,
which is what lets the binding be judged first; the password is still checked after.

`optional_no_ca` matters. With `optional`, a certificate from a foreign CA makes nginx answer 400 before any rule
runs; the drill met this. `optional_no_ca` records the failed check, and the rule answers 403 as it does for no
certificate at all.

In the door itself (Keycloak) the rule is a step-up flow by level of authentication: level 1 is the provider's
sign-in; the higher level adds Keycloak's X.509 client-certificate authenticator, with the user found by a regular
expression on the subject and compared with the account already signed in. Keycloak reads the certificate from the
proxy (its nginx certificate-lookup provider, from a header the proxy sets and a caller cannot). Applications that
need administrator rights request that level and refuse a token without it.

The password manager: Settings, Security, Two-step login, and choose a passkey or FIDO2 key (or an authenticator
app). Save the recovery code where the carried secrets are kept.

## The drill

[`drill-second-factor.sh`](drill-second-factor.sh) needs no credential and no root. It makes a throwaway person CA
and an outside CA, certificates for two people's laptops (alice, bob) from the first and one for a stranger's machine
from the second, two passwords, and an nginx door configured as above. Then it tries the combinations. Needs bash 4.4
or later, curl, OpenSSL 1.1.1 or later (LibreSSL lacks some of the options used) and nginx.

```
$ ./drill-second-factor.sh
admin door on 127.0.0.1:29463
ok    alice's password and alice's laptop -> 200
ok    alice's password alone, no certificate -> 403
ok    alice's password and another CA's certificate -> 403
ok    alice's password and bob's laptop -> 403
ok    neither factor -> 403
ok    a wrong password and alice's laptop -> 401
ok    alice's laptop alone, no password -> 401
all checks passed
```

Two arms. `ARM=nocert` removes both certificate rules: exactly the four checks that need the second factor must
fail. `ARM=nobinding` keeps the CA check but drops the binding: exactly one must fail, bob's laptop opening alice's
page.

```
$ ARM=nocert ./drill-second-factor.sh
...
ARM: exactly the 4 checks that need the second factor failed without it, as they must
$ ARM=nobinding ./drill-second-factor.sh
...
ARM: exactly the binding check failed when any person's certificate was enough, as it must
```

## What is still open

- **The password manager's second factor is an app code,** not a key that cannot be relayed. Whether the recovery code
  is kept with the carried secrets, and whether the owner's account ever had an API key, which would skip it, is the
  owner's to confirm.
- **The identity providers' own second factor is not checked.** The door trusts a Google, Microsoft or GitHub sign-in.
  Whether each administrator's provider account requires a second factor is that provider's setting, and nothing
  here reads it. The machine certificate is what the door adds on top.
- **A router's people's logins are a password,** because the router's graphical management tool (MikroTik's WinBox)
  signs in only with a password; it has no key and no second factor. The command line accepts SSH keys, and the
  nightly configuration backup uses a key-only login. Limiting WinBox to the private network is what stands in for a
  second factor there.
- **A lost machine.** Its certificate is revoked as [The root of trust](../root-of-trust/README.md) describes, and its
  private-network peer removed from the routers. The revocation list is published but the door does not yet check
  it, so until a lost certificate expires it is still accepted.
- **Which machine keys are hardware-bound** is not measured.
- **Expired and revoked certificates** are not in the drill. A person with another machine left still has a second factor; a
  person with none has to enroll a new machine in person.
