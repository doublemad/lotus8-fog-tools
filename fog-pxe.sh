#!/usr/bin/env bash
# LOTUS8: leaves ONE PXE menu (FOG's own) with the LOTUS8 background. Run once on the FOG server with sudo.
#  1) /tftpboot/default.ipxe: the LOTUS8 wrapper (extra 'dhcp' + chain to /lotus8-pxe/menu.ipxe) is replaced by FOG's standard loader
#     (the old file is kept as default.ipxe.lotus8-wrapper.bak; the /lotus8-pxe folder itself is not touched)
#  2) the background picture is installed (fog-bg.sh)
#   apply  : sudo bash fog-pxe.sh
#   restore: sudo REMOVE=1 bash fog-pxe.sh     (brings the wrapper back; the background has its own REMOVE in fog-bg.sh)
BG="https://raw.githubusercontent.com/doublemad/lotus8-fog-tools/a7644ffb64b06a3dd125e48ff8013f18af9a1df8/fog-bg.sh"
D=/tftpboot/default.ipxe; BAK=/tftpboot/default.ipxe.lotus8-wrapper.bak
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -d /tftpboot ] || die "/tftpboot not found - is this the FOG server?"

if [ "${REMOVE:-0}" = "1" ]; then
    [ -f "$BAK" ] || die "no backup $BAK, nothing to restore"
    cp -a "$BAK" "$D" && echo "Restored the LOTUS8 wrapper: $D"; exit 0
fi

# FOG webroot/address come from FOG's own settings (not guessed)
IP=$(grep -m1 '^ipaddress=' /opt/fog/.fogsettings 2>/dev/null | cut -d= -f2- | tr -d "'\"")
WR=$(grep -m1 '^webroot=' /opt/fog/.fogsettings 2>/dev/null | cut -d= -f2- | tr -d "'\"")
IP="${IP:-192.168.8.3}"; WR="${WR:-/fog}"; WR="/${WR#/}"; WR="${WR%/}"
BOOT="http://$IP$WR/service/ipxe/boot.php"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BOOT?mac0=aa:bb:cc:dd:ee:ff")
[ "$code" = "200" ] || die "FOG boot.php answers HTTP $code at $BOOT - nothing changed"

[ -f "$BAK" ] || { [ -f "$D" ] && cp -a "$D" "$BAK" && echo "Kept the old file as $BAK"; }
cat > "$D.new" <<EOF
#!ipxe
cpuid --ext 29 && set arch x86_64 || set arch i386
params
param mac0 \${net0/mac}
param arch \${arch}
param platform \${platform}
param product \${product}
param manufacturer \${manufacturer}
param ipxever \${version}
param filename \${filename}
isset \${net1/mac} && param mac1 \${net1/mac} || goto bootme
isset \${net2/mac} && param mac2 \${net2/mac} || goto bootme
isset \${net3/mac} && param mac3 \${net3/mac} || goto bootme
:bootme
chain $BOOT##params
EOF
OWN=$(stat -c '%U:%G' /tftpboot 2>/dev/null || echo fogproject:root)
chown "$OWN" "$D.new"; chmod 644 "$D.new"; mv -f "$D.new" "$D"
echo "default.ipxe now loads FOG's menu directly: $BOOT"

# background picture
curl -fsSL "$BG" | bash || echo "WARN: background step failed (menu is fine, rerun fog-bg.sh)"
echo
echo "Done. Next PXE boot shows ONE menu (FOG) with the LOTUS8 picture. Back to the wrapper: sudo REMOVE=1 bash fog-pxe.sh"
