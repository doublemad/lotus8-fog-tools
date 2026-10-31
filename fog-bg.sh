#!/usr/bin/env bash
# LOTUS8: sets the FOG PXE menu background picture. Run once on the FOG server with sudo.
#   install: sudo bash fog-bg.sh          (downloads the picture from GitHub, checks it, keeps the old one as <file>.orig)
#   restore: sudo REMOVE=1 bash fog-bg.sh
# Only one file on the server is replaced; no database or service is touched.
URL="https://raw.githubusercontent.com/doublemad/lotus8-fog-tools/4c9631a1b8aaed821c78148f84f0ac2c45cb313f/fog-bg.png"
SHA="c7974bb7871e55cbc86ea8f284af73cbb98cc90d55bb592644d6ab7e1fc851c1"
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v curl >/dev/null || die "curl is required"
SET=/opt/fog/.fogsettings
get() { [ -r "$SET" ] && grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
F=""
if command -v mysql >/dev/null; then
    if mysql -uroot fog -e "SELECT 1" >/dev/null 2>&1; then
        F=$(mysql -uroot fog -N -B -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_IPXE_BG_FILE' LIMIT 1")
    else
        F=$(MYSQL_PWD="$(get snmysqlpass)" mysql -u"$(get snmysqluser)" -h"$(get snmysqlhost)" fog -N -B -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_IPXE_BG_FILE' LIMIT 1" 2>/dev/null)
    fi
fi
[ -n "$F" ] || F=bg.png
# FOG stores just a file name here; the picture is served from the iPXE service folder
case "$F" in /*) ;; *) F="/var/www/fog/service/ipxe/$F" ;; esac
[ -d "$(dirname "$F")" ] || die "folder of $F does not exist - is this the FOG server?"

if [ "${REMOVE:-0}" = "1" ]; then
    [ -f "$F.orig" ] || die "no backup $F.orig, nothing to restore"
    cp -a "$F.orig" "$F" && echo "Restored the original background: $F"; exit 0
fi

T=$(mktemp /tmp/.fogbg.XXXXXX); trap 'rm -f "$T"' EXIT
curl -fsSL "$URL" -o "$T" || die "download failed"
[ "$(sha256sum "$T" | cut -d' ' -f1)" = "$SHA" ] || die "checksum mismatch, file not installed"
head -c 8 "$T" | od -An -tx1 | tr -d ' \n' | grep -q '^89504e470d0a1a0a' || die "not a PNG, file not installed"

[ -f "$F" ] && [ ! -f "$F.orig" ] && cp -a "$F" "$F.orig" && echo "Old background saved: $F.orig"
OWN=$(stat -c '%U:%G' "$F" 2>/dev/null || echo fogproject:www-data)
install -o "${OWN%%:*}" -g "${OWN##*:}" -m 644 "$T" "$F" || die "could not write $F"
echo "Background installed: $(ls -la "$F")"
echo "It shows on the next PXE boot. Restore:  sudo REMOVE=1 bash fog-bg.sh"
