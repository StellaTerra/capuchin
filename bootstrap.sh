#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_OSTREE_PACKAGES="$ROOT/packages/rpm-ostree.txt"
USER_FLATPAKS="$ROOT/packages/flatpaks-user.txt"
RPM_OSTREE_REPOS="$ROOT/repos/rpm-ostree-repos.txt"
RPM_REPO_FILES_DIR="$ROOT/repos/yum.repos.d"
RPM_GPG_DIR="$ROOT/repos/rpm-gpg"
USER_FLATPAK_REMOTES="$ROOT/repos/flatpak-remotes-user.txt"

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

  if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
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

main() {
  install_rpm_repo_files
  install_rpm_ostree_repo_packages
  ensure_flatpak_user_remotes
  install_missing_rpm_ostree_packages
  install_missing_user_flatpaks
}

main "$@"
