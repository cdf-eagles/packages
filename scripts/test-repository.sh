#!/bin/sh
#
# Prove the repositories end to end: build two versions of a stand-in
# package with throwaway keys, serve the repositories over HTTP, install
# the first version on each distribution with its package manager, publish
# the second, and check that the package manager upgrades to it. Finally
# check that apt refuses the repository when it trusts a different key.
#
# Usage: test-repository.sh
#
# Run from the repository root with nfpm, gpg, openssl, python3,
# apt-ftparchive, createrepo_c, and docker on PATH.
#
# Environment (optional, for networks that need them):
#   DOCKER_RUN_ARGS    extra arguments for docker run
#   TEST_SETUP_SCRIPT  shell script run as root in each container before the
#                      test, given the distribution name as its argument

set -eu

port=8099
url="http://127.0.0.1:${port}"
distributions="debian ubuntu almalinux9 almalinux10 alpine"

work=$(mktemp -d)
server=
cleanup() {
    for d in ${distributions}; do
        docker rm -f "packages-test-${d}" > /dev/null 2>&1 || true
    done
    if [ -n "${server}" ]; then
        kill "${server}" 2> /dev/null || true
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

# Throwaway keys of the same kinds the deploy uses: OpenPGP Ed25519 for apt
# and dnf, RSA for apk.
GNUPGHOME="${work}/gnupg"
export GNUPGHOME
mkdir -m 0700 "${GNUPGHOME}"
gpg --quiet --batch --passphrase '' --quick-generate-key \
    "packages test key <noreply@github.com>" ed25519 sign 1d
SIGNING_FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
export SIGNING_FPR
gpg --quiet --batch --armor --export-secret-keys "${SIGNING_FPR}" > "${work}/signing.asc"
openssl genrsa -out "${work}/packages-test.rsa" 2048 2> /dev/null
APK_KEY_FILE="${work}/packages-test.rsa"
SITE_URL=${url}
export APK_KEY_FILE SITE_URL

build_packages() {
    version=$1
    stage="${work}/stage-${version}"
    mkdir -p "${stage}" "${work}/in"
    printf '#!/usr/bin/env python3\nprint("packages-test v%s")\n' "${version}" > "${stage}/packages-test"
    cat > "${stage}/nfpm.yaml" <<NFPM
name: packages-test
arch: all
platform: linux
version: ${version}
maintainer: noreply@github.com
description: Stand-in package for the repository tests
license: BSD-3-Clause
depends:
  - python3
contents:
  - src: ${stage}/packages-test
    dst: /usr/bin/packages-test
    file_info:
      mode: 0755
rpm:
  signature:
    key_file: ${work}/signing.asc
apk:
  signature:
    key_file: ${APK_KEY_FILE}
    key_name: packages-test
NFPM
    for packager in deb rpm apk; do
        nfpm package --packager "${packager}" --config "${stage}/nfpm.yaml" \
            --target "${work}/in/" > /dev/null
    done
}

as_root() {
    # shellcheck disable=SC2086
    docker exec --user 0 "packages-test-$1" sh -euxc "$2"
}

check_version() {
    got=$(docker exec --user nobody "packages-test-$1" packages-test)
    if [ "${got}" != "packages-test v$2" ]; then
        echo "FAIL $1: packages-test printed '${got}', not v$2" >&2
        exit 1
    fi
    echo "PASS $1: packages-test v$2"
}

build_packages 1.0.0
sh scripts/build-repository.sh "${work}/in" "${work}/site"

python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${work}/site" \
    > "${work}/http.log" 2>&1 &
server=$!
sleep 1

for d in ${distributions}; do
    echo "== ${d}: install 1.0.0"
    docker build --quiet --tag "packages-test-${d}" "test/images/${d}" > /dev/null
    # shellcheck disable=SC2086
    docker run --detach --network host ${DOCKER_RUN_ARGS:-} \
        --name "packages-test-${d}" "packages-test-${d}" sleep 3600 > /dev/null
    for f in packages-signing.asc packages.sources packages.repo packages-test.rsa.pub; do
        docker cp "${work}/site/${f}" "packages-test-${d}:/tmp/${f}"
    done
    if [ -n "${TEST_SETUP_SCRIPT:-}" ]; then
        docker cp "${TEST_SETUP_SCRIPT}" "packages-test-${d}:/tmp/setup.sh"
        as_root "${d}" "sh /tmp/setup.sh ${d}"
    fi
    case ${d} in
        debian | ubuntu)
            as_root "${d}" 'mkdir -p /etc/apt/keyrings
                cp /tmp/packages-signing.asc /etc/apt/keyrings/
                cp /tmp/packages.sources /etc/apt/sources.list.d/
                apt-get update
                apt-get install -y --no-install-recommends packages-test'
            ;;
        almalinux*)
            as_root "${d}" 'cp /tmp/packages.repo /etc/yum.repos.d/
                dnf install -y packages-test'
            ;;
        alpine)
            as_root "${d}" "cp /tmp/packages-test.rsa.pub /etc/apk/keys/
                echo '${url}/alpine' >> /etc/apk/repositories
                apk update
                apk add packages-test"
            ;;
        *) exit 70 ;;
    esac
    check_version "${d}" 1.0.0
done

build_packages 1.0.1
sh scripts/build-repository.sh "${work}/in" "${work}/site"

for d in ${distributions}; do
    echo "== ${d}: upgrade to 1.0.1"
    case ${d} in
        debian | ubuntu)
            as_root "${d}" 'apt-get update && apt-get upgrade -y' ;;
        almalinux*)
            as_root "${d}" 'dnf upgrade -y --refresh' ;;
        alpine)
            as_root "${d}" 'apk update && apk upgrade' ;;
        *) exit 70 ;;
    esac
    check_version "${d}" 1.0.1
done

echo "== debian: refuse a repository signed by an untrusted key"
gpg --quiet --batch --passphrase '' --quick-generate-key \
    "untrusted key <noreply@github.com>" ed25519 sign 1d
gpg --batch --armor --export "untrusted key" > "${work}/untrusted.asc"
docker cp "${work}/untrusted.asc" packages-test-debian:/etc/apt/keyrings/packages-signing.asc
if as_root debian 'apt-get update -o APT::Update::Error-Mode=any' > "${work}/untrusted.log" 2>&1; then
    echo "FAIL debian: apt accepted the repository with an untrusted key" >&2
    exit 1
fi
if ! grep -q "^[EW]:.*127\.0\.0\.1:${port}/deb" "${work}/untrusted.log"; then
    cat "${work}/untrusted.log" >&2
    echo "FAIL debian: apt failed for a reason other than the signature" >&2
    exit 1
fi
echo "PASS debian: apt refused the repository with an untrusted key"

echo "REPOSITORY TEST PASS"
