#!/usr/bin/env python3
"""Exit 0 when Nomad lists at least --min nodes and every one is ready.

Reads `nomad node status -json`, not the table. The CLI appends hints such as
"==> View and manage Nomad clients in the Web UI" to table output, and a row
parser counts them as nodes that are not ready. Prints one line per node from
the last attempt, as checks notices when GITHUB_ACTIONS is set.
"""

import argparse
import json
import os
import subprocess
import sys
import time


def node_list(text):
    # Hints go to stderr today. A banner a later CLI puts on stdout must not
    # hide the list, so decode the first JSON array and skip the lines around it.
    decoder = json.JSONDecoder()
    offset = 0
    for line in text.splitlines(keepends=True):
        start = offset + len(line) - len(line.lstrip())
        offset += len(line)
        if not text.startswith("[", start):
            continue
        try:
            value, _ = decoder.raw_decode(text, start)
        except ValueError:
            continue
        if isinstance(value, list):
            return value
    raise ValueError("no JSON node list in nomad node status output")


def evaluate(nodes, min_nodes):
    lines = []
    ready = True
    listed = []
    for node in nodes:
        if isinstance(node, dict):
            listed.append(node)
        else:
            lines.append("node status entry is not an object")
            ready = False
    for node in sorted(listed, key=lambda n: str(n.get("Name", ""))):
        status = node.get("Status")
        lines.append(
            "node {} status={} eligibility={} drain={}".format(
                node.get("Name"),
                status,
                node.get("SchedulingEligibility"),
                str(node.get("Drain")).lower(),
            )
        )
        if status != "ready":
            ready = False
    if len(listed) < min_nodes:
        lines.append(f"{len(listed)} nodes listed, want at least {min_nodes}")
        ready = False
    return ready, lines


def probe(min_nodes, timeout):
    try:
        proc = subprocess.run(
            ["nomad", "node", "status", "-json"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, [f"nomad node status timed out after {timeout:g}s"]
    except OSError as err:
        return False, [f"nomad node status did not run: {err}"]
    if proc.returncode != 0:
        stderr = [s.strip() for s in proc.stderr.splitlines() if s.strip()]
        return False, [f"nomad node status exited {proc.returncode}"] + stderr[:5]
    try:
        nodes = node_list(proc.stdout)
    except ValueError as err:
        return False, [str(err)]
    return evaluate(nodes, min_nodes)


def annotation(line):
    return "::notice::" + line.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--min", type=int, default=3, help="nodes that must be listed")
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--delay", type=float, default=10, help="seconds between attempts")
    parser.add_argument("--timeout", type=float, default=15, help="seconds per nomad call")
    args = parser.parse_args(argv)

    ready, lines = False, []
    for attempt in range(max(args.attempts, 1)):
        if attempt:
            time.sleep(args.delay)
        ready, lines = probe(args.min, args.timeout)
        if ready:
            break

    in_actions = bool(os.environ.get("GITHUB_ACTIONS"))
    for line in lines:
        print(annotation(line) if in_actions else line)
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
