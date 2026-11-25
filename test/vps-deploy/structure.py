"""Guard rails of the deploy workflows that a run can't show (vps-deploy-selftest.yml):

- vps-deploy.yml's job uses Environment "vps", runs only for a push or dispatch on main, may mint an OIDC
  token and takes no secrets as inputs (they come from the Environment); Tailscale uses workload
  identity (no OAuth secret);
- every action it uses is pinned to a 40-character commit SHA;
- no ${{ }} expression inside a run: script (steps read env only);
- smoke.yml passes no secrets and grants id-token: write.
usage: structure.py <vps-deploy.yml> <smoke.yml>
"""
import re
import sys

import yaml

problems = []
wf = yaml.safe_load(open(sys.argv[1]))
smoke = yaml.safe_load(open(sys.argv[2]))
on = wf.get("on") or wf.get(True)
call = on["workflow_call"]
if call.get("secrets"):
    problems.append("vps-deploy.yml declares secrets; they must come from the Environment")
job = wf["jobs"]["deploy"]
if job.get("environment") != "vps":
    problems.append("job environment is not 'vps'")
if job.get("if") != "github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')":
    problems.append("job lacks the guard: main only, push or workflow_dispatch only")
if (job.get("permissions") or {}).get("id-token") != "write":
    problems.append("job can't mint an OIDC token")
for step in job["steps"]:
    uses = step.get("uses")
    if uses and not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", uses):
        problems.append(f"action not pinned by SHA: {uses}")
    if "${{" in step.get("run", ""):
        problems.append(f"${{{{ }}}} inside the script of step {step.get('id') or step.get('name')}")
    with_ = step.get("with") or {}
    if "oauth-secret" in with_:
        problems.append("Tailscale with an OAuth secret instead of workload identity")
text = open(sys.argv[1]).read()
if "TS_OAUTH_SECRET" in text:
    problems.append("TS_OAUTH_SECRET still referenced")
sjob = smoke["jobs"]["deploy"]
if "secrets" in sjob:
    problems.append("smoke.yml passes secrets")
if (smoke.get("permissions") or {}).get("id-token") != "write":
    problems.append("smoke.yml doesn't grant id-token: write")
for p in problems:
    print("   FAIL: " + p)
if problems:
    sys.exit(1)
print("   ok: Environment vps, push/dispatch on main only, OIDC, every action SHA-pinned, no secrets passed, no ${{ }} in scripts")
