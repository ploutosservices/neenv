# The root of trust: who signs what, where the keys are kept, and how a certificate is taken back

## The problem

Every machine and every device trusts one root certificate. That trust is what lets a browser open an internal
name with no warning, a proxy check a calling service's certificate, and a sign-in server recognise a person's
laptop. [A root limited to your own names](../constrained-root/README.md) stops a stolen key from forging
anyone else's website. It does not answer four other questions:

- **Who signs day to day?** If the root signs everything, its key is in use every day, on a machine that answers
  the network.
- **Where is the root key?** A key that must be used once a year and must never be lost is kept differently from
  one used every minute.
- **How is the root replaced?** Every device trusts the old one, and certificates already issued name it.
- **How is one certificate taken back?** A laptop is lost. Its certificate is valid for another eleven months.

**Without a hierarchy**, the one key that every device trusts sits on the server that signs, and a compromise of
that server is a compromise of all trust. **With one**, the root signs only a few intermediate certificates and is
then put away. Each intermediate signs one kind of certificate. A compromised signing server costs one
intermediate, which the root can disown, not the root itself.

Think of a bank. The board's seal is in the vault and is brought out to appoint branch managers. Each branch
manager signs the day's cheques. A forged cheque from one branch is that branch's problem; the board appoints a
new manager without changing its seal.

**Words used here.** A *root* is a certificate that signs itself and that clients are told to trust. An
*intermediate* (or *issuing CA*) is a certificate the root signed that may itself sign. A *leaf* is a certificate
that may not sign: a server's, a service's or a person's. A *cross-certificate* is a second certificate for an
existing intermediate's key, signed by a different root. A *revocation list* (CRL) is a signed list of serial
numbers its issuer has taken back.

## What runs here

**step-ca**, an open-source certificate authority, in two separate instances, one per intermediate (one instance
signs with one intermediate). nginx at the edge checks client certificates and revocation lists. OpenSSL, run by
hand, does the few acts that need the root key.

### The hierarchy

```
Root (limited to our names, pathlen 1, 20 years, EC P-256)
│   key: on no machine
├── Service CA (pathlen 0)            servers and services
│     ├── 24-hour identities          service to service, renewed by machine
│     └── 1-year certificates         private-suffix names a person opens in a browser
├── Person CA (pathlen 0)             people's devices
│     └── 1-year client certificates  CN=<person>-<machine>@production, client authentication only
│
SSH host CA key, SSH user CA key      plain SSH CA keys, served by the service CA's instance

Non-production person CA (self-signed, separate)   trusted only by non-production edges; on no device
```

- **Two intermediates, not one.** The two classes can be revoked, rotated and given lifetimes separately. The
  edge that admits people names the person CA to the browser, because a browser offers a certificate only when its
  issuer is named. Naming it is not the same as admitting only it: that edge also trusts the root, so a certificate
  from the service CA can build a valid chain there too (see *What is still open*).
- **Two issuers for names a browser opens, by zone.** A name in a **public** zone, even one that points at a
  private address, gets a publicly trusted certificate from Let's Encrypt by DNS challenge. A name under the
  **private** suffix (`home.arpa` here), for which Let's Encrypt cannot issue, gets the service CA's one-year
  certificate. A name is issued by one of the two, never both.
- **`pathlen` is the limit on depth.** The root allows one level of CA below it (`pathlen:1`); each intermediate
  allows none (`pathlen:0`). An intermediate cannot create a CA of its own.
- **Lifetimes are a policy per class, enforced by the CA.** Service identities live 24 hours, so a short life is a
  real control on a credential worth stealing. Browser-facing certificates live a year because no daemon renews
  them at night. A year is a choice: it stays under the 398-day limit browsers place on publicly trusted
  certificates, so it would still be accepted if browsers ever applied that limit to a root a user installed,
  which today they do not. Person certificates live a year. A request for longer than its class allows is refused,
  not shortened.
- **The person CA signs one shape only.** Its template refuses any common name that is not
  `<person>-<machine>@production`. A device enrols by SCEP (it makes its own key, which never leaves it, and
  presents a one-time code that is replaced after every enrolment) or with a one-time token bound to one name.
  SCEP needs an RSA key to decrypt the request; the person CA is EC, so SCEP has its own RSA decrypter key, and
  signing stays with the CA. The devices' own keys are RSA 2048 (the enrolment profile asks for that), which is
  why the template below grants `keyEncipherment`. The template grants it whatever the key type, so a device that
  enrols with an EC key by token gets a usage its key cannot perform; that is harmless to verification but
  untidy, and is noted under open.
- **SSH has its own CA keys.** SSH certificates are not X.509, so the root does not sign them. Host certificates
  (a year) are signed on the configuration controller by an administrator provisioner; no server holds a signing
  credential. A person's SSH certificate is signed after they sign in at the sign-in server, and a server admits it
  only into an account whose principals file lists one of its principals.
- **Non-production has its own person CA**, self-signed and outside this hierarchy. Only non-production edges
  trust it, and only as a client CA. A production person certificate is refused there.

### Where each key is kept, by kind

| Key | Kept | Used for |
|---|---|---|
| Root | **On no machine.** Encrypted, in the password manager people use, with that store's own backup and recovery. | Minting an intermediate or a cross-certificate; signing the root's own revocation list once a year |
| Each intermediate | On its CA's host, encrypted. The password is fetched from the secret store when the host is configured and placed beside the key, so the CA starts unattended. | Signing every certificate of its class |
| SSH host and user CA keys | Made on the configuration controller, encrypted with the CA key password, stored in the password manager **before first use**, placed on the CA host | Signing SSH certificates |
| A device's key | On the device; for SCEP, made there and not exportable | Proving the device is who it says |

- **The root key is never written to a disk.** When it is needed, it is read from the store into a pipe, used,
  and gone. The mint script put it into the store at once and wrote it to no file. Swap, and temporary copies a
  tool may make, were not ruled out.
- **The CA host proves the root key is absent.** Configuring a CA host fails if any file named like a root key is
  found there. The rule survives someone who does not know why it matters.
- **This is not an offline root on dedicated hardware.** There is no air-gapped machine and no hardware security
  module. The root key's exposure is the password manager's. That is a choice of cost, stated so it is not
  mistaken for one.
- **A signing key is live in memory on its CA host**, as on any CA. That is why only intermediates sign there.

### The CA's availability is a cost of short lifetimes

If the service CA is down, nothing renews. Renewal fires at about two thirds of a certificate's life, so 24-hour
identities give about 8 hours before the first one expires and about 24 before most have. Watching the CA host is
therefore not optional.

## Configuration, with example values

The service CA's lifetimes, as step-ca provisioners (`ca.json`, abridged):

```json
"authority": {
  "claims": { "minTLSCertDuration": "5m", "defaultTLSCertDuration": "24h", "maxTLSCertDuration": "8760h" },
  "provisioners": [
    { "type": "ACME", "name": "acme",     "claims": { "defaultTLSCertDuration": "24h",   "maxTLSCertDuration": "24h" } },
    { "type": "ACME", "name": "acme-web", "claims": { "defaultTLSCertDuration": "8760h", "maxTLSCertDuration": "8760h" } }
  ]
}
```

The person CA's revocation list and device template:

```json
"crl": { "enabled": true, "generateOnRevoke": true, "cacheDuration": "48h", "renewPeriod": "24h",
         "idpURL": "https://person-ca.home.arpa/1.0/crl" }
```

```
{{- if not (regexMatch "^[a-z][a-z0-9]*-[a-z0-9-]+@production$" .Insecure.CR.Subject.CommonName) -}}
  {{- fail "refused: CN is not <person>-<machine>@production" -}}
{{- end -}}
{ "subject": {"commonName": {{ toJson .Insecure.CR.Subject.CommonName }}, "organizationalUnit": ["person"]},
  "keyUsage": ["digitalSignature", "keyEncipherment"], "extKeyUsage": ["clientAuth"],
  "basicConstraints": {"isCA": false},
  "crlDistributionPoints": ["https://person-ca.home.arpa/1.0/crl"] }
```

An edge that admits people (nginx). Verification is optional, because a visitor with no certificate must still
reach the sign-in page. Admission is therefore decided after it: the certificate is passed to the sign-in server
**only when nginx verified it**, and the sign-in server maps the subject to a person and checks that person's list
of machines. A header a caller types is overwritten on every request.

```nginx
ssl_client_certificate /etc/ssl/person-ca-chain.pem;     # the person CA, then the root
ssl_crl                /etc/ssl/person-ca-chain.crl.pem; # a list for EVERY CA in that file
ssl_verify_depth       2;                                # leaf <- person CA <- root
ssl_verify_client      optional;

set $person_cert "";
if ($ssl_client_verify = SUCCESS) {                      # only a verified chain is passed on
    set $person_cert $ssl_client_escaped_cert;
}

location / {
    proxy_set_header ssl-client-cert   $person_cert;     # empty (dropped) unless verified
    proxy_set_header ssl-client-verify $ssl_client_verify;
    proxy_pass https://sign-in.home.arpa;
}
```

**The issuer check this edge should also carry** (not in place here; see open). It admits a verified certificate
only when the person CA issued it:

```nginx
map "$ssl_client_verify|$ssl_client_i_dn" $person_cert_ok {
    default 0;
    "SUCCESS|CN=Example Person CA,OU=person,O=Example" 1;   # the person CA's subject, as nginx prints it
}
# then: set $person_cert only when $person_cert_ok is 1
```

## Replacing the root

The mechanism is in [the constrained-root pattern](../constrained-root/README.md#moving-to-it-without-re-issuing-a-key):
the new root cross-signs each intermediate's existing key, both roots are trusted during the overlap, and the old
one leaves last. No device re-enrols and no key changes. What a whole estate adds:

1. **Mint the new root and trust both.** Put its key in the store at once.
2. **Devices install the new root** next to the old one. On a phone or laptop that is the person's act.
3. **Each CA presents the old-issued certificate first, then the cross.** What was measured, with the server
   sending leaf, old-issued, cross: OpenSSL 3.5, curl, Python and Node holding the old root alone accepted it, and
   holding the new root alone refused it; with the order reversed, the reverse. OpenSSL does search for alternative
   chains, but in this measurement it did not reach the new root through the second, untrusted certificate of the
   same subject. Go, Chromium and Firefox accepted either order with either root. So this order keeps every client
   that holds only the old root working, and path builders reach the new root through the cross. An
   OpenSSL-family client must not be moved to the new root alone until the cross is presented first or alone.
4. **Re-issue the long-lived certificates.** A year-long certificate keeps the chain it was issued with for its
   whole life (certbot stores it), so a device that trusts only the new root cannot reach it. Re-issue every one
   whose stored chain differs from what the CA presents now. 24-hour certificates turn over by themselves.
5. **Find every private copy of the old root** before removing it: application trust stores (Java keystores,
   a secret store's own CA file), files a tool reads with a single-root option, downloads you publish for
   devices, and copies inside container images. Each one holding the old root alone breaks at the next step.
6. **The CAs present the cross alone; the old root leaves every store.** Devices remove it too.
7. **The new root signs its own revocation list.** Once a chain ends at the new root, an edge that checks the
   whole chain needs a list signed by it (the drill shows this).

**Signing the new root with the old one does not work** with `pathlen:1`. The chain cross, then new root, then
old root has two CAs between the old root and the leaf, which `pathlen:1` forbids. Cross-sign the intermediates
instead.

## Taking a certificate back

There are two ways, by class.

**A service certificate is not revoked; it expires.** It lives 24 hours. To take one back, stop it renewing
(remove the line that allows it) and wait one lifetime. No list is published for services.

**A person certificate is on a revocation list, which the edge enforces.**

- **The first act on a lost device is removing it from the sign-in server's list of that person's machines.**
  That takes effect at once. The revocation list is the second wall.
- The person CA publishes its list at `/1.0/crl`. It re-signs the list on every revocation and once a day, each
  valid 48 hours, so a fetched list always has at least a day left.
- **The root's list is signed by hand**, once a year, with the root key read from the store on stdin. It carries
  no distribution point, so it covers every certificate the root signed.
- **The edge checks the whole chain.** With the person CA's list alone, every certificate is refused for want of
  the root's list. An edge's list bundle therefore holds one list for every CA in its client-CA file.
- **A refresh job runs hourly.** It fetches the CA's list, checks each part (signed by the chain, not expired,
  every CA covered), installs only a whole bundle, tests the configuration and reloads. A failed fetch keeps the
  bundle that is still valid. A check alerts at 12 hours left on a fetched list and 30 days on a hand-signed one.
- **It fails closed.** A list past its next update refuses every certificate, revoked or not, with no reload. A
  missing list file stops nginx loading its whole configuration, so the lists are built before any server block
  that names them is written.
- **The refusal is an HTTP 400, not a failed handshake.** Client certificates are optional (visitors with none
  must pass), so the handshake completes and nginx answers 400 before the request reaches the application.
- **The issuing distribution point must match.** step-ca marks its list with a critical *issuing distribution
  point*. OpenSSL then applies the list only to a certificate whose *CRL distribution point* names the same URL;
  a certificate without one is refused as having no list. Every person certificate therefore carries that URL
  (the template above). Certificates issued before it was added must be re-issued before the edge turns
  enforcement on, or those devices are locked out.
- **Revoking needs no signing power.** A separate provisioner may revoke a serial and nothing else: its template
  fails every signing request.

The sign-in server's own revocation check is off; nginx refuses before the request reaches it.

## The drill

[`drill-revocation.sh`](drill-revocation.sh) builds a throwaway hierarchy in a private temporary directory (old
root, new root limited to `home.arpa`, a person CA with an old-issued and a cross-certificate, a service CA, two
person devices and a 24-hour service certificate), revokes one device, and checks with `openssl verify`. The
person edge's issuer check is played by comparing the leaf's issuer with the person CA's subject, as the nginx
`map` above would; nginx itself is not run. A
refusal counts only for its stated reason. It reads no real key, contacts nothing, and deletes everything on exit.

**Needs:** bash and OpenSSL 3.0 or later, on Linux or macOS (macOS ships LibreSSL; use Homebrew's `openssl@3`, or
point `OPENSSL=` at it).

```
$ ./drill-revocation.sh
PASS kept-device want=ok got=ok
PASS revoked want=refused(certificate revoked) got=refused(certificate revoked)
PASS no-revocation-check want=ok got=ok
PASS root-list-missing want=refused(unable to get certificate CRL) got=refused(unable to get certificate CRL)
PASS list-stale want=refused(CRL has expired) got=refused(CRL has expired)
PASS new-root-kept-device want=ok got=ok
PASS new-root-revoked want=refused(certificate revoked) got=refused(certificate revoked)
PASS new-root-old-list-only want=refused(unable to get certificate CRL) got=refused(unable to get certificate CRL)
PASS service-today want=ok got=ok
PASS service-tomorrow want=refused(certificate has expired) got=refused(certificate has expired)
PASS service-chain-at-person-edge want=ok got=ok
PASS service-at-person-edge-with-lists want=refused(unable to get certificate CRL) got=refused(unable to get certificate CRL)
PASS service-at-person-edge-issuer-check want=refused(issuer is not the person CA) got=refused(issuer is not the person CA)
PASS person-at-person-edge-issuer-check want=ok got=ok
14 passed, 0 failed
```

`no-revocation-check` shows that the revoked device is admitted by any client that does not check: the list is
only as good as the edge that reads it. `service-chain-at-person-edge` shows the weakness under open: a service
certificate builds a valid chain at an edge that trusts the root; with the lists it is refused only for want of a
service CA list, and the issuer check refuses it for the right reason. Each arm removes one fix and must go red:

```
$ ARM=no-revoke ./drill-revocation.sh      # the lost device is never put on the list
FAIL revoked want=refused(certificate revoked) got=ok
FAIL new-root-revoked want=refused(certificate revoked) got=ok
ARM=no-revoke: 12 passed, 2 failed

$ ARM=no-cross ./drill-revocation.sh       # the new root never cross-signs the person CA
FAIL new-root-kept-device want=ok got=error(unable_to_get_local_issuer_certificate)
FAIL new-root-revoked want=refused(certificate revoked) got=error(unable_to_get_local_issuer_certificate)
FAIL new-root-old-list-only want=refused(unable to get certificate CRL) got=error(unable_to_get_local_issuer_certificate)
FAIL person-at-person-edge-issuer-check want=ok got=error(unable_to_get_local_issuer_certificate)
ARM=no-cross: 10 passed, 4 failed

$ ARM=no-issuer-check ./drill-revocation.sh   # the person edge admits any verified chain
FAIL service-at-person-edge-issuer-check want=refused(issuer is not the person CA) got=ok
ARM=no-issuer-check: 13 passed, 1 failed
```

(The arms' PASS lines are left out above.) The constrained-root pattern's drills cover the name limit and chain
order across clients; this one covers revocation and what a rotation does to it.

## What is still open

- **Replacing an intermediate's key** (not its issuer) has no written procedure: the new key, the overlap, and
  the certificates the old one issued.
- **Replacing the SSH CA keys**, and revoking an SSH certificate (a key revocation list), are not written down.
  A host certificate lives a year; nothing takes one back early.
- **Year-long browser-facing certificates have no revocation.** No list is published for the service CA. A
  stolen key on such a server is answered only by re-issuing and waiting.
- **No OCSP.** Revocation is by list only.
- **Java does not apply a trust anchor's name limit** (see the constrained-root pattern), so a Java client needs
  its own check.
- **The root is not on dedicated offline hardware.** Moving it to a hardware token or an air-gapped machine,
  and what that would cost in the yearly list signing, is not decided.
- **What happens when the root key is stolen**, end to end, belongs to a pattern on incidents that is not yet
  written.
- **The edge that admits people does not check the issuer.** It trusts the root, so a service certificate sent
  with its own intermediate builds a valid chain to the root there. Today such a certificate is refused only
  because the edge holds no revocation list for the service CA (`unable to get certificate CRL`): an accident of
  the revocation setup, not a control. Turning revocation off, or adding a service CA list to the bundle, would let
  it through to the sign-in server, whose remaining guard is matching the subject against a person's list of
  machines. The fix is the issuer check shown above; the drill shows all three cases.
- **The device template grants `keyEncipherment` whatever the key type.** Devices that enrol by SCEP have RSA
  keys, where it fits; one that enrols by token with an EC key gets a usage its key cannot perform.
- **The intermediates' keys sit on their CA host with their password beside them.** A compromise of that host is
  a compromise of the intermediate; there is no hardware module for it either.
