# dashboard

Three machines on one page. Hosts, backups, syncs, apps, and a band at the top
that is empty when nothing is wrong.

Two ways to deploy it, and neither puts any Nix in here:

| | |
|---|---|
| `./install.sh --agents …` | a systemd unit, a service user and a credentials directory, on any distro with a writable `/etc`. See *Installing it*. |
| `app.json` | the app platform in [neburion/NixOS](https://github.com/neburion/NixOS) reads that manifest and generates the same unit, user and firewall rule |

They describe the same service, and `install.sh` is the one that outlives NixOS.

It is reachable on the tailnet and nowhere else, at
**http://personal-server:8779**. There is no public hostname and no login:
`dashboard.azuresalt.app` was a Cloudflare tunnel in front of a password, and the
two left together, because each was the other's reason. The tunnel and its DNS
record are deleted, not unwired.

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

## Installing it

```sh
git clone https://github.com/neburion/dashboard && cd dashboard
sudo ./install.sh --agents pod042,home-server,personal-server
./install.sh --agents pod042 --user          # no root, 127.0.0.1
./install.sh --agents pod042 --dry-run       # print the unit, touch nothing
```

`--agents` is required. There is no sensible default for which machines are
yours, and the app exits without it.

Idempotent: `git pull && ./install.sh --agents …` rewrites the unit and restarts
the service.

**A system install copies the code to `/opt/dashboard`** rather than running it
from the checkout. The service runs as its own user, a checkout lives in a home
directory, and a home directory is mode `0700` — so the service cannot read its
own `app.py`, and no `ProtectHome=` value argues with a directory mode. The NixOS
unit never met this because its code sat in `/nix/store`. `--in-place` skips the
copy and preflights that the service user really can read the code; `--prefix`
moves where it lands. A `--user` install always runs in place.

**The three account credentials live in files.** `install.sh` creates
`/etc/dashboard/credentials/` (`~/.config/dashboard/credentials/` for `--user`)
holding `porkbun-api-key`, `porkbun-secret-key` and `cloudflare-token`, empty,
`0600`. The unit hands them over with `LoadCredential=`, which systemd reads as
root before the `User=` drop, so they never reach the process environment table.
Empty reads as absent, the accounts panel says *not configured*, and the service
starts regardless — a missing key is not a failed unit. Fill one in and restart:

```sh
printf %s 'THE-KEY' | sudo tee /etc/dashboard/credentials/porkbun-api-key >/dev/null
sudo systemctl restart dashboard
```

The three lines are unconditional because `LoadCredential=` fails a unit when its
source file is missing, and there is no optional form. Creating them empty is
what buys the graceful version.

**It turns the login off, deliberately.** The app refuses to bind a reachable
address without a password — this page is a map of the fleet, which is the
document you would want first — and the unit sets `DASH_ALLOW_NO_AUTH=1` because
the deployment it came from reaches it over a tailnet, where the interface is the
gate. Bind something strangers can reach and you need to put that back.

**On NixOS a system install cannot work**, since `/etc/systemd/system` is a
read-only store symlink. `install.sh` says so and offers `--user`, or
`--unit-dir /run/systemd/system --no-enable` for a real system service that lasts
until reboot. That is how the system path here was tested.

`uninstall.sh` takes it back, and keeps the credentials unless you type `delete`.

### The agents are not installed by this

`install.sh` deploys the page, not the things it reads. Each host still needs a
`fleet-status` agent answering on `:8081`, and that is currently a NixOS module
in `modules/system/services/fleet-status/` — so on a host that is not NixOS,
this draws three unreachable cards. Most of that collector is plain systemd and
`/proc`; only its `generation()` and its two readers under `/run/secrets` know
what NixOS is.

## Running it from a checkout

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

| `DASH_PORKBUN_API_KEY` etc. | — | the account keys, when not run under systemd |
| `DASH_ALLOW_NO_AUTH` | — | bind a reachable address with no password, on purpose |

Under systemd every credential arrives through `LoadCredential=` instead, from
files on a NixOS host by way of sops, and from `--creds-dir` otherwise. Binding
anything but loopback without a password is refused unless `DASH_ALLOW_NO_AUTH`
says it was meant — see *Installing it*.

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
