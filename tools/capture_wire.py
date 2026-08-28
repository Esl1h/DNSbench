#!/usr/bin/env python3
"""Capture real DNS wire bytes into testdata/, without root.

Binds a UDP relay on 127.0.0.1:15353 and forwards verbatim to an upstream
resolver, writing both directions to disk. The query bytes are the ones kdig
actually produced and the response bytes are the ones the resolver actually
sent; the relay copies, it never rewrites. That keeps the rule in CLAUDE.md
intact: assert against real captured bytes, never against bytes we invented and
never against another implementation's rendering of them.

A pcap via tcpdump would work too and needs root. This does not.

    python3 tools/capture_wire.py minimal dnssec cname nxdomain
    kdig +noedns +nocookie -p 15353 @127.0.0.1 google.com

One label is consumed per query, in order. Rate-limited by hand: these are free
public resolvers and this script exists to be run a handful of times.
"""

import os
import socket
import sys

UPSTREAM = ("1.1.1.1", 53)
BIND = ("127.0.0.1", 15353)
OUTDIR = "testdata"


def main(labels):
    os.makedirs(OUTDIR, exist_ok=True)

    down = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    down.bind(BIND)
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    up.settimeout(5.0)

    print(f"relay on {BIND[0]}:{BIND[1]} -> {UPSTREAM[0]}:{UPSTREAM[1]}")
    print(f"expecting {len(labels)} queries: {', '.join(labels)}")

    for label in labels:
        query, client = down.recvfrom(65535)
        up.sendto(query, UPSTREAM)
        try:
            response, _ = up.recvfrom(65535)
        except socket.timeout:
            print(f"{label}: upstream timed out, nothing written")
            continue
        down.sendto(response, client)

        for kind, blob in (("query", query), ("response", response)):
            path = os.path.join(OUTDIR, f"{label}.{kind}.bin")
            with open(path, "wb") as fh:
                fh.write(blob)
            print(f"  {path}  {len(blob)} bytes")

    down.close()
    up.close()
    print("done")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
