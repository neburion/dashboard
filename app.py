#!/usr/bin/env python3
"""Dashboard — three machines on one page.

Stdlib only: no Flask, no pip. Polls the fleet-status agent on each host over
the tailnet, works out what is wrong, and serves that plus the UI in ui.html.

    python3 app.py                 # http://127.0.0.1:8779, no auth
    python3 app.py --port 9000
    python3 app.py --once          # print the verdict and exit, no server

It holds nothing. There is no database and no state directory: every number on
the page is read from an agent on the request that asked for it, so the worst
this can be is out of date by `CACHE_TTL` seconds, and a restart loses nothing
because there was nothing to lose.

Auth is the same login screen the two trackers use, for the same reason — this
is published at dashboard.azuresalt.app, and it is an inventory of what the fleet
runs and where. See the auth section.

What it cannot tell you: whether personal-server is up, because that is where
it runs. A dead page is that host's outage. Everything else in here degrades to
one unreachable card.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, urlencode

HERE = Path(__file__).resolve().parent
UI = Path(os.environ.get("DASH_UI") or HERE / "ui.html")

AGENTS = [h for h in (os.environ.get("DASH_AGENTS") or "").split(",") if h.strip()]
AGENT_PORT = int(os.environ.get("DASH_AGENT_PORT", "8081"))
AGENT_TIMEOUT = 5

DEFAULT_HOST = os.environ.get("DASH_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("DASH_PORT", "8779"))

# Three HTTP round trips over the tailnet per page load, and the agents only
# take a fresh reading every 30s anyway — so polling harder than this buys
# nothing but load. The page refreshes itself on a timer; without a cache,
# two open tabs would double the traffic for identical numbers.
CACHE_TTL = 10

# An agent that has not collected in this long is reporting a dead timer, not
# a healthy machine. Generous next to the 30s cadence so a slow boot or a
# single missed tick is not an alarm.
STALE_AFTER = 180

DAY = 86400


# --------------------------------------------------------------------- auth
#
# Same gate as the two trackers. This one holds no data of its own, which is
# exactly why it needs the gate anyway: it is a map of the fleet — hostnames,
# what each runs, which ports answer, how full the disks are. That is the
# document you would want first.

def _credential(name, env, fallback=""):
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    if creds:
        p = Path(creds) / name
        if p.exists():
            return p.read_text().strip()
    return (os.environ.get(env) or fallback).strip()


PASSWORD = _credential("password", "DASH_PASSWORD")
USERNAME = _credential("username", "DASH_USERNAME", "dashboard")
AUTH_ON = bool(PASSWORD)

RATE_WINDOW = 3600
RATE_MAX = 20
RATE_MSG = "Too many attempts. Try again in an hour."
_rate_lock = threading.Lock()
_failures = defaultdict(deque)


def _rate_ok(ip):
    now = time.time()
    with _rate_lock:
        q = _failures[ip]
        while q and now - q[0] > RATE_WINDOW:
            q.popleft()
        return len(q) < RATE_MAX


def _rate_fail(ip):
    with _rate_lock:
        _failures[ip].append(time.time())


def check_credentials(user, pw, ip):
    """(ok, reason). Constant-time; never leaks which half was wrong."""
    if not AUTH_ON:
        return True, ""
    if not _rate_ok(ip):
        return False, "rate"
    user_ok = hmac.compare_digest(user, USERNAME)
    pw_ok = hmac.compare_digest(pw, PASSWORD)
    if user_ok and pw_ok:
        return True, ""
    _rate_fail(ip)
    return False, "bad"


def check_auth(header, ip):
    """(ok, reason) for an Authorization header. Kept for scripts and curl."""
    if not AUTH_ON:
        return True, ""
    if not _rate_ok(ip):
        return False, "rate"
    if not header or not header.startswith("Basic "):
        return False, "missing"
    try:
        raw = base64.b64decode(header[6:]).decode("utf-8")
        user, _, pw = raw.partition(":")
    except Exception:                                    # noqa: BLE001
        _rate_fail(ip)
        return False, "bad"
    return check_credentials(user, pw, ip)


# ------------------------------------------------------------------ session
#
# A signed timestamp rather than a session id: nothing to store, sweep or lose
# across a restart. The key is derived from the password, so rotating the sops
# secret invalidates every cookie in the wild for free.

SESSION_COOKIE = "dash_session"
SESSION_TTL = 30 * DAY
SESSION_REFRESH = 21 * DAY


def _session_key():
    return hashlib.sha256(b"fd-session\x00" + PASSWORD.encode("utf-8")).digest()


def _session_sig(exp):
    return hmac.new(_session_key(), str(exp).encode("ascii"),
                    hashlib.sha256).hexdigest()


def make_session(now=None):
    exp = int(now or time.time()) + SESSION_TTL
    return f"{exp}.{_session_sig(exp)}"


def check_session(value):
    """(ok, seconds_left). Unsigned, malformed and expired all read False."""
    if not AUTH_ON or not value:
        return False, 0
    exp, _, sig = value.partition(".")
    if not exp.isdigit() or not sig:
        return False, 0
    if not hmac.compare_digest(sig, _session_sig(exp)):
        return False, 0
    left = int(exp) - int(time.time())
    return left > 0, max(0, left)


def safe_next(path):
    """Only ever a path on this origin. An open redirect on the login of an
    infrastructure page is a phishing kit with a real hostname in front of it."""
    if not path or not path.startswith("/") or path.startswith("//"):
        return "/"
    return path


_LOGIN_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>Dashboard</title>
<style>
:root{
  --bg:#0b0d10; --panel:#14171c; --line:#232830;
  --ink:#e6e9ef; --dim:#8b93a1; --accent:#7fb2e5; --bad:#e5786d;
}
*{box-sizing:border-box}
body{margin:0;min-height:100dvh;display:grid;place-items:center;background:var(--bg);
  color:var(--ink);font:400 15px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif}
form{width:min(92vw,340px);padding:28px;background:var(--panel);
  border:1px solid var(--line);border-radius:14px}
h1{margin:0 0 4px;font-size:19px;font-weight:600;letter-spacing:-.01em}
p.sub{margin:0 0 22px;color:var(--dim);font-size:13px}
label{display:block;margin:0 0 6px;font-size:12px;color:var(--dim);
  text-transform:uppercase;letter-spacing:.06em}
input{width:100%;margin:0 0 16px;padding:10px 12px;background:#0e1115;
  border:1px solid var(--line);border-radius:8px;color:var(--ink);font:inherit}
input:focus{outline:none;border-color:var(--accent)}
button{width:100%;padding:10px;background:var(--accent);border:0;border-radius:8px;
  color:#0b0d10;font:600 15px/1 inherit;cursor:pointer}
.err{margin:0 0 16px;padding:9px 11px;background:#2a1714;border:1px solid #4a2721;
  border-radius:8px;color:var(--bad);font-size:13px}
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>Dashboard</h1>
  <p class="sub">__SUB__</p>
  __ERR__
  <input type="hidden" name="next" value="__NEXT__">
  <label for="u">User</label>
  <input id="u" type="text" name="username" autocomplete="username"
         autocapitalize="none" autocorrect="off" spellcheck="false" required>
  <label for="p">Password</label>
  <input id="p" type="password" name="password" autocomplete="current-password" required>
  <button type="submit">Sign in</button>
</form>
<script>
/* Focus the first empty field: a password manager that filled both should not
   have the cursor dropped back into what it just completed. */
for (const el of [u, p]) if (!el.value) { el.focus(); break; }
</script>
</body>
</html>"""


def login_page(error="", nxt="/"):
    esc = lambda s: (s.replace("&", "&amp;").replace("<", "&lt;")
                      .replace(">", "&gt;").replace('"', "&quot;"))
    return (_LOGIN_HTML
            .replace("__SUB__", "Three machines, one page.")
            .replace("__ERR__", f'<p class="err">{esc(error)}</p>' if error else "")
            .replace("__NEXT__", esc(safe_next(nxt))))


# ------------------------------------------------------------------ polling

def fetch(host):
    """One agent's reading, or a card that says why there isn't one.

    A refused connection and a timeout mean different things to a person —
    "the service is down" against "the machine is" — so the reason is carried
    through rather than flattened to False.
    """
    url = f"http://{host}:{AGENT_PORT}/status.json"
    started = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=AGENT_TIMEOUT) as r:
            data = json.load(r)
        data["reachable"] = True
        data["rtt_ms"] = int((time.monotonic() - started) * 1000)
        # The agent reports its own hostname; trust the name we dialled for
        # identity, so a misconfigured agent cannot rename a card.
        data["host"] = host
        return data
    except urllib.error.HTTPError as e:
        why = f"agent answered {e.code}"
    except urllib.error.URLError as e:
        why = str(getattr(e, "reason", e))
    except (socket.timeout, TimeoutError):
        why = f"no answer in {AGENT_TIMEOUT}s"
    except Exception as e:                               # noqa: BLE001
        why = f"{type(e).__name__}: {e}"
    return {"host": host, "reachable": False, "error": why}


_cache = {"at": 0, "value": None}
_cache_lock = threading.Lock()


def poll(force=False):
    with _cache_lock:
        if not force and _cache["value"] and time.time() - _cache["at"] < CACHE_TTL:
            return _cache["value"]
    # Outside the lock: three hosts in parallel, and one that has gone away
    # takes AGENT_TIMEOUT to say so. Holding the lock through that would make
    # every other viewer wait on the dead machine.
    with ThreadPoolExecutor(max_workers=max(1, len(AGENTS))) as pool:
        hosts = list(pool.map(fetch, AGENTS))
    value = {"at": int(time.time()), "hosts": hosts, "alerts": alerts(hosts)}
    with _cache_lock:
        _cache.update(at=time.time(), value=value)
    return value


# ----------------------------------------------------------------- the vendor
#
# The half of this that is not a machine. Three accounts hold things the fleet
# depends on and cannot see for itself: who the domain is registered with and
# until when, where mail addressed to it goes, what the object store is
# holding.
#
# Read-only, deliberately. The Cloudflare credential here is a scoped token
# with six read permissions — not the account's Global API Key, which can do
# anything and has no business inside a process that answers a public URL. A
# write through this token comes back "Authentication error", which is the
# point.
#
# Backblaze is absent on purpose. Its key can delete files, so that call is
# made by the agent on the host that already holds the key for restic's sake,
# and only the counts travel. See the b2 probe in the fleet-status collector.
#
# Everything here is cached for hours. The page polls every 15s and a domain's
# expiry date does not move at that speed; three vendors should not hear from
# every tab somebody leaves open.

PORKBUN_KEY = _credential("porkbun-api-key", "DASH_PORKBUN_API_KEY")
PORKBUN_SECRET = _credential("porkbun-secret-key", "DASH_PORKBUN_SECRET_KEY")
CF_TOKEN = _credential("cloudflare-token", "DASH_CLOUDFLARE_TOKEN")
CF_ACCOUNT = os.environ.get("DASH_CF_ACCOUNT", "")
ZONE = os.environ.get("DASH_ZONE", "azuresalt.app")

PORKBUN_API = "https://api.porkbun.com/api/json/v3"
CF_API = "https://api.cloudflare.com/client/v4"

# Cloudflare's free R2 allowance, for the meter. Nothing enforces this — it is
# the line past which the bill stops being zero.
R2_FREE_BYTES = 10 * 1024 ** 3

_vendor = {}
_vendor_lock = threading.Lock()


def vendor(name, ttl, fn):
    """Call fn at most once per ttl, and never let it take the page down.

    A vendor that is down, rate-limiting, or slow is not an outage here — the
    last good answer keeps being served, marked with how old it is. The failure
    is reported beside it rather than in place of it, because "Cloudflare did
    not answer just now" and "you have no domain" should not look the same.
    """
    now = time.time()
    with _vendor_lock:
        entry = _vendor.get(name)
        if entry and now - entry["at"] < ttl:
            return entry["value"]
    try:
        value = {"at": int(now), **fn()}
    except Exception as e:                               # noqa: BLE001
        with _vendor_lock:
            entry = _vendor.get(name)
        stale = dict(entry["value"]) if entry else {"at": int(now)}
        stale["error"] = f"{type(e).__name__}: {e}"
        return stale
    with _vendor_lock:
        _vendor[name] = {"at": now, "value": value}
    return value


def _post_json(url, payload, timeout=15):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _cf(path, timeout=15):
    req = urllib.request.Request(
        CF_API + path, headers={"Authorization": f"Bearer {CF_TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.load(r)
    if not body.get("success"):
        raise RuntimeError("; ".join(e.get("message", "?")
                                     for e in body.get("errors") or []) or "failed")
    return body["result"]


def domain():
    """The registration itself, from Porkbun.

    This is the one fact in the whole fleet with a hard deadline and no
    fallback: every hostname, every tunnel and the mail all hang off one
    registration that lapses on a date. Nothing else on this page can tell you
    that date, because nothing else knows who the registrar is.
    """
    if not PORKBUN_KEY or not PORKBUN_SECRET:
        return {"configured": False}
    auth = {"apikey": PORKBUN_KEY, "secretapikey": PORKBUN_SECRET}

    listing = _post_json(f"{PORKBUN_API}/domain/listAll", auth)
    if listing.get("status") != "SUCCESS":
        raise RuntimeError(listing.get("message", "listAll failed"))
    rows = [d for d in listing.get("domains", []) if d["domain"] == ZONE]
    if not rows:
        # The account-wide opt-in is a single switch on the API page, and with
        # it off the domain is simply not in the answer — not an error, just
        # absent, which is a worse thing to debug.
        raise RuntimeError(f"{ZONE} is not opted in to API access")
    d = rows[0]

    ns = _post_json(f"{PORKBUN_API}/domain/getNs/{ZONE}", auth)
    price = {}
    try:
        tld = ZONE.rsplit(".", 1)[-1]
        # 25s, not the usual 15: the pricing table is the slowest thing
        # Porkbun serves, around nine seconds on a good day. It is cached for
        # six hours, so waiting is free and timing out costs the one number
        # that says what the renewal will actually charge.
        with urllib.request.urlopen(f"{PORKBUN_API}/pricing/get", timeout=25) as r:
            price = (json.load(r).get("pricing") or {}).get(tld) or {}
    except Exception:                                    # noqa: BLE001
        price = {}                                       # a nice-to-have only

    expires = d.get("expireDate", "")
    left = None
    if expires:
        exp = time.mktime(time.strptime(expires, "%Y-%m-%d %H:%M:%S"))
        left = int((exp - time.time()) / 86400)
    return {
        "configured": True,
        "domain": d["domain"],
        "status": d.get("status"),
        "registered": d.get("createDate"),
        "expires": expires,
        "days_left": left,
        "auto_renew": bool(int(d.get("autoRenew", 0))),
        "locked": bool(int(d.get("securityLock", 0))),
        "whois_privacy": bool(int(d.get("whoisPrivacy", 0))),
        "nameservers": ns.get("ns", []),
        "renewal": price.get("renewal"),
        "registrar": "Porkbun",
    }


def cloudflare():
    """The zone, its mail routing, and the object store.

    Mail is the part worth watching: a routing rule that gets disabled does not
    bounce anything, it drops it. The rules are listed in full rather than
    summarised to a count for that reason — a count of one looks identical
    whether the rule forwards to the right address or to nothing.
    """
    if not CF_TOKEN or not CF_ACCOUNT:
        return {"configured": False}

    zones = _cf(f"/zones?name={ZONE}")
    if not zones:
        raise RuntimeError(f"zone {ZONE} not visible to this token")
    z = zones[0]
    zid = z["id"]

    routing = _cf(f"/zones/{zid}/email/routing")
    rules = _cf(f"/zones/{zid}/email/routing/rules")
    catch_all = _cf(f"/zones/{zid}/email/routing/rules/catch_all")

    def targets(rule):
        out = []
        for a in rule.get("actions") or []:
            out += [v for v in (a.get("value") or [])]
        return out

    buckets = []
    total = 0
    for b in (_cf(f"/accounts/{CF_ACCOUNT}/r2/buckets") or {}).get("buckets", []):
        u = _cf(f"/accounts/{CF_ACCOUNT}/r2/buckets/{b['name']}/usage")
        size = int(u.get("payloadSize") or 0)
        total += size
        buckets.append({
            "name": b["name"],
            "created": b.get("creation_date"),
            "location": b.get("location"),
            "bytes": size,
            "objects": int(u.get("objectCount") or 0),
        })

    return {
        "configured": True,
        "zone": {
            "name": z["name"],
            "status": z.get("status"),
            "paused": z.get("paused"),
            "plan": (z.get("plan") or {}).get("name"),
            "activated": z.get("activated_on"),
            "nameservers": z.get("name_servers") or [],
            "records": len(_cf(f"/zones/{zid}/dns_records?per_page=100") or []),
        },
        "email": {
            "enabled": routing.get("enabled"),
            "status": routing.get("status"),
            # Destination-address verification is not readable here: Cloudflare
            # refuses the account-level addresses endpoint to a scoped token
            # whatever permissions it carries. The forward target below is the
            # same address, so nothing on the page is missing — only the tick
            # that says the address confirmed itself.
            "catch_all": {
                "enabled": catch_all.get("enabled"),
                "to": targets(catch_all),
            },
            # The catch-all comes back in this list too, as a nameless rule
            # matching "all". It already has its own row above, and drawing it
            # twice would read as two rules where there is one.
            "rules": [{
                "name": r.get("name") or "(unnamed)",
                "enabled": r.get("enabled"),
                "match": [m.get("value") for m in (r.get("matchers") or [])],
                "to": targets(r),
            } for r in (rules or [])
                if not any((m.get("type") == "all")
                           for m in (r.get("matchers") or []))],
        },
        "r2": {
            "buckets": buckets,
            "bytes": total,
            "free_bytes": R2_FREE_BYTES,
        },
    }


def accounts(force=False):
    """Everything vendor-side, in one answer, each piece on its own clock."""
    if force:
        with _vendor_lock:
            _vendor.clear()
    return {
        "at": int(time.time()),
        # Six hours: a registration date moves once a year, and the renewal
        # price about as often.
        "domain": vendor("domain", 6 * 3600, domain),
        # Fifteen minutes: mail routing is the one thing here somebody might
        # change and want to see reflected without waiting for lunch.
        "cloudflare": vendor("cloudflare", 900, cloudflare),
    }


# ------------------------------------------------------------------ verdicts
#
# The page's whole reason to exist is the top band, and a band that cries wolf
# gets scrolled past. So: `bad` is something broken now, `warn` is something
# that will be broken later, and anything that is merely a standing fact of the
# fleet — home-server keeps no backups, a phone is asleep — is neither. It gets
# drawn in its own colour further down and never appears up here.

def alerts(hosts):
    out = []

    def add(level, host, what, detail=""):
        out.append({"level": level, "host": host, "what": what, "detail": detail})

    now = time.time()
    for h in hosts:
        name = h["host"]
        if not h.get("reachable"):
            add("bad", name, "unreachable", h.get("error", ""))
            continue

        age = now - h.get("collected", 0)
        if age > STALE_AFTER:
            add("warn", name, "stale reading",
                f"last collected {int(age // 60)} min ago")

        health = h.get("health") or {}
        for unit in health.get("failed", []):
            add("bad", name, "unit failed", unit)
        if health.get("state") not in ("running", None):
            if health.get("state") != "degraded":   # degraded is the failed list
                add("warn", name, "systemd", health.get("state", "?"))

        for d in h.get("disks") or []:
            if not isinstance(d, dict):
                continue
            pct = 100 * d["used"] / d["total"] if d.get("total") else 0
            if pct >= 92:
                add("bad", name, "disk full", f"{d['mount']} at {pct:.0f}%")
            elif pct >= 85:
                add("warn", name, "disk filling", f"{d['mount']} at {pct:.0f}%")

        for b in h.get("backups") or []:
            if not isinstance(b, dict):
                continue
            if b.get("running"):
                continue
            if b.get("result") not in ("success", None):
                add("bad", name, "backup failed",
                    f"{b['job']}: {b.get('result')} (exit {b.get('exit')})")
            elif b.get("last") and now - b["last"] > 2 * DAY:
                add("warn", name, "backup stale",
                    f"{b['job']} last ran {int((now - b['last']) // DAY)} days ago")

        for a in h.get("apps") or []:
            if isinstance(a, dict) and not a.get("up"):
                add("bad", name, "app not answering",
                    f"{a['name']} on :{a['port']}")

        for s in h.get("services") or []:
            if isinstance(s, dict) and s.get("active") != "active":
                add("bad", name, "service down",
                    f"{s['unit']} is {s.get('active')}")

        gen = h.get("generation") or {}
        if gen.get("reboot_pending"):
            add("warn", name, "reboot pending", "kernel or initrd changed")
        if gen.get("untracked"):
            # A `trebuild` is a test activation: it dies on the next boot and
            # belongs to no generation. Worth saying, because the machine looks
            # entirely normal while running config that is about to vanish.
            add("warn", name, "test activation", "running config is not a generation")

        sync = h.get("syncthing")
        if isinstance(sync, dict):
            if sync.get("error"):
                add("warn", name, "syncthing", sync["error"])
            for f in sync.get("folders", []):
                # Out of sync is only news when there is something to send.
                # A folder a phone has not accepted sits at 0% forever and is
                # a decision nobody made, not a fault. It shows as its own
                # state on the card.
                if f.get("need_bytes", 0) > 0:
                    add("warn", name, "folder out of sync",
                        f"{f['label']}: {f['need_items']} items behind")

        # A section the collector could not read at all. Rare, and invisible
        # otherwise, because everything above skips what it cannot parse.
        for key, val in h.items():
            if isinstance(val, dict) and val.get("error") and key != "syncthing":
                add("warn", name, f"{key} unreadable", val["error"])

    order = {"bad": 0, "warn": 1}
    return sorted(out, key=lambda a: (order.get(a["level"], 2), a["host"]))


# -------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    server_version = "dashboard"
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def client_ip(self):
        # Behind the tunnel every request arrives from loopback, so the rate
        # limiter would be one shared bucket for the whole internet. CF-
        # Connecting-IP is set by Cloudflare and is the only way to tell two
        # of them apart; over the tailnet it is absent and the peer address is
        # already the truth.
        return (self.headers.get("CF-Connecting-IP")
                or self.client_address[0])

    # -- plumbing --------------------------------------------------------

    def _write(self, body, ctype, code=200, headers=()):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _send(self, obj, code=200, headers=()):
        self._write(json.dumps(obj), "application/json", code, headers)

    def _html(self, body, code=200, headers=()):
        self._write(body, "text/html; charset=utf-8", code, headers)

    def _redirect(self, to, code=303):
        self.send_response(code)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def cookie(self, name):
        try:
            jar = SimpleCookie(self.headers.get("Cookie", ""))
        except CookieError:
            return ""
        got = jar.get(name)
        return got.value if got else ""

    def _secure_link(self):
        return ((self.headers.get("X-Forwarded-Proto") or "").lower() == "https"
                or "https" in (self.headers.get("CF-Visitor") or ""))

    def _issue_session(self):
        self._cookie_out = (
            f"{SESSION_COOKIE}={make_session()}; Max-Age={SESSION_TTL}; "
            f"Path=/; HttpOnly; SameSite=Lax"
            + ("; Secure" if self._secure_link() else ""))

    def end_headers(self):
        out = getattr(self, "_cookie_out", "")
        if out:
            self._cookie_out = ""
            self.send_header("Set-Cookie", out)
        super().end_headers()

    # -- the gate --------------------------------------------------------

    def logged_in(self):
        ok, left = check_session(self.cookie(SESSION_COOKIE))
        if ok:
            if left < SESSION_REFRESH:
                self._issue_session()
            return True, ""
        ok, why = check_auth(self.headers.get("Authorization"), self.client_ip())
        if ok:
            if AUTH_ON:
                self._issue_session()
            return True, ""
        return False, why

    def authed(self):
        ok, why = self.logged_in()
        if not ok:
            self._deny(why)
        return ok

    def _deny(self, why):
        """Refuse in the shape the caller can act on. Never WWW-Authenticate —
        that header is what summons the browser's grey credential modal, which
        is the thing the login screen exists to replace."""
        page = self.command == "GET" and not self.path.startswith("/api/")
        if why == "rate":
            hdrs = (("Retry-After", str(RATE_WINDOW)),)
            if page:
                return self._html(login_page(RATE_MSG, safe_next(self.path)),
                                  429, hdrs)
            return self._send({"error": RATE_MSG}, 429, hdrs)
        if page:
            return self._redirect("/login?" + urlencode({"next": safe_next(self.path)}))
        return self._send({"error": "not logged in"}, 401)

    # -- routes ----------------------------------------------------------

    def do_GET(self):
        u = urlparse(self.path)

        if u.path == "/login":
            if not AUTH_ON or self.logged_in()[0]:
                return self._redirect("/")
            nxt = safe_next((parse_qs(u.query).get("next") or ["/"])[0])
            return self._html(login_page(nxt=nxt))

        if not self.authed():
            return

        if u.path in ("/", "/index.html"):
            try:
                return self._html(UI.read_text())
            except FileNotFoundError:
                return self.send_error(500, "ui.html missing")

        if u.path == "/api/status":
            force = (parse_qs(u.query).get("force") or ["0"])[0] == "1"
            return self._send(poll(force))

        # Separate from /api/status on purpose. The hosts are polled every 15s
        # and have to stay quick; the vendors are cached for hours and would
        # otherwise make every fleet refresh drag three accounts behind it.
        if u.path == "/api/accounts":
            force = (parse_qs(u.query).get("force") or ["0"])[0] == "1"
            return self._send(accounts(force))

        return self.send_error(404, "not found")

    def do_POST(self):
        if urlparse(self.path).path != "/login":
            return self.send_error(404, "not found")
        n = int(self.headers.get("Content-Length") or 0)
        form = parse_qs(self.rfile.read(n).decode("utf-8"))
        get = lambda k: (form.get(k) or [""])[0]
        nxt = safe_next(get("next"))

        ok, why = check_credentials(get("username"), get("password"),
                                    self.client_ip())
        if ok:
            self._issue_session()
            return self._redirect(nxt)
        if why == "rate":
            return self._html(login_page(RATE_MSG, nxt), 429,
                              (("Retry-After", str(RATE_WINDOW)),))
        return self._html(login_page("Wrong username or password.", nxt), 401)


def print_once():
    """The page's verdict, in a terminal. What this was debugged with."""
    data = poll(force=True)
    for h in data["hosts"]:
        if not h.get("reachable"):
            print(f"  {h['host']:<16} UNREACHABLE  {h.get('error','')}")
            continue
        b = h.get("boot") or {}
        print(f"  {h['host']:<16} up {b.get('uptime',0)//3600}h  "
              f"kernel {b.get('kernel','?')}  {h.get('rtt_ms','?')}ms")
    if not data["alerts"]:
        print("\n  nothing wrong anywhere.\n")
        return
    print()
    for a in data["alerts"]:
        print(f"  [{a['level']:<4}] {a['host']:<16} {a['what']}"
              + (f" — {a['detail']}" if a["detail"] else ""))
    print()


def main():
    ap = argparse.ArgumentParser(description="Dashboard")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--once", action="store_true",
                    help="print the verdict and exit, no server")
    a = ap.parse_args()

    if not AGENTS:
        raise SystemExit("no agents to poll — set DASH_AGENTS=host1,host2")
    if a.once:
        return print_once()

    # Fail closed. This page is an inventory of the fleet and it is published,
    # so binding a reachable interface without a password is not a degraded
    # mode worth having. A restart loop is the better failure.
    loopback = a.host in ("127.0.0.1", "localhost", "::1")
    if not AUTH_ON and not loopback and not os.environ.get("DASH_ALLOW_NO_AUTH"):
        raise SystemExit(
            f"refusing to bind {a.host} with no password set.\n"
            "Set DASH_PASSWORD, provide a systemd credential named 'password', "
            "or bind 127.0.0.1. Override with DASH_ALLOW_NO_AUTH=1 if you mean it.")

    auth = "password required" if AUTH_ON else "NO AUTH (loopback only)"
    print(f"Dashboard → http://{a.host}:{a.port}   [{auth}]   "
          f"{len(AGENTS)} agents: {', '.join(AGENTS)}")
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
