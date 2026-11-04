# A root certificate limited to your own names

## The mechanism

Your private certificate authority has a root that every machine and every device trusts. That is what makes
your internal https names work without warnings.

**Without a limit**, the root vouches for any name. Your phone trusts it, so a certificate it signs for
`yourbank.com` is accepted too. If the root's key, or any intermediate under it, is ever stolen or misused, every
device that trusts the root can be shown a convincing fake of any website in the world.

**With a limit**, the root carries a *Name Constraints* extension: "I vouch only for names under `home.arpa`
and for private addresses." A browser that trusts this root still opens your internal names with no warning.
It refuses a certificate the same root signed for any other name.

Think of a notary whose stamp reads "valid for documents of this building only". A forged lease for another
building fails, even though the stamp itself is real.

Two conditions apply:

- **It protects nothing while an unlimited root is still trusted.** Until the old root is gone from every
  machine's store and every device, a stolen old key still forges anything.
- **Everything outside the limit stops working.** That includes names under another suffix, IPv6 addresses,
  ranges you did not list (such as 100.64.0.0/10, which VPN meshes use), and in OpenSSL clients certificates
  whose only name is a dotted common name (below). Survey before you choose.

## The constraint

[`name-constraints.txt`](name-constraints.txt) holds one OpenSSL `nameConstraints` value:

```
critical, permitted;DNS:home.arpa, permitted;IP:10.0.0.0/255.0.0.0, permitted;IP:172.16.0.0/255.240.0.0,
          permitted;IP:192.168.0.0/255.255.0.0, permitted;IP:127.0.0.0/255.0.0.0
```

- `DNS:home.arpa` permits `home.arpa` and every name under it. It does not permit `evilhome.arpa`.
- A certificate carrying one permitted name and one foreign name is refused whole.
- **IP ranges are only the ones listed.** Once any IP range is permitted, every other address is refused: IPv6
  (add `permitted;IP:fc00::/fe00::` and `permitted;IP:::1/ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff` if you use it;
  OpenSSL takes a mask written as an address, not a prefix length) and 100.64.0.0/10 (add
  `permitted;IP:100.64.0.0/255.192.0.0` if a VPN mesh hands out those addresses).
- An email-style name (`billing@example.test`) is not limited.
- **A common name is checked when a certificate has no DNS name.** OpenSSL then reads a hostname-like CN as a DNS
  name and checks it against the limit, even if the certificate carries an IP address. `CN=alice.laptop` is
  refused; `CN=alice-laptop@production` is not, because the `@` stops it looking like a hostname. Go never reads
  the CN. Give person and device certificates a CN with no dots, or one inside the limit.
- Mark it `critical`: a client that cannot read it must refuse the root rather than ignore the limit.

Before choosing, survey every certificate your CA has issued: each name and address must fall inside the limit.

## Moving to it without re-issuing a key

You already have a root, intermediates under it, and certificates on every machine. You do not re-issue them.

**1. Mint the new root.** Keep its key off ordinary disk: make it in a RAM directory, put it in whatever holds
your secrets (a password manager, a vault, an offline USB key), then delete the RAM copy.

```
d=$(mktemp -d -p /dev/shm); chmod 700 "$d"
printf '[r]\nbasicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nnameConstraints=%s\n' \
  "$(grep -v '^#' name-constraints.txt | tr -d '\n ')" > "$d/root.ext"
openssl ecparam -name prime256v1 -genkey -noout -out "$d/root.key"
openssl req -x509 -new -key "$d/root.key" -subj "/O=Example/CN=Example Root (our names)" -days 7300 \
  -config "$d/root.ext" -extensions r -out new-root.crt
# store $d/root.key where you keep secrets, then: rm -rf "$d"
```

`pathlen` must allow every CA level below the root: `pathlen:1` permits one intermediate between root and leaf.

**2. Cross-sign each intermediate.** The new root signs the intermediate's existing certificate again: same public
key, same subject, new issuer. Only public data is used; the intermediate's key is not touched.

```
printf '[c]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > ca.ext
openssl x509 -in old-intermediate.crt -CA new-root.crt -CAkey "$d/root.key" -set_serial 0x$(openssl rand -hex 16) \
  -days 3650 -extfile ca.ext -extensions c -out cross.crt
for f in old-intermediate.crt cross.crt; do openssl x509 -in $f -noout -subject -ext subjectKeyIdentifier; done   # must match
```

- OpenSSL prints "Error with certificate … unable to get local issuer certificate" about the input while it
  signs; that is a note about the old intermediate, not a failure. Check `cross.crt` was written.
- The extensions are **given again**, not copied. Copied, the authority key identifier would still name the old
  root and no chain would build. The intermediate's own `basicConstraints`, `keyUsage` and any constraints are
  replaced by what `ca.ext` says, so write them as the old certificate had them.
- The **subject key identifier must stay byte-identical**: every certificate the intermediate issued names it.
  `hash` reproduces it only if the old one was made the same way; if the check above differs, write the old
  value in `ca.ext` (`subjectKeyIdentifier=<hex from the old certificate>`).

Every certificate already issued now chains to the new root as well as the old one.

**3. Trust both roots** on every machine and every device.

**4. Present both chains, and keep both roots trusted by every OpenSSL-family client.** No single order serves
an OpenSSL-family client that trusts only one root (the drill measures it):

| Server sends | Client trusts the old root only | the new root only | both |
|---|---|---|---|
| old-issued, then cross | opens | **refused** | opens |
| cross, then old-issued | **refused** | opens | opens |

Browsers and Go try every candidate chain, so either order works for them. Send the old-issued certificate first
while any machine still trusts only the old root, and install the new root next to the old one everywhere
before any client is moved to the new root alone.

**5. Retire the old root.** Servers present the cross-certificate alone. Every machine's store, and every device,
holds the new root alone. Only from here does the limit protect anything.

**6. Prove the refusal** on a real device with [`drill-device.sh`](drill-device.sh).

## What the clients do

| Client | Honours the limit | How we know |
|---|---|---|
| OpenSSL 3.5 command line | yes; takes the first chain that matches, no backtracking | drill |
| Go 1.24 | yes; tries every candidate chain; never reads the CN | drill |
| Chromium | yes | drill (refused under the limited root, opened under an otherwise identical root without it) |
| Firefox (NSS) | yes | drill (same twin check) |
| nginx 1.28 verifying client certificates | yes; a person certificate with no subjectAltName verifies | drill |
| Java 21 | **no**: ignores a trust anchor's constraint and accepts every name | drill |
| A browser on macOS (which one was not recorded) | yes | seen by hand: refused the foreign page of `drill-device.sh` |
| macOS, iOS | opens permitted names with no warning | seen by hand; refusal on iOS not yet tried |

Libraries built on OpenSSL (Node's bundled copy, Python and curl where they use OpenSSL) behave as OpenSSL does.
curl built on GnuTLS, Schannel or Secure Transport, and Python on Windows or macOS, use other verifiers: test
them.

**What happened on our own move** (seen by hand, not drilled):

- **Java needs its own guard.** If a Java service must refuse foreign names, it needs a check of its own.
- **One root per file for some tools.** smallstep's `step --root` refuses a file holding two certificates. Keep
  each root in its own file.
- **Long-running servers cache the client CA.** nginx reads `ssl_client_certificate` at start and reload. After
  the root files change, reload every nginx (after `nginx -t`), or client certificates are refused.
- **Restart in the right order.** A service restarted before its root file changed keeps the old root until
  restarted again.

## The drills

Both drills make a throwaway root in a private temporary directory and read no real key. A refusal counts only
when it is for the name; any other error fails the drill.

**Prerequisites:** OpenSSL 3.0 or later (macOS ships LibreSSL, which lacks `-no-CAstore`), bash, curl and
python3. `drill-clients.sh` runs Go, Java and nginx in docker (images `golang:1.24`, `eclipse-temurin:21-jdk`,
`nginx:1.28`, `debian:trixie`, pulled on first use), and the browsers through playwright-core. `drill-device.sh
serve` needs Linux (`ip`, `setsid`, GNU `timeout`).

```
./drill-clients.sh                     # OpenSSL, the cross-signing move and chain order always; Go, Java, nginx,
                                       # Chromium and Firefox when their tools are present, otherwise SKIP
ARM=noconstraint ./drill-clients.sh    # same root without the limit: every refused(constraint) case must FAIL

./drill-device.sh check                # proves the two device pages on this machine, then deletes everything
ARM=noconstraint ./drill-device.sh check   # must FAIL
./drill-device.sh serve 192.168.1.10   # serves them on your network for a phone or laptop; prints the steps
./drill-device.sh stop                 # stops the pages and deletes the directory
```

`drill-device.sh serve` deletes the root key as soon as the two pages are signed; the certificates stay until
`stop`. It uses sslip.io, a public DNS service, to give the device a foreign name that points at your machine.
A resolver with DNS-rebind protection (dnsmasq, OpenWrt, Pi-hole) drops such answers; then the device fails on
DNS, which proves nothing. The refusal must be a certificate error. Afterwards, remove the drill root from the
device.
