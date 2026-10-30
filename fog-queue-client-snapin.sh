#!/usr/bin/env bash
# LOTUS8: ONE-SHOT, all-in-one. Run on the FOG server with sudo.
# 1) creates the snapin 'LOTUS8 FOG Client' if missing   2) enables FOG API + tokens if needed
# 3) queues a Single Snapin task (FOG task manager) for NEW hosts: registered since SINCE, inventory done, not pending.
# Hosts that already got this snapin are skipped, so re-running does nothing twice. Nothing persistent is installed.
# Vars: SINCE=YYYY-MM-DD (default: yesterday)   SNAPIN_NAME (default: LOTUS8 FOG Client)
SNAPIN_NAME="${SNAPIN_NAME:-LOTUS8 FOG Client}"
SINCE="${SINCE:-$(date -d '1 day ago' +%F)}"
TASK_NAME="LOTUS8 install FOG client"
SNAPIN_FILE="lotus8-fog-client.bat"
SET=/opt/fog/.fogsettings
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -r "$SET" ] || die "$SET not found - run this on the FOG server"
command -v mysql >/dev/null && command -v curl >/dev/null || die "mysql client and curl are required"
get() { grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
U=$(get snmysqluser); P=$(get snmysqlpass); H=$(get snmysqlhost)
export MYSQL_PWD="$P"
trap 'unset MYSQL_PWD; rm -f /tmp/.fogq.$$' EXIT
q() { mysql -N -B -u"${U:-fogstorage}" -h"${H:-localhost}" fog -e "$1"; }
SNAPDIR=$(get snapindir); SNAPDIR="${SNAPDIR:-/opt/fog/snapins}"

echo "=== LOTUS8: FOG client snapin for NEW hosts (since $SINCE) ==="
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to FOG database"
for t in "hosts hostID,hostName,hostPending,hostCreateDate" "inventory iHostID" \
         "snapins sID,sName,sFilePath,sArgs,sCreateDate,sCreator,sRunWith,sRunWithArgs,sEnabled,sReplicate,sHash,sSize" \
         "snapinAssoc saHostID,saSnapinID" "snapinJobs sjID,sjHostID" "snapinTasks stJobID,stSnapinID" \
         "taskTypes ttID,ttName" "users uName,uAllowAPI,uAPIToken" "globalSettings settingKey,settingValue"; do
    q "SELECT ${t#* } FROM ${t%% *} LIMIT 1" >/dev/null 2>&1 || die "unexpected FOG schema: ${t%% *}(${t#* }). Nothing changed."
done

# ---------- 1. snapin ----------
step "1/3 Snapin"
SID=$(q "SELECT sID FROM snapins WHERE sName='$SNAPIN_NAME' LIMIT 1")
if [ -z "$SID" ]; then
    mkdir -p "$SNAPDIR"
    cat > "$SNAPDIR/$SNAPIN_FILE" <<'BAT'
@echo off
rem LOTUS8: runs by FOG client (SYSTEM). Makes sure FOGService is automatic, running and self-healing. Never stops the service.
sc.exe query FOGService >nul 2>&1 || exit /b 2
sc.exe config FOGService start= auto >nul 2>&1
sc.exe failure FOGService reset= 86400 actions= restart/60000/restart/60000/restart/60000 >nul 2>&1
exit /b 0
BAT
    sed -i 's/$/\r/' "$SNAPDIR/$SNAPIN_FILE"
    chmod 777 "$SNAPDIR/$SNAPIN_FILE"; chown fogproject:www-data "$SNAPDIR/$SNAPIN_FILE" 2>/dev/null
    HASH=$(sha512sum "$SNAPDIR/$SNAPIN_FILE" | cut -d' ' -f1 | tr a-z A-Z); SIZE=$(stat -c %s "$SNAPDIR/$SNAPIN_FILE")
    # INSERT IGNORE: columns I do not list (sReboot, sShutdown, ...) take FOG's own defaults, so enum/int type differences cannot break it
    q "INSERT IGNORE INTO snapins (sName,sDesc,sFilePath,sArgs,sCreateDate,sCreator,sRunWith,sRunWithArgs,sEnabled,sReplicate,sHash,sSize)
       VALUES ('$SNAPIN_NAME','LOTUS8 one-shot: keep FOG client service healthy','$SNAPIN_FILE','',NOW(),'LOTUS8','cmd.exe','/c','1','1','$HASH','$SIZE')" 2>/dev/null        || die "snapin INSERT failed (FOG schema differs). Nothing else changed."
    SID=$(q "SELECT sID FROM snapins WHERE sName='$SNAPIN_NAME' LIMIT 1")
    [ -n "$SID" ] || die "could not create snapin"
    # storage group association (table/column names discovered, not guessed)
    GT_TBL=$(q "SELECT table_name FROM information_schema.tables WHERE table_schema='fog' AND table_name LIKE 'snapinGroup%' LIMIT 1")
    if [ -n "$GT_TBL" ]; then
        C_SN=$(q "SELECT column_name FROM information_schema.columns WHERE table_schema='fog' AND table_name='$GT_TBL' AND column_name LIKE '%SnapinID' LIMIT 1")
        C_SG=$(q "SELECT column_name FROM information_schema.columns WHERE table_schema='fog' AND table_name='$GT_TBL' AND column_name LIKE '%StorageGroupID' LIMIT 1")
        C_PR=$(q "SELECT column_name FROM information_schema.columns WHERE table_schema='fog' AND table_name='$GT_TBL' AND column_name LIKE '%Primary' LIMIT 1")
        SG=$(q "SELECT ngID FROM nfsGroups ORDER BY ngID LIMIT 1")
        if [ -n "$C_SN" ] && [ -n "$C_SG" ] && [ -n "$SG" ]; then
            q "INSERT INTO $GT_TBL ($C_SN,$C_SG${C_PR:+,$C_PR}) VALUES ($SID,$SG${C_PR:+,1})"
        else echo "  [WARN] storage group link not created - open the snapin in the web UI and press Update once"; fi
    fi
    echo "  created snapin '$SNAPIN_NAME' (id $SID), file $SNAPDIR/$SNAPIN_FILE"
else
    echo "  snapin already exists (id $SID)"
fi

# ---------- 2. API ----------
step "2/3 FOG API"
q "UPDATE globalSettings SET settingValue='1' WHERE settingKey='FOG_API_ENABLED'"
GTOK=$(q "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_API_TOKEN' LIMIT 1")
if [ -z "$GTOK" ]; then GTOK=$(openssl rand -base64 24); q "UPDATE globalSettings SET settingValue='$GTOK' WHERE settingKey='FOG_API_TOKEN'"; echo "  global API token generated"; fi
UNAME=$(q "SELECT uName FROM users WHERE uName='fog' LIMIT 1"); UNAME=${UNAME:-$(q "SELECT uName FROM users ORDER BY uId LIMIT 1")}
UTOK=$(q "SELECT uAPIToken FROM users WHERE uName='$UNAME'")
if [ -z "$UTOK" ]; then UTOK=$(openssl rand -base64 24); q "UPDATE users SET uAPIToken='$UTOK' WHERE uName='$UNAME'"; echo "  user API token generated for '$UNAME'"; fi
q "UPDATE users SET uAllowAPI='1' WHERE uName='$UNAME'"
echo "  API enabled, user '$UNAME'"

# FOG API expects both tokens base64-encoded in the headers
GH=$(printf %s "$GTOK" | base64 -w0); UH=$(printf %s "$UTOK" | base64 -w0)

# ---------- 3. tasks ----------
step "3/3 Tasks for new hosts"
TT=$(q "SELECT ttID FROM taskTypes WHERE ttName LIKE '%Single Snapin%' LIMIT 1"); TT=${TT:-13}
HOSTS=$(q "SELECT h.hostID, h.hostName FROM hosts h
  WHERE h.hostPending='0' AND h.hostCreateDate >= '$SINCE'
    AND EXISTS (SELECT 1 FROM inventory i WHERE i.iHostID=h.hostID)
    AND NOT EXISTS (SELECT 1 FROM snapinJobs j JOIN snapinTasks t ON t.stJobID=j.sjID
                    WHERE j.sjHostID=h.hostID AND t.stSnapinID=$SID)
  ORDER BY h.hostID")
[ -n "$HOSTS" ] || { echo "  no new hosts (registered since $SINCE, inventory done, not tasked yet). Done."; exit 0; }
echo "$HOSTS" | awk -F'\t' '{printf "  #%-5s %s\n",$1,$2}'
# preflight: one harmless GET with the same headers, so a bad token is reported once with the facts instead of once per host
FIRST=$(echo "$HOSTS" | head -1 | cut -f1)
PC=$(curl -s -o /tmp/.fogq.$$ -w '%{http_code}' "http://127.0.0.1/fog/host/$FIRST" -H "fog-api-token: $GH" -H "fog-user-token: $UH")
if [ "$PC" != "200" ]; then
    echo "  [FAIL] API preflight returned HTTP $PC (200 expected). Facts:"
    echo "    FOG_API_ENABLED=$(q "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_API_ENABLED'")  global token length=${#GTOK}  user '$UNAME': $(q "SELECT CONCAT('uType=',uType,' uAllowAPI=',uAllowAPI,' tokenLen=',LENGTH(uAPIToken)) FROM users WHERE uName='$UNAME'")"
    echo "    body: $(head -c 200 /tmp/.fogq.$$)"
    echo "    403 = global/user token rejected or user is not admin (uType must be 0); 302/404 = API disabled or wrong webroot."
    die "no tasks were created"
fi
echo "  API preflight OK"
sleep 3
OKN=0; BAD=0
while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    [ -n "$(q "SELECT 1 FROM snapinAssoc WHERE saHostID=$id AND saSnapinID=$SID LIMIT 1")" ] || q "INSERT INTO snapinAssoc (saHostID, saSnapinID) VALUES ($id, $SID)"
    code=$(curl -s -o /tmp/.fogq.$$ -w '%{http_code}' -X POST "http://127.0.0.1/fog/host/$id/task" \
        -H 'Content-Type: application/json' -H "fog-api-token: $GH" -H "fog-user-token: $UH" \
        -d "{\"taskTypeID\":$TT,\"taskName\":\"$TASK_NAME\",\"deploySnapins\":$SID}")
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then OKN=$((OKN+1)); echo "  [ OK ] $name"; else BAD=$((BAD+1)); echo "  [FAIL] $name http $code: $(head -c 200 /tmp/.fogq.$$)"; fi
done <<< "$HOSTS"
echo; echo "Done. Queued: $OKN, failed: $BAD. Snapin tasks in DB: $(q "SELECT COUNT(*) FROM snapinTasks WHERE stSnapinID=$SID")"
echo "The task runs when the host's FOG client checks in (~every 2 min)."
