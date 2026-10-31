#!/usr/bin/env bash
# LOTUS8: deletes ALL FOG images (database records AND their files) so ONE new image can be captured.   !!! IRREVERSIBLE !!!
# Run once on the FOG server with sudo. It refuses to run while any task is active.
#  - removes every image's folder under /images (only folders named in the images table; /images/dev leftovers named by MAC)
#  - removes the image records and their storage-group links
#  - hosts lose their image link (hostImage=0); auto-deploy at registration is switched OFF until you set the new image
# Hosts, domain trigger, PXE menu, snapins and the Windows setup folder are NOT touched.
# After capturing the new image:  sudo IMAGE_ID=<new id> bash fog-setup.sh   (turns auto-deploy back on)
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
IMGROOT=/images
[ -d "$IMGROOT" ] || die "$IMGROOT not found - is this the FOG server?"

ACT=$(q "SELECT COUNT(*) FROM tasks WHERE taskStateID IN (1,2,3)")
[ "$ACT" = "0" ] || die "there are $ACT active tasks. Cancel them in FOG (Tasks > Active) first. Nothing changed."

echo "=== LOTUS8: delete ALL images ==="
ROWS=$(q "SELECT imageID, imageName, imagePath FROM images ORDER BY imageID")
[ -n "$ROWS" ] && echo "$ROWS" | while IFS=$'\t' read -r id name path; do
    sz=$(du -sh "$IMGROOT/$path" 2>/dev/null | cut -f1)
    printf '  #%-3s %-20s folder %s/%s  (%s)\n' "$id" "$name" "$IMGROOT" "$path" "${sz:-no folder}"
done
[ -n "$ROWS" ] || echo "  (no images in the database)"
echo "  capture leftovers in $IMGROOT/dev:"; find "$IMGROOT/dev" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9a-fA-F]{12}' -printf '    %f\n' 2>/dev/null
df -h "$IMGROOT" | tail -1 | awk '{print "  disk now: used "$3" of "$2", free "$4}'
echo
echo "This deletes the files above for good. Hosts and settings stay."
printf 'Type YES to delete ALL images: '
read -r ANS < /dev/tty 2>/dev/null || die "no terminal for confirmation, nothing changed"
[ "$ANS" = "YES" ] || die "cancelled, nothing changed"

# files first (only plain folder names from the database, never paths with / or ..)
if [ -n "$ROWS" ]; then
    echo "$ROWS" | while IFS=$'\t' read -r id name path; do
        case "$path" in ""|*/*|*..*|dev|postdownloadscripts|postinitscripts) echo "  skip folder '$path' (not a plain image folder)"; continue;; esac
        [ -d "$IMGROOT/$path" ] && rm -rf -- "${IMGROOT:?}/$path" && echo "  removed files: $path"
    done
fi
find "$IMGROOT/dev" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9a-fA-F]{12}' -exec rm -rf -- {} + 2>/dev/null

# database
HAS=$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='fog' AND table_name='imageGroupAssoc'")
[ "$HAS" = "1" ] && q "DELETE FROM imageGroupAssoc"
q "DELETE FROM images"
q "UPDATE hosts SET hostImage=0"
q "UPDATE globalSettings SET settingValue='0' WHERE settingKey IN ('FOG_QUICKREG_IMG_WHEN_REG','FOG_QUICKREG_IMG_ID')"

echo
echo "Done. Images in database: $(q "SELECT COUNT(*) FROM images")   hosts linked to an image: $(q "SELECT COUNT(*) FROM hosts WHERE hostImage<>0")"
df -h "$IMGROOT" | tail -1 | awk '{print "disk now: used "$3" of "$2", free "$4}'
echo "Next: create the new image in FOG (Image Management > Create), capture it, then:  sudo IMAGE_ID=<new id> bash fog-setup.sh"
