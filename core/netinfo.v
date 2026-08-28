module core

import os

// Discovery of the machine's own network situation: which resolvers it already
// uses, which of them answer from memory, and whether a tunnel is in the way.
//
// The parsers are pure and take text, so they are tested against fixtures. Only
// `detect` runs commands, and it never fails: a benchmark that refuses to start
// because `resolvectl` is missing is useless on exactly the machines where the
// measurement is most interesting. See docs/ARCHITECTURE.md § Failure policy.
pub enum ResolverSource {
	resolv_conf
	resolvectl
	gateway
}

pub struct Resolver {
pub:
	ip     string
	source ResolverSource
	// is_cache marks a resolver that can answer from local memory. Its warm
	// latency is a memory lookup wearing the units of a network round trip, so
	// it is excluded from the warm ranking and shown separately.
	// See docs/SCORING.md § Exclusions.
	is_cache bool
}

pub struct NetInfo {
pub:
	resolvers []Resolver
	gateway   string
	// ifname is the interface carrying the default route, and travels in every
	// output line: without it, history silently averages fibre with mobile.
	ifname string
	// tunnels are tunnel-like interfaces that are up. Any entry means the
	// measurement is of the tunnel, not of the link.
	tunnels []string
	// ipv6 is whether this machine has a default IPv6 route. It gates the IPv6
	// component of the capability subscore: a provider is not credited for an
	// address family the link cannot carry. docs/SCORING.md § capability.
	ipv6 bool
}

// tunnel_prefixes is the closed list from docs/METHODOLOGY.md § Fail loudly on
// interference. A name matching one of these does not prove traffic is being
// tunnelled; it proves the question is worth putting to the user.
const tunnel_prefixes = ['tun', 'tap', 'wg', 'tailscale', 'ppp', 'ipsec', 'utun']

// vpn_detected reports whether anything tunnel-shaped is up. The run continues
// either way; the user is warned and may pass --force.
pub fn (n NetInfo) vpn_detected() bool {
	return n.tunnels.len > 0
}

// detect gathers what the system will tell us. Every step degrades to nothing
// rather than to an error, and a machine that answers none of these still
// benchmarks public resolvers correctly.
pub fn detect() NetInfo {
	mut resolvers := []Resolver{}

	for ip in parse_resolv_conf(read_file_or_empty('/etc/resolv.conf')) {
		resolvers << Resolver{
			ip: ip
			source: .resolv_conf
			is_cache: is_loopback(ip)
		}
	}

	// The upstream behind a local stub competes on its own terms; the stub in
	// front of it does not. Both are measured, labelled differently.
	for ip in parse_resolvectl_status(run_or_empty('resolvectl status')) {
		if resolvers.any(it.ip == ip) {
			continue
		}
		resolvers << Resolver{
			ip: ip
			source: .resolvectl
			is_cache: is_loopback(ip)
		}
	}

	gateway, ifname := parse_default_route(run_or_empty('ip route'))
	if gateway != '' && !resolvers.any(it.ip == gateway) {
		// The router is usually a resolver too, and on many consumer links it
		// is the fastest one. It is probed, never assumed to answer.
		resolvers << Resolver{
			ip: gateway
			source: .gateway
			is_cache: false
		}
	}

	// A default IPv6 route is the cheapest honest test of whether this link can
	// carry IPv6 at all. The same parser reads it: `ip -6 route` prints default
	// routes in the same shape.
	v6_gateway, _ := parse_default_route(run_or_empty('ip -6 route'))

	return NetInfo{
		resolvers: resolvers
		gateway: gateway
		ifname: ifname
		tunnels: parse_tunnel_interfaces(run_or_empty('ip -o link'))
		ipv6: v6_gateway != ''
	}
}

// parse_resolv_conf returns the nameserver addresses in the order the file
// lists them, which is the order the stub resolver would try.
pub fn parse_resolv_conf(text string) []string {
	mut out := []string{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line.starts_with('#') || line.starts_with(';') {
			continue
		}
		fields := line.fields()
		if fields.len >= 2 && fields[0] == 'nameserver' {
			out << fields[1]
		}
	}
	return out
}

// parse_default_route returns the gateway and interface of the default route
// with the lowest metric, which is the one the kernel will actually use.
//
// A machine with two default routes is ordinary, not exotic: a laptop on wifi
// with a second adapter attached has exactly the layout this handles. Taking
// the first line instead would name the wrong interface in every output line.
pub fn parse_default_route(text string) (string, string) {
	mut best_metric := int(2147483647)
	mut gateway := ''
	mut ifname := ''

	for raw in text.split_into_lines() {
		fields := raw.trim_space().fields()
		if fields.len < 5 || fields[0] != 'default' {
			continue
		}

		mut via := ''
		mut dev := ''
		// A route with no metric keyword has metric 0, the highest priority.
		mut metric := 0
		for i, f in fields {
			if i + 1 >= fields.len {
				break
			}
			match f {
				'via' {
					via = fields[i + 1]
				}
				'dev' {
					dev = fields[i + 1]
				}
				'metric' {
					metric = fields[i + 1].int()
				}
				else {}
			}
		}

		// A point-to-point default route has a dev and no via, which is the
		// normal shape for OpenVPN and some WireGuard setups. Requiring a
		// gateway would let a higher-metric route win and file a tunnelled run
		// under the untunnelled interface's name.
		if dev != '' && metric < best_metric {
			best_metric = metric
			gateway = via
			ifname = dev
		}
	}

	return gateway, ifname
}

// parse_tunnel_interfaces returns the tunnel-like interfaces that are up.
//
// Up is read from the interface flags, not from `state`: a WireGuard or
// Tailscale interface carrying traffic reports `state UNKNOWN` while its flags
// say UP, and keying on `state UP` misses it entirely.
pub fn parse_tunnel_interfaces(text string) []string {
	mut out := []string{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' {
			continue
		}
		// "4: tailscale0: <POINTOPOINT,...,UP,LOWER_UP> mtu 1280 ..."
		parts := line.split(':')
		if parts.len < 3 {
			continue
		}
		// A virtual interface may be written as "vlan0@eth0"; the parent is not
		// part of its name.
		name := parts[1].trim_space().all_before('@')
		if name == '' {
			continue
		}

		flags := line.find_between('<', '>').split(',')
		if 'UP' !in flags {
			continue
		}
		if tunnel_prefixes.any(name.starts_with(it)) {
			out << name
		}
	}
	return out
}

// parse_resolvectl_status returns the upstream servers systemd-resolved is
// forwarding to, which is what actually competes when /etc/resolv.conf points
// at the 127.0.0.53 stub.
//
// NOTE: this parser is written against systemd-resolved's documented output and
// has not been checked against a live one, because the machine it was developed
// on runs a different local resolver. Verify it on a systemd-resolved host
// before trusting the stub-versus-upstream delta.
pub fn parse_resolvectl_status(text string) []string {
	mut out := []string{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		key, value := line.split_once(':') or { continue }
		if key.trim_space() !in ['Current DNS Server', 'DNS Servers'] {
			continue
		}
		for ip in value.fields() {
			// Link-scoped IPv6 arrives as "fe80::1%wlp3s0". The zone is kept: a
			// link-local address without it is not the same address, and dropping
			// it would send the probe out of whatever interface the kernel picked
			// and file the result under this resolver's name.
			//
			// The transports do not dial a zoned address yet. Reporting it
			// faithfully and failing loudly later beats reporting a different
			// address that happens to connect.
			if ip != '' && ip !in out {
				out << ip
			}
		}
	}
	return out
}

// is_loopback reports whether an address answers from this machine. It is a
// prefix test, not a parse: 127.0.0.0/8 is loopback in its entirety, which is
// how systemd-resolved (127.0.0.53) and dnscrypt-proxy (127.0.0.1) both land
// here.
fn is_loopback(ip string) bool {
	return ip.starts_with('127.') || ip == '::1' || ip == '0:0:0:0:0:0:0:1'
}

fn read_file_or_empty(path string) string {
	return os.read_file(path) or { '' }
}

fn run_or_empty(cmd string) string {
	result := os.execute(cmd)
	if result.exit_code != 0 {
		return ''
	}
	return result.output
}
