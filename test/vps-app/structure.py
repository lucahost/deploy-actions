"""Guard rails of vps-app.yml (Onboarding v2) that a run can't show (vps-app-selftest.yml):

- the job uses Environment "vps", runs only for a push or dispatch on main, may mint an OIDC token;
  the workflow declares no secrets as inputs, references only VPS_REGISTRY_PASSWORD and
  VPS_RECEIVER_TOKEN, and never TS_OAUTH_*;
- every action is pinned to a 40-character commit SHA; no ${{ }} expression inside a run: script;
- the check step reports each of the two secrets by name (true/false, never a value);
- the Receiver call and the wait run only when the app is switched over (live exists);
- the render/pack action vps-app.yml pins (lucahost/deploy-actions/vps@<sha>) has the same vps/ as
  this checkout: the chart that runs is the one reviewed here.
usage: structure.py <vps-app.yml> <repo root>
"""
import re
import subprocess
import sys

import yaml

problems = []
src = open(sys.argv[1]).read()
wf = yaml.safe_load(src)
on = wf.get("on") or wf.get(True)
if on["workflow_call"].get("secrets"):
    problems.append("vps-app.yml declares secrets; they must come from the Environment")
job = wf["jobs"]["deploy"]
if job.get("environment") != "vps":
    problems.append("job environment is not 'vps'")
if job.get("if") != "github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')":
    problems.append("job lacks the guard: main only, push or workflow_dispatch only")
if (job.get("permissions") or {}).get("id-token") != "write":
    problems.append("job can't mint an OIDC token")
used = set(re.findall(r"secrets\.([A-Z0-9_]+)", src))
if used != {"VPS_REGISTRY_PASSWORD", "VPS_RECEIVER_TOKEN"}:
    problems.append(f"secrets referenced: {sorted(used)} (want only VPS_REGISTRY_PASSWORD, VPS_RECEIVER_TOKEN)")
if "TS_OAUTH" in src:
    problems.append("TS_OAUTH_* referenced")
pin = None
for step in job["steps"]:
    uses = step.get("uses")
    if uses and not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", uses):
        problems.append(f"action not pinned by SHA: {uses}")
    if uses and uses.startswith("lucahost/deploy-actions/vps@"):
        pin = uses.split("@")[1]
    if "${{" in step.get("run", ""):
        problems.append(f"${{{{ }}}} inside the script of step {step.get('id') or step.get('name')}")
    if step.get("id") in ("notify", "wait") and step.get("if") != "${{ steps.publish.outputs.live == 'true' }}":
        problems.append(f"step {step.get('id')} must run only when live exists")
check = next(st for st in job["steps"] if st.get("id") == "check")
if {k[4:] for k in check.get("env", {}) if k.startswith("SET_")} != {"VPS_REGISTRY_PASSWORD", "VPS_RECEIVER_TOKEN"}:
    problems.append("the check step doesn't report each secret by name")
if not pin:
    problems.append("no lucahost/deploy-actions/vps@<sha> step")
else:
    r = subprocess.run(["git", "-C", sys.argv[2], "diff", "--quiet", pin, "HEAD", "--", "vps/"], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"vps/ at the pinned {pin[:7]} differs from this checkout's (or the commit is unknown): repin vps-app.yml ({r.stderr.strip()[:120]})")
for p in problems:
    print("   FAIL: " + p)
if problems:
    sys.exit(1)
print("   ok: Environment vps, push/dispatch on main only, OIDC, two secrets by name, SHA pins, live-gated Receiver/wait, the pinned vps/ is this one")
