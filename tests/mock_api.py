"""A stand-in for the Demofy jobs API, for tests/run.sh.

The scenario is chosen by the API key the action sends, so one server serves every case:
  dmf_success  queued -> capturing -> done, with a downloadable MP4
  dmf_fail     the job fails with an errorCode
  dmf_stuck    the job never leaves capturing (timeout)
  dmf_signin   the job pauses for a sign-in
  dmf_flaky    a 503 and a 429 while polling, then done
  dmf_bad      401 invalid_api_key
  dmf_scope    403 for a key without the write permission
  dmf_invalid  400 with validation issues on create
  dmf_pro      402 upgrade_required on create
  dmf_quota    429 quota_exhausted on create
Each create body is written to <log dir>/<scenario>.json so the tests can check what was sent.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG_DIR = sys.argv[2]
VIDEO = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 1000
polls = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, headers=None):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def scenario(self):
        auth = self.headers.get("Authorization", "")
        return auth[len("Bearer dmf_"):] if auth.startswith("Bearer dmf_") else None

    def refused(self, scenario):
        if scenario is None:
            self.send(500, {"error": "the mock expects a dmf_ bearer key"})
        elif scenario == "bad":
            self.send(401, {"error": "invalid_api_key", "message": "This API key is not valid."},
                      {"WWW-Authenticate": 'Bearer realm="demofy"'})
        else:
            return False
        return True

    def do_POST(self):
        scenario = self.scenario()
        if self.refused(scenario):
            return
        if self.path != "/api/jobs":
            return self.send(404, {"error": "not found"})
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(f"{LOG_DIR}/{scenario}.json", "wb") as log:
            log.write(body)
        if scenario == "scope":
            return self.send(403, {"error": "insufficient_scope",
                                   "message": "This key cannot do this: it needs the Write permission."})
        if scenario == "invalid":
            return self.send(400, {"error": "invalid request", "issues": [
                {"path": ["quality"], "message": "Invalid enum value"}]})
        if scenario == "pro":
            return self.send(402, {"error": "upgrade_required", "features": ["quality"],
                                   "message": "High quality is a Pro feature."})
        if scenario == "quota":
            return self.send(429, {"error": "quota_exhausted", "scope": "daily", "limit": 3,
                                   "message": "You have made today's 3 demos."}, {"Retry-After": "3600"})
        job = f"job-{scenario}"
        polls[job] = 0
        self.send(202, {"id": job, "status": "queued", "quality": "standard", "url": f"/jobs/{job}"})

    def do_GET(self):
        if self.path.startswith("/files/"):
            if "Authorization" in self.headers:
                return self.send(400, {"error": "the API key must not go to storage"})
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(VIDEO)))
            self.end_headers()
            self.wfile.write(VIDEO)
            return
        scenario = self.scenario()
        if self.refused(scenario):
            return
        job = self.path.rsplit("/", 1)[-1]
        if job not in polls:
            return self.send(404, {"error": "not found"})
        polls[job] += 1
        n = polls[job]
        base = {"id": job, "kind": "demo", "url": f"/jobs/{job}", "error": None, "errorCode": None,
                "needsSignIn": None, "video": None, "shareUrl": None, "cancelled": False}
        if scenario == "fail":
            return self.send(200, {**base, "status": "failed", "errorCode": "page_not_found",
                                   "error": "The URL opened a page not found screen."})
        if scenario == "stuck":
            return self.send(200, {**base, "status": "capturing"})
        if scenario == "signin":
            return self.send(200, {**base, "status": "queued", "needsSignIn": [
                {"site": "app.example.com", "reason": "The dashboard needs a sign-in.",
                 "signInUrl": "https://app.demofy.io/jobs/job-signin#sign-in"}]})
        if scenario == "flaky" and n == 1:
            return self.send(503, {"error": "unavailable"})
        if scenario == "flaky" and n == 2:
            return self.send(429, {"error": "rate_limited", "message": "Slow down."}, {"Retry-After": "1"})
        if n < 3:
            return self.send(200, {**base, "status": ["queued", "capturing"][n - 1]})
        host = f"http://127.0.0.1:{PORT}"
        self.send(200, {**base, "status": "done", "shareUrl": f"{host}/s/abc",
                        "video": {"url": f"{host}/files/{job}.mp4", "contentType": "video/mp4",
                                  "downloadUrl": f"{host}/files/{job}.mp4?download=1"}})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
