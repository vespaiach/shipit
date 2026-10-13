#!/usr/bin/env bash
# Installs shipit from this checkout: copies bin/ lib/ libexec/ templates/ to /usr/local/lib/shipit
# and links /usr/local/bin/shipit. Re-running it replaces the installed copy. Run as root.
set -euo pipefail

dest=/usr/local/lib/shipit
src=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root, or with sudo: sudo $0" >&2
  exit 1
fi

# Build the new copy next to the old one, then swap, so a failed copy leaves the old install working.
rm -rf "$dest.new" "$dest.old"
mkdir -p "$dest.new"
for dir in bin lib libexec templates; do
  [ ! -d "$src/$dir" ] || cp -R "$src/$dir" "$dest.new/"
done
chown -R root:root "$dest.new"
chmod -R u+rwX,go+rX,go-w "$dest.new"
[ ! -d "$dest" ] || mv "$dest" "$dest.old"
mv "$dest.new" "$dest"
rm -rf "$dest.old"

ln -sfn "$dest/bin/shipit" /usr/local/bin/shipit
echo "Installed shipit to $dest. Next: sudo shipit setup"
