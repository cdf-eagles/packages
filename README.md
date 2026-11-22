[![CI](https://github.com/cdf-eagles/packages/actions/workflows/ci.yaml/badge.svg)](https://github.com/cdf-eagles/packages/actions/workflows/ci.yaml)
[![Deploy](https://github.com/cdf-eagles/packages/actions/workflows/deploy.yaml/badge.svg)](https://github.com/cdf-eagles/packages/actions/workflows/deploy.yaml)

# packages

Signed apt, dnf, and apk repositories for this account's tools, served from GitHub Pages at <https://cdf-eagles.github.io/packages/>. Once a repository is added, the distribution's package manager installs the tools and offers each new release as an upgrade.

| Package | Installs | Source |
|---|---|---|
| `findbig` | the command `findbig`, which lists the largest files and directories under a directory, and its manual page (`man findbig`) | [py-findbig](https://github.com/cdf-eagles/py-findbig) |
| `zpool-status-exporter` | the Prometheus exporter for ZFS `zpool-status-exporter`, its systemd unit, its settings file `/etc/sysconfig/zpool-status-exporter`, and its manual page (`man 8 zpool-status-exporter`); served for dnf on x86_64 only | [zpool-status-exporter](https://github.com/cdf-eagles/zpool-status-exporter) |

## Installation

The commands below install findbig; install any other package in the table the same way, by its name.

### Debian and Ubuntu

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/packages-signing.asc https://cdf-eagles.github.io/packages/packages-signing.asc
sudo curl -fsSLo /etc/apt/sources.list.d/packages.sources https://cdf-eagles.github.io/packages/packages.sources
sudo apt update
sudo apt install findbig
```

### Red Hat Enterprise Linux (RHEL), Rocky Linux, AlmaLinux, and Fedora

```sh
sudo curl -fsSLo /etc/yum.repos.d/packages.repo https://cdf-eagles.github.io/packages/packages.repo
sudo dnf install findbig
```

dnf asks once to import the signing key; check its fingerprint against the one below before accepting.

### Alpine Linux

```sh
sudo wget -qO /etc/apk/keys/py-findbig.rsa.pub https://cdf-eagles.github.io/packages/py-findbig.rsa.pub
echo https://cdf-eagles.github.io/packages/alpine | sudo tee -a /etc/apk/repositories
sudo apk update
sudo apk add findbig
```

`apt upgrade`, `dnf upgrade`, and `apk upgrade` then install new releases.

## Keys

| Key | Signs | Identity |
|---|---|---|
| `packages-signing.asc` (OpenPGP, Ed25519) | the apt `InRelease` and `Release.gpg`, the dnf `repomd.xml`, and every `.rpm` | fingerprint `CFB4 69E9 9EB8 7CAA 961E  BF13 9241 DF59 F784 6543`, expires 2028-11-21 |
| `py-findbig.rsa.pub` (RSA 4096) | each `APKINDEX.tar.gz` and every `.apk` | the key py-findbig publishes with each release |

Both public keys are committed under `keys/`. The deploy refuses to sign with a secret key that does not match them. apt checks only the signed `InRelease`, so the `.deb` files themselves are not signed.

## How releases arrive

1. A project's final release opens a pull request here that adds one line per package file to `sources/<project>.txt`: the release tag, the release candidate tag its files were built under, the file name, and the file's SHA-256. The pull request comes from a GitHub App installed only on this repository.
2. CI runs on the pull request, and it is merged by hand.
3. The `Deploy` workflow runs on every push to `main`. It downloads each listed file from its project's GitHub release, checks it against its SHA-256, and verifies its build provenance attestation against the project's release workflow and release candidate tag (`scripts/fetch-release-files.sh`). It then builds the apt suite, the dnf repository, and the apk indexes, signs them (`scripts/build-repository.sh`), and deploys the site to GitHub Pages. With no files listed it builds nothing and deploys nothing.

No package file is stored in this repository; the GitHub releases remain the source of every file.

The site holds one apt suite, `stable`, with one component, `main`; a dnf repository under `rpm/`; and apk indexes for `x86_64` and `aarch64` under `alpine/`. apk-tools 2 downloads packages from the architecture's directory and apk-tools 3 from `noarch/`, so both hold a copy of each `.apk`, named `<name>-<version>.apk` as apk expects. The dnf repository and the apt suite hold every architecture's packages, and the package manager installs those that match the host; an `.apk` must be architecture-independent (`noarch`), and the build refuses any other.

### Adding a project

* `sources/<project>.conf` names the project's repository (`repository=`) and the release workflow that attests its files (`signer_workflow=`).
* `sources/<project>.txt` lists its files as above.
* The project's release workflow signs its `.rpm` with the OpenPGP key and any `.apk` with an RSA key whose public key is committed under `keys/` and copied to the site; a second apk key also needs a line in the Alpine instructions.

## Continuous integration

`.github/workflows/ci.yaml` runs on every pull request to `main`, every push of `main`, weekly, and by hand. `main` requires the `Lint`, `Secret scan`, `Repository`, and `Snyk` checks.

| Job | Runner | Does |
|---|---|---|
| `Lint` | Ubuntu 24.04 | `yamllint --strict`, then the pre-commit hooks: workflow and Dependabot schema checks, actionlint, shellcheck over the scripts, whitespace and private-key checks, and ripsecrets |
| `Secret scan` | Ubuntu 24.04 | gitleaks over the full history of an unshallow clone |
| `Repository` | Ubuntu 24.04 | `scripts/test-repository.sh`: builds two versions of two stand-in packages with nFPM and throwaway keys, one architecture-independent and one `.deb` and `.rpm` pair built for the runner's architecture, serves the repositories over HTTP, installs the first version and upgrades to the second on Debian 13, Ubuntu 26.04, AlmaLinux 9 and 10, and Alpine Linux 3.24 (the architecture-independent one only), then checks that the build refuses an `.apk` built for one architecture and that apt refuses the suite when it trusts a different key |
| `Snyk` | Ubuntu 24.04 | installs the Python tools pinned in `ci/requirements.txt` and tests them with the Snyk command-line interface (CLI); fails on any high or critical dependency issue, a scan error, or a missing `SNYK_TOKEN` secret |
| `Tool drift` | Ubuntu 24.04 | weekly only: opens an issue when a pinned tool that Dependabot cannot update falls behind |

`.github/workflows/deploy.yaml` holds the `Deploy` workflow described above. It reads the `PACKAGES_SIGNING_KEY` (OpenPGP) and `APK_SIGNING_KEY` (RSA) secrets, and only its `deploy` job can write to GitHub Pages.

## Contributing

* Work reaches `main` only through squash-merged pull requests from branches named `<type>/<short-description>`, with type one of `feat`, `fix`, `chore`, `docs`, or `ci`.
* Set up the checks:
  * `python3 -m venv .venv`
  * `.venv/bin/pip install -r ci/requirements.txt`
  * `PATH="$PWD/.venv/bin:$PATH" pre-commit install`
  * `PATH="$PWD/.venv/bin:$PATH" pre-commit run --all-files` and `PATH="$PWD/.venv/bin:$PATH" yamllint --strict .`
  * The `pre-push` hook runs gitleaks over the commits being pushed, so install it (`brew install gitleaks`).
* `scripts/test-repository.sh` runs on Linux with Docker, nFPM, GnuPG, `apt-ftparchive`, and `createrepo_c`. Behind a proxy, `DOCKER_RUN_ARGS` adds `docker run` arguments and `TEST_SETUP_SCRIPT` names a script run as root in each container before the test.
