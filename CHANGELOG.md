# Changelog

- 2026-11-22
  - The repository starts as a signed apt, dnf, and apk repository served from GitHub Pages, with py-findbig as its first source. Releases are listed in `sources/`; each deploy downloads the listed files, checks them against their SHA-256 and their build provenance attestations, then builds and signs the indexes. Found internally from backlog item 580.
  - Continuous integration (CI) lints the YAML, the workflows, and the shell scripts, scans the full history for secrets with gitleaks, tests the CI tool pins with Snyk, and proves the repositories end to end: a stand-in package installs and upgrades on Debian 13, Ubuntu 24.04, AlmaLinux 9 and 10, and Alpine Linux 3.24, and apt refuses the repository under an untrusted key.
