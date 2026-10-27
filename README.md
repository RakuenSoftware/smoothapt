# smoothapt

The apt repository for every SmoothKernel-based distribution, served from
`https://updates.rakuensoftware.com`. It ingests each Smooth* project's GitHub
releases and publishes them unmodified: nothing is built, re-signed or
re-versioned here, and a package only gets in if its GitHub build-provenance
attestation shows it was built by that project's own release pipeline.

## Archives and suites

| URL | Suite | Access | Contents |
|---|---|---|---|
| `/public` | `common` | public | SmoothKernel: per-build `linux-image-*-smoothkernel` / `linux-headers-*-smoothkernel`, the `linux-image-smoothkernel` / `linux-headers-smoothkernel` metapackages, `linux-libc-dev`, OpenZFS |
| `/public` | `smoothnas` | public | SmoothNAS |
| `/smoothrouter` | `smoothrouter` | per-user credential | SmoothRouter |

Every `Release` file carries `Origin: RakuenSoftware`, is signed with the
archive key and is valid for 7 days (re-signed daily). The key is published as
`/public-key.asc` and, ready for `signed-by`, `/smooth-archive-keyring.gpg`.

A client:

```
# /etc/apt/sources.list.d/smooth.sources
Types: deb
URIs: https://updates.rakuensoftware.com/public
Suites: common
Components: main
Signed-By: /etc/apt/keyrings/smooth-archive-keyring.gpg
```

A SmoothRouter adds the `smoothrouter` archive and its user's certificate:

```
Types: deb
URIs: https://updates.rakuensoftware.com/smoothrouter
Suites: smoothrouter
Components: main
Signed-By: /etc/apt/keyrings/smooth-archive-keyring.gpg

# apt.conf: the certificate apt presents to updates.rakuensoftware.com
Acquire::https::updates.rakuensoftware.com::SslCert "<certificate>";
Acquire::https::updates.rakuensoftware.com::SslKey "<key>";
```

## Ingestion

`conf/sources` lists the projects. Every hour `smoothapt-ingest`:

1. lists each project's GitHub releases, prereleases included, so every
   build the pipeline publishes from `main` reaches the archive unattended;
2. downloads every `.deb` of a release it has not seen (debug-symbol packages
   excepted);
3. verifies it. For a public project (`attestation`), its attestation is
   fetched by digest from GitHub and checked with `cosign` against the public
   Sigstore log: the certificate must be GitHub Actions' and name the
   project's workflow on `main` or a `v*` tag, so a PR build or another
   repository cannot get a package in. A private project's attestations are
   not in that log (`actions-upload`): the release and every package must
   have been uploaded by `github-actions[bot]`, and each package's SHA-256
   must be the digest GitHub recorded for it;
4. adds the release to the suite only if every package verified, and records
   it as rejected, with the reason, otherwise.

The archive keeps the newest 3 releases of each project: a per-build kernel
package is removed when the last release carrying it ages out.

Private projects (SmoothRouter) need a GitHub token with read access to their
releases: a fine-grained token limited to those repositories, permission
Contents: read only, in `/etc/smoothapt/github-token`:

```
install -m 640 -g smoothapt /dev/stdin /etc/smoothapt/github-token <<< '<token>'
```

State, per project: `/var/lib/smoothapt/state/<owner>__<repo>.json`. Log:
`journalctl -u smoothapt-ingest`.

Anyone can repeat the check on a package taken from the archive:

```
gh attestation verify linux-image-7.2.10-70-smoothkernel_7.2.10-70_amd64.deb \
    --repo RakuenSoftware/smoothkernel
```

## Credentials

Each SmoothRouter user has their own client certificate, issued by smoothapt's
CA with the user id as its subject, and part of the image built for them. apt
presents it on every request; the host's nginx verifies it against the CA, and
the container refuses revoked ones and logs every request with the id. On the
server:

```
smoothapt-user add smoothrouter <id>     # prints the certificate and its key
smoothapt-user revoke smoothrouter <id>  # that user's images are refused from now on
smoothapt-user list smoothrouter
```

Issued certificates are listed in `/etc/smoothapt/users/smoothrouter.certs`
(id and serial; the key is shown once, by `add`), revoked serials as files in
`smoothrouter.revoked/` (checked per request, so a revoke is immediate), and
every add and revoke is logged in
`smoothrouter.log`. Requests: `/var/log/nginx/smoothapt.log`.

## User images

A SmoothRouter release carries the base installer image: the same for
everyone, with no credential in it. `smoothapt-ingest` keeps the newest one
under `/var/lib/smoothapt/images/smoothrouter/base/`. A user's image is made
from it here, so the user's certificate never leaves this server except inside
their image:

```
smoothapt-user add smoothrouter <id>      # once: issue the certificate
smoothapt-image smoothrouter <id>         # the user's image from the newest base
```

The image is the base with the user's certificate and key on the medium as
`/smoothrouter/client.pem`, which the installer installs for apt, signed with
the user's key. It lands in `/var/lib/smoothapt/images/smoothrouter/users/<id>/`
with `.sig`, `.crt` (issued by our CA) and `.sha256`:

```
openssl dgst -sha256 -verify <(openssl x509 -in <image>.crt -pubkey -noout) \
    -signature <image>.sig <image>
```

## Deployment

Container `ct252` (10.1.0.252) on the VPS, Debian 13:

```
git clone https://github.com/RakuenSoftware/smoothapt /opt/smoothapt
/opt/smoothapt/deploy/install.sh
```

`install.sh` is idempotent; to update, `git pull` and run it again. On first
run it generates the archive signing key in `/var/lib/smoothapt/gnupg` and the
client CA in `/etc/smoothapt/ca`; neither key leaves the container. The VPS host's nginx terminates TLS for
`updates.rakuensoftware.com` and proxies to the container (see
`deploy/host-nginx.md`).
