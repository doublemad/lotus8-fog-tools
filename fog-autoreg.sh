#!/usr/bin/env bash
# LOTUS8: a NEW PC that is not in FOG registers itself and gets image IMAGE_ID deployed, using FOG's own Quick Registration.
# Only FOG settings are changed (no daemons, nothing persistent outside the FOG database). Run on the FOG server with sudo.
#   enable : sudo bash fog-autoreg.sh          (IMAGE_ID=1 by default)
#   disable: sudo REMOVE=1 bash fog-autoreg.sh
# Domain join for the new host comes from the trigger lotus8_host_ad_defaults (fog-ad-trigger.sh).
IMAGE_ID="${IMAGE_ID:-1}"
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v mysql >/dev/null || die "mysql client is required"
SET=/opt/fog/.fogsettings
get() { [ -r "$SET" ] && grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
if mysql -uroot fog -e "SELECT 1" >/dev/null 2>&1; then DB=(mysql -uroot fog)
else export MYSQL_PWD="$(get snmysqlpass)"; DB=(mysql -u"$(get snmysqluser)" -h"$(get snmysqlhost)" fog); fi
trap 'unset MYSQL_PWD' EXIT
q() { "${DB[@]}" -N -B -e "$1"; }
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to the FOG database"
setv() { q "UPDATE globalSettings SET settingValue='$2' WHERE settingKey='$1'"; }
val()  { q "SELECT settingValue FROM globalSettings WHERE settingKey='$1' LIMIT 1"; }
for k in FOG_QUICKREG_AUTOPOP FOG_QUICKREG_IMG_ID FOG_QUICKREG_IMG_WHEN_REG; do
    [ -n "$(q "SELECT 1 FROM globalSettings WHERE settingKey='$k'")" ] || die "setting $k not found - FOG version differs. Nothing changed."
done

if [ "${REMOVE:-0}" = "1" ]; then
    setv FOG_QUICKREG_AUTOPOP 0; setv FOG_QUICKREG_IMG_WHEN_REG 0
    echo "Auto registration + deploy switched OFF."; exit 0
fi

IMG=$(q "SELECT imageName FROM images WHERE imageID='$IMAGE_ID' LIMIT 1")
[ -n "$IMG" ] || die "image id $IMAGE_ID does not exist (FOG > Image Management)"
DOM=$(val FOG_AD_DEFAULT_DOMAINNAME)
TRG=$(q "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='fog' AND trigger_name='lotus8_host_ad_defaults'")
echo "Image to deploy : #$IMAGE_ID $IMG"
echo "Domain for new  : ${DOM:-<AD defaults empty>}  (trigger installed: $([ "$TRG" = 1 ] && echo yes || echo NO - run fog-ad-trigger.sh))"
echo
echo "After this, every PC that registers through the FOG PXE menu is registered automatically and its disk is ERASED and re-imaged."
printf 'Type YES to enable: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

setv FOG_REGISTRATION_ENABLED 1
setv FOG_QUICKREG_AUTOPOP 1
setv FOG_QUICKREG_IMG_ID "$IMAGE_ID"
setv FOG_QUICKREG_IMG_WHEN_REG 1
echo
echo "AUTOPOP=$(val FOG_QUICKREG_AUTOPOP)  IMG_ID=$(val FOG_QUICKREG_IMG_ID)  IMG_WHEN_REG=$(val FOG_QUICKREG_IMG_WHEN_REG)  REGISTRATION_ENABLED=$(val FOG_REGISTRATION_ENABLED)"
echo "Name for new hosts: $(val FOG_QUICKREG_SYS_NAME)$(val FOG_QUICKREG_SYS_NUMBER)  (FOG settings > Quick Registration)"
echo
echo "PXE menu items for NEW (unregistered) PCs:"
T=$(q "SELECT table_name FROM information_schema.tables WHERE table_schema='fog' AND table_name LIKE 'pxeMenu%' LIMIT 1")
[ -n "$T" ] && "${DB[@]}" -t -e "SELECT * FROM $T WHERE pxeName LIKE '%reg%'" 2>/dev/null | cut -c1-200
echo "Disable any time: sudo REMOVE=1 bash fog-autoreg.sh"
