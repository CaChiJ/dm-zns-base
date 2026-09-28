#!/usr/bin/env python3
"""Sample upper writes, lower zone pointers and DM GC state together."""

import argparse
import csv
import re
import signal
import subprocess
import time
from pathlib import Path

stop = False


def stop_sampling(_signum, _frame):
    global stop
    stop = True


def sample(underlying, target, stat_path, initial_sectors):
    timestamp_ns = time.time_ns()
    sectors_written = int(stat_path.read_text().split()[6]) - initial_sectors
    report = subprocess.check_output(["blkzone", "report", underlying], text=True)
    status = subprocess.check_output(["dmsetup", "status", target], text=True)
    zones = []
    for line in report.splitlines():
        matches = re.findall(r"\b(start|cap|wptr):?\s+(0x[0-9a-fA-F]+)", line)
        fields = {key: int(value, 16) for key, value in matches}
        if len(fields) != 3:
            raise ValueError(f"unrecognized blkzone line: {line}")
        zones.append(fields)
    if len(zones) < 3:
        raise ValueError("at least three zones are required")
    # util-linux blkzone prints wptr relative to each zone's start.
    written_blocks = sum(min(z["wptr"], z["cap"]) // 8 for z in zones[:-1])
    values = dict(re.findall(r"\b([a-z_]+)=([^\s]+)", status))
    valid = int(values["valid_blocks"])
    return (timestamp_ns, max(sectors_written, 0) * 512, valid,
            written_blocks, f"{valid / written_blocks:.8f}" if written_blocks else "N/A",
            int(values["meta_used"]), int(values["gc_runs"]),
            int(values["gc_moved"]), int(values["zone_resets"]),
            values["gc_policy"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--underlying", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--stat", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--initial-sectors", type=int)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    initial = args.initial_sectors
    if initial is None:
        initial = int(args.stat.read_text().split()[6])
    signal.signal(signal.SIGTERM, stop_sampling)
    signal.signal(signal.SIGINT, stop_sampling)
    with args.output.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("timestamp_ns", "user_written_bytes", "valid_blocks",
                         "data_written_blocks", "valid_ratio", "meta_used_sectors",
                         "gc_runs", "gc_moved", "zone_resets", "gc_policy"))
        while True:
            writer.writerow(sample(args.underlying, args.target, args.stat, initial))
            handle.flush()
            if args.once or stop:
                break
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
