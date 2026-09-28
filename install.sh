#!/bin/sh
# Wires this checkout into a running system, with systemd and nothing else.
# Idempotent: run it again after `git pull` and it rewrites the unit, reloads it
# and restarts the service.
#
#   ./install.sh --agents pod042,home-server,personal-server
#                                    the page: system service on 0.0.0.0:8779.
#   ./install.sh --agent             the agent this polls, on THIS host: a root
#                                    timer taking a reading every 30s and an
#                                    unprivileged server handing it out on :8081.
#                                    Every host in the fleet needs one; only the
#                                    machine showing the page needs the page.
#   ./install.sh --agents pod042 --user
#                                    user service on 127.0.0.1:8779. No root.
#   ./install.sh --agents … --port 8779 --agent-port 8081
#   ./install.sh --agents … --zone azuresalt.app --cf-account <id>
#   ./install.sh --agents … --prefix /srv/dashboard
#   ./install.sh --agents … --in-place    run from this checkout, not a copy
#   ./install.sh --agents … --unit-dir DIR
#   ./install.sh --agents … --no-enable
#   ./install.sh --agents … --dry-run     print the unit, touch nothing
#
# --agents is required for the page, because there is no sensible default for
# which machines are yours and the app exits without it. --agent takes none of
# that: an agent reports on the box it is running on and knows about no others.
#
# A system install COPIES the code to --prefix (/opt/dashboard by default) rather
# than running it out of the checkout, because a checkout usually lives in a home
# directory and a home directory is usually mode 0700 — which no systemd
# hardening setting can talk its way past. The service runs as its own user, and
# that user has to read app.py. A user install runs in place, because there the
# reader owns the files.
#
# Three credentials are read from files under --creds-dir. install.sh creates the
# directory and the three empty files; you fill them in. Empty reads as absent
# and the accounts panel says "not configured", so the service starts either way.
#
# What it does NOT do: install python3, open a firewall port, put anything in
# front of either service, or give the page a password. The agent listens on
# 0.0.0.0:8081 and expects the host firewall to admit only the tailnet — on NixOS
# that rule is in the module; anywhere else it is yours to add, and until you do
# the port is open to whatever can route to the box.
set -eu

SELF=$(readlink -f -- "$0")
ROOT=$(dirname -- "$SELF")

mode=system
what=page
host=
port=8779
agents=
agentport=8081
probes=
syncuser=
claudehome=
secretsdir=/run/secrets
agentbind=0.0.0.0
zone=azuresalt.app
cfaccount=
python=
prefix=
credsdir=
unitdir=
enable=yes
inplace=no
dryrun=no

while [ $# -gt 0 ]; do
    case "$1" in
        --user)        mode=user ;;
        --system)      mode=system ;;
        --agent)       what=agent ;;
        --agents)      agents=${2:?--agents needs a value}; shift ;;
        --probes)      probes=${2:?--probes needs a value}; shift ;;
        --sync-user)   syncuser=${2:?--sync-user needs a value}; shift ;;
        --claude-home) claudehome=${2:?--claude-home needs a value}; shift ;;
        --secrets-dir) secretsdir=${2:?--secrets-dir needs a value}; shift ;;
        --agent-bind)  agentbind=${2:?--agent-bind needs a value}; shift ;;
        --host)        host=${2:?--host needs a value}; shift ;;
        --port)        port=${2:?--port needs a value}; shift ;;
        --agent-port)  agentport=${2:?--agent-port needs a value}; shift ;;
        --zone)        zone=${2:?--zone needs a value}; shift ;;
        --cf-account)  cfaccount=${2:?--cf-account needs a value}; shift ;;
        --python)      python=${2:?--python needs a value}; shift ;;
        --prefix)      prefix=${2:?--prefix needs a value}; shift ;;
        --creds-dir)   credsdir=${2:?--creds-dir needs a value}; shift ;;
        --unit-dir)    unitdir=${2:?--unit-dir needs a value}; shift ;;
        --in-place)    inplace=yes ;;
        --no-enable)   enable=no ;;
        --dry-run)     dryrun=yes; enable=no ;;
        -h|--help)     sed -n '2,42p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

# ── 0. the things that have to be true first ────────────────────────────────
# The agent is a root timer reading every filesystem and another user's units.
# There is no user-scope version of that, so there is no --user for it.
if [ "$what" = agent ] && [ "$mode" = user ]; then
    echo "install.sh: --agent has no user-scope version." >&2
    echo "  It reads other users' units, every filesystem and syncthing's key," >&2
    echo "  which is privilege a user unit does not have. Run it with sudo." >&2
    exit 2
fi

if [ "$what" = agent ] && [ -n "$agents" ]; then
    echo "install.sh: --agent and --agents are different things, and not both." >&2
    echo "  --agent installs the collector on this host. --agents tells the page" >&2
    echo "  which hosts to poll. Run the two separately." >&2
    exit 2
fi

if [ "$what" = page ] && [ -z "$agents" ]; then
    echo "install.sh: --agents is required, e.g." >&2
    echo "  ./install.sh --agents pod042,home-server,personal-server" >&2
    echo "Each name has to resolve and answer on :$agentport — the fleet-status" >&2
    echo "agent, which this does not install." >&2
    exit 2
fi

if [ -z "$python" ]; then
    python=$(command -v python3 || true)
fi
[ -n "$python" ] || { echo "install.sh: no python3 on PATH; pass --python" >&2; exit 1; }
"$python" - <<'PY' || { echo "install.sh: that python3 is too old" >&2; exit 1; }
import sys
assert sys.version_info >= (3, 9), f"python 3.9+ required, this is {sys.version.split()[0]}"
PY

if [ "$what" = agent ]; then
    port=$agentport
    host=$agentbind
fi

for n in "$port" "$agentport"; do
    case "$n" in
        ''|*[!0-9]*) echo "install.sh: ports must be numbers, got '$n'" >&2; exit 2 ;;
    esac
done

# ── 1. what the two modes differ on ─────────────────────────────────────────
if [ "$mode" = system ]; then
    if [ "$dryrun" = yes ] || [ "$(id -u)" = 0 ]; then
        sudo=
    elif command -v sudo >/dev/null 2>&1; then
        sudo=sudo
    else
        echo "install.sh: system mode needs root or sudo; or use --user" >&2
        exit 1
    fi
    : "${unitdir:=/etc/systemd/system}"
    : "${prefix:=/opt/dashboard}"
    : "${credsdir:=/etc/dashboard/credentials}"
    agentstate=/var/lib/fleet-status
    svcuser=dashboard
    # No Group=: useradd --user-group creates a primary group of the same name,
    # which is what systemd falls back to. A two-line value here would also be a
    # two-line sed replacement, which sed refuses.
    userdirective="User=$svcuser"
    target=multi-user.target
    ctl="$sudo systemctl"
    : "${host:=0.0.0.0}"
    if [ "$inplace" = yes ]; then
        code=$ROOT
        case "$ROOT" in
            /home/*|/root/*|/Users/*)
                protecthome="# read-only, not true: --in-place code lives under /home
ProtectHome=read-only" ;;
            *)  protecthome="ProtectHome=true" ;;
        esac
    else
        code=$prefix
        protecthome="ProtectHome=true"
    fi
else
    sudo=
    : "${unitdir:=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    : "${credsdir:=${XDG_CONFIG_HOME:-$HOME/.config}/dashboard/credentials}"
    agentstate=/var/lib/fleet-status
    svcuser=
    code=$ROOT
    userdirective="# no User=: a user unit already runs as you"
    # ProtectHome would hide both the checkout and the credentials, which in a
    # user install both live under $HOME by definition.
    protecthome="# ProtectHome: omitted, a user unit lives under \$HOME"
    target=default.target
    ctl="systemctl --user"
    : "${host:=127.0.0.1}"
fi

# Everything below is pasted into a sed s||| command, so a value carrying the
# delimiter or a newline would corrupt the unit rather than fail loudly.
for v in "$code" "$python" "$credsdir" "$agents" "$zone" "$cfaccount" "$host" "$port"; do
    case "$v" in
        *"|"*|*"
"*) echo "install.sh: '$v' contains | or a newline, which the unit templating cannot carry" >&2
    exit 1 ;;
    esac
done

if [ "$dryrun" = yes ]; then
    sudo=
    unitdir=$(mktemp -d)
    echo "dashboard → DRY RUN, nothing outside $unitdir is written"
fi

if [ "$what" = agent ]; then
    echo "fleet-status → agent on this host, $host:$port"
else
    echo "dashboard → $mode service, $host:$port"
fi
echo "  checkout   $ROOT"
if [ "$code" != "$ROOT" ]; then
    echo "  code       $code (copied from the checkout)"
else
    echo "  code       $ROOT (in place)"
fi
echo "  python     $python"
if [ "$what" = agent ]; then
    echo "  reading    $agentstate/status.json every 30s"
    [ -n "$probes" ] && echo "  probes     $probes" || true
    echo "  secrets    $secretsdir (listed by name only, never read)"
else
    echo "  agents     $agents on :$agentport"
    echo "  creds      $credsdir"
fi
echo "  units      $unitdir"

# ── 2. the service user ─────────────────────────────────────────────────────
# No shell and no home: it exists to be a uid, and a login for it would be a way
# in that nothing needs.
if [ "$what" = page ] && [ "$mode" = system ] && [ "$dryrun" = no ]; then
    if getent passwd "$svcuser" >/dev/null 2>&1; then
        echo "  user       $svcuser exists"
    else
        $sudo useradd --system --no-create-home --home-dir /nonexistent \
                      --shell /usr/sbin/nologin --user-group "$svcuser" \
            || $sudo useradd --system --no-create-home --home-dir /nonexistent \
                      --shell /sbin/nologin --user-group "$svcuser"
        echo "  user       $svcuser created"
    fi
fi

# ── 3. the code the service runs ────────────────────────────────────────────
# Named rather than `cp -a .`, so what lands in a system directory is a decision
# and not whatever happened to be in the working tree.
payload="app.py ui.html agent"

if [ "$code" != "$ROOT" ] && [ "$dryrun" = no ]; then
    $sudo mkdir -p "$code"
    for item in $payload; do
        if [ -e "$ROOT/$item" ]; then
            $sudo rm -rf "$code/$item"
            $sudo cp -R "$ROOT/$item" "$code/$item"
        else
            echo "install.sh: $ROOT/$item is missing from this checkout" >&2
            exit 1
        fi
    done
    $sudo chown -R root:root "$code"
    $sudo chmod -R a+rX "$code"
    echo "  installed  $(printf '%s' "$payload" | wc -w) items → $code"
fi

# PrivateTmp=true gives the unit its own empty /tmp, so code living under /tmp is
# not merely unreadable to it but absent — `No such file or directory` for a file
# that is plainly there.
case "$code" in
    /tmp/*|/var/tmp/*)
        echo "install.sh: $code is under /tmp." >&2
        echo "  The unit sets PrivateTmp=true, so the service gets its own empty" >&2
        echo "  /tmp and would not find this code at all. Put the checkout" >&2
        echo "  somewhere permanent, or drop --in-place so it installs to a prefix." >&2
        exit 1 ;;
esac

# A home directory at 0700 is the common way this fails, and it fails as a
# restart loop three seconds after a deploy rather than here.
if [ "$what" = agent ]; then
    reader=nobody
    probe_file=$code/agent/serve.py
else
    reader=$svcuser
    probe_file=$code/app.py
fi

if [ "$mode" = system ] && [ "$dryrun" = no ] && getent passwd "$reader" >/dev/null 2>&1; then
    if ! $sudo -u "$reader" test -r "$probe_file"; then
        echo "install.sh: $reader cannot read $probe_file" >&2
        echo "  Every parent directory has to be traversable by that user." >&2
        case "$code" in
            /home/*|/root/*|/Users/*)
                echo "  $code is under a home directory, which is usually mode 0700." >&2
                echo "  Drop --in-place and let it install to $prefix instead." >&2 ;;
            *)  echo "  Check the modes on the path to $code." >&2 ;;
        esac
        exit 1
    fi
fi

# ── 4. the credentials ──────────────────────────────────────────────────────
# Created empty rather than left absent: LoadCredential= fails a unit when its
# source file is missing, while an empty one reads as absent to the app and the
# accounts panel reports "not configured". So the unit starts, and filling a key
# in later is a write and a restart rather than another install.
secrets="porkbun-api-key porkbun-secret-key cloudflare-token"
missing=

if [ "$what" = page ] && [ "$dryrun" = no ]; then
    $sudo mkdir -p "$credsdir"
    $sudo chmod 0700 "$credsdir"
    if [ "$mode" = system ]; then
        $sudo chown root:root "$credsdir"
    fi
    for sname in $secrets; do
        if ! $sudo test -e "$credsdir/$sname"; then
            $sudo touch "$credsdir/$sname"
            $sudo chmod 0600 "$credsdir/$sname"
        fi
        # `test -s` rather than measuring it: a `$sudo wc -c < file` reads the
        # file with the *calling* shell's redirection, which cannot open 0600
        # root, and then the size comparison silently gets an empty string.
        if ! $sudo test -s "$credsdir/$sname"; then
            missing="$missing $sname"
        fi
    done
fi

# ── 5. the unit, with this checkout's real paths in it ──────────────────────
# @PROTECTHOME@ is the one placeholder whose value can be two lines, so it goes
# in with sed's `r` rather than `s|||`, which cannot carry a newline.
phfile=$(mktemp)
printf '%s\n' "$protecthome" > "$phfile"
trap 'rm -f "$phfile"' EXIT INT TERM

if ! $sudo mkdir -p "$unitdir" 2>/dev/null || ! $sudo test -w "$unitdir"; then
    echo "install.sh: $unitdir is not writable." >&2
    if [ -e /etc/NIXOS ]; then
        echo "  This is NixOS, which owns that directory as a read-only store" >&2
        echo "  symlink. A system install belongs on a distro with a writable" >&2
        echo "  /etc — Arch, Fedora, Debian. Here, either:" >&2
        echo "    ./install.sh --agents … --user" >&2
        echo "    ./install.sh --agents … --unit-dir /run/systemd/system --no-enable" >&2
    else
        echo "  Pass --unit-dir DIR, or --user for a service that needs no root." >&2
    fi
    exit 1
fi

fill() {
    sed -e "/@PROTECTHOME@/{
                r $phfile
                d
            }" \
        -e "s|@ROOT@|$code|g" \
        -e "s|@PYTHON@|$python|g" \
        -e "s|@CREDS@|$credsdir|g" \
        -e "s|@AGENTS@|$agents|g" \
        -e "s|@AGENTPORT@|$agentport|g" \
        -e "s|@ZONE@|$zone|g" \
        -e "s|@CFACCOUNT@|$cfaccount|g" \
        -e "s|@STATE@|$agentstate|g" \
        -e "s|@PROBES@|$probes|g" \
        -e "s|@SYNCUSER@|$syncuser|g" \
        -e "s|@CLAUDEHOME@|$claudehome|g" \
        -e "s|@SECRETSDIR@|$secretsdir|g" \
        -e "s|@BIND@|$agentbind|g" \
        -e "s|@HOST@|$host|g" \
        -e "s|@PORT@|$port|g" \
        -e "s|@TARGET@|$target|g" \
        -e "s|@USERDIRECTIVE@|$userdirective|g" \
        "$1"
}

if [ "$what" = agent ]; then
    services="fleet-status-collect.service fleet-status.service"
    timers="fleet-status-collect.timer"
    # The timer drives the collector, so the collector itself is not enabled —
    # enabling a oneshot with no [Install] would be a unit that wants to run at
    # boot and then never again.
    enableunits="fleet-status.service fleet-status-collect.timer"
else
    services="dashboard.service"
    timers=""
    enableunits="dashboard.service"
fi

for u in $services; do
    fill "$ROOT/systemd/$u.in" | $sudo tee "$unitdir/$u" >/dev/null
    echo "  wrote      $unitdir/$u"
done
for t in $timers; do
    $sudo cp "$ROOT/systemd/$t" "$unitdir/$t"
    echo "  wrote      $unitdir/$t"
done

# ── 6. hand it to systemd ───────────────────────────────────────────────────
if [ "$dryrun" = yes ]; then
    echo
    for f in "$unitdir"/*; do
        echo "─── ${f##*/} ───"
        cat "$f"
        echo
    done
    echo "dry run: $unitdir holds the units, nothing else changed"
    exit 0
fi

$ctl daemon-reload

if [ "$enable" = no ]; then
    echo
    echo "units written, nothing started (--no-enable). When you want it:"
    echo "  $ctl enable --now $enableunits"
else
    # shellcheck disable=SC2086
    $ctl enable --now $enableunits
    echo
    for u in $enableunits; do
        $ctl --no-pager --lines=0 status "$u" | sed -n '1,3p' | sed 's/^/  /' || true
    done
fi

echo
if [ "$what" = agent ]; then
    echo "  http://$(hostname -s 2>/dev/null || echo this-host):$port/status.json"
    echo "  logs:    journalctl -u fleet-status-collect -u fleet-status -f"
    echo "  the first reading lands 30s after boot, or now:"
    echo "    $ctl start fleet-status-collect.service"
    echo "  the firewall is yours: this listens on $agentbind:$port and admits"
    echo "  whatever can route to it until a rule says otherwise."
elif [ "$mode" = system ]; then
    echo "  http://$host:$port"
    echo "  logs:    journalctl -u dashboard -f"
else
    echo "  http://$host:$port"
    echo "  logs:    journalctl --user -u dashboard -f"
fi
if [ -n "$missing" ]; then
    echo
    echo "  the accounts panel will read \"not configured\" until these are filled:"
    for sname in $missing; do
        echo "    $credsdir/$sname"
    done
    echo "  write one with, e.g."
    echo "    printf %s 'THE-KEY' | ${sudo:+sudo }tee $credsdir/porkbun-api-key >/dev/null"
    echo "  then: $ctl restart dashboard"
fi
