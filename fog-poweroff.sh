#!/usr/bin/env bash
# LOTUS8: every PC shuts down every day at HOUR:MIN (default 21:00) through FOG's own Power Management (cron on the FOG client).
# Run once on the FOG server with sudo. Only database rows are added; nothing runs on the server afterwards.
#  - adds a daily 'shutdown' schedule to every host (except pending hosts and hosts named like *DC*; EXCLUDE='name1,name2' for more)
#  - a trigger gives the same schedule to every NEW host
#  - makes sure the Power Management client module is switched on
#   apply : sudo bash fog-poweroff.sh           vars: HOUR=21 MIN=0 EXCLUDE=
#   remove: sudo REMOVE=1 bash fog-poweroff.sh  (deletes these schedules and the trigger)
# Needs the FOG client on the PC (service FOGService running) and the PC switched on at that time. The PC clock is the reference.
HOUR="${HOUR:-21}"; MIN="${MIN:-0}"; EXCLUDE="${EXCLUDE:-}"
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v mysql >/dev/null || die "mysql client is required"
case "$HOUR$MIN" in *[!0-9]*|"") die "HOUR and MIN must be numbers";; esac
[ "$HOUR" -le 23 ] && [ "$MIN" -le 59 ] || die "HOUR 0-23, MIN 0-59"
SET=/opt/fog/.fogsettings
get() { [ -r "$SET" ] && grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
if mysql -uroot fog -e "SELECT 1" >/dev/null 2>&1; then DB=(mysql -uroot fog)
else export MYSQL_PWD="$(get snmysqlpass)"; DB=(mysql -u"$(get snmysqluser)" -h"$(get snmysqlhost)" fog); fi
trap 'unset MYSQL_PWD' EXIT
q() { "${DB[@]}" -N -B -e "$1"; }
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to the FOG database"

if [ "${REMOVE:-0}" = "1" ]; then
    q "DROP TRIGGER IF EXISTS lotus8_host_poweroff"
    q "DELETE FROM powerManagement WHERE pmAction='shutdown' AND pmOndemand='0' AND pmHour='$HOUR' AND pmMin='$MIN' AND pmDom='*' AND pmMonth='*' AND pmDow='*'"
    echo "Removed: daily $HOUR:$(printf %02d "$MIN") shutdown schedules and the new-host trigger."; exit 0
fi

for c in pmHostID pmMin pmHour pmDom pmMonth pmDow pmAction pmOndemand; do
    q "SELECT $c FROM powerManagement LIMIT 1" >/dev/null 2>&1 || die "powerManagement.$c missing - FOG schema differs. Nothing changed."
done

# hosts to include
EXC=""; IFS=',' read -ra E <<< "$EXCLUDE"; for n in "${E[@]}"; do n=$(printf %s "$n" | tr -d "'\"; "); [ -n "$n" ] && EXC="$EXC AND hostName<>'$n'"; done
WHERE="hostPending='0' AND hostName NOT LIKE '%DC%'$EXC"
HOSTS=$(q "SELECT hostID,hostName FROM hosts WHERE $WHERE ORDER BY hostID")
SKIP=$(q "SELECT hostName FROM hosts WHERE NOT ($WHERE) ORDER BY hostID" | paste -sd, -)
[ -n "$HOSTS" ] || die "no hosts to schedule"
T=$(printf '%02d:%02d' "$HOUR" "$MIN")
echo "=== LOTUS8: daily shutdown at $T ==="
echo "$HOSTS" | awk -F'\t' '{printf "  #%-4s %s\n",$1,$2}'
echo "Skipped: ${SKIP:-none}"
echo "New hosts get the same schedule automatically (trigger)."
printf 'Type YES to apply: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

q "INSERT IGNORE INTO powerManagement (pmHostID,pmMin,pmHour,pmDom,pmMonth,pmDow,pmAction,pmOndemand)
   SELECT hostID,'$MIN','$HOUR','*','*','*','shutdown','0' FROM hosts WHERE $WHERE"

"${DB[@]}" <<SQL || echo "WARN: trigger for new hosts could not be created (needs TRIGGER privilege). Existing hosts are done."
DROP TRIGGER IF EXISTS lotus8_host_poweroff;
DELIMITER \$\$
CREATE TRIGGER lotus8_host_poweroff AFTER INSERT ON hosts FOR EACH ROW
BEGIN
    IF NEW.hostName NOT LIKE '%DC%' THEN
        INSERT IGNORE INTO powerManagement (pmHostID,pmMin,pmHour,pmDom,pmMonth,pmDow,pmAction,pmOndemand)
        VALUES (NEW.hostID,'$MIN','$HOUR','*','*','*','shutdown','0');
    END IF;
END\$\$
DELIMITER ;
SQL

# make sure the client module is on (global switch + per-host state, only if FOG's own tables are as expected)
if [ -n "$(q "SELECT 1 FROM globalSettings WHERE settingKey='FOG_CLIENT_POWERMANAGEMENT_ENABLED'")" ]; then
    q "UPDATE globalSettings SET settingValue='1' WHERE settingKey='FOG_CLIENT_POWERMANAGEMENT_ENABLED'"; echo "Power Management client module: ON (global)"
else echo "WARN: FOG_CLIENT_POWERMANAGEMENT_ENABLED not found - check FOG Configuration > FOG Settings > FOG Client > Power Management"; fi
MID=$(q "SELECT id FROM modules WHERE shortName='powermanagement' LIMIT 1" 2>/dev/null)
if [ -n "$MID" ] && q "SELECT msState FROM moduleStatusByHost LIMIT 1" >/dev/null 2>&1; then
    q "UPDATE moduleStatusByHost m JOIN hosts h ON h.hostID=m.msHostID SET m.msState='1' WHERE m.msModuleID=$MID AND $WHERE" 2>/dev/null
    q "INSERT INTO moduleStatusByHost (msHostID,msModuleID,msState) SELECT hostID,$MID,'1' FROM hosts WHERE $WHERE AND hostID NOT IN (SELECT msHostID FROM moduleStatusByHost WHERE msModuleID=$MID)" 2>/dev/null
fi

echo
echo "Scheduled hosts: $(q "SELECT COUNT(*) FROM powerManagement WHERE pmAction='shutdown' AND pmOndemand='0' AND pmHour='$HOUR' AND pmMin='$MIN'")   trigger: $([ "$(q "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='fog' AND trigger_name='lotus8_host_poweroff'")" = 1 ] && echo active || echo MISSING)"
echo "Works on PCs with the FOG client running at $T. Undo: sudo REMOVE=1 bash fog-poweroff.sh"
