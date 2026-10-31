#!/usr/bin/env bash
# LOTUS8: ONE script for the FOG server. Run once with sudo. Changes only the FOG database (settings, one trigger, one menu title).
#  1) Quick Registration: a NEW PC that is not in FOG registers itself and gets image IMAGE_ID deployed (disk is ERASED)
#  2) Trigger: every NEW host gets domain join + enforce from FOG's Active Directory Defaults
#  3) PXE menu: the Quick Registration item is shown as MENU_TITLE (only unregistered PCs see it)
#   enable : sudo bash fog-setup.sh            vars: IMAGE_ID=1  MENU_TITLE='NEW MANAGER PC SETUP'
#   disable: sudo REMOVE=1 bash fog-setup.sh   (turns auto registration off, drops the trigger, restores the menu title)
IMAGE_ID="${IMAGE_ID:-1}"
MENU_TITLE="${MENU_TITLE:-NEW MANAGER PC SETUP}"
ORIG_TITLE="Quick Registration and Inventory"
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

if [ "${REMOVE:-0}" = "1" ]; then
    setv FOG_QUICKREG_AUTOPOP 0; setv FOG_QUICKREG_IMG_WHEN_REG 0
    q "DROP TRIGGER IF EXISTS lotus8_host_ad_defaults"
    q "UPDATE pxeMenu SET pxeDesc='$ORIG_TITLE' WHERE pxeName='fog.reg'"
    echo "OFF: auto registration disabled, trigger dropped, menu title restored."; exit 0
fi

# ---- preflight: nothing is changed until every check passes ----
for k in FOG_QUICKREG_AUTOPOP FOG_QUICKREG_IMG_ID FOG_QUICKREG_IMG_WHEN_REG FOG_AD_DEFAULT_DOMAINNAME FOG_AD_DEFAULT_USER; do
    [ -n "$(q "SELECT 1 FROM globalSettings WHERE settingKey='$k'")" ] || die "setting $k not found - FOG version differs. Nothing changed."
done
for c in hostUseAD hostADDomain hostADOU hostADUser hostADPass hostADPassLegacy hostEnforce; do
    q "SELECT $c FROM hosts LIMIT 1" >/dev/null 2>&1 || die "hosts.$c missing - FOG schema differs. Nothing changed."
done
q "SELECT pxeDesc FROM pxeMenu WHERE pxeName='fog.reg' LIMIT 1" >/dev/null 2>&1 || die "pxeMenu/fog.reg not found. Nothing changed."
IMG=$(q "SELECT imageName FROM images WHERE imageID='$IMAGE_ID' LIMIT 1")
[ -n "$IMG" ] || die "image id $IMAGE_ID does not exist (FOG > Image Management). Nothing changed."
DOM=$(val FOG_AD_DEFAULT_DOMAINNAME); ADU=$(val FOG_AD_DEFAULT_USER)
[ -n "$DOM" ] && [ -n "$ADU" ] || echo "WARN: AD defaults are empty (FOG > FOG Settings > Active Directory Defaults). The trigger stays inactive until they are filled."

echo "=== LOTUS8 FOG setup ==="
echo "Image for new PCs : #$IMAGE_ID  $IMG   (the disk of every newly registered PC will be ERASED)"
echo "Domain for new PCs: ${DOM:-<empty>}  user ${ADU:-<empty>}  (+ enforce)"
echo "PXE menu title    : $MENU_TITLE"
printf 'Type YES to apply: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

# ---- 1. auto registration + image ----
setv FOG_REGISTRATION_ENABLED 1
setv FOG_QUICKREG_AUTOPOP 1
setv FOG_QUICKREG_IMG_ID "$IMAGE_ID"
setv FOG_QUICKREG_IMG_WHEN_REG 1

# ---- 2. domain trigger ----
"${DB[@]}" <<'SQL' || die "trigger creation failed (needs TRIGGER privilege). Settings above are already applied."
DROP TRIGGER IF EXISTS lotus8_host_ad_defaults;
DELIMITER $$
CREATE TRIGGER lotus8_host_ad_defaults BEFORE INSERT ON hosts FOR EACH ROW
BEGIN
    DECLARE d_dom TEXT DEFAULT '';
    DECLARE d_usr TEXT DEFAULT '';
    IF IFNULL(NEW.hostADDomain,'') = '' AND IFNULL(NEW.hostADUser,'') = '' THEN
        SELECT IFNULL(MAX(settingValue),'') INTO d_dom FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_DOMAINNAME';
        SELECT IFNULL(MAX(settingValue),'') INTO d_usr FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_USER';
        IF d_dom <> '' AND d_usr <> '' THEN
            SET NEW.hostUseAD = '1';
            SET NEW.hostEnforce = '1';
            SET NEW.hostADDomain = d_dom;
            SET NEW.hostADUser = d_usr;
            SET NEW.hostADOU = IFNULL((SELECT MAX(settingValue) FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_OU'),'');
            SET NEW.hostADPass = IFNULL((SELECT MAX(settingValue) FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_PASSWORD'),'');
            SET NEW.hostADPassLegacy = IFNULL((SELECT MAX(settingValue) FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_PASSWORD_LEGACY'),'');
        END IF;
    END IF;
END$$
DELIMITER ;
SQL

# ---- 3. menu title ----
q "UPDATE pxeMenu SET pxeDesc='$(printf %s "$MENU_TITLE" | sed "s/'/''/g")' WHERE pxeName='fog.reg'"

# ---- verify ----
echo
echo "Result:"
echo "  auto registration : AUTOPOP=$(val FOG_QUICKREG_AUTOPOP) IMG_ID=$(val FOG_QUICKREG_IMG_ID) IMG_WHEN_REG=$(val FOG_QUICKREG_IMG_WHEN_REG) REGISTRATION_ENABLED=$(val FOG_REGISTRATION_ENABLED)"
echo "  domain trigger    : $([ "$(q "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='fog' AND trigger_name='lotus8_host_ad_defaults'")" = 1 ] && echo active || echo MISSING)"
echo "  PXE menu item     : $(q "SELECT pxeDesc FROM pxeMenu WHERE pxeName='fog.reg'")"
echo "  next host name    : $(val FOG_QUICKREG_SYS_NAME)$(val FOG_QUICKREG_SYS_NUMBER)"
echo
echo "A new PC: PXE boot > pick '$MENU_TITLE' once > registers, joins the domain settings, image #$IMAGE_ID is deployed."
echo "Undo everything: sudo REMOVE=1 bash fog-setup.sh"
