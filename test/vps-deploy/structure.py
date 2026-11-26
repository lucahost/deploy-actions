"""Guard rails of vps-deploy.yml (Onboarding v2) that a run can't show (vps-deploy-selftest.yml):

- the job uses Environment "vps", runs only for a push or dispatch on main, may mint an OIDC token;
  the workflow declares no secrets as inputs, references only VPS_REGISTRY_PASSWORD and
  VPS_RECEIVER_TOKEN, and never TS_OAUTH_*;
- every action is pinned to a 40-character commit SHA; no ${{ }} expression inside a run: script;
- the check step reports each of the two secrets by name (true/false, never a value);
- the Receiver call and the wait run only when the app is switched over (live exists);
- the render/pack action vps-deploy.yml pins (lucahost/deploy-actions/vps@<sha>) has the same vps/ as
  this checkout: the chart that runs is the one reviewed here.
usage: structure.py <vps-deploy.yml> <repo root>
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
    problems.append("vps-deploy.yml declares secrets; they must come from the Environment")
job = wf["jobs"]["deploy"]
if job.get("environment") != "vps":
    problems.append("job environment is not 'vps'")
if job.get("if") != "github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')":
    problems.append("job lacks the guard: main only, push or workflow_dispatch only")
if (job.get("permissions") or {}).get("id-token") != "write":
    problems.append("job can't mint an OIDC token")
# The two secrets, each by name, or by name plus the per-app suffix (inputs.per-app-secrets):
# secrets[format('<NAME>{0}', steps.names.outputs.suffix)], nothing else indexed.
fmt = r"secrets\[format\('([A-Z0-9_]+)\{0\}', steps\.names\.outputs\.suffix\)\]"
used = set(re.findall(r"secrets\.([A-Z0-9_]+)", src)) | set(re.findall(fmt, src))
if used != {"VPS_REGISTRY_PASSWORD", "VPS_RECEIVER_TOKEN"}:
    problems.append(f"secrets referenced: {sorted(used)} (want only VPS_REGISTRY_PASSWORD, VPS_RECEIVER_TOKEN)")
if len(re.findall(r"secrets\[", src)) != len(re.findall(fmt, src)):
    problems.append("secrets[…] other than secrets[format('<NAME>{0}', steps.names.outputs.suffix)]")
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
        problems.append(f"vps/ at the pinned {pin[:7]} differs from this checkout's (or the commit is unknown): repin vps-deploy.yml ({r.stderr.strip()[:120]})")
    # Every app fetches the action at that commit: it must stay in this branch's history (on main:
    # main's), not only on a PR branch that a squash or rebase leaves behind and someone deletes.
    r = subprocess.run(["git", "-C", sys.argv[2], "merge-base", "--is-ancestor", pin, "HEAD"], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"the pinned {pin[:7]} isn't an ancestor of this commit: merge with a merge commit, or repin to a commit on this branch")
# Every caller in this repo (smoke) passes the Environment's secrets with inherit only, may mint
# an OIDC token, and names a vps.yaml that exists.
import glob, os
for f in glob.glob(os.path.join(sys.argv[2], ".github/workflows/*.yml")):
    caller = yaml.safe_load(open(f))
    for jname, j in (caller.get("jobs") or {}).items():
        if str(j.get("uses", "")).endswith("workflows/vps-deploy.yml"):
            if j.get("secrets") != "inherit":
                problems.append(f"{os.path.basename(f)}: job {jname} must pass 'secrets: inherit' (and no secrets by name)")
            if ((caller.get("permissions") or {}).get("id-token") != "write") and ((j.get("permissions") or {}).get("id-token") != "write"):
                problems.append(f"{os.path.basename(f)}: no id-token: write for job {jname}")
            vf = (j.get("with") or {}).get("file", "vps.yaml")
            if not os.path.exists(os.path.join(sys.argv[2], vf)):
                problems.append(f"{os.path.basename(f)}: {vf} doesn't exist")
for p in problems:
    print("   FAIL: " + p)
if problems:
    sys.exit(1)
print("   ok: Environment vps, push/dispatch on main only, OIDC, two secrets by name, SHA pins, live-gated Receiver/wait, the pinned vps/ is this one and in this history")
