#!/usr/bin/env bash
# LOTUS8: ONE-SHOT. For NEW FOG hosts (registered since SINCE, inventory done, not pending, never tasked with this snapin)
# queue a Single Snapin task through FOG's own task manager (REST API). Nothing is left behind.
# Vars: SNAPIN_NAME (snapin created once in FOG web UI), SINCE (YYYY-MM-DD, default: yesterday)
SNAPIN_NAME="${SNAPIN_NAME:-LOTUS8 FOG Client}"
SINCE="${SINCE:-$(date -d '1 day ago' +%F)}"
TASK_NAME="LOTUS8 install FOG client"
SET=/opt/fog/.fogsettings
die() { echo "ABORT: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -r "$SET" ] || die "$SET not found - run on the FOG server"
command -v mysql >/dev/null && command -v curl >/dev/null || die "mysql client and curl are required"
get() { grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
U=$(get snmysqluser); P=$(get snmysqlpass); H=$(get snmysqlhost)
export MYSQL_PWD="$P"
trap 'unset MYSQL_PWD' EXIT
q() { mysql -N -B -u"${U:-fogstorage}" -h"${H:-localhost}" fog -e "$1"; }

echo "=== LOTUS8: queue FOG-client snapin for NEW hosts ==="
echo "Snapin: '$SNAPIN_NAME'   Registered since: $SINCE"

q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to FOG database"
for t in "hosts hostID,hostName,hostPending,hostCreateDate" "inventory iHostID" "snapins sID,sName" \
         "snapinAssoc saHostID,saSnapinID" "snapinJobs sjID,sjHostID" "snapinTasks stJobID,stSnapinID" "taskTypes ttID,ttName"; do
    tbl=${t%% *}; cols=${t#* }
    q "SELECT $cols FROM $tbl LIMIT 1" >/dev/null 2>&1 || die "table/columns not as expected: $tbl($cols) - FOG version differs, nothing changed"
done

SID=$(q "SELECT sID FROM snapins WHERE sName='$SNAPIN_NAME' LIMIT 1")
[ -n "$SID" ] || die "snapin '$SNAPIN_NAME' not found. Create it once: FOG web UI > Snapin Management > Create New Snapin"
TT=$(q "SELECT ttID FROM taskTypes WHERE ttName LIKE '%Single Snapin%' LIMIT 1"); TT=${TT:-13}

HOSTS=$(q "SELECT h.hostID, h.hostName FROM hosts h
  WHERE h.hostPending='0' AND h.hostCreateDate >= '$SINCE'
    AND EXISTS (SELECT 1 FROM inventory i WHERE i.iHostID=h.hostID)
    AND NOT EXISTS (SELECT 1 FROM snapinJobs j JOIN snapinTasks t ON t.stJobID=j.sjID
                    WHERE j.sjHostID=h.hostID AND t.stSnapinID=$SID)
  ORDER BY h.hostID")
[ -n "$HOSTS" ] || { echo "No new hosts to task. Done."; exit 0; }
echo; echo "Hosts that will get the task (snapin id $SID, task type $TT):"
echo "$HOSTS" | awk -F'\t' '{printf "  #%-5s %s\n",$1,$2}'

GT=$(q "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_API_TOKEN' LIMIT 1")
EN=$(q "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_API_ENABLED' LIMIT 1")
UT=$(q "SELECT uToken FROM users WHERE uToken IS NOT NULL AND uToken<>'' LIMIT 1")
[ "$EN" = "1" ] || die "FOG API is disabled: FOG Configuration > FOG Settings > API System > enable"
[ -n "$GT" ] && [ -n "$UT" ] || die "API tokens missing (global or user token) - get them in the web UI"

echo; printf 'Type YES to queue these tasks: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

OKN=0; BAD=0
while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    [ -n "$(q "SELECT 1 FROM snapinAssoc WHERE saHostID=$id AND saSnapinID=$SID LIMIT 1")" ] || \
        q "INSERT INTO snapinAssoc (saHostID, saSnapinID) VALUES ($id, $SID)"
    code=$(curl -s -o /tmp/.fogq.$$ -w '%{http_code}' -X POST "http://127.0.0.1/fog/host/$id/task" \
        -H 'Content-Type: application/json' -H "fog-api-token: $GT" -H "fog-user-token: $UT" \
        -d "{\"taskTypeID\":$TT,\"taskName\":\"$TASK_NAME\",\"deploySnapins\":$SID}")
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then OKN=$((OKN+1)); echo "  [ OK ] $name"; else BAD=$((BAD+1)); echo "  [FAIL] $name http $code: $(head -c 150 /tmp/.fogq.$$)"; fi
done <<< "$HOSTS"
rm -f /tmp/.fogq.$$

QUEUED=$(q "SELECT COUNT(*) FROM snapinTasks WHERE stSnapinID=$SID")
echo; echo "Queued ok: $OKN, failed: $BAD. Snapin tasks now in DB for this snapin: $QUEUED"
echo "Tasks run when the host's FOG client checks in (~every 2 min). Hosts without a client keep waiting."
