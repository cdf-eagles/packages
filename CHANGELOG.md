# Changelog

- 2026-11-23
  - Continuous integration (CI) retries each pinned tool download (`--retry 8 --retry-delay 30 --retry-max-time 300 --retry-all-errors`) for up to about five minutes, so a passing error from GitHub's release download service, such as the 504 replies of 2026-11-08, no longer fails the job before its checks run; the SHA-256 check after each download is unchanged. Found internally from backlog item 516.
- 2026-11-22
  - zpool-status-exporter joins as the second source, with its `.rpm` for x86_64 only (`sources/zpool-status-exporter.conf` and `.txt`). The build refuses an `.apk` that is not architecture-independent, and the repository test adds a stand-in `.deb` and `.rpm` built for the runner's architecture. Found internally from backlog item 632.
  - The AlmaLinux 9 repository test runs on AlmaLinux 9.7 again: Dependabot had raised its image to AlmaLinux 10.3, so AlmaLinux 9 went untested, and it now ignores major updates of that image. The README names Ubuntu 26.04, the image Dependabot raised the Ubuntu test to.
  - The repository starts as a signed apt, dnf, and apk repository served from GitHub Pages, with py-findbig as its first source. Releases are listed in `sources/`; each deploy downloads the listed files, checks them against their SHA-256 and their build provenance attestations, then builds and signs the indexes. Found internally from backlog item 580.
  - Continuous integration (CI) lints the YAML, the workflows, and the shell scripts, scans the full history for secrets with gitleaks, tests the CI tool pins with Snyk, and proves the repositories end to end: a stand-in package installs and upgrades on Debian 13, Ubuntu 24.04, AlmaLinux 9 and 10, and Alpine Linux 3.24, and apt refuses the repository under an untrusted key.
