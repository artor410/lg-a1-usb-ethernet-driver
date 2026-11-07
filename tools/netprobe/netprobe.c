/*
 * netprobe - tiny network measurement helper for the TV (Linux, libc only).
 *
 *   netprobe sink PORT SECONDS [RCVBUF_BYTES]  UDP receiver, prints JSON stats
 *   netprobe echo PORT                         UDP echo server (until killed)
 *   netprobe cpu SECONDS                       per-core busy/softirq%, NET_RX
 *   netprobe ethstats IFACE                    driver/chip counters (ethtool -S)
 *
 * Datagram payload (sender -> sink, and rtt probes): big-endian
 *   uint64 sequence number, uint64 sender timestamp in ns, then padding.
 *
 * Build (static, ARMv7):
 *   arm-linux-gnueabihf-gcc-9 -O2 -static -Wall -Wextra -o netprobe-armv7 netprobe.c
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_CPUS 16
#define MAX_DGRAM 65536
#define IDLE_STOP_NS (2LL * 1000000000LL)
#define START_TIMEOUT_MS 60000		/* give up if no packet arrives at all */
#define MAX_SEQ_SPAN (1ULL << 28)	/* ignore absurd sequence jumps */

static void die(const char *what)
{
	fprintf(stderr, "netprobe: %s: %s\n", what, strerror(errno));
	exit(1);
}

static int64_t now_ns(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		die("clock_gettime");
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static uint64_t get_be64(const unsigned char *p)
{
	uint64_t v = 0;
	int i;

	for (i = 0; i < 8; i++)
		v = (v << 8) | p[i];
	return v;
}

static long parse_long(const char *s, const char *name)
{
	char *end;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (errno || end == s || *end || v < 0) {
		fprintf(stderr, "netprobe: bad %s '%s'\n", name, s);
		exit(2);
	}
	return v;
}

static int udp_bind(long port)
{
	struct sockaddr_in a;
	int fd;

	if (port < 1 || port > 65535) {
		fprintf(stderr, "netprobe: bad port %ld\n", port);
		exit(2);
	}
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		die("socket");
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_ANY);
	a.sin_port = htons((uint16_t)port);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0)
		die("bind");
	return fd;
}

/* Udp InErrors and RcvbufErrors from /proc/net/snmp; -1 if unavailable. */
static void read_udp_snmp(long long *in_errors, long long *rcvbuf_errors)
{
	char hdr[1024], val[1024];
	FILE *f = fopen("/proc/net/snmp", "r");

	*in_errors = *rcvbuf_errors = -1;
	if (!f)
		return;
	while (fgets(hdr, sizeof(hdr), f)) {
		char *hs, *vs, *h, *v;

		if (strncmp(hdr, "Udp: ", 5) != 0)
			continue;
		if (!fgets(val, sizeof(val), f))
			break;
		h = strtok_r(hdr, " \n", &hs);
		v = strtok_r(val, " \n", &vs);
		while (h && v) {
			if (strcmp(h, "InErrors") == 0)
				*in_errors = atoll(v);
			else if (strcmp(h, "RcvbufErrors") == 0)
				*rcvbuf_errors = atoll(v);
			h = strtok_r(NULL, " \n", &hs);
			v = strtok_r(NULL, " \n", &vs);
		}
		break;
	}
	fclose(f);
}

static long long delta(long long a, long long b)
{
	return (a < 0 || b < 0) ? -1 : b - a;
}

struct sink_stats {
	unsigned char *seen;	/* bitmap of received (seq - base) */
	size_t seen_bytes;
	uint64_t base, max_seq, unique, packets, bytes;
	uint64_t reordered, duplicates, ignored;
	int64_t first_ns, last_ns, prev_transit, max_gap;
	double jitter;		/* ns, RFC 3550 interarrival jitter */
};

static void sink_account(struct sink_stats *s, const unsigned char *buf, size_t n, int64_t t)
{
	uint64_t seq, off;
	int64_t transit;

	seq = get_be64(buf);
	/* Sender and receiver clocks differ; RFC 3550 only uses transit deltas. */
	transit = t - (int64_t)get_be64(buf + 8);
	if (s->packets == 0) {
		s->first_ns = t;
		s->base = seq;
	} else {
		int64_t gap = t - s->last_ns, d = transit - s->prev_transit;

		if (gap > s->max_gap)
			s->max_gap = gap;
		if (d < 0)
			d = -d;
		s->jitter += ((double)d - s->jitter) / 16.0;
	}
	s->prev_transit = transit;
	s->last_ns = t;
	s->packets++;
	s->bytes += n;

	if (seq < s->base || seq - s->base >= MAX_SEQ_SPAN) {
		s->ignored++;	/* sent before our first packet, or garbage */
		return;
	}
	off = seq - s->base;
	if (off / 8 >= s->seen_bytes) {
		size_t nb = s->seen_bytes ? s->seen_bytes : 65536;
		unsigned char *p;

		while (nb <= off / 8)
			nb *= 2;
		p = realloc(s->seen, nb);
		if (!p)
			die("realloc");
		memset(p + s->seen_bytes, 0, nb - s->seen_bytes);
		s->seen = p;
		s->seen_bytes = nb;
	}
	if (s->seen[off / 8] & (1u << (off % 8))) {
		s->duplicates++;
		return;
	}
	s->seen[off / 8] |= (unsigned char)(1u << (off % 8));
	s->unique++;
	if (s->unique == 1 || seq > s->max_seq)
		s->max_seq = seq;
	else
		s->reordered++;	/* arrived after a higher sequence number */
}

static int do_sink(long port, long seconds, long rcvbuf_req)
{
	static unsigned char buf[MAX_DGRAM];
	struct sink_stats s;
	long long in0, rb0, in1, rb1;
	int fd = udp_bind(port), rcvbuf = 0;
	socklen_t len = sizeof(rcvbuf);

	memset(&s, 0, sizeof(s));
	if (rcvbuf_req > 0) {
		int v = (int)rcvbuf_req;

		/* SO_RCVBUFFORCE ignores net.core.rmem_max but needs CAP_NET_ADMIN. */
		if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &v, sizeof(v)) != 0 &&
		    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, sizeof(v)) != 0)
			die("setsockopt SO_RCVBUF");
	}
	if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, &len) != 0)
		die("getsockopt SO_RCVBUF");
	read_udp_snmp(&in0, &rb0);
	fprintf(stderr, "netprobe: sink on udp/%ld, rcvbuf=%d, waiting...\n", port, rcvbuf);

	for (;;) {
		struct pollfd p = { .fd = fd, .events = POLLIN, .revents = 0 };
		int r = poll(&p, 1, s.packets ? 100 : START_TIMEOUT_MS);
		int64_t t;
		ssize_t n;

		if (r < 0) {
			if (errno == EINTR)
				continue;
			die("poll");
		}
		if (r == 0 && s.packets == 0) {
			fprintf(stderr, "netprobe: no packet within %d s\n", START_TIMEOUT_MS / 1000);
			return 1;
		}
		t = now_ns();
		if (s.packets && (t - s.first_ns >= seconds * 1000000000LL ||
				  t - s.last_ns >= IDLE_STOP_NS))
			break;
		if (r == 0)
			continue;
		n = recv(fd, buf, sizeof(buf), 0);
		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN)
				continue;
			die("recv");
		}
		if (n < 16) {
			s.ignored++;
			continue;
		}
		sink_account(&s, buf, (size_t)n, now_ns());
	}
	read_udp_snmp(&in1, &rb1);

	{
		uint64_t expected = s.unique ? s.max_seq - s.base + 1 : 0;
		uint64_t lost = expected - s.unique;
		double dur = (double)(s.last_ns - s.first_ns) / 1e9;

		printf("{\"mode\":\"sink\",\"port\":%ld,\"duration_s\":%.3f,\"packets\":%llu,"
		       "\"bytes\":%llu,\"mbps\":%.2f,\"expected\":%llu,\"lost\":%llu,"
		       "\"reordered\":%llu,\"duplicates\":%llu,\"ignored\":%llu,"
		       "\"loss_pct\":%.4f,\"jitter_us\":%.1f,\"max_gap_us\":%.1f,"
		       "\"rcvbuf\":%d,\"udp_in_errors\":%lld,\"udp_rcvbuf_errors\":%lld}\n",
		       port, dur, (unsigned long long)s.packets, (unsigned long long)s.bytes,
		       dur > 0 ? (double)s.bytes * 8 / dur / 1e6 : 0.0,
		       (unsigned long long)expected, (unsigned long long)lost,
		       (unsigned long long)s.reordered, (unsigned long long)s.duplicates,
		       (unsigned long long)s.ignored,
		       expected ? 100.0 * (double)lost / (double)expected : 0.0,
		       s.jitter / 1e3, (double)s.max_gap / 1e3, rcvbuf,
		       delta(in0, in1), delta(rb0, rb1));
	}
	free(s.seen);
	close(fd);
	return 0;
}

static void __attribute__((noreturn)) do_echo(long port)
{
	static unsigned char buf[MAX_DGRAM];
	int fd = udp_bind(port);

	fprintf(stderr, "netprobe: echo on udp/%ld\n", port);
	for (;;) {
		struct sockaddr_storage from;
		socklen_t fl = sizeof(from);
		ssize_t n = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			die("recvfrom");
		}
		/* A failed reply is just a lost probe; report it and keep serving. */
		if (sendto(fd, buf, (size_t)n, 0, (struct sockaddr *)&from, fl) < 0)
			fprintf(stderr, "netprobe: sendto: %s\n", strerror(errno));
	}
}

struct cpu_sample {
	int ncpu;
	unsigned long long total[MAX_CPUS], idle[MAX_CPUS], irq[MAX_CPUS], softirq[MAX_CPUS];
	unsigned long long net_rx[MAX_CPUS], net_tx[MAX_CPUS];
};

/* Parse one /proc/softirqs row ("NET_RX:   1   2   3   4") into out[]. */
static void parse_softirq_row(const char *line, unsigned long long *out)
{
	const char *p = strchr(line, ':') + 1;
	int i;

	for (i = 0; i < MAX_CPUS; i++) {
		char *end;
		unsigned long long v = strtoull(p, &end, 10);

		if (end == p)
			break;
		out[i] = v;
		p = end;
	}
}

static void cpu_read(struct cpu_sample *s)
{
	char line[1024];
	FILE *f = fopen("/proc/stat", "r");

	memset(s, 0, sizeof(*s));
	if (!f)
		die("open /proc/stat");
	while (fgets(line, sizeof(line), f)) {
		unsigned long long v[8] = { 0 };
		int cpu;

		if (strncmp(line, "cpu", 3) != 0 || line[3] < '0' || line[3] > '9')
			continue;
		/* user nice system idle iowait irq softirq steal */
		if (sscanf(line + 3, "%d %llu %llu %llu %llu %llu %llu %llu %llu", &cpu,
			   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 8 ||
		    cpu < 0 || cpu >= MAX_CPUS)
			continue;
		s->total[cpu] = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
		s->idle[cpu] = v[3] + v[4];
		s->irq[cpu] = v[5];
		s->softirq[cpu] = v[6];
		if (cpu + 1 > s->ncpu)
			s->ncpu = cpu + 1;
	}
	fclose(f);

	f = fopen("/proc/softirqs", "r");
	if (!f)
		die("open /proc/softirqs");
	while (fgets(line, sizeof(line), f)) {
		const char *l = line + strspn(line, " ");

		if (strncmp(l, "NET_RX:", 7) == 0)
			parse_softirq_row(l, s->net_rx);
		else if (strncmp(l, "NET_TX:", 7) == 0)
			parse_softirq_row(l, s->net_tx);
	}
	fclose(f);
}

static double pct(unsigned long long part, unsigned long long total)
{
	return total ? 100.0 * (double)part / (double)total : 0.0;
}

static int do_cpu(long seconds)
{
	struct cpu_sample a, b;
	int i;

	cpu_read(&a);
	if (seconds > 0)
		sleep((unsigned)seconds);
	cpu_read(&b);
	/* Offline/hotplugged cores show up as zero deltas. */
	printf("{\"mode\":\"cpu\",\"seconds\":%ld,\"cpus\":[", seconds);
	for (i = 0; i < b.ncpu; i++) {
		unsigned long long tot = b.total[i] - a.total[i];
		unsigned long long idle = b.idle[i] - a.idle[i];

		printf("%s{\"cpu\":%d,\"busy_pct\":%.1f,\"irq_pct\":%.1f,\"softirq_pct\":%.1f,"
		       "\"net_rx\":%llu,\"net_tx\":%llu}",
		       i ? "," : "", i, pct(tot - idle, tot),
		       pct(b.irq[i] - a.irq[i], tot), pct(b.softirq[i] - a.softirq[i], tot),
		       b.net_rx[i] - a.net_rx[i], b.net_tx[i] - a.net_tx[i]);
	}
	printf("]}\n");
	return 0;
}

/* Driver statistics through the ethtool ioctl (the TV has no ethtool binary).
 * For r8152 these include the chip's own tally counters, e.g. rx_missed
 * (frames the adapter dropped because its receive FIFO was full).
 */
static int do_ethstats(const char *ifname)
{
	struct ethtool_drvinfo drv = { .cmd = ETHTOOL_GDRVINFO };
	struct ethtool_gstrings *strs;
	struct ethtool_stats *stats;
	struct ifreq ifr;
	unsigned int i, n;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);

	if (fd < 0)
		die("socket");
	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifname);
	ifr.ifr_data = (void *)&drv;
	if (ioctl(fd, SIOCETHTOOL, &ifr) < 0)
		die("ETHTOOL_GDRVINFO");
	n = drv.n_stats;
	strs = calloc(1, sizeof(*strs) + (size_t)n * ETH_GSTRING_LEN);
	stats = calloc(1, sizeof(*stats) + (size_t)n * sizeof(stats->data[0]));
	if (!strs || !stats)
		die("calloc");
	strs->cmd = ETHTOOL_GSTRINGS;
	strs->string_set = ETH_SS_STATS;
	strs->len = n;
	ifr.ifr_data = (void *)strs;
	if (ioctl(fd, SIOCETHTOOL, &ifr) < 0)
		die("ETHTOOL_GSTRINGS");
	stats->cmd = ETHTOOL_GSTATS;
	stats->n_stats = n;
	ifr.ifr_data = (void *)stats;
	if (ioctl(fd, SIOCETHTOOL, &ifr) < 0)
		die("ETHTOOL_GSTATS");
	printf("{\"mode\":\"ethstats\",\"driver\":\"%.32s\"", drv.driver);
	for (i = 0; i < n; i++) {
		const char *name = (const char *)strs->data + (size_t)i * ETH_GSTRING_LEN;

		printf(",\"%.*s\":%llu", (int)strnlen(name, ETH_GSTRING_LEN), name,
		       (unsigned long long)stats->data[i]);
	}
	printf("}\n");
	close(fd);
	free(strs);
	free(stats);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: netprobe sink PORT SECONDS [RCVBUF_BYTES]\n"
		"       netprobe echo PORT\n"
		"       netprobe cpu SECONDS\n"
		"       netprobe ethstats IFACE\n");
	exit(2);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if ((argc == 4 || argc == 5) && strcmp(argv[1], "sink") == 0)
		return do_sink(parse_long(argv[2], "port"), parse_long(argv[3], "seconds"),
			       argc == 5 ? parse_long(argv[4], "rcvbuf") : 0);
	if (argc == 3 && strcmp(argv[1], "echo") == 0)
		do_echo(parse_long(argv[2], "port"));
	if (argc == 3 && strcmp(argv[1], "cpu") == 0)
		return do_cpu(parse_long(argv[2], "seconds"));
	if (argc == 3 && strcmp(argv[1], "ethstats") == 0)
		return do_ethstats(argv[2]);
	usage();
	return 2;
}
