#!/usr/bin/env bash
# LOTUS8: every NEW host created in FOG automatically gets domain join (FOG's own Active Directory Defaults).
# Installs ONE database trigger on the FOG database. Run on the FOG server with sudo.
#   install : sudo bash fog-ad-trigger.sh
#   remove  : sudo REMOVE=1 bash fog-ad-trigger.sh
# The trigger only fills hosts that arrive WITHOUT their own AD settings, and only if the defaults exist. It never changes existing hosts.
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v mysql >/dev/null || die "mysql client is required"
SET=/opt/fog/.fogsettings
get() { [ -r "$SET" ] && grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }

# root over the local socket (Ubuntu MariaDB); fall back to the FOG user
if mysql -uroot fog -e "SELECT 1" >/dev/null 2>&1; then DB=(mysql -uroot fog)
else export MYSQL_PWD="$(get snmysqlpass)"; DB=(mysql -u"$(get snmysqluser)" -h"$(get snmysqlhost)" fog); fi
trap 'unset MYSQL_PWD' EXIT
"${DB[@]}" -e "SELECT 1" >/dev/null 2>&1 || die "cannot connect to the FOG database"

if [ "${REMOVE:-0}" = "1" ]; then
    "${DB[@]}" -e "DROP TRIGGER IF EXISTS lotus8_host_ad_defaults" || die "could not remove trigger"
    echo "Trigger removed. New hosts no longer get the domain automatically."; exit 0
fi

for c in hostUseAD hostADDomain hostADOU hostADUser hostADPass hostADPassLegacy; do
    "${DB[@]}" -e "SELECT $c FROM hosts LIMIT 1" >/dev/null 2>&1 || die "hosts.$c missing - FOG schema differs. Nothing changed."
done
DOM=$("${DB[@]}" -N -B -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_DOMAINNAME'")
ADU=$("${DB[@]}" -N -B -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_USER'")
[ -n "$DOM" ] && [ -n "$ADU" ] || echo "WARN: AD defaults are empty now (FOG Configuration > FOG Settings > Active Directory Defaults). The trigger stays inactive until you fill them."
echo "Domain from FOG defaults: ${DOM:-<empty>}   user: ${ADU:-<empty>}"
printf 'Install the trigger on the FOG database? Type YES: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

"${DB[@]}" <<'SQL' || die "trigger creation failed (needs TRIGGER privilege). Nothing else changed."
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

N=$("${DB[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='fog' AND trigger_name='lotus8_host_ad_defaults'")
[ "$N" = "1" ] || die "trigger was not created"
echo "Trigger lotus8_host_ad_defaults is active: every NEW host gets domain '${DOM:-<defaults>}' automatically."
echo "Remove any time:  sudo REMOVE=1 bash fog-ad-trigger.sh"
