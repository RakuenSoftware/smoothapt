#!/bin/sh
# Set up (or update) smoothapt inside its Debian 13 container. Idempotent.
#
#   git clone https://github.com/RakuenSoftware/smoothapt /opt/smoothapt
#   /opt/smoothapt/deploy/install.sh
#
# To update: git -C /opt/smoothapt pull && /opt/smoothapt/deploy/install.sh
#
# The archive signing key is generated here on first run and never leaves
# /var/lib/smoothapt/gnupg; its public half is published as public-key.asc.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
HOME_DIR=/var/lib/smoothapt
WWW=/srv/smoothapt
export GNUPGHOME=$HOME_DIR/gnupg

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    reprepro cosign gnupg nginx openssl python3 ca-certificates git >/dev/null

id smoothapt >/dev/null 2>&1 ||
    useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin smoothapt
install -d -o smoothapt -g smoothapt -m 755 "$HOME_DIR" "$HOME_DIR/archives" "$HOME_DIR/state" "$WWW"
install -d -o smoothapt -g smoothapt -m 700 "$GNUPGHOME"
install -d -m 750 -g www-data /etc/smoothapt/users

as() { runuser -u smoothapt -- env GNUPGHOME="$GNUPGHOME" HOME="$HOME_DIR" "$@"; }

if ! as gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    # No expiry: an expired archive key stops every appliance from updating,
    # and nobody is there to fix it by hand.
    as gpg --batch --passphrase '' --quick-gen-key \
        "Smooth* Archive Signing Key" ed25519 sign never
fi
fpr=$(as gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
as gpg --armor --export "$fpr" > "$WWW/public-key.asc"
as gpg --export "$fpr" > "$WWW/smooth-archive-keyring.gpg"

for conf in "$SRC"/conf/archives/*/distributions; do
    name=$(basename "$(dirname "$conf")")
    base=$HOME_DIR/archives/$name
    install -d -o smoothapt -g smoothapt "$base/conf" "$WWW/$name"
    sed "s/@SIGNWITH@/$fpr/" "$conf" > "$base/conf/distributions"
    printf 'outdir %s\n' "$WWW/$name" > "$base/conf/options"
    chown smoothapt:smoothapt "$base/conf/distributions" "$base/conf/options"
    as reprepro -b "$base" export
    # The user list is created empty once and then owned by smoothapt-user.
    if [ "$name" != public ] && [ ! -f "/etc/smoothapt/users/$name.htpasswd" ]; then
        install -m 640 -g www-data /dev/null "/etc/smoothapt/users/$name.htpasswd"
    fi
done

ln -sf "$SRC/bin/smoothapt-user" /usr/local/sbin/smoothapt-user
install -m 644 "$SRC/deploy/nginx.conf" /etc/nginx/sites-available/smoothapt
ln -sf ../sites-available/smoothapt /etc/nginx/sites-enabled/smoothapt
rm -f /etc/nginx/sites-enabled/default
nginx -t -q
systemctl reload-or-restart nginx

for unit in "$SRC"/deploy/systemd/*; do
    sed "s#@SRC@#$SRC#g" "$unit" > "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
systemctl enable --now smoothapt-ingest.timer smoothapt-export.timer

echo "smoothapt ready; archive key $fpr"
