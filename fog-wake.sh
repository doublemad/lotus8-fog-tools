#!/usr/bin/env bash
# LOTUS8: every PC is switched on every day at HOUR:MIN (default 08:00) by Wake-on-LAN, sent by the FOG server (FOGScheduler).
# Run once on the FOG server with sudo. Only database rows are added; nothing else is installed.
#  - adds a daily 'wol' schedule to every host (except pending hosts and hosts named like *DC*; EXCLUDE='name1,name2' for more)
#  - a trigger gives the same schedule to every NEW host
#   apply : sudo bash fog-wake.sh              vars: HOUR=8 MIN=0 DOW='*' (e.g. DOW='1-5' = Mon-Fri) EXCLUDE=
#   remove: sudo REMOVE=1 bash fog-wake.sh     (deletes these schedules and the trigger)
# The PC must allow wake-up: BIOS 'Wake on LAN' on + Windows network card 'Wake on Magic Packet' on (see fog-wake-pc.ps1).
HOUR="${HOUR:-8}"; MIN="${MIN:-0}"; DOW="${DOW:-*}"; EXCLUDE="${EXCLUDE:-}"
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v mysql >/dev/null || die "mysql client is required"
case "$HOUR$MIN" in *[!0-9]*|"") die "HOUR and MIN must be numbers";; esac
[ "$HOUR" -le 23 ] && [ "$MIN" -le 59 ] || die "HOUR 0-23, MIN 0-59"
case "$DOW" in *[!0-9,*/-]*|"") die "DOW is a cron weekday field, e.g. '*' or '1-5'";; esac
SET=/opt/fog/.fogsettings
get() { [ -r "$SET" ] && grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
if mysql -uroot fog -e "SELECT 1" >/dev/null 2>&1; then DB=(mysql -uroot fog)
else export MYSQL_PWD="$(get snmysqlpass)"; DB=(mysql -u"$(get snmysqluser)" -h"$(get snmysqlhost)" fog); fi
trap 'unset MYSQL_PWD' EXIT
q() { "${DB[@]}" -N -B -e "$1"; }
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to the FOG database"

if [ "${REMOVE:-0}" = "1" ]; then
    q "DROP TRIGGER IF EXISTS lotus8_host_wake"
    q "DELETE FROM powerManagement WHERE pmAction='wol' AND pmOndemand='0' AND pmHour='$HOUR' AND pmMin='$MIN' AND pmDom='*' AND pmMonth='*' AND pmDow='$DOW'"
    echo "Removed: $HOUR:$(printf %02d "$MIN") wake-up schedules and the new-host trigger."; exit 0
fi

for c in pmHostID pmMin pmHour pmDom pmMonth pmDow pmAction pmOndemand; do
    q "SELECT $c FROM powerManagement LIMIT 1" >/dev/null 2>&1 || die "powerManagement.$c missing - FOG schema differs. Nothing changed."
done

EXC=""; IFS=',' read -ra E <<< "$EXCLUDE"; for n in "${E[@]}"; do n=$(printf %s "$n" | tr -d "'\"; "); [ -n "$n" ] && EXC="$EXC AND hostName<>'$n'"; done
WHERE="hostPending='0' AND hostName NOT LIKE '%DC%'$EXC"
HOSTS=$(q "SELECT h.hostID,h.hostName,IFNULL((SELECT hmMAC FROM hostMAC WHERE hmHostID=h.hostID LIMIT 1),'(no MAC)') FROM hosts h WHERE $WHERE ORDER BY h.hostID" 2>/dev/null)
[ -n "$HOSTS" ] || HOSTS=$(q "SELECT hostID,hostName,'' FROM hosts WHERE $WHERE ORDER BY hostID")
SKIP=$(q "SELECT hostName FROM hosts WHERE NOT ($WHERE) ORDER BY hostID" | paste -sd, -)
[ -n "$HOSTS" ] || die "no hosts to schedule"
T=$(printf '%02d:%02d' "$HOUR" "$MIN")
echo "=== LOTUS8: Wake-on-LAN at $T (weekdays: $DOW) ==="
echo "$HOSTS" | awk -F'\t' '{printf "  #%-4s %-18s %s\n",$1,$2,$3}'
echo "Skipped: ${SKIP:-none}"
echo "FOGScheduler (sends the wake-up packets): $(systemctl is-active FOGScheduler 2>/dev/null || echo unknown)"
echo "New hosts get the same schedule automatically (trigger)."
printf 'Type YES to apply: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

# idempotent: the table has no unique key, so drop identical rows first (a re-run must not double the schedule)
q "DELETE FROM powerManagement WHERE pmAction='wol' AND pmOndemand='0' AND pmHour='$HOUR' AND pmMin='$MIN' AND pmDom='*' AND pmMonth='*' AND pmDow='$DOW' AND pmHostID IN (SELECT hostID FROM hosts WHERE $WHERE)"
q "INSERT INTO powerManagement (pmHostID,pmMin,pmHour,pmDom,pmMonth,pmDow,pmAction,pmOndemand)
   SELECT hostID,'$MIN','$HOUR','*','*','$DOW','wol','0' FROM hosts WHERE $WHERE"

"${DB[@]}" <<SQL || echo "WARN: trigger for new hosts could not be created (needs TRIGGER privilege). Existing hosts are done."
DROP TRIGGER IF EXISTS lotus8_host_wake;
DELIMITER \$\$
CREATE TRIGGER lotus8_host_wake AFTER INSERT ON hosts FOR EACH ROW
BEGIN
    IF NEW.hostName NOT LIKE '%DC%' THEN
        INSERT IGNORE INTO powerManagement (pmHostID,pmMin,pmHour,pmDom,pmMonth,pmDow,pmAction,pmOndemand)
        VALUES (NEW.hostID,'$MIN','$HOUR','*','*','$DOW','wol','0');
    END IF;
END\$\$
DELIMITER ;
SQL

echo
echo "Scheduled hosts: $(q "SELECT COUNT(*) FROM powerManagement WHERE pmAction='wol' AND pmOndemand='0' AND pmHour='$HOUR' AND pmMin='$MIN'")   trigger: $([ "$(q "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='fog' AND trigger_name='lotus8_host_wake'")" = 1 ] && echo active || echo MISSING)"
[ "$(systemctl is-active FOGScheduler 2>/dev/null)" = "active" ] || echo "WARN: FOGScheduler is not active - wake-ups will NOT be sent. Start it: sudo systemctl enable --now FOGScheduler"
echo "Undo: sudo REMOVE=1 bash fog-wake.sh"
