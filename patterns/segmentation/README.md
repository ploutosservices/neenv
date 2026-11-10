# Segmentation without host firewalls

## The problem

A service that should answer only its own consumers answers anyone who can reach its port. The textbook answer is a
default-deny firewall on every machine (nftables), listing what may reach what. On a dozen machines that list is a
second copy of something that already exists: which service listens where, and for whom. Two copies of one fact
disagree sooner or later. Then the firewall either blocks something that was working or allows something that should
not be open, and nobody notices which.

This pattern keeps services apart without a host firewall on the servers at home. It does that at four places that
already exist, with one declaration and a daily check that the machines match it. The machines with public addresses
do run a host firewall, for the reason given below.

**What it does not do: separate the servers from each other.** Inside the server network and the private mesh, any
machine reaches any service another machine offers there. One compromised server reaches every cluster service. From
that point the services' own sign-in is the only control: database logins, client certificates, tokens. This
pattern makes the network small and declared; it does not make the inside untrusted.

## The decision

**Declined: a default-deny host firewall on the servers behind the routers.** The servers sit behind each site's
router, which forwards almost nothing inward. Inside, the four layers below do the separating. A host firewall would
add a second list of ports that has to agree with the first one. What is not declined is a firewall at the
**router**, between networks: layer 2 below needs one, and the routers' IPv6 filter already is one. This stands until the owner reverses
it, and it is recorded with its reason so that nobody has to ask "did you not consider it?".

**Kept: a host firewall where a machine has a public address.** A cloud machine has no router in front of it. There,
`ufw` denies everything inbound by default and allows only the private network's port, ssh, the public web, and a
short list of internal services on the private network's interface only. Measured here: default deny incoming, 27
allow rules on one cloud machine.

## The four layers

**1. One door from the internet per site.** Each site's router forwards three ports and nothing else, all to one
reverse proxy: 80, 443, and ssh on a non-standard port to that proxy's machine. Measured on both routers here: the
first site forwards exactly 80, 443 and 22→2222 to its proxy; the second forwards 80 and 443 to its proxy, plus one
port to a client's file server on that client's own network, which is that client's decision. The private network
(WireGuard) is the only other way in, and every peer is a key the routers know. Port forwarding covers IPv4 only.
Over IPv6 each server has a global address, so the router's IPv6 forward filter is what keeps the internet out:
here both routers accept established connections and ICMPv6 and drop every other new connection from the WAN. That
filter is declared in configuration and was read back as declared on both routers. It is a precondition of this
decision: without it, every service listening on `::` is on the internet.

**2. Bind addresses, declared per socket.** Every listening socket is declared in one registry, with how far it may be
reached:

| Exposure | Binds | Example |
|---|---|---|
| loopback | `127.0.0.1` only | a database used only by the application beside it; a service behind the local proxy |
| cluster | named addresses: the server network and the private mesh | node exporter, an internal API |
| public | every address | the reverse proxy, ssh |

A *device network*, the Wi-Fi where the televisions, cameras and thermostats live, is not trusted. A service is not
to answer there unless something on that network is its consumer. **A bind address alone does not do that.** It
chooses which of the machine's addresses answers, not who may send to it. Linux answers a packet for any of its own
addresses whichever interface it arrives on, and the router routes between the device network and the server
network. Measured here: from a machine's Wi-Fi interface on the device network, a node exporter bound only to the
server-network address answered 200. Keeping the device network out takes a forward rule at the router, from the
device network to the server network, admitting only what lives there as a consumer: browsers to the proxy, ssh to
named machines. That rule is not built here yet (below). What the bind address does do: a service bound to the
server-network address is not offered on the machine's own device-network address, and a service bound to loopback
is reached by nothing outside the machine at all. It has no rule order to get wrong. It can make a service fail at
boot, if the address is not up yet (configuration, below).

**3. The proxy decides by source address.** A private name answers only a private source; the internet gets 403. That
fence and its traps are in [Names, public and private](../names/README.md), among them a router's hairpin NAT, which
makes a request from outside arrive from a private address.

**4. The mesh decides by key, and the router by rule.** A WireGuard peer is accepted only from the addresses its
`AllowedIPs` names. That limits where it may claim to come from, not where it may go: the router forwards a peer's
packets wherever its routes lead. A guest (a contractor who needs one file server) is limited by a forward rule on
the router that admits that peer's address to that one server and drops the rest. That rule is a firewall rule, at
the router. A Linux machine acting as the hub with forwarding on and no forward rules would admit a guest everywhere.

**Containers.** A container runtime that publishes a port (`docker run -p 8080:80`) writes its own packet rules,
which a host firewall like `ufw` does not see, and with Docker's `userland-proxy` off there is no listening socket for
`ss` to report either. The rule here is that a container behind the proxy publishes its port on loopback
(`-p 127.0.0.1:8080:80`) and the registry declares that loopback port; a container that must be reached directly
publishes on one named private address, never on every address. On a machine with a public address, a published port that is
not on loopback is on the internet whatever `ufw` says; Docker's `DOCKER-USER` chain is where to restrict it.

## The check

The registry is only worth something if the machines match it. Every day a job asks each machine what is listening
(`ss -ltnp` for TCP) and compares it with the registry. A socket nobody declared is a finding with an owner. So is a socket
bound wider than its declaration. The registry is the declaration; the kernel is the truth; the job is the judge.
[`drill-segmentation.sh`](drill-segmentation.sh) is the same comparison for one machine.

## The configuration, with example values

The registry, one line per socket (the drill's form; ours is richer, with the process, the owner and which networks
may reach it):

```
# proto/port  exposure  name
tcp/5432      loopback  database
tcp/9100      cluster   node-exporter
tcp/443       public    proxy
tcp/22        public    ssh
udp/51820     public    mesh
```

A cluster service binding named addresses, for example the node exporter:

```
ARGS="--web.listen-address=127.0.0.1:9100 --web.listen-address=10.0.0.21:9100"
```

A service that binds an address the network has not assigned yet fails at boot. Either it waits for the address
(`After=` and `Wants=` on what brings it up), or the kernel is told it may bind an address it does not hold yet
(`net.ipv4.ip_nonlocal_bind=1`); [Patching](../patching/README.md) met both.

On a machine with a public address, `ufw`:

```
ufw default deny incoming
ufw allow 51820/udp                        # the private mesh
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow in on wg0 to any port 9100 proto tcp   # an internal service, on the mesh only
ufw enable
```

## The drill

[`drill-segmentation.sh`](drill-segmentation.sh) needs no credential and no root.

**Its own listeners (`local`, the default).** It starts two throwaway listeners with python: a "database" on loopback
and a "web" service on every address. It declares them as loopback and public, then compares what the kernel says
with the declaration. Only its own ports are judged, so a busy machine does not disturb it, and only once each
listener is confirmed to be its own: a port another program already held is "could not run" (exit 2). If `ss` fails
or reports nothing at all, the drill exits 2 rather than calling an empty list a pass.

```
$ ./drill-segmentation.sh
listeners on tcp/39025 tcp/39026; declared: database tcp/39025 loopback, web tcp/39026 public
ok    every listening socket is declared
ok    database (tcp/39025) is loopback and listens on: 127.0.0.1
ok    web (tcp/39026) is public and listens on: 0.0.0.0
all checks passed
```

Two arms, each breaking one thing. `ARM=widebind` starts the database on every address: exactly its bind check must
fail. `ARM=undeclared` adds a listener nobody declared: exactly the undeclared check must fail.

```
$ ARM=widebind ./drill-segmentation.sh
...
ARM: exactly the database's bind check failed when it listened everywhere, as it must
$ ARM=undeclared ./drill-segmentation.sh
...
ARM: exactly the undeclared check failed for the listener nobody declared, as it must
```

**A real machine (`machine`).** `REGISTRY=ports.tsv CLUSTER_NETS="10.0.0.0/24 10.8.0.0/24" ./drill-segmentation.sh
machine` judges every TCP and UDP socket on the machine against a registry file. With `CLUSTER_NETS` set, a cluster
service must bind only addresses inside those networks, so a bind to the device network's address fails too.
Addresses are read as `ss` writes them: a scope (`%lo`, `%eno1`) is reported, not mistaken for a different address,
and an IPv4-mapped IPv6 loopback counts as loopback.

Run here on one server, against a registry generated from ours (TCP only), it failed six checks:

- UDP sockets the registry never listed: rpcbind (111), the DNS server (53), DHCP clients. Our registry lists TCP only.
- ssh and the proxy's 80 and 443 on every address, while the generated file called them cluster. That is deliberate:
  their consumers are on every network, which our registry says in a way the drill's three words cannot.
- the DNS server on the device network's address, also deliberate: the devices there resolve through it.
- rpcbind on every address. That is a finding: nothing on the device network needs it.

```
FAIL  listening and declared nowhere: udp/111@:: udp/111@0.0.0.0 udp/53@127.0.0.1 ...
FAIL  portmap.rpc (tcp/111) is declared cluster and listens on: :: 0.0.0.0
ok    monitoring.node-exporter (tcp/9100) is cluster and listens on: 127.0.0.1 10.0.0.21
...
```

The drill cannot see who can *route* to an address (layer 2's gap), or a container port published by the runtime's
packet rules with no socket behind it.

## What is still open

- **The device networks reach the server network.** The router forward rule layer 2 needs is not built, so a device
  on the home Wi-Fi reaches cluster services (measured: a node exporter answered 200). It is a change people at home
  would feel, and it waits for the owner's decision.
- **rpcbind listens on every address** on a server that also sits on a device network. It is declared, so the
  daily check does not flag it; the declaration is what is too wide.
- **UDP is not in our registry.** The drill checks it; the daily job here checks TCP only.
- **The development machine and production's databases.** PostgreSQL now refuses the development machines by
  address, in a `reject` line above every login (`host all all <dev-box>/32 reject`; pg_hba is first-match), so a
  production password on a development machine opens nothing. MariaDB has no such list: an account is admitted by its
  own host pattern, and two production accounts here still match a development machine (one names it outright). Until
  those patterns are narrowed, only their passwords keep it out.
- **IPv6.** Several services bind `::` beside `0.0.0.0`. What reaches them from outside over IPv6 is decided by the
  routers' IPv6 filter, not by anything in this pattern, and the drill does not check it.
- **The check is daily.** A socket opened by hand and closed before the job runs is never seen.
