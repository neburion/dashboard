#!/bin/sh
# Wires this checkout into a running system, with systemd and nothing else.
# Idempotent: run it again after `git pull` and it rewrites the unit, reloads it
# and restarts the service.
#
#   ./install.sh --agents pod042,home-server,personal-server
#                                    system service on 0.0.0.0:8779. Needs root.
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
# --agents is required, because there is no sensible default for which machines
# are yours and the app exits without it.
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
# front of the app, give it a password, or install the fleet-status agents this
# polls. Without an agent answering on each host there is nothing to draw.
set -eu

SELF=$(readlink -f -- "$0")
ROOT=$(dirname -- "$SELF")

mode=system
host=
port=8779
agents=
agentport=8081
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
        --agents)      agents=${2:?--agents needs a value}; shift ;;
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
        -h|--help)     sed -n '2,33p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

# ── 0. the things that have to be true first ────────────────────────────────
if [ -z "$agents" ]; then
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

echo "dashboard → $mode service, $host:$port"
echo "  checkout   $ROOT"
if [ "$code" != "$ROOT" ]; then
    echo "  code       $code (copied from the checkout)"
else
    echo "  code       $ROOT (in place)"
fi
echo "  python     $python"
echo "  agents     $agents on :$agentport"
echo "  creds      $credsdir"
echo "  units      $unitdir"

# ── 2. the service user ─────────────────────────────────────────────────────
# No shell and no home: it exists to be a uid, and a login for it would be a way
# in that nothing needs.
if [ "$mode" = system ] && [ "$dryrun" = no ]; then
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
payload="app.py ui.html"

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
if [ "$mode" = system ] && [ "$dryrun" = no ]; then
    if ! $sudo -u "$svcuser" test -r "$code/app.py"; then
        echo "install.sh: $svcuser cannot read $code/app.py" >&2
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

if [ "$dryrun" = no ]; then
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
    -e "s|@HOST@|$host|g" \
    -e "s|@PORT@|$port|g" \
    -e "s|@TARGET@|$target|g" \
    -e "s|@USERDIRECTIVE@|$userdirective|g" \
    "$ROOT/systemd/dashboard.service.in" | $sudo tee "$unitdir/dashboard.service" >/dev/null
echo "  wrote      $unitdir/dashboard.service"

# ── 6. hand it to systemd ───────────────────────────────────────────────────
if [ "$dryrun" = yes ]; then
    echo
    cat "$unitdir/dashboard.service"
    echo
    echo "dry run: $unitdir holds the unit, nothing else changed"
    exit 0
fi

$ctl daemon-reload

if [ "$enable" = no ]; then
    echo
    echo "unit written, nothing started (--no-enable). When you want it:"
    echo "  $ctl enable --now dashboard.service"
else
    $ctl enable --now dashboard.service
    echo
    $ctl --no-pager --lines=0 status dashboard.service | sed -n '1,4p' | sed 's/^/  /' || true
fi

echo
echo "  http://$host:$port"
if [ "$mode" = system ]; then
    echo "  logs:    journalctl -u dashboard -f"
else
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
