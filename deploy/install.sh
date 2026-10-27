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
# So is the CA that issues users' client certificates (smoothapt-user); its
# key never leaves /etc/smoothapt/ca, and the host's nginx gets its
# certificate (deploy/host-nginx.md).
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
HOME_DIR=/var/lib/smoothapt
WWW=/srv/smoothapt
export GNUPGHOME=$HOME_DIR/gnupg

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    reprepro cosign gnupg nginx openssl python3 python3-snappy ca-certificates git xorriso >/dev/null

id smoothapt >/dev/null 2>&1 ||
    useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin smoothapt
install -d -o smoothapt -g smoothapt -m 755 "$HOME_DIR" "$HOME_DIR/archives" "$HOME_DIR/state" "$HOME_DIR/images" "$WWW"
install -d -o smoothapt -g smoothapt -m 700 "$HOME_DIR/tmp"
install -d -o smoothapt -g smoothapt -m 700 "$GNUPGHOME"
install -d -m 750 -g www-data /etc/smoothapt/users
install -d -m 700 /etc/smoothapt/ca

if [ ! -f /etc/smoothapt/ca/ca.key ]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out /etc/smoothapt/ca/ca.key
    chmod 600 /etc/smoothapt/ca/ca.key
    openssl req -x509 -new -key /etc/smoothapt/ca/ca.key -sha256 -days 36500 \
        -subj "/O=RakuenSoftware/CN=Smooth* Archive Client CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out /etc/smoothapt/ca/ca.crt
fi
chmod 644 /etc/smoothapt/ca/ca.crt

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
    install -d -o smoothapt -g smoothapt "$base" "$base/conf" "$WWW/$name"
    sed "s/@SIGNWITH@/$fpr/" "$conf" > "$base/conf/distributions"
    printf 'outdir %s\n' "$WWW/$name" > "$base/conf/options"
    chown smoothapt:smoothapt "$base/conf/distributions" "$base/conf/options"
    as reprepro -b "$base" export
    # The certificate list and revocations are created empty once and then
    # owned by smoothapt-user.
    if [ "$name" != public ]; then
        [ -f "/etc/smoothapt/users/$name.certs" ] ||
            install -m 640 -g www-data /dev/null "/etc/smoothapt/users/$name.certs"
        if [ -f "/etc/smoothapt/users/$name.revoked" ]; then
            # Revocations were an nginx map ("<serial> 1;") before.
            mv "/etc/smoothapt/users/$name.revoked" "/etc/smoothapt/users/$name.revoked.map"
            install -d -m 755 "/etc/smoothapt/users/$name.revoked"
            awk '{print $1}' "/etc/smoothapt/users/$name.revoked.map" |
                while read -r serial; do touch "/etc/smoothapt/users/$name.revoked/$serial"; done
            rm "/etc/smoothapt/users/$name.revoked.map"
        fi
        install -d -m 755 "/etc/smoothapt/users/$name.revoked"
        rm -f "/etc/smoothapt/users/$name.htpasswd"
    fi
done

ln -sf "$SRC/bin/smoothapt-user" /usr/local/sbin/smoothapt-user
ln -sf "$SRC/bin/smoothapt-image" /usr/local/sbin/smoothapt-image
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
