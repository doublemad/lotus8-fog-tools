#!/usr/bin/env bash
# LOTUS8: auto-deploy for NEW FOG hosts. Run on the FOG server with sudo.   !!! DEPLOY ERASES THE HOST DISK !!!
# For every new host (registered since SINCE, never deployed, not pending):
#   - image id IMAGE_ID (default 1) is assigned,  - domain join (AD defaults from FOG settings) is switched on,
#   - a Deploy task is queued through FOG's task manager (REST API).
# For FUTURE registrations it switches on FOG's own Quick Registration auto mode (image + deploy at registration).
# Vars: SINCE=YYYY-MM-DD (default: today)   IMAGE_ID (default 1)   NATIVE=0 to skip the future-hosts setting
IMAGE_ID="${IMAGE_ID:-1}"
SINCE="${SINCE:-$(date +%F)}"
NATIVE="${NATIVE:-1}"
SET=/opt/fog/.fogsettings
die() { echo "ABORT: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -r "$SET" ] || die "$SET not found - run this on the FOG server"
command -v mysql >/dev/null && command -v curl >/dev/null || die "mysql client and curl are required"
get() { grep -m1 "^$1=" "$SET" | cut -d= -f2- | tr -d "'\""; }
U=$(get snmysqluser); P=$(get snmysqlpass); H=$(get snmysqlhost)
export MYSQL_PWD="$P"
trap 'unset MYSQL_PWD; rm -f /tmp/.fogd.$$' EXIT
q() { mysql -N -B -u"${U:-fogstorage}" -h"${H:-localhost}" fog -e "$1"; }
setting() { q "SELECT settingValue FROM globalSettings WHERE settingKey='$1' LIMIT 1"; }

echo "=== LOTUS8: auto-deploy image $IMAGE_ID + domain join for NEW hosts (since $SINCE) ==="
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to FOG database"
for t in "hosts hostID,hostName,hostPending,hostCreateDate,hostLastDeploy,hostImage,hostUseAD,hostADDomain,hostADOU,hostADUser,hostADPass,hostADPassLegacy" \
         "images imageID,imageName" "globalSettings settingKey,settingValue" "users uName,uAllowAPI,uAPIToken"; do
    q "SELECT ${t#* } FROM ${t%% *} LIMIT 1" >/dev/null 2>&1 || die "unexpected FOG schema: ${t%% *}. Nothing changed."
done

IMG=$(q "SELECT imageName FROM images WHERE imageID='$IMAGE_ID' LIMIT 1")
[ -n "$IMG" ] || die "image id $IMAGE_ID does not exist in FOG (Image Management)"
DOM=$(setting FOG_AD_DEFAULT_DOMAINNAME); ADU=$(setting FOG_AD_DEFAULT_USER); ADP=$(setting FOG_AD_DEFAULT_PASSWORD)
if [ -z "$DOM" ] || [ -z "$ADU" ] || [ -z "$ADP" ]; then
    die "AD defaults are empty. Fill them once: FOG web UI > FOG Configuration > FOG Settings > Active Directory Defaults (domain, user, password, OU). I never ask for the password. Nothing changed."
fi

HOSTS=$(q "SELECT hostID, hostName FROM hosts
  WHERE hostPending='0' AND hostCreateDate >= '$SINCE'
    AND (hostLastDeploy IS NULL OR hostLastDeploy < '2000-01-01')
  ORDER BY hostID")
echo
echo "Image:   #$IMAGE_ID  $IMG"
echo "Domain:  $DOM  (user $ADU, OU '$(setting FOG_AD_DEFAULT_OU)')"
if [ -n "$HOSTS" ]; then
    echo "Hosts that will be ERASED and re-imaged:"
    echo "$HOSTS" | awk -F'\t' '{printf "  #%-5s %s\n",$1,$2}'
else
    echo "No new hosts to deploy (registered since $SINCE, never deployed)."
fi
[ "$NATIVE" = "1" ] && echo "Future hosts: FOG Quick Registration auto mode ON (every NEW PXE registration gets image #$IMAGE_ID and a deploy task at once)."
echo
printf 'Type YES to continue (disks of the listed hosts will be wiped): '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

# ---- API access (tokens are sent base64-encoded) ----
q "UPDATE globalSettings SET settingValue='1' WHERE settingKey='FOG_API_ENABLED'"
GTOK=$(setting FOG_API_TOKEN)
[ -n "$GTOK" ] || { GTOK=$(openssl rand -base64 24); q "UPDATE globalSettings SET settingValue='$GTOK' WHERE settingKey='FOG_API_TOKEN'"; }
UNAME=$(q "SELECT uName FROM users WHERE uName='fog' LIMIT 1"); UNAME=${UNAME:-$(q "SELECT uName FROM users ORDER BY uId LIMIT 1")}
UTOK=$(q "SELECT uAPIToken FROM users WHERE uName='$UNAME'")
[ -n "$UTOK" ] || { UTOK=$(openssl rand -base64 24); q "UPDATE users SET uAPIToken='$UTOK' WHERE uName='$UNAME'"; }
q "UPDATE users SET uAllowAPI='1' WHERE uName='$UNAME'"
GH=$(printf %s "$GTOK" | base64 -w0); UH=$(printf %s "$UTOK" | base64 -w0)

OKN=0; BAD=0
if [ -n "$HOSTS" ]; then
    FIRST=$(echo "$HOSTS" | head -1 | cut -f1)
    PC=$(curl -s -o /tmp/.fogd.$$ -w '%{http_code}' "http://127.0.0.1/fog/host/$FIRST" -H "fog-api-token: $GH" -H "fog-user-token: $UH")
    [ "$PC" = "200" ] || die "API preflight returned HTTP $PC. No host was changed."
    echo; echo "API preflight OK"
    while IFS=$'\t' read -r id name; do
        [ -n "$id" ] || continue
        q "UPDATE hosts SET hostImage='$IMAGE_ID', hostUseAD='1',
             hostADDomain=(SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_DOMAINNAME'),
             hostADOU=(SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_OU'),
             hostADUser=(SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_USER'),
             hostADPass=(SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_PASSWORD'),
             hostADPassLegacy=IFNULL((SELECT settingValue FROM globalSettings WHERE settingKey='FOG_AD_DEFAULT_PASSWORD_LEGACY'),'')
           WHERE hostID=$id" || { BAD=$((BAD+1)); echo "  [FAIL] $name: cannot set image/AD"; continue; }
        code=$(curl -s -o /tmp/.fogd.$$ -w '%{http_code}' -X POST "http://127.0.0.1/fog/host/$id/task" \
            -H 'Content-Type: application/json' -H "fog-api-token: $GH" -H "fog-user-token: $UH" \
            -d "{\"taskTypeID\":1,\"taskName\":\"LOTUS8 deploy image $IMAGE_ID\",\"shutdown\":false,\"wol\":true}")
        if [ "$code" = "200" ] || [ "$code" = "201" ]; then OKN=$((OKN+1)); echo "  [ OK ] $name: image #$IMAGE_ID + domain $DOM + deploy queued"
        else BAD=$((BAD+1)); echo "  [FAIL] $name: task http $code $(head -c 200 /tmp/.fogd.$$)"; fi
    done <<< "$HOSTS"
fi

if [ "$NATIVE" = "1" ]; then
    for kv in "FOG_QUICKREG_AUTOPOP=1" "FOG_QUICKREG_IMG_ID=$IMAGE_ID" "FOG_QUICKREG_IMG_WHEN_REG=1"; do
        q "UPDATE globalSettings SET settingValue='${kv#*=}' WHERE settingKey='${kv%%=*}'"
    done
    echo; echo "Quick Registration auto mode set: AUTOPOP=$(setting FOG_QUICKREG_AUTOPOP) IMG_ID=$(setting FOG_QUICKREG_IMG_ID) IMG_WHEN_REG=$(setting FOG_QUICKREG_IMG_WHEN_REG)"
    echo "Note: auto mode does not fill the domain fields. For future hosts install fog-ad-trigger.sh (fills the domain at creation), or re-run this script."
fi
echo; echo "Done. Deploy queued: $OKN, failed: $BAD. Hosts start when they PXE boot (wake-on-LAN was requested)."
