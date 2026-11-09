# Names, public and private

## The problem

Every service needs a name. Some names are for the world: a tenant's website, the door where a stranger signs in.
Most are not: a database console, a staging copy, an admin page. Both kinds must resolve on every machine and on
every device, wherever that device happens to be.

Two easy answers are both wrong. Giving private names no public record at all breaks a phone that is away from
home and does not use your resolvers. Trusting the name to hide the service protects nothing: if the router
forwards port 443 to the proxy, anyone on the internet can reach any name the proxy serves with one line of
`curl --resolve`, whatever the DNS says.

This pattern keeps every name in files in git, lets a name resolve anywhere, and lets the **proxy** decide who is
answered, by the caller's source address.

## What runs here

**Two kinds of zone, both written from git.**

- **Private zones** use a suffix that is not on the internet: `home.arpa` (set aside for home networks by RFC 8375)
  or one of your own. Bind9 serves them on several servers. Every server is primary for every zone and holds the
  same zone files; no server transfers a zone to another. Each server resolves through itself, and every other
  machine has a static `resolv.conf` naming one of them. The servers answer recursive questions only from private
  addresses and forward everything else to two public resolvers.
- **Public zones** live at a public DNS host. OctoDNS reads one YAML file per zone from git and makes the host
  match it.

The records are declared in git and nowhere else. Here the declarations go first into the *catalogue*: one
database listing every machine, service, name and address, which the other layers read instead of keeping their
own copies (NetBox, with its DNS plugin; the "A catalogue" row of neenv's [layers table](../../README.md#the-layers)).
The catalogue is loaded from git and never edited by hand. OctoDNS reads it and writes the Bind9 zone files. A
smaller estate can keep the zone files themselves in git. Either way:

- **Nobody edits a record by hand.** A change is a commit, then a run.
- **Each zone file's serial is derived from its content**, so a run that changes nothing writes the same bytes and
  reports nothing changed. OctoDNS's zone-file writer puts the clock into the serial, so a small step after it
  replaces the serial with a number made from the file's own bytes, the serial line left out (below). The serial
  orders nothing here, because no server transfers a zone.
- **Every zone file is checked before it lands** (`named-checkzone`); a broken file never replaces a good one.
- **OctoDNS changes only the public records it owns.** Its ownership processor writes a TXT record beside each
  record it manages and never touches a record without one. Records another tool writes are filtered out by name:
  the `_acme-challenge` TXT records a certificate client adds and removes, and a name a dynamic-address job
  rewrites.

**A public name may point at a private address.** `tools.example.org` is in the public zone with an `A` record of
`10.0.0.20`. The name resolves anywhere, from any resolver. It connects only from inside the private network,
because `10.0.0.20` exists only there; a device away from home reaches it over the private network (WireGuard, for
example). This is accepted, with two consequences:

- **It discloses an internal address.** Anyone can look up `10.0.0.20`. That says a little about how the network
  is laid out and nothing more.
- **Some home routers drop the answer.** A resolver with DNS-rebinding protection (dnsmasq, OpenWrt, Pi-hole and
  many consumer routers) refuses a public answer that holds a private address. The device then fails on DNS, not
  on the connection. Devices therefore use the estate's own resolvers, which the private network hands them,
  never the resolver of whatever network they are on.

**The proxy fences by source address.** nginx answers a private name only to a caller whose source address is
private: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and loopback (`127.0.0.0/8`). Everyone else gets 403.
The fence does not list `100.64.0.0/10`, the shared address range that an overlay network such as Tailscale hands
its devices, although the resolvers below do answer that range (see what is still open). A name is private
when any of three things is true:

1. its suffix is private (`*.home.arpa`);
2. its server block is declared `internal_only: true` (a private name in a public zone, such as
   `tools.example.org`);
3. every address it resolves to is private (here counting `100.64.0.0/10` and link-local as private too).

The fence is one file that every private server block includes (below), not a copy in each template. A rule
written out four times is remembered four times, and the fourth copy is the one that is missing.

**Public or private is decided once per service, not per name.** A service is public only when a consumer
outside the private network is named for it: a tenant's visitors, a vendor that posts a webhook. Everything else
is private by default and needs no decision. A new name for a service already decided inherits its ruling.

**Two traps the fence must survive.**

- **The router must not rewrite the source.** The fence works only if a request from the internet arrives with
  its real public source address. Check this before relying on it: a router that masquerades inbound traffic makes
  every caller look private.
- **An inside request can arrive from outside.** A name whose public record holds the site's WAN address resolves
  to that address for everybody. A browser at one site asking for a name served at another then crosses the
  internet, and the proxy sees the first site's public WAN address. The fence refuses it. Point private names at
  a private address on a listener the router does not forward to, so inside traffic stays inside. Where a name
  must keep the WAN address, list your own WAN addresses on that one server block, never as a default: a blanket
  allow re-admits anything that leaves through either site.

**Mail records** are in the public zone files with everything else: `MX` for where mail arrives, an SPF `TXT` naming
who may send, a DKIM `TXT` under `<selector>._domainkey` with the signing key's public half, and a DMARC `TXT` at
`_dmarc` telling receivers to reject what fails.

**Certificates depend on which zone the name is in.**

- **A name in a public zone**, including one that points at a private address such as `tools.example.org`, gets a
  Let's Encrypt certificate by DNS challenge: the certificate client writes an `_acme-challenge` TXT record in the
  public zone, so the server never has to be reachable from the internet. The certificate is publicly trusted, and
  the name is listed in the public Certificate Transparency logs; that is accepted.
- **A name under the private suffix**, such as `notes.home.arpa`, cannot get a Let's Encrypt certificate: no public
  authority issues for a suffix that is not on the internet. It gets one from the estate's own certificate
  authority, whose root every machine and device trusts and which is limited to the private suffix and private
  addresses ([The root of trust](../root-of-trust/README.md)).

How the public certificates are obtained and renewed is a later pattern, not yet written.

## The configuration, with example values

The public zone, `public/example.org.yaml`, as OctoDNS reads it:

```yaml
'':
  - type: MX
    values:
      - {preference: 10, exchange: mx1.mail-provider.example.}
      - {preference: 20, exchange: mx2.mail-provider.example.}
  - type: TXT
    value: v=spf1 include:_spf.mail-provider.example -all
_dmarc:
  type: TXT
  value: v=DMARC1\; p=reject\; sp=reject\; rua=mailto:dmarc@example.org
mail2026._domainkey:
  type: TXT
  value: v=DKIM1\; k=rsa\; p=MIIBIjANBgkqh...        # the public key, from the signer
www:
  type: A
  value: 192.0.2.10                                   # the public proxy
tools:
  type: A
  value: 10.0.0.20                                    # a private address in a public zone
```

The sync, `public.yaml`. The token is the *name* of an environment variable, never a value:

```yaml
providers:
  public:
    class: octodns.provider.yaml.YamlProvider
    directory: ./public
  dnshost:
    class: octodns_cloudflare.CloudflareProvider
    token: env/DNS_HOST_TOKEN   # the NAME of an environment variable  pragma: allowlist secret
processors:
  no-root-ns:   {class: octodns.processor.filter.IgnoreRootNsFilter}
  never-acme:   {class: octodns.processor.filter.NameRejectlistFilter, rejectlist: ['/^_acme-challenge(\..*)?$/']}
  ownership:    {class: octodns.processor.ownership.OwnershipProcessor}
zones:
  example.org.: {sources: [public], targets: [dnshost], processors: [no-root-ns, never-acme, ownership]}
```

```
octodns-sync --config-file public.yaml          # the plan: read it; a delete nobody can explain stops the run
octodns-sync --config-file public.yaml --doit   # apply
```

The private zones, written as Bind9 zone files. OctoDNS's `octodns_bind.ZoneFileProvider` does the writing; the
source is the catalogue (here NetBox, through `octodns_netbox_dns`), or a directory of zone files in git:

```yaml
providers:
  catalogue:
    class: octodns_netbox_dns.NetBoxDNSProvider
    url: env/NETBOX_URL
    token: env/NETBOX_TOKEN   # the NAME of an environment variable  pragma: allowlist secret
  bind:
    class: octodns_bind.ZoneFileProvider
    directory: ./out
    file_extension: .zone
    hostmaster_email: hostmaster@example.org.
    default_ttl: 300
zones:
  home.arpa.: {sources: [catalogue], targets: [bind]}
```

After the render, each file's serial is replaced by one made from its content. The file must carry exactly one
`<n> ; Serial` line:

```python
import hashlib, re
SERIAL = re.compile(r"^(\s*)(\d+)( ; Serial)$", re.M)

def content_serial(text):
    body = SERIAL.sub(r"\1\3", text)                     # the serial itself left out
    return int(hashlib.sha256(body.encode()).hexdigest()[:12], 16) % 2147483646 + 1
```

The same records give the same serial on every run and every server; any change of content gives a new one. The
serial is not increasing, which is harmless only because no secondary ever compares two serials.

Each Bind9 server, `named.conf.options`. `100.64.0.0/10` is there so a device on the overlay network can resolve:

```
options {
    listen-on { any; };
    forwarders { 1.1.1.1; 9.9.9.9; };
    forward only;
    allow-transfer { none; };
    recursion yes;
    allow-recursion { 127.0.0.1; 10.0.0.0/8; 172.16.0.0/12; 192.168.0.0/16; 100.64.0.0/10; };
};
zone "home.arpa" { type primary; file "/var/cache/bind/home.arpa.zone"; };
```

Every other machine, `/etc/resolv.conf`, written by configuration management and never by a DHCP client:

```
nameserver 10.0.0.2
nameserver 10.0.0.3
```

The fence, one file, `/etc/nginx/private-fence.conf`:

```nginx
# a private name answers a private source only
allow 10.0.0.0/8;
allow 172.16.0.0/12;
allow 192.168.0.0/16;
allow 127.0.0.0/8;
deny all;                                        # 403 to every other source
```

and the one line that every server block of a private name carries:

```nginx
server {
    server_name tools.example.org;               # internal_only: true
    include /etc/nginx/private-fence.conf;
    location / { proxy_pass http://10.0.0.30:8080; }
}
```

Here the server blocks are generated by configuration management, and the template includes the fence in the same
way; a server block that needs its own WAN addresses gets extra `allow` lines before the include.

`allow` and `deny` run in nginx's access phase. A `return` in the same server block runs earlier and answers
before the fence is read, so a private name never answers with `return`; the drill met this on its first run.

## The drill

[`drill-names.sh`](drill-names.sh) needs no credential. It has two parts.

**The fence, on one machine.** It starts a throwaway nginx on loopback with four server blocks: a public site, a
private name by suffix, a private name in a public zone, and a default that answers 404. nginx is told to take the
caller's address from a header sent by the drill itself (the realip module), so one machine can play a device on
the private network (`10.0.0.5`) and a caller on the internet (`192.0.2.50`). That trust is for the simulation
only; a real proxy must never take its caller's address from a header the caller can send. Needs bash, curl and
nginx with the realip module (Debian's, Homebrew's and the official images have it); `NGINX_BIN=/path/to/nginx`
picks another binary.

```
$ ./drill-names.sh
nginx on 127.0.0.1:21266, fence
ok    www.example.org from 192.0.2.50 -> 200 (a public site serves the internet)
ok    notes.home.arpa from 10.0.0.5 -> 200 (a private name serves the private network)
ok    tools.example.org from 10.0.0.5 -> 200 (a public name on a private address serves the private network)
ok    notes.home.arpa from 192.0.2.50 -> 403 (a private name refuses the internet)
ok    tools.example.org from 192.0.2.50 -> 403 (a public name on a private address refuses the internet)
ok    undeclared.example.org from 10.0.0.5 -> 404 (an undeclared name reaches nothing)
all checks passed
```

With the fence removed, the two refusals must fail. If they did not, the drill could not tell a refusal from a
served page:

```
$ ARM=nofence ./drill-names.sh
nginx on 127.0.0.1:32219, nofence
...
FAIL  notes.home.arpa from 192.0.2.50 -> 200, not 403 (a private name refuses the internet)
FAIL  tools.example.org from 192.0.2.50 -> 200, not 403 (a public name on a private address refuses the internet)
...
ARM: 2 check(s) failed without the fence, as they must
```

Any answer other than the one expected fails, including no answer at all.

**The public record, from public resolvers.** `dns NAME ADDRESS` asks public resolvers directly (1.1.1.1 and
9.9.9.9 unless others are given), so a rebinding filter on your own router cannot hide the answer. It passes only
when the address is private and every resolver answers with it. Needs dig. The public service sslip.io gives a
name that carries a private address, to see it pass; the same name with the wrong address must fail:

```
$ ./drill-names.sh dns 10-0-0-5.sslip.io 10.0.0.5
ok    10.0.0.5 is a private address
ok    1.1.1.1 answers 10-0-0-5.sslip.io with 10.0.0.5
ok    9.9.9.9 answers 10-0-0-5.sslip.io with 10.0.0.5
all checks passed

$ ./drill-names.sh dns 10-0-0-5.sslip.io 10.0.0.6
ok    10.0.0.6 is a private address
FAIL  1.1.1.1 answers 10-0-0-5.sslip.io with '10.0.0.5', not 10.0.0.6
FAIL  9.9.9.9 answers 10-0-0-5.sslip.io with '10.0.0.5', not 10.0.0.6
2 check(s) failed
```

On your own estate, run the fence check for real from two places: from a machine on the internet, `curl --resolve
tools.example.org:443:<your WAN address> https://tools.example.org/` must get 403; from a device on the private
network the same name must be served.

## What is still open

- **DNSSEC is not used.** The private zones are not signed, and the Bind9 servers run with
  `dnssec-validation no`, trusting the two public resolvers they forward to. Whether the public zones are signed is
  a setting at the DNS host; the files in git do not hold it.
- **The resolvers and the fence disagree about `100.64.0.0/10`.** The resolvers answer the overlay network's
  range and the fence counts a name resolving into it as private, but the fence does not admit a caller from it.
  A device on the overlay whose traffic reaches the proxy with its own `100.64.x.x` address resolves a private name
  and is then refused with 403. Whether overlay traffic arrives with that address or with the address of the
  machine that routes it into the private network has not been measured. No reason for leaving the range out is
  recorded. Either the fence admits it or the resolvers stop answering it; until one is chosen, the two disagree.
- **IPv6 is not covered.** The resolvers do not listen on IPv6, and the fence lists IPv4 ranges only. A private
  name given an `AAAA` record would need the fence extended first.
- **The fence is computed when the proxy is configured.** Trigger 3 (every address is private) reads DNS at that
  moment; a record changed afterwards changes nothing until the next run. It needs a check that re-measures on a
  schedule beside it.
- **Mail records are not drilled.** Nothing here checks that `MX`, SPF, DKIM and DMARC are present, or that the
  DKIM key published matches the one the sender signs with.
- **A device on a foreign network without the private network** resolves a private name in a public zone, or
  fails to if its router filters rebinding, and cannot connect either way. That is the intended result, but the
  error it sees differs by router.
