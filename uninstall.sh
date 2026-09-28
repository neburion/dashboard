#!/bin/sh
# Takes back what install.sh did. The credentials stay unless you say otherwise —
# they are keys to a registrar and a Cloudflare account, and a cleanup script is
# not the place to lose them.
#
#   ./uninstall.sh                  stop, disable, remove the unit and the code
#   ./uninstall.sh --user           the user-scope install instead
#   ./uninstall.sh --purge-user     also remove the dashboard system user
#   ./uninstall.sh --purge-creds    also delete the credentials. Asks first.
#   ./uninstall.sh --prefix DIR / --creds-dir DIR / --unit-dir DIR
set -eu

SELF=$(readlink -f -- "$0")
mode=system
purgeuser=no
purgecreds=no
prefix=/opt/dashboard
credsdir=
unitdir=

while [ $# -gt 0 ]; do
    case "$1" in
        --user)        mode=user ;;
        --system)      mode=system ;;
        --purge-user)  purgeuser=yes ;;
        --purge-creds) purgecreds=yes ;;
        --prefix)      prefix=${2:?--prefix needs a value}; shift ;;
        --creds-dir)   credsdir=${2:?--creds-dir needs a value}; shift ;;
        --unit-dir)    unitdir=${2:?--unit-dir needs a value}; shift ;;
        -h|--help)     sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "uninstall.sh: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$mode" = system ]; then
    if [ "$(id -u)" = 0 ]; then sudo=; else sudo=sudo; fi
    : "${unitdir:=/etc/systemd/system}"
    : "${credsdir:=/etc/dashboard/credentials}"
    ctl="$sudo systemctl"
else
    sudo=
    : "${unitdir:=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    : "${credsdir:=${XDG_CONFIG_HOME:-$HOME/.config}/dashboard/credentials}"
    ctl="systemctl --user"
fi

echo "dashboard → removing the $mode install"

if [ -e "$unitdir/dashboard.service" ]; then
    $ctl disable --now dashboard.service >/dev/null 2>&1 || true
    $sudo rm -f "$unitdir/dashboard.service"
    echo "  removed    $unitdir/dashboard.service"
fi
$ctl daemon-reload
$ctl reset-failed >/dev/null 2>&1 || true

SELFDIR=$(dirname -- "$SELF")
if [ "$mode" = system ] && [ -d "$prefix" ] && [ "$prefix" != "$SELFDIR" ]; then
    $sudo rm -rf "$prefix"
    echo "  removed    $prefix (the installed copy of the code)"
fi

if [ "$purgeuser" = yes ] && [ "$mode" = system ]; then
    if getent passwd dashboard >/dev/null 2>&1; then
        $sudo userdel dashboard || true
        echo "  removed    user dashboard"
    fi
fi

if [ "$purgecreds" = yes ]; then
    echo
    echo "  about to delete $credsdir, which holds:"
    for f in porkbun-api-key porkbun-secret-key cloudflare-token; do
        if $sudo test -s "$credsdir/$f"; then
            echo "    $f  (has a value)"
        elif $sudo test -e "$credsdir/$f"; then
            echo "    $f  (empty)"
        fi
    done
    printf '  type "delete" to confirm: '
    read -r answer
    if [ "$answer" = delete ]; then
        $sudo rm -rf "$credsdir"
        # The directory install.sh made to hold it, if nothing else moved in.
        $sudo rmdir "$(dirname -- "$credsdir")" 2>/dev/null || true
        echo "  deleted    $credsdir"
    else
        echo "  kept       nothing deleted"
    fi
else
    echo
    echo "  kept       $credsdir (--purge-creds deletes it)"
    if [ "$mode" = system ] && [ "$purgeuser" = no ]; then
        echo "  kept       user dashboard (--purge-user removes it)"
    fi
fi
