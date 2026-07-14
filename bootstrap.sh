#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_OSTREE_PACKAGES="$ROOT/packages/rpm-ostree.txt"
RPM_OSTREE_BASE_REMOVALS="$ROOT/packages/rpm-ostree-base-removals.txt"
USER_FLATPAKS="$ROOT/packages/flatpaks-user.txt"
VSCODE_EXTENSIONS="$ROOT/packages/vscode-extensions.txt"
RPM_OSTREE_REPOS="$ROOT/repos/rpm-ostree-repos.txt"
RPM_REPO_FILES_DIR="$ROOT/repos/yum.repos.d"
RPM_GPG_DIR="$ROOT/repos/rpm-gpg"
USER_FLATPAK_REMOTES="$ROOT/repos/flatpak-remotes-user.txt"
SYSTEM_FILES_DIR="$ROOT/system"
FIREWALL_PORTS="$ROOT/system/firewalld-ports.txt"

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

fedora_version() {
  local version_id=""
  [[ -r /etc/os-release ]] || die "missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  version_id="${VERSION_ID:-}"
  [[ -n "$version_id" ]] || die "could not determine Fedora VERSION_ID"
  printf '%s\n' "$version_id"
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

install_system_files() {
  need_cmd cmp
  need_cmd grep
  need_cmd install
  need_cmd tee

  install_if_changed "$SYSTEM_FILES_DIR/etc/borgmatic/config.yaml" "/etc/borgmatic/config.yaml" 0600
  install_if_changed "$SYSTEM_FILES_DIR/etc/systemd/system/borgmatic-marmoset.service" "/etc/systemd/system/borgmatic-marmoset.service" 0644
  install_if_changed "$SYSTEM_FILES_DIR/etc/systemd/system/borgmatic-marmoset.timer" "/etc/systemd/system/borgmatic-marmoset.timer" 0644
  install_if_changed "$SYSTEM_FILES_DIR/etc/udev/rules.d/50-keychron.rules" "/etc/udev/rules.d/50-keychron.rules" 0644
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

normalize_home_directory() {
  need_cmd getent
  need_cmd usermod

  local user="stella"
  local expected_home="/home/stella"
  local current_home
  current_home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$current_home" ]] || die "user $user does not exist"

  if [[ "$current_home" == "$expected_home" ]]; then
    printf 'account: %s home is already %s\n' "$user" "$expected_home"
    return
  fi

  [[ -d "$expected_home" ]] || die "$expected_home does not exist; refusing to change $user home"
  printf 'account: setting %s home to %s without moving files\n' "$user" "$expected_home"
  as_root usermod --home "$expected_home" "$user"
}

configure_firewall_ports() {
  need_cmd firewall-cmd

  local changed=0
  local port
  while IFS= read -r port; do
    [[ -n "$port" && "$port" != \#* ]] || continue
    if as_root firewall-cmd --permanent --zone=public --query-port="$port" >/dev/null; then
      continue
    fi
    printf 'firewall: allowing %s in public zone\n' "$port"
    as_root firewall-cmd --permanent --zone=public --add-port="$port"
    changed=1
  done <"$FIREWALL_PORTS"

  if ((changed)); then
    as_root firewall-cmd --reload
  fi
}

install_rpm_ostree_repo_packages() {
  need_cmd rpm
  need_cmd rpm-ostree

  local version
  version="$(fedora_version)"

  local missing=()
  local name url expanded_url
  while read -r name url; do
    [[ -n "$name" && -n "$url" ]] || die "invalid repo entry in $RPM_OSTREE_REPOS"
    if rpm -q "$name" >/dev/null 2>&1; then
      continue
    fi

    expanded_url="${url//\{fedora_version\}/$version}"
    missing+=("$expanded_url")
  done < <(read_list "$RPM_OSTREE_REPOS")

  if ((${#missing[@]} == 0)); then
    printf 'rpm-ostree repos: all requested repo packages are already installed\n'
    return
  fi

  printf 'rpm-ostree repos: installing %d missing repo package(s)\n' "${#missing[@]}"
  rpm-ostree install "${missing[@]}"
  printf 'rpm-ostree repos: install staged; reboot may be required\n'
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

current_rpm_ostree_base_removals() {
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
    for package in sorted(set(target.get("requested-base-removals", []))):
        print(package)
' <<<"$status_json"
}

remove_base_rpm_ostree_packages() {
  need_cmd rpm-ostree
  need_cmd python3

  mapfile -t wanted < <(read_list "$RPM_OSTREE_BASE_REMOVALS" | sort -u)
  mapfile -t removed < <(current_rpm_ostree_base_removals)

  mapfile -t missing < <(
    comm -23 \
      <(printf '%s\n' "${wanted[@]}" | sort -u) \
      <(printf '%s\n' "${removed[@]}" | sort -u)
  )

  if ((${#missing[@]} == 0)); then
    printf 'rpm-ostree base removals: all requested base packages are already removed\n'
    return
  fi

  printf 'rpm-ostree base removals: removing %d base package(s): %s\n' "${#missing[@]}" "${missing[*]}"
  rpm-ostree override remove "${missing[@]}"
  printf 'rpm-ostree base removals: removal staged; reboot may be required\n'
}

install_missing_rpm_ostree_packages() {
  need_cmd rpm-ostree
  need_cmd python3

  mapfile -t wanted < <(read_list "$RPM_OSTREE_PACKAGES" | sort -u)
  mapfile -t installed < <(current_rpm_ostree_packages)

  mapfile -t missing < <(
    comm -23 \
      <(printf '%s\n' "${wanted[@]}" | sort -u) \
      <(printf '%s\n' "${installed[@]}" | sort -u)
  )

  if ((${#missing[@]} == 0)); then
    printf 'rpm-ostree: all requested packages are already installed\n'
    return
  fi

  printf 'rpm-ostree: installing %d missing package(s): %s\n' "${#missing[@]}" "${missing[*]}"
  rpm-ostree install "${missing[@]}"
  printf 'rpm-ostree: install staged; reboot may be required\n'
}

ensure_flatpak_user_remote() {
  local remote="$1"
  local url="$2"

  if flatpak remotes --user --columns=name | grep -Fxq "$remote"; then
    return
  fi

  printf 'flatpak remotes: adding user remote %s\n' "$remote"
  flatpak remote-add --user --if-not-exists "$remote" "$url"
}

ensure_flatpak_user_remotes() {
  need_cmd flatpak
  need_cmd grep

  local remote url
  while read -r remote url; do
    [[ -n "$remote" && -n "$url" ]] || die "invalid Flatpak remote entry in $USER_FLATPAK_REMOTES"
    ensure_flatpak_user_remote "$remote" "$url"
  done < <(read_list "$USER_FLATPAK_REMOTES")
}

current_user_flatpaks() {
  flatpak list --user --app --columns=origin,application,branch |
    awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' |
    sort -u
}

install_missing_user_flatpaks() {
  need_cmd flatpak
  need_cmd awk

  mapfile -t wanted < <(read_list "$USER_FLATPAKS" | awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' | sort -u)
  mapfile -t installed < <(current_user_flatpaks)

  mapfile -t missing < <(
    comm -23 \
      <(printf '%s\n' "${wanted[@]}" | sort -u) \
      <(printf '%s\n' "${installed[@]}" | sort -u)
  )

  if ((${#missing[@]} == 0)); then
    printf 'flatpak: all requested user refs are already installed\n'
    return
  fi

  local remote app branch
  for ref in "${missing[@]}"; do
    IFS=$'\t' read -r remote app branch <<<"$ref"
    printf 'flatpak: installing %s//%s from %s\n' "$app" "$branch" "$remote"
    flatpak install --user --assumeyes "$remote" "$app//$branch"
  done
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

main() {
  normalize_home_directory
  install_rpm_repo_files
  install_system_files
  configure_firewall_ports
  install_rpm_ostree_repo_packages
  ensure_flatpak_user_remotes
  remove_base_rpm_ostree_packages
  install_missing_rpm_ostree_packages
  install_missing_user_flatpaks
  install_missing_vscode_extensions
  apply_home_config
}

main "$@"
