#!/usr/bin/env python3
"""Error counts for the lock-related services from CloudWatch Logs Insights.

Used by tasks/lock-services-error-summary.md. Discovers the log groups by prefix,
runs one Insights query per batch of at most 50 groups (StartQuery rejects more:
"Too many log groups specified"), and writes the merged rows as JSON.

  python3 -I scripts/lock-errors-cw.py --start 2026-10-15T05:01:21Z --end 2026-10-16T05:01:21Z --out rows.json

Each output row: family, log_group, message, n, first, last (UTC), sample, account.
Exits non-zero if any batch fails, so the task can take its failure branch.
"""
import argparse, json, os, re, subprocess, sys, tempfile

INSIGHTS = os.path.expanduser("~/.claude/skills/shared-kasa-cloudwatch-logs/scripts/insights.py")
ECS_GROUPS = [f"{s}-{e}-{k}" for s in ("css-api", "seam-sync") for e in ("production", "dev") for k in ("app", "worker")]
LAMBDA_PREFIXES = [f"/aws/lambda/{p}-" for p in (
    "code-setting-service-production", "smartthings-sync-production", "remotelock-sync-production",
    "salto-sync-production", "device-service-production", "device-service-dev")]
QUERY = ('filter level = "error" | stats count() as n, min(@timestamp) as first, max(@timestamp) as last, '
         'latest(error.message) as sample, latest(accountName) as account by @log, message '
         '| sort n desc | limit 10000')
BATCH = 50

# Exported STS env vars shadow the SSO profile and expire mid-run; always use the profile.
ENV = {k: v for k, v in os.environ.items() if k not in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")}
ENV.setdefault("AWS_PROFILE", "poweruser")


def aws(*args):
    out = subprocess.run(["aws", *args, "--region", "us-west-2", "--output", "json"],
                         env=ENV, capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"aws {' '.join(args[:2])} failed: {out.stderr.strip()}")
    return json.loads(out.stdout)


def discover():
    groups = []
    for prefix in LAMBDA_PREFIXES:
        groups += [g["logGroupName"] for g in aws("logs", "describe-log-groups", "--log-group-name-prefix", prefix)["logGroups"]]
    for name in ECS_GROUPS:
        found = aws("logs", "describe-log-groups", "--log-group-name-prefix", name)["logGroups"]
        groups += [g["logGroupName"] for g in found if g["logGroupName"] == name]
    return sorted(set(groups))


def family(group):
    g = group.replace("/aws/lambda/", "")
    m = re.match(r"(css-api|seam-sync)-(production|dev)-", g)
    if m:
        return m.group(1)  # Datadog reports both envs under one service name
    return re.match(r"(.*?-(production|dev))-", g).group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    groups = discover()
    print(f"groups: {len(groups)}, batches: {-(-len(groups) // BATCH)}", file=sys.stderr)
    rows, failed = [], False
    for i in range(0, len(groups), BATCH):
        cmd = ["python3", "-I", INSIGHTS, "--start", a.start, "--end", a.end, "--json", "--timeout", "900", "-q", QUERY]
        for g in groups[i:i + BATCH]:
            cmd += ["-g", g]
        with tempfile.TemporaryFile("w+") as err:
            out = subprocess.run(cmd, env=ENV, stdout=subprocess.PIPE, stderr=err, text=True)
            err.seek(0)
            status = [l.strip() for l in err if l.startswith(("scanned:", "error:"))]
        print(f"batch {i // BATCH + 1}: exit {out.returncode}; {'; '.join(status)}", file=sys.stderr)
        if out.returncode:
            failed = True
            continue
        for r in json.loads(out.stdout or "[]"):
            lg = r["@log"].split(":", 1)[1]
            rows.append({"family": family(lg), "log_group": lg, "message": r.get("message"), "n": int(r["n"]),
                         "first": r.get("first"), "last": r.get("last"),
                         "sample": r.get("sample"), "account": r.get("account")})
    json.dump(rows, open(a.out, "w"), indent=1)
    totals = {}
    for r in rows:
        totals[r["family"]] = totals.get(r["family"], 0) + r["n"]
    for f, n in sorted(totals.items(), key=lambda x: -x[1]):
        print(f"{f}\t{n}", file=sys.stderr)
    print(f"total\t{sum(totals.values())}", file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
