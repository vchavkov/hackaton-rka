#!/usr/bin/env python3
"""
secret-age.py — monitor, rotate and clean up Kubernetes secrets.

Detects secrets in a Kubernetes namespace, reports their age, and can
rotate the oldest one via an ArgoCD Application patch or clean up stale
Helm release-history secrets.

Default action:
  namespace == "demo"  → rotate the oldest secret via ArgoCD
  any other namespace  → check & report secret ages

Use --rotate / --no-rotate to override, or --cleanup to delete unused secrets.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import string
import subprocess
import sys
import textwrap
from datetime import datetime, timezone
from typing import Optional


# ── ANSI helpers ──────────────────────────────────────────────────────────────

def _fmt(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m"

def bold(text: str)  -> str: return _fmt("1", text)
def cyan(text: str)  -> str: return _fmt("36", text)
def green(text: str) -> str: return _fmt("32", text)
def yellow(text: str)-> str: return _fmt("33", text)
def red(text: str)   -> str: return _fmt("31", text)

def info(msg: str)  -> None: print(f"  {cyan('→')} {msg}")
def ok(msg: str)    -> None: print(f"  {green('✓')} {msg}")
def warn(msg: str)  -> None: print(f"  {yellow('!')} {msg}")
def err(msg: str)   -> None: print(f"  {red('✗')} {msg}", file=sys.stderr)


# ── kubectl helpers ───────────────────────────────────────────────────────────

def kubectl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", *args],
        capture_output=True,
        text=True,
        check=check,
    )


def kget_json(namespace: str, kind: str) -> list[dict]:
    result = kubectl("-n", namespace, "get", kind, "-o", "json", check=False)
    if result.returncode != 0:
        return []
    return json.loads(result.stdout).get("items", [])


# ── time helpers ──────────────────────────────────────────────────────────────

def parse_ts(ts: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def latest_ts(item: dict) -> Optional[datetime]:
    """Return the most recent timestamp for a secret.

    Preference order:
      1. kra/rotated-at annotation — written by cmd_rotate after each rotation,
         reliably tracks when we last changed the secret value.
      2. managedFields — fallback for secrets that have never been rotated.
    """
    annotations = item["metadata"].get("annotations") or {}
    rotated_at = annotations.get("kra/rotated-at")
    if rotated_at:
        t = parse_ts(rotated_at)
        if t:
            return t

    best: Optional[datetime] = parse_ts(item["metadata"].get("creationTimestamp", ""))
    for mf in item["metadata"].get("managedFields") or []:
        if mf.get("operation") in ("Update", "Apply"):
            t = parse_ts(mf.get("time", ""))
            if t and (best is None or t > best):
                best = t
    return best


def human_duration(seconds: int) -> str:
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    mins = rem // 60
    if days:
        return f"{days} day{'s' if days != 1 else ''}, {hours} hour{'s' if hours != 1 else ''}"
    if hours:
        return f"{hours} hour{'s' if hours != 1 else ''}, {mins} min{'s' if mins != 1 else ''}"
    return f"{mins} minute{'s' if mins != 1 else ''}"


# ── cmd: check ────────────────────────────────────────────────────────────────

def cmd_check(ns: str, threshold_days: int, alert_only: bool,
              output_json: bool, sort_by_age: bool) -> None:
    all_items = kget_json(ns, "secrets")
    # Only report on KRA-managed credential secrets, not Helm history,
    # ArgoCD internals, or other noise in the namespace.
    items = [
        i for i in all_items
        if i["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "key-rotation-agent"
    ]
    if not items:
        warn(f"No key-rotation-agent secrets found in namespace: {ns}")
        sys.exit(1)

    now = datetime.now(tz=timezone.utc)
    threshold_secs = threshold_days * 86400

    rows = []
    for item in items:
        ts = latest_ts(item)
        if ts is None:
            continue
        age_secs = int((now - ts).total_seconds())
        rows.append({
            "name": item["metadata"]["name"],
            "age_seconds": age_secs,
            "age_days": age_secs // 86400,
            "last_updated": ts.strftime("%Y-%m-%dT%H:%M:%S"),
            "exceeds_threshold": age_secs > threshold_secs,
        })

    if sort_by_age:
        rows.sort(key=lambda r: r["age_seconds"], reverse=True)

    if output_json:
        _output_json(ns, threshold_days, rows)
    else:
        _output_table(ns, threshold_days, rows, alert_only)


def _output_table(ns: str, threshold_days: int, rows: list[dict],
                  alert_only: bool) -> None:
    print(bold(f"Secret Age Report — namespace: {ns}"))
    print(f"  Threshold: {threshold_days} days  |  KRA secrets: {len(rows)}")
    print()
    print(bold(f"{'SECRET':<30} {'AGE (DAYS)':<12} {'LAST UPDATE':<20} STATUS"))
    print("─" * 70)

    alert_count = ok_count = 0
    for r in rows:
        if alert_only and not r["exceeds_threshold"]:
            ok_count += 1
            continue
        name = r["name"][:28]
        if r["exceeds_threshold"]:
            status = red("✗ ROTATE")
            alert_count += 1
        else:
            status = green("✓ ok")
            ok_count += 1
        print(f"{name:<30} {r['age_days']:<12} {r['last_updated']:<20} {status}")

    print()
    print("Summary:")
    if alert_count == 0:
        ok("All secrets within threshold")
    else:
        err(f"{alert_count} secret(s) exceed {threshold_days}-day threshold")
    if ok_count:
        info(f"{ok_count} secret(s) within threshold")
    print()


def _output_json(ns: str, threshold_days: int, rows: list[dict]) -> None:
    now_iso = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    output = {
        "namespace": ns,
        "threshold_days": threshold_days,
        "checked_at": now_iso,
        "secrets": [
            {
                "name": r["name"],
                "age_seconds": r["age_seconds"],
                "age_days": r["age_days"],
                "last_updated": r["last_updated"],
                "exceeds_threshold": r["exceeds_threshold"],
            }
            for r in rows
        ],
    }
    print(json.dumps(output, indent=2))


# ── cmd: rotate ───────────────────────────────────────────────────────────────

def cmd_rotate(ns: str, argocd_ns: str) -> None:
    print(bold(f"Finding oldest secret — namespace: {ns}"))

    items = kget_json(ns, "secrets")
    kra_items = [
        i for i in items
        if i["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "key-rotation-agent"
    ]
    if not kra_items:
        err(f"No secrets with label app.kubernetes.io/name=key-rotation-agent in {ns}")
        sys.exit(1)

    now = datetime.now(tz=timezone.utc)
    oldest = max(kra_items, key=lambda i: (now - (latest_ts(i) or now)).total_seconds())
    oldest_ts = latest_ts(oldest)
    age_secs = int((now - oldest_ts).total_seconds()) if oldest_ts else 0
    secret_name = oldest["metadata"]["name"]
    release = oldest["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "")

    if not release:
        err(f"Secret {secret_name} has no app.kubernetes.io/instance label")
        sys.exit(1)

    info(f"Oldest secret : {secret_name}")
    info(f"Release       : {release}")
    info(f"Age           : {human_duration(age_secs)} (last updated: {str(oldest_ts)[:19]})")
    print()

    # Fetch the ArgoCD Application to preserve color / ingress settings.
    result = kubectl("get", "application", release, "-n", argocd_ns, "-o", "json", check=False)
    if result.returncode != 0:
        err(f"ArgoCD Application '{release}' not found in namespace '{argocd_ns}'")
        sys.exit(1)
    app = json.loads(result.stdout)
    vals = app["spec"]["source"]["helm"].get("values", "")

    def extract(pattern: str, default: str = "") -> str:
        m = re.search(pattern, vals, re.MULTILINE)
        return m.group(1).strip().strip("\"' ") if m else default

    color         = extract(r'^\s+color:\s*["\']?([^"\'\n]+)["\']?', "#000000")
    hostname      = extract(r'^\s+host:\s*["\']?([^"\'\n]+)["\']?', "")
    ingress_class = extract(r'className:\s*["\']?([^"\'\n]+)["\']?', "nginx")

    # If hostname was lost from values (e.g. wiped by a previous bad rotation),
    # fall back to the live Ingress object.
    if not hostname:
        ing = kubectl(
            "get", "ingress", "-n", ns,
            "-l", f"app.kubernetes.io/instance={release}",
            "-o", "jsonpath={.items[0].spec.rules[0].host}",
            check=False,
        )
        hostname = ing.stdout.strip()

    # Generate new credentials.
    alphabet = string.ascii_letters + string.digits
    db_password = "".join(secrets.choice(alphabet) for _ in range(32))
    db_password_fmt = "-".join(db_password[i:i+8] for i in range(0, 32, 8))
    updated_at = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    new_values = textwrap.dedent(f"""\
        podinfo:
          color: "{color}"
        secret:
          data:
            PASSWORD: "{db_password}"
            UPDATED_AT: "{updated_at}"
        ingress:
          enabled: true
          className: "{ingress_class}"
          hosts:
            - host: "{hostname}"
              paths:
                - path: /
                  pathType: Prefix
    """)

    patch = json.dumps({
        "spec": {
            "source": {"helm": {"values": new_values}},
            # Clear ignoreDifferences so the chart's checksum/secret annotation
            # is no longer suppressed and ArgoCD will re-apply the Deployment,
            # which in turn triggers a rolling restart of pods.
            "ignoreDifferences": [],
        }
    })

    kubectl("patch", "application", release,
            "-n", argocd_ns,
            "--type=merge",
            "-p", patch)

    # Stamp the rotation timestamp directly on the Secret so that the next
    # run of cmd_rotate can reliably compare ages across all releases.
    # (The Secret has helm.sh/resource-policy:keep so Helm never re-applies
    # it, meaning managedFields stays frozen at the initial deploy time.)
    rotated_iso = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    kubectl("annotate", "secret", secret_name,
            "-n", ns,
            f"kra/rotated-at={rotated_iso}",
            "--overwrite")

    print()
    ok(f"Rotated: {release}")
    info(f"New PASSWORD : {db_password_fmt}")
    info("ArgoCD will sync; checksum/secret annotation will trigger a rolling restart")

    # Belt-and-suspenders: issue an explicit rollout restart so the pods roll
    # immediately rather than waiting for the next ArgoCD reconcile.
    dep_result = kubectl(
        "get", "deployment", "-n", ns,
        "-l", f"app.kubernetes.io/instance={release}",
        "-o", "jsonpath={.items[0].metadata.name}",
        check=False,
    )
    deploy_name = dep_result.stdout.strip()
    if deploy_name:
        kubectl("-n", ns, "rollout", "restart", f"deployment/{deploy_name}")
        info(f"Rolling restart triggered: deployment/{deploy_name}")


# ── cmd: cleanup ──────────────────────────────────────────────────────────────

PROTECTED_PREFIXES = ("argocd-",)
PROTECTED_LABELS   = ("app.kubernetes.io/part-of", "app.kubernetes.io/managed-by")
PROTECTED_ANNOTS   = ("meta.helm.sh/release-name",)


def _collect_referenced(ns: str) -> set[str]:
    referenced: set[str] = set()

    def scan_pod_spec(spec: Optional[dict]) -> None:
        if not spec:
            return
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            for env in c.get("env") or []:
                ref = (env.get("valueFrom") or {}).get("secretKeyRef", {}).get("name")
                if ref:
                    referenced.add(ref)
            for ef in c.get("envFrom") or []:
                ref = (ef.get("secretRef") or {}).get("name")
                if ref:
                    referenced.add(ref)
        for v in spec.get("volumes") or []:
            ref = (v.get("secret") or {}).get("secretName")
            if ref:
                referenced.add(ref)
            for src in (v.get("projected") or {}).get("sources") or []:
                ref = (src.get("secret") or {}).get("name")
                if ref:
                    referenced.add(ref)
        for ips in spec.get("imagePullSecrets") or []:
            if ips.get("name"):
                referenced.add(ips["name"])

    for p in kget_json(ns, "pods"):
        scan_pod_spec(p.get("spec"))

    for kind in ("deployments", "statefulsets", "daemonsets", "replicasets", "jobs"):
        for item in kget_json(ns, kind):
            scan_pod_spec(
                ((item.get("spec") or {}).get("template") or {}).get("spec")
            )

    for cj in kget_json(ns, "cronjobs"):
        scan_pod_spec(
            (((cj.get("spec") or {}).get("jobTemplate") or {})
             .get("spec", {}).get("template", {}).get("spec"))
        )

    for sa in kget_json(ns, "serviceaccounts"):
        for s in sa.get("secrets") or []:
            if s.get("name"):
                referenced.add(s["name"])
        for s in sa.get("imagePullSecrets") or []:
            if s.get("name"):
                referenced.add(s["name"])

    for ing in kget_json(ns, "ingresses"):
        for tls in (ing.get("spec") or {}).get("tls") or []:
            if tls.get("secretName"):
                referenced.add(tls["secretName"])

    return referenced


def cmd_cleanup(ns: str, include_unreferenced: bool, dry_run: bool) -> None:
    print(bold(f"Scanning for unused secrets — namespace: {ns}"))
    if include_unreferenced:
        info("Mode: stale Helm history + unreferenced (with controller skip rules)")
    else:
        info("Mode: stale Helm history only (use --include-unreferenced for more)")

    secrets_items = kget_json(ns, "secrets")
    secret_map = {s["metadata"]["name"]: s for s in secrets_items}

    sa_names = {sa["metadata"]["name"] for sa in kget_json(ns, "serviceaccounts")}
    referenced = _collect_referenced(ns) if include_unreferenced else set()

    # Identify stale Helm release-history secrets.
    helm_re = re.compile(r"^sh\.helm\.release\.v1\.(.+)\.v(\d+)$")
    helm_latest: dict[str, int] = {}
    helm_secrets: list[tuple[str, str, int]] = []
    for name, sec in secret_map.items():
        if sec.get("type") == "helm.sh/release.v1":
            m = helm_re.match(name)
            if m:
                rel, ver = m.group(1), int(m.group(2))
                helm_secrets.append((name, rel, ver))
                if ver > helm_latest.get(rel, 0):
                    helm_latest[rel] = ver
    helm_stale = {n for n, r, v in helm_secrets if v != helm_latest.get(r)}

    candidates: list[tuple[str, str]] = []
    for name, sec in secret_map.items():
        annotations = sec["metadata"].get("annotations") or {}
        labels      = sec["metadata"].get("labels") or {}

        if annotations.get("helm.sh/resource-policy") == "keep":
            continue

        if name in helm_stale:
            candidates.append((name, "stale Helm history"))
            continue

        if not include_unreferenced:
            continue

        stype = sec.get("type", "")
        if stype == "helm.sh/release.v1":
            continue

        if stype == "kubernetes.io/service-account-token":
            sa = annotations.get("kubernetes.io/service-account.name")
            if sa and sa in sa_names:
                continue
            candidates.append((name, "orphaned SA token"))
            continue

        if name in referenced:
            continue

        if any(name.startswith(p) for p in PROTECTED_PREFIXES):
            continue
        if any(k in labels for k in PROTECTED_LABELS):
            continue
        if any(k in annotations for k in PROTECTED_ANNOTS):
            continue

        candidates.append((name, f"unreferenced ({stype or 'Opaque'})"))

    if not candidates:
        ok("No unused secrets found")
        return

    print()
    print(bold(f"{'SECRET':<40} REASON"))
    print("─" * 70)
    for name, reason in candidates:
        print(f"{name[:38]:<40} {reason}")
    print()

    if dry_run:
        info(f"{len(candidates)} secret(s) would be deleted "
             "(dry-run; pass without --dry-run to apply)")
        return

    warn(f"Deleting {len(candidates)} secret(s) from namespace {ns}")
    names = [n for n, _ in candidates]
    kubectl("delete", "secret", "-n", ns, *names)
    print()
    ok(f"Deleted {len(candidates)} secret(s)")


# ── CLI ───────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="./scripts/secret-age.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent("""\
            Monitor secret age, rotate the oldest secret, or clean up unused secrets.

            Default action:
              namespace == "demo"  → rotate the oldest secret via ArgoCD
              any other namespace  → check & report secret ages

            Use --rotate / --no-rotate to override, or --cleanup for housekeeping.
        """),
        epilog=textwrap.dedent("""\
            Examples:
              # Default: rotate the oldest secret in 'demo' via ArgoCD
              ./scripts/secret-age.py

              # Inspect 'demo' without rotating
              ./scripts/secret-age.py --no-rotate

              # Check 'prod' with a 30-day threshold (check-only by default)
              ./scripts/secret-age.py --namespace prod --threshold-days 30

              # Only show secrets that need rotation
              ./scripts/secret-age.py --no-rotate --alert-only

              # Machine-readable export for monitoring systems
              ./scripts/secret-age.py --no-rotate --json --sort-by-age

              # Force rotation in a non-default namespace
              ./scripts/secret-age.py --namespace staging --rotate

              # Preview stale Helm history secrets (dry-run)
              ./scripts/secret-age.py --cleanup --dry-run

              # Delete stale Helm history secrets
              ./scripts/secret-age.py --cleanup

              # Also sweep unreferenced secrets (skips argocd-*, managed-by/part-of)
              ./scripts/secret-age.py --cleanup --include-unreferenced --dry-run
        """),
    )

    p.add_argument("--namespace", "-n",
                   default=os.environ.get("NAMESPACE", "demo"),
                   help="Kubernetes namespace (default: demo)")
    p.add_argument("--argocd-namespace",
                   default=os.environ.get("ARGOCD_NAMESPACE", "argocd"),
                   help="ArgoCD namespace (default: argocd)")
    p.add_argument("--threshold-days", type=int, default=7,
                   help="Age threshold in days for check mode (default: 7)")
    p.add_argument("--alert-only", action="store_true",
                   help="Only show secrets exceeding the threshold")
    p.add_argument("--json", action="store_true", dest="output_json",
                   help="Output check results as JSON")
    p.add_argument("--sort-by-age", action="store_true",
                   help="Sort check results oldest first")

    rotate_grp = p.add_mutually_exclusive_group()
    rotate_grp.add_argument("--rotate", action="store_true", default=None,
                             help="Force rotation of the oldest secret via ArgoCD")
    rotate_grp.add_argument("--no-rotate", dest="rotate", action="store_false",
                             help="Force check-only (skip rotation even on 'demo')")

    p.add_argument("--cleanup", action="store_true",
                   help="Delete stale Helm release-history secrets")
    p.add_argument("--include-unreferenced", action="store_true",
                   help="With --cleanup: also delete secrets not referenced by "
                        "any pod/controller/SA/Ingress")
    p.add_argument("--dry-run", action="store_true",
                   help="With --cleanup: list candidates without deleting")

    return p


def main() -> None:
    args = build_parser().parse_args()

    if args.cleanup:
        cmd_cleanup(args.namespace, args.include_unreferenced, args.dry_run)
        return

    # Resolve rotate default from namespace when neither --rotate nor
    # --no-rotate was given (args.rotate is None).
    do_rotate: bool
    if args.rotate is None:
        do_rotate = args.namespace == "demo"
    else:
        do_rotate = args.rotate

    if do_rotate:
        cmd_rotate(args.namespace, args.argocd_namespace)
    else:
        cmd_check(
            args.namespace,
            args.threshold_days,
            args.alert_only,
            args.output_json,
            args.sort_by_age,
        )


if __name__ == "__main__":
    main()
