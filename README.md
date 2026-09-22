# dashboard

Three machines on one page. Hosts, backups, syncs, apps, and a band at the top
that is empty when nothing is wrong.

Runs on the app platform in [neburion/NixOS](https://github.com/neburion/NixOS):
`app.json` is the whole interface, and there is no Nix in here.

## What it is

A poller and a page. Every host in the fleet runs a `fleet-status` agent — a
root timer that writes a JSON reading every 30s, and an unprivileged server
that hands that one file out on `:8081` over the tailnet. This dials all three,
works out what is wrong, and draws it.

Pull, not push. A host that has stopped answering *is* the down signal, so
there is no heartbeat to miss and no writable endpoint anywhere in the fleet.

It keeps nothing. No database, no state directory: every number is read on the
request that asked for it, cached for ten seconds so two open tabs do not
double the traffic. A restart loses nothing because there was nothing to lose.

## What it cannot tell you

**Whether `personal-server` is up**, because that is where it runs. A dead page
is that host's outage. Everything else degrades to one unreachable card.

## Running it

```
python3 app.py                     # http://127.0.0.1:8779, no auth
DASH_AGENTS=pod042,home-server python3 app.py
python3 app.py --once              # the verdict, in a terminal, no server
```

| Env | Default | |
|---|---|---|
| `DASH_AGENTS` | — | comma-separated hosts to poll; required |
| `DASH_AGENT_PORT` | `8081` | where the agent listens |
| `DASH_HOST` / `DASH_PORT` | `127.0.0.1` / `8779` | bind |
| `DASH_PASSWORD` / `DASH_USERNAME` | — | login, when not run under systemd |
| `DASH_UI` | `./ui.html` | the page |

Deployed, both halves of the login arrive as systemd credentials from sops.
Binding anything but loopback without a password is refused — the page is an
inventory of the fleet and it is published, so there is no degraded mode worth
having.

## The verdicts

`bad` is broken now. `warn` is going to be broken later. Anything that is
merely a standing fact of this fleet gets neither, and is drawn in its own
colour further down:

- **home-server keeps no backups.** Its row reads *not configured*, not green.
- **A phone at 0% completion** has not accepted that folder yet. That is a tap
  on the phone, not a stalled sync.
- **A sleeping phone** is offline, in grey, and never an alert.

Red and green sit about four ΔE apart under deuteranopia, so every state on the
page carries a glyph and a word as well as a colour.
