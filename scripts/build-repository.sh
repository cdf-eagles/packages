#!/bin/sh
#
# Build the signed apt, dnf, and apk repositories from a directory of
# release files.
#
# Usage: build-repository.sh <input-dir> <site-dir>
#
# Environment:
#   SIGNING_FPR   fingerprint of the OpenPGP key in GNUPGHOME that signs the
#                 apt Release and the dnf repomd.xml
#   APK_KEY_FILE  RSA private key (PEM) that signs each APKINDEX.tar.gz; the
#                 signature is named after the file, so it must be
#                 <key name>.rsa, matching the public key the clients trust
#   SITE_URL      address the site is served from, written into the client
#                 configuration files
#   DOCKER_RUN_ARGS  optional extra arguments for docker run
#   ALPINE_INDEX_IMAGE  optional image to use instead of building
#                 images/alpine-index
#
# Needs apt-ftparchive, createrepo_c, gpg, GNU tar, and docker. Run from the
# repository root: the apk indexes are built in images/alpine-index.

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <input-dir> <site-dir>" >&2
    exit 64
fi

input=$1
site=$2
: "${SIGNING_FPR:?SIGNING_FPR is not set}"
: "${APK_KEY_FILE:?APK_KEY_FILE is not set}"
: "${SITE_URL:?SITE_URL is not set}"

case ${APK_KEY_FILE} in
    *.rsa) ;;
    *)
        echo "APK_KEY_FILE must end in .rsa: ${APK_KEY_FILE}" >&2
        exit 65
        ;;
esac

apk_key_name=$(basename "${APK_KEY_FILE}")
apk_arches="x86_64 aarch64"
deb_arches="amd64 arm64"

rm -rf "${site}"
mkdir -p "${site}"

# apt: one suite, stable, with one component, main. Each binary-<arch>
# index lists the architecture-independent packages too, as Debian's do.
mkdir -p "${site}/deb/pool/main"
for f in "${input}"/*.deb; do
    [ -e "${f}" ] || continue
    cp "${f}" "${site}/deb/pool/main/"
done
(
    cd "${site}/deb"
    for arch in ${deb_arches} all; do
        dir="dists/stable/main/binary-${arch}"
        mkdir -p "${dir}"
        apt-ftparchive --arch "${arch}" packages pool > "${dir}/Packages"
        gzip -9nc "${dir}/Packages" > "${dir}/Packages.gz"
    done
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=packages \
        -o APT::FTPArchive::Release::Label=packages \
        -o APT::FTPArchive::Release::Suite=stable \
        -o APT::FTPArchive::Release::Codename=stable \
        -o "APT::FTPArchive::Release::Architectures=${deb_arches} all" \
        -o APT::FTPArchive::Release::Components=main \
        release dists/stable > Release.tmp
    mv Release.tmp dists/stable/Release
    gpg --batch --yes --local-user "${SIGNING_FPR}" --digest-algo SHA512 \
        --clearsign --output dists/stable/InRelease dists/stable/Release
    gpg --batch --yes --local-user "${SIGNING_FPR}" --digest-algo SHA512 \
        --armor --detach-sign --output dists/stable/Release.gpg dists/stable/Release
)

# dnf: one repository of noarch packages; gzip metadata for older dnf.
mkdir -p "${site}/rpm"
for f in "${input}"/*.rpm; do
    [ -e "${f}" ] || continue
    cp "${f}" "${site}/rpm/"
done
createrepo_c --quiet --checksum sha256 --general-compress-type gz "${site}/rpm"
gpg --batch --yes --local-user "${SIGNING_FPR}" --digest-algo SHA512 \
    --armor --detach-sign --output "${site}/rpm/repodata/repomd.xml.asc" \
    "${site}/rpm/repodata/repomd.xml"

# apk: apk reads <repository>/<arch>/APKINDEX.tar.gz, so each supported
# architecture gets a copy of the noarch packages and its own index.
# apk derives each download's name from the index as <name>-<version>.apk,
# so the files are renamed from their .PKGINFO. apk-tools 2 downloads them
# from the architecture's directory and apk-tools 3 from noarch/, so both
# hold a copy.
for arch in ${apk_arches} noarch; do
    mkdir -p "${site}/alpine/${arch}"
done
for f in "${input}"/*.apk; do
    [ -e "${f}" ] || continue
    info=$(tar --ignore-zeros -xzOf "${f}" .PKGINFO)
    name=$(printf '%s\n' "${info}" | sed -n 's/^pkgname = //p')
    ver=$(printf '%s\n' "${info}" | sed -n 's/^pkgver = //p')
    if [ -z "${name}" ] || [ -z "${ver}" ]; then
        echo "no pkgname or pkgver in ${f}" >&2
        exit 65
    fi
    for arch in ${apk_arches} noarch; do
        cp "${f}" "${site}/alpine/${arch}/${name}-${ver}.apk"
    done
done
keys=$(mktemp -d)
trap 'rm -rf "${keys}"' EXIT
cp "${APK_KEY_FILE}" "${keys}/${apk_key_name}"
chmod 0644 "${keys}/${apk_key_name}"
openssl pkey -in "${APK_KEY_FILE}" -pubout -out "${keys}/${apk_key_name}.pub"
image=${ALPINE_INDEX_IMAGE:-}
if [ -z "${image}" ]; then
    image=packages-alpine-index
    docker build --quiet --tag "${image}" images/alpine-index > /dev/null
fi
# shellcheck disable=SC2086
docker run --rm ${DOCKER_RUN_ARGS:-} --user "$(id -u):$(id -g)" \
    --volume "$(cd "${site}/alpine" && pwd):/alpine" \
    --volume "${keys}:/keys:ro" \
    --env APK_ARCHES="${apk_arches}" --env KEY="/keys/${apk_key_name}" \
    "${image}" sh -euc '
        for arch in ${APK_ARCHES}; do
            cd "/alpine/${arch}"
            set -- *.apk
            if [ -e "$1" ]; then
                apk index --keys-dir /keys \
                    --output APKINDEX.tar.gz "$@"
            else
                apk index --output APKINDEX.tar.gz
            fi
            abuild-sign -q -k "${KEY}" APKINDEX.tar.gz
        done'

# Client files: the keys and the repository definitions.
gpg --armor --export "${SIGNING_FPR}" > "${site}/packages-signing.asc"
cp "${keys}/${apk_key_name}.pub" "${site}/${apk_key_name}.pub"
cat > "${site}/packages.sources" <<SOURCES
Types: deb
URIs: ${SITE_URL}/deb
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/packages-signing.asc
SOURCES
cat > "${site}/packages.repo" <<REPO
[packages]
name=packages
baseurl=${SITE_URL}/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${SITE_URL}/packages-signing.asc
REPO
cp site/index.html "${site}/index.html"
touch "${site}/.nojekyll"
