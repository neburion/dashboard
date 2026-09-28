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

A poller and a page. Every host in the fleet runs the `fleet-status` agent in
`agent/` — a root timer that writes a JSON reading every 30s, and an
unprivileged server that hands that one file out on `:8081` over the tailnet.
This dials all three, works out what is wrong, and draws it.

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

### The agent, on every host

`agent/collect.py` and `agent/serve.py` live here, and `install.sh --agent`
deploys them on whichever box you run it on:

```sh
sudo ./install.sh --agent
sudo ./install.sh --agent --probes media-tracker=8778 --sync-user neburion
```

Every host needs one; only the host showing the page needs the page. It installs
a root timer taking a reading every 30s and an unprivileged `DynamicUser` server
handing that one file out on `:8081` — two units, because the numbers worth
having need privilege and the thing behind a socket should not have it.

`--agent` has no `--user` form. It reads other users' units, every filesystem and
syncthing's API key, and a user unit has none of that.

**It does not open a firewall port.** The server binds `0.0.0.0:8081` and admits
whatever can route to the box until a rule says otherwise. On NixOS that rule is
in the module; anywhere else it is yours to write.

| `--agent` flag | |
|---|---|
| `--agent-port` / `--agent-bind` | where it listens; `8081` on `0.0.0.0` |
| `--probes name=port,…` | local services to knock on. A unit can be `active` while the thing inside it has stopped answering, and that gap is the whole reason |
| `--sync-user` | whose syncthing to report on. Named, not discovered: the API key is in that user's `config.xml` |
| `--claude-home` | whose Claude Code transcripts to total |
| `--secrets-dir` | where this host keeps decrypted credentials, `/run/secrets` by default. Listed **by name only** and never read |

`FS_PROBES` takes JSON *or* `name=port,name=port`, because systemd strips quotes
out of an `Environment=` value and JSON cannot be written without them. Nix
generates its unit and escapes them properly, so it passes JSON; a hand-written
unit passes the pairs and never has to get the escaping right.

#### What a reboot means, three ways

The only reading in here that cannot be taken the same way twice, because it is a
question about how the OS is assembled. `generation.kind` says which answer you
are looking at, and the page falls back to `version` where there is no generation
number to show:

| kind | how it decides a reboot is owed |
|---|---|
| `nixos` | `/run/booted-system` vs `/run/current-system`, comparing only kernel, kernel-modules, initrd and systemd. Comparing the whole thing would flag a reboot after every rebuild, including ones that only moved a config file, and a warning that is always on is one nobody reads |
| `bootc` | a staged deployment in `bootc status`, which is one reboot from being the running one. **Untested against a real bootc host** — read defensively, so a surprise in that JSON records an error for this section rather than costing the reading |
| `packaged` | `/usr/lib/modules/$(uname -r)` is gone, so the package manager replaced the kernel under the running one. The check every Arch reboot hint makes, and it reads the same on Debian and Fedora |

The NixOS module in
[neburion/NixOS](https://github.com/neburion/NixOS) still exists and is still how
that fleet runs this, but it reads these two files out of `inputs.dashboard`
rather than keeping its own copies — one collector, not two drifting ones.

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
