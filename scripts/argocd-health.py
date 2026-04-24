#!/usr/bin/env python3
"""
argocd-health.py — check health and sync status of ArgoCD Applications.

Exits 0 if all applications are Healthy + Synced.
Exits 1 if any application is not Healthy or not Synced.

Usage:
  ./scripts/argocd-health.py [OPTIONS]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import textwrap
from typing import Optional


# ── ANSI helpers ──────────────────────────────────────────────────────────────

def _fmt(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m"

def bold(text: str)   -> str: return _fmt("1", text)
def cyan(text: str)   -> str: return _fmt("36", text)
def green(text: str)  -> str: return _fmt("32", text)
def yellow(text: str) -> str: return _fmt("33", text)
def red(text: str)    -> str: return _fmt("31", text)

def info(msg: str) -> None: print(f"  {cyan('→')} {msg}")
def ok(msg: str)   -> None: print(f"  {green('✓')} {msg}")
def warn(msg: str) -> None: print(f"  {yellow('!')} {msg}")
def err(msg: str)  -> None: print(f"  {red('✗')} {msg}")


# ── kubectl helper ────────────────────────────────────────────────────────────

def kubectl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", *args],
        capture_output=True,
        text=True,
        check=False,
    )


# ── status colours ────────────────────────────────────────────────────────────

def fmt_health(status: str) -> str:
    if status == "Healthy":
        return green(status)
    if status in ("Progressing", "Suspended"):
        return yellow(status)
    return red(status)


def fmt_sync(status: str) -> str:
    if status == "Synced":
        return green(status)
    if status == "OutOfSync":
        return yellow(status)
    return red(status)


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(
        prog="./scripts/argocd-health.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent("""\
            Check health and sync status of ArgoCD Applications.

            Exits 0 when all applications are Healthy + Synced.
            Exits 1 when any application is Degraded, OutOfSync, or missing.
        """),
        epilog=textwrap.dedent("""\
            Examples:
              # Check all apps in the default ArgoCD namespace
              ./scripts/argocd-health.py

              # Check a specific namespace
              ./scripts/argocd-health.py --argocd-namespace argo-system

              # Watch continuously every 5 seconds
              watch -n 5 ./scripts/argocd-health.py

              # Use in CI — non-zero exit on any unhealthy app
              ./scripts/argocd-health.py || echo "cluster not ready"
        """),
    )
    p.add_argument(
        "--argocd-namespace", "-n",
        default=os.environ.get("ARGOCD_NAMESPACE", "argocd"),
        help="Namespace where ArgoCD Applications live (default: argocd)",
    )
    p.add_argument(
        "--app",
        metavar="NAME",
        help="Check a single application by name instead of all",
    )
    p.add_argument(
        "--json", dest="output_json", action="store_true",
        help="Output results as JSON",
    )
    args = p.parse_args()

    if args.app:
        result = kubectl(
            "get", "application", args.app,
            "-n", args.argocd_namespace,
            "-o", "json",
        )
        if result.returncode != 0:
            err(f"Application '{args.app}' not found in namespace '{args.argocd_namespace}'")
            sys.exit(1)
        apps = [json.loads(result.stdout)]
    else:
        result = kubectl(
            "get", "applications",
            "-n", args.argocd_namespace,
            "-o", "json",
        )
        if result.returncode != 0:
            err(f"Could not query applications in namespace '{args.argocd_namespace}'")
            err(result.stderr.strip())
            sys.exit(1)
        apps = json.loads(result.stdout).get("items", [])

    if not apps:
        warn(f"No applications found in namespace: {args.argocd_namespace}")
        sys.exit(0)

    rows = []
    for app in apps:
        name    = app["metadata"]["name"]
        health  = app.get("status", {}).get("health", {}).get("status", "Unknown")
        sync    = app.get("status", {}).get("sync",   {}).get("status", "Unknown")
        message = (
            app.get("status", {}).get("conditions", [{}])[0].get("message", "")
            or app.get("status", {}).get("health", {}).get("message", "")
        )
        rows.append({
            "name": name,
            "health": health,
            "sync": sync,
            "message": message,
        })

    unhealthy = [r for r in rows if r["health"] != "Healthy" or r["sync"] != "Synced"]

    if args.output_json:
        print(json.dumps(rows, indent=2))
    else:
        print(bold(f"ArgoCD Application Health — namespace: {args.argocd_namespace}"))
        print()
        print(bold(f"{'APPLICATION':<25} {'HEALTH':<15} {'SYNC':<12} NOTE"))
        print("─" * 70)
        for r in rows:
            note = f"  {yellow(r['message'])}" if r["message"] else ""
            print(
                f"{r['name']:<25} "
                f"{fmt_health(r['health']):<24} "
                f"{fmt_sync(r['sync']):<21} "
                f"{note}"
            )
        print()
        if unhealthy:
            names = ", ".join(r["name"] for r in unhealthy)
            err(f"{len(unhealthy)} application(s) not Healthy+Synced: {names}")
        else:
            ok(f"All {len(rows)} application(s) Healthy and Synced")
        print()

    if unhealthy:
        sys.exit(1)


if __name__ == "__main__":
    main()
