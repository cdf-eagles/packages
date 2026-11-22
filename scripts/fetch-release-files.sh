#!/bin/sh
#
# Download every release file listed in sources/<project>.txt, check it
# against the SHA-256 in the list, and verify its build provenance
# attestation against the project's release workflow.
#
# Usage: fetch-release-files.sh <output-dir>
#
# Run from the repository root with gh on PATH and signed in (GH_TOKEN in CI). Prints
# the number of files fetched as its last line.

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <output-dir>" >&2
    exit 64
fi

out=$1
mkdir -p "${out}"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
count=0
if command -v sha256sum > /dev/null 2>&1; then
    sum="sha256sum"
else
    sum="shasum -a 256"
fi

for conf in sources/*.conf; do
    [ -e "${conf}" ] || continue
    project=$(basename "${conf}" .conf)
    list="sources/${project}.txt"
    repository=$(sed -n 's/^repository=//p' "${conf}")
    signer=$(sed -n 's/^signer_workflow=//p' "${conf}")
    if ! printf '%s\n' "${repository}" | grep -Eqx '[A-Za-z0-9-]+/[A-Za-z0-9._-]+'; then
        echo "${conf}: bad repository '${repository}'" >&2
        exit 65
    fi
    if ! printf '%s\n' "${signer}" | grep -Eqx '\.github/workflows/[A-Za-z0-9._-]+\.ya?ml'; then
        echo "${conf}: bad signer_workflow '${signer}'" >&2
        exit 65
    fi
    if [ ! -f "${list}" ]; then
        echo "${conf}: no ${list}" >&2
        exit 66
    fi

    # Each line: <tag> <release candidate tag> <file> <sha256>
    while read -r tag rc file sha extra; do
        case ${tag} in '' | '#'*) continue ;; *) ;; esac
        if [ -n "${extra}" ] \
            || ! printf '%s\n' "${tag}" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+' \
            || ! printf '%s\n' "${rc}" | grep -Eqx "${tag}-rc\\.[0-9]+" \
            || ! printf '%s\n' "${file}" | grep -Eqx '[A-Za-z0-9._+-]+\.(deb|rpm|apk)' \
            || ! printf '%s\n' "${sha}" | grep -Eqx '[0-9a-f]{64}'; then
            echo "${list}: bad line: ${tag} ${rc} ${file} ${sha} ${extra}" >&2
            exit 65
        fi
        if [ -e "${out}/${file}" ]; then
            echo "${list}: ${file} is listed twice" >&2
            exit 65
        fi
        echo "== ${repository} ${tag} ${file}"
        gh release download "${tag}" --repo "${repository}" --pattern "${file}" --dir "${tmp}"
        # shellcheck disable=SC2086
        echo "${sha}  ${tmp}/${file}" | ${sum} -c -
        gh attestation verify "${tmp}/${file}" --repo "${repository}" \
            --signer-workflow "${repository}/${signer}" \
            --source-ref "refs/tags/${rc}" > /dev/null
        echo "attestation verified: ${file}"
        mv "${tmp}/${file}" "${out}/${file}"
        count=$((count + 1))
    done < "${list}"
done

echo "${count}"
