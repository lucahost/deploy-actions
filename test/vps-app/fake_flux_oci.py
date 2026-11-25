"""A stand-in for the VPS side of vps-app.yml, for the self-test (never deployed anywhere).

POST /hook/<path>: checks X-Signature like Flux's generic-hmac Receiver, then "applies" what the
tag `live` of <app>/manifests points to in the registry: after a second, GET /status/<app> answers
like Flux's Kustomization over an OCIRepository would ("live@sha256:<digest>"), depending on the
mode file: ok (applied, Ready), fail (HealthCheckFailed), never (stays Progressing).

usage: fake_flux_oci.py <port> <token file> <hook path> <registry url> <user:password file> <app> <mode file>
"""
import base64
import hashlib
import hmac
import http.server
import json
import sys
import threading
import time
import urllib.request

port, token_file, hook, registry, cred_file, app, mode_file = sys.argv[1:8]
token = open(token_file, "rb").read()
cred = base64.b64encode(open(cred_file, "rb").read().strip()).decode()
state = {"applied": "", "attempted": "", "ready": "Unknown", "reason": "Progressing", "message": ""}
lock = threading.Lock()


def live_digest():
    req = urllib.request.Request(f"{registry}/v2/{app}/manifests/manifests/live", method="HEAD",
                                 headers={"Authorization": "Basic " + cred,
                                          "Accept": "application/vnd.oci.image.manifest.v1+json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.headers["Docker-Content-Digest"]


def apply_later(rev, mode):
    time.sleep(1)
    with lock:
        state["attempted"] = rev
        if mode == "ok":
            state.update(applied=rev, ready="True", reason="ReconciliationSucceeded", message="Applied revision: " + rev)
        elif mode == "fail":
            state.update(ready="False", reason="HealthCheckFailed", message="Deployment/api not ready")
        else:  # never: still reconciling
            state.update(ready="Unknown", reason="Progressing", message="Reconciliation in progress")


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        want = "sha256=" + hmac.new(token, body, hashlib.sha256).hexdigest()
        if self.path != "/hook/" + hook or not hmac.compare_digest(self.headers.get("X-Signature", ""), want):
            self.send_response(401); self.end_headers(); return
        rev = "live@" + live_digest()
        threading.Thread(target=apply_later, args=(rev, open(mode_file).read().strip()), daemon=True).start()
        self.send_response(200); self.end_headers()

    def do_GET(self):
        if self.path != "/status/" + app:
            self.send_response(404); self.end_headers(); return
        with lock:
            doc = {"status": {"lastAppliedRevision": state["applied"], "lastAttemptedRevision": state["attempted"],
                              "conditions": [{"type": "Ready", "status": state["ready"], "reason": state["reason"],
                                              "message": state["message"]}]}}
        out = json.dumps(doc).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out)


http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), H).serve_forever()
