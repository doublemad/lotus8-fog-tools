#!/usr/bin/env bash
# LOTUS8: on the Ubuntu FOG SERVER - which Windows clients reach FOG and are alive. Read-only.
# Usage: sudo bash fog-server-clients-check.sh [stale_minutes]   (default 30; the client polls every ~2 min)
STALE_MIN="${1:-30}"
WEBROOT="fog"
LOGS="/var/log/apache2/access.log /var/log/apache2/access.log.1 /var/log/httpd/access_log /var/log/nginx/access.log"
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }

echo "=== LOTUS8 FOG SERVER -> WINDOWS CLIENTS CHECK ==="
echo "Server: $(hostname)  $(hostname -I 2>/dev/null | awk '{print $1}')   now: $(date '+%F %T')"
[ "$(id -u)" -ne 0 ] && warn "run with sudo to read logs and the FOG database"
echo

echo "[1] Server services"
for s in apache2 httpd nginx mysql mariadb tftpd-hpa nfs-kernel-server vsftpd FOGScheduler FOGMulticastManager FOGImageReplicator FOGSnapinReplicator FOGPingHosts; do
    systemctl list-unit-files 2>/dev/null | grep -q "^$s\.service" || continue
    st=$(systemctl is-active "$s" 2>/dev/null)
    if [ "$st" = "active" ]; then ok "$s"; else bad "$s: $st"; fi
done
for p in 80 69 2049; do
    ss -ltnu 2>/dev/null | grep -q ":$p " && ok "port $p listening" || warn "port $p not listening"
done

echo
echo "[2] Windows clients that checked in (from web access log)"
LOGFILES=""
for f in $LOGS; do [ -r "$f" ] && LOGFILES="$LOGFILES $f"; done
if [ -z "$LOGFILES" ]; then
    bad "no readable web access log (run with sudo)"
else
    NOW=$(date +%s)
    TMP=$(mktemp)
    # fog client requests: /fog/service/*.php  (excluding browsers)
    cat $LOGFILES | awk -v re="/$WEBROOT/service/" 'index($0,re){
        ip=$1; match($0,/\[[^]]+\]/); ts=substr($0,RSTART+1,RLENGTH-2); n[ip]++; last[ip]=ts }
        END{ for(i in n) print i"|"n[i]"|"last[i] }' > "$TMP"
    if [ ! -s "$TMP" ]; then
        bad "no FOG client requests found in the log - no client is reaching /$WEBROOT/service/"
    else
        printf '  %-16s %-8s %-22s %-10s %s\n' IP REQ LAST_SEEN AGE STATE
        ALIVE=0; STALE=0
        sort -t'|' -k1,1V "$TMP" | while IFS='|' read -r ip n raw; do
            t=$(echo "$raw" | sed 's#/# #g; s#:# #')
            es=$(date -d "$t" +%s 2>/dev/null || echo 0)
            age=$(( (NOW - es) / 60 ))
            if ping -c1 -W1 "$ip" >/dev/null 2>&1; then pg="ping-ok"; else pg="no-ping"; fi
            if [ "$es" -eq 0 ]; then state="?"
            elif [ "$age" -le "$STALE_MIN" ]; then state="ALIVE ($pg)"
            else state="STALE ($pg)"; fi
            printf '  %-16s %-8s %-22s %-10s %s\n' "$ip" "$n" "$(date -d "@$es" '+%F %T' 2>/dev/null)" "${age}m" "$state"
        done
    fi
    rm -f "$TMP"
fi

echo
echo "[3] Registered hosts in FOG database"
SET=/opt/fog/.fogsettings
if [ -r "$SET" ] && command -v mysql >/dev/null 2>&1; then
    U=$(grep -m1 '^snmysqluser=' "$SET" | cut -d= -f2- | tr -d "'\"")
    P=$(grep -m1 '^snmysqlpass=' "$SET" | cut -d= -f2- | tr -d "'\"")
    H=$(grep -m1 '^snmysqlhost=' "$SET" | cut -d= -f2- | tr -d "'\"")
    export MYSQL_PWD="$P"
    Q="SELECT hostName, IFNULL(hostIP,'-') ip, IFNULL(hostLastDeploy,'-') last_deploy FROM hosts ORDER BY hostName;"
    if OUT=$(mysql -N -B -u"${U:-fogstorage}" -h"${H:-localhost}" fog -e "$Q" 2>&1); then
        COUNT=$(echo "$OUT" | grep -c .)
        ok "$COUNT host(s) registered"
        echo "$OUT" | head -50 | awk -F'\t' '{printf "  %-24s %-16s %s\n",$1,$2,$3}'
        while IFS=$'\t' read -r name ip _; do
            [ "$ip" = "-" ] || [ -z "$ip" ] && continue
            ping -c1 -W1 "$ip" >/dev/null 2>&1 || warn "$name ($ip) does not answer ping"
        done <<< "$OUT"
    else
        warn "cannot read DB: $(echo "$OUT" | head -1)"
    fi
    unset MYSQL_PWD
else
    warn "no access to $SET or mysql client (run with sudo)"
fi

echo
echo "[4] Recent FOG server errors"
for f in /var/log/fog/*.log; do
    [ -f "$f" ] && { echo "--- $f"; grep -iE 'error|fail|unable' "$f" 2>/dev/null | tail -n 5; }
done
for f in /var/log/apache2/error.log; do
    [ -r "$f" ] && { echo "--- $f"; grep -i 'fog' "$f" | tail -n 5; }
done

echo
echo "LEGEND: ALIVE = client polled within ${STALE_MIN} min. STALE = PC is off, FOG service stopped or no route/firewall."
