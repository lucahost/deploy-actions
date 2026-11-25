"""Prints the run script of one step of .github/workflows/vps-deploy.yml (by its id), so the
self-test runs exactly the code the reusable workflow runs. usage: steps.py <workflow> <step id>"""
import sys

import yaml

wf = yaml.safe_load(open(sys.argv[1]))
for step in wf["jobs"]["deploy"]["steps"]:
    if step.get("id") == sys.argv[2]:
        sys.stdout.write(step["run"])
        sys.exit(0)
sys.exit("no step with id " + sys.argv[2])
