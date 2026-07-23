#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_OSTREE_PACKAGES="$ROOT/packages/rpm-ostree.txt"
BORGMATIC_RPM_OSTREE_PACKAGES="$ROOT/packages/borg-rpm-ostree.txt"
VSCODE_EXTENSIONS="$ROOT/packages/vscode-extensions.txt"
RPM_REPO_FILES_DIR="$ROOT/repos/yum.repos.d"
RPM_GPG_DIR="$ROOT/repos/rpm-gpg"
SYSTEM_FILES_DIR="$ROOT/system"
BREWFILE="$ROOT/Brewfile"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

read_list() {
  local file="$1"
  [[ -f "$file" ]] || die "missing package list: $file"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file"
}

install_if_changed() {
  local source="$1"
  local destination="$2"
  local mode="$3"

  if [[ -r "$destination" ]] && cmp -s "$source" "$destination"; then
    return
  fi

  if [[ ! -r "$destination" ]] && as_root test -f "$destination" && as_root cmp -s "$source" "$destination"; then
    return
  fi

  printf 'repo: installing %s\n' "$destination"
  as_root install -D -m "$mode" "$source" "$destination"
}

install_rpm_repo_files() {
  need_cmd cmp
  need_cmd install

  local file
  for file in "$RPM_GPG_DIR"/*; do
    [[ -f "$file" ]] || continue
    install_if_changed "$file" "/etc/pki/rpm-gpg/$(basename "$file")" 0644
  done

  for file in "$RPM_REPO_FILES_DIR"/*.repo; do
    [[ -f "$file" ]] || continue
    install_if_changed "$file" "/etc/yum.repos.d/$(basename "$file")" 0644
  done
}

install_borg_files() {
  need_cmd cmp
  need_cmd grep
  need_cmd install
  need_cmd tee

  install_if_changed "$SYSTEM_FILES_DIR/etc/borgmatic/config.yaml" "/etc/borgmatic/config.yaml" 0600
  install_if_changed "$SYSTEM_FILES_DIR/etc/systemd/system/borgmatic-marmoset.service" "/etc/systemd/system/borgmatic-marmoset.service" 0644
  install_if_changed "$SYSTEM_FILES_DIR/etc/systemd/system/borgmatic-marmoset.timer" "/etc/systemd/system/borgmatic-marmoset.timer" 0644
  install_if_changed "$SYSTEM_FILES_DIR/usr/local/sbin/borgmatic-marmoset-backup" "/usr/local/sbin/borgmatic-marmoset-backup" 0755

  local hosts_entry
  while IFS= read -r hosts_entry; do
    [[ -n "$hosts_entry" && "$hosts_entry" != \#* ]] || continue
    if ! as_root grep -Fqx "$hosts_entry" /etc/hosts; then
      printf 'system: adding /etc/hosts entry: %s\n' "$hosts_entry"
      printf '%s\n' "$hosts_entry" | as_root tee -a /etc/hosts >/dev/null
    fi
  done <"$SYSTEM_FILES_DIR/etc/hosts.entries"

  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl daemon-reload
    as_root systemctl enable --now borgmatic-marmoset.timer
  fi

  for file in /etc/borg-marmoset/ssh_key /etc/borg-marmoset/known_hosts /etc/borg-marmoset/passphrase; do
    if ! as_root test -e "$file"; then
      printf 'borgmatic: missing secret file %s; restore it before backups can run\n' "$file"
    fi
  done
}

current_rpm_ostree_packages() {
  local status_json
  status_json="$(rpm-ostree status --json)"

  python3 -c '
import json
import sys

status = json.load(sys.stdin)
deployments = status.get("deployments", [])
target = next((deployment for deployment in deployments if deployment.get("staged")), None)
if target is None:
    target = next((deployment for deployment in deployments if deployment.get("booted")), None)

if target is not None:
    deployment = target
    packages = set(deployment.get("requested-packages", []))
    packages.update(deployment.get("requested-local-packages", []))
    for package in sorted(packages):
        print(package)
' <<<"$status_json"
}

install_missing_rpm_ostree_packages_from() {
  local package_file="$1"
  local label="$2"
  need_cmd rpm-ostree
  need_cmd python3

  mapfile -t wanted < <(read_list "$package_file" | sort -u)
  mapfile -t installed < <(current_rpm_ostree_packages)

  mapfile -t missing < <(
    comm -23 \
      <(printf '%s\n' "${wanted[@]}" | sort -u) \
      <(printf '%s\n' "${installed[@]}" | sort -u)
  )

  if ((${#missing[@]} == 0)); then
    printf '%s: all requested packages are already installed\n' "$label"
    return
  fi

  printf '%s: installing %d missing package(s): %s\n' "$label" "${#missing[@]}" "${missing[*]}"
  rpm-ostree install "${missing[@]}"
  printf '%s: install staged; reboot may be required\n' "$label"
}

install_missing_rpm_ostree_packages() {
  install_missing_rpm_ostree_packages_from "$RPM_OSTREE_PACKAGES" "rpm-ostree"
}

install_borg_rpm_ostree_packages() {
  install_missing_rpm_ostree_packages_from "$BORGMATIC_RPM_OSTREE_PACKAGES" "borg rpm-ostree"
}

install_brew_bundle() {
  need_cmd brew

  if brew bundle check --file="$BREWFILE" >/dev/null; then
    printf 'brew: bundle is already satisfied\n'
    return
  fi

  printf 'brew: installing missing bundle entries from %s\n' "$BREWFILE"
  brew bundle install --file="$BREWFILE"
}

install_missing_vscode_extensions() {
  if ! command -v code >/dev/null 2>&1; then
    printf 'vscode: not available in this boot; rerun after reboot\n'
    return
  fi

  mapfile -t wanted < <(read_list "$VSCODE_EXTENSIONS" | sort -u)
  mapfile -t installed < <(code --list-extensions | sort -u)
  mapfile -t missing < <(
    comm -23 \
      <(printf '%s\n' "${wanted[@]}" | sort -u) \
      <(printf '%s\n' "${installed[@]}" | sort -u)
  )

  if ((${#missing[@]} == 0)); then
    printf 'vscode: all requested extensions are already installed\n'
    return
  fi

  local extension
  for extension in "${missing[@]}"; do
    printf 'vscode: installing extension %s\n' "$extension"
    code --install-extension "$extension"
  done
}

apply_home_config() {
  if ! command -v chezmoi >/dev/null 2>&1; then
    printf 'chezmoi: not available in this boot; rerun after rpm-ostree apply-live or reboot\n'
    return
  fi

  printf 'chezmoi: applying home configuration from %s\n' "$ROOT"
  chezmoi --source "$ROOT" apply
}

packages_main() {
  install_rpm_repo_files
  install_missing_rpm_ostree_packages
  install_brew_bundle
  install_missing_vscode_extensions
}

home_main() {
  apply_home_config
}

borg_main() {
  install_borg_rpm_ostree_packages
  install_borg_files
}

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [all|packages|home|borg]

  all       Provision packages, Borg, and home configuration (default)
  packages  Provision host packages, Brew formulae, Flatpaks, and VS Code extensions
  home      Apply the Chezmoi home configuration
  borg      Install Borg packages, configuration, service, and timer
EOF
}

main() {
  local operation="${1:-all}"
  case "$operation" in
    all)
      packages_main
      borg_main
      home_main
      ;;
    packages)
      packages_main
      ;;
    home)
      home_main
      ;;
    borg)
      borg_main
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      die "unknown operation: $operation"
      ;;
  esac
}

main "$@"
