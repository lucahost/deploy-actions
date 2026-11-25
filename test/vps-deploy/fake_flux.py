"""A stand-in for the VPS side of vps-deploy.yml, for the self-test (never deployed anywhere).

POST <hook path>: checks X-Signature like Flux's generic-hmac Receiver (HMAC-SHA256 of the body
with the token), then "applies" the deploy repo's main: after a second, GET /status/<app> answers
like Flux's Kustomization would, depending on the mode file: ok (applied, Ready), fail
(HealthCheckFailed), never (stays Progressing).

usage: fake_flux.py <port> <token file> <hook path> <bare deploy repo> <mode file> <log file>
"""
import hashlib
import hmac
import http.server
import json
import subprocess
import sys
import threading
import time

port, token_file, hook, repo, mode_file, log_file = sys.argv[1:7]
token = open(token_file, "rb").read()
lock = threading.Lock()
state = {"applied": "", "attempted": "", "ready": "Unknown", "reason": "Progressing", "message": ""}


def head():
    out = subprocess.run(["git", "--git-dir", repo, "rev-parse", "refs/heads/main"], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def apply_later(rev, mode):
    time.sleep(1)
    with lock:
        state["attempted"] = rev
        if mode == "ok":
            state.update(applied=rev, ready="True", reason="ReconciliationSucceeded", message="Applied revision: " + rev)
        elif mode == "fail":
            state.update(ready="False", reason="HealthCheckFailed", message="timeout waiting for: [Deployment/smoke/hello status: 'InProgress']")
        else:
            state.update(ready="Unknown", reason="Progressing", message="Reconciliation in progress")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        sig = self.headers.get("X-Signature", "")
        want = "sha256=" + hmac.new(token, body, hashlib.sha256).hexdigest()
        ok = self.path == hook and hmac.compare_digest(sig, want)
        with open(log_file, "a") as log:
            log.write(("accepted " if ok else "rejected ") + body.decode() + "\n")
        if not ok:
            self.send_response(401)
            self.end_headers()
            return
        rev = "main@sha1:" + head()
        mode = open(mode_file).read().strip()
        threading.Thread(target=apply_later, args=(rev, mode), daemon=True).start()
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if not self.path.startswith("/status/"):
            self.send_response(404)
            self.end_headers()
            return
        with lock:
            doc = {
                "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization",
                "metadata": {"name": self.path.rsplit("/", 1)[1], "namespace": "flux-system"},
                "status": {
                    "lastAppliedRevision": state["applied"], "lastAttemptedRevision": state["attempted"],
                    "conditions": [{"type": "Ready", "status": state["ready"], "reason": state["reason"], "message": state["message"]}],
                },
            }
        data = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
