#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_OSTREE_PACKAGES="$ROOT/packages/rpm-ostree.txt"
RPM_OSTREE_BASE_REMOVALS="$ROOT/packages/rpm-ostree-base-removals.txt"
USER_FLATPAKS="$ROOT/packages/flatpaks-user.txt"
VSCODE_EXTENSIONS="$ROOT/packages/vscode-extensions.txt"
RPM_OSTREE_REPOS="$ROOT/repos/rpm-ostree-repos.txt"
USER_FLATPAK_REMOTES="$ROOT/repos/flatpak-remotes-user.txt"
FIREWALL_PORTS="$ROOT/system/firewalld-ports.txt"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

read_list() {
  local file="$1"
  [[ -f "$file" ]] || die "missing list: $file"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file"
}

print_diff() {
  local title="$1"
  local expected_file="$2"
  local actual_file="$3"
  local expected_sorted actual_sorted missing_file extra_file

  expected_sorted="$(mktemp)"
  actual_sorted="$(mktemp)"
  missing_file="$(mktemp)"
  extra_file="$(mktemp)"

  LC_ALL=C sort -u "$expected_file" >"$expected_sorted"
  LC_ALL=C sort -u "$actual_file" >"$actual_sorted"

  LC_ALL=C comm -23 "$expected_sorted" "$actual_sorted" >"$missing_file"
  LC_ALL=C comm -13 "$expected_sorted" "$actual_sorted" >"$extra_file"

  printf '%s\n' "$title"
  if [[ ! -s "$missing_file" && ! -s "$extra_file" ]]; then
    printf '  ok: matches repo\n'
    rm -f "$expected_sorted" "$actual_sorted" "$missing_file" "$extra_file"
    return
  fi

  if [[ -s "$missing_file" ]]; then
    printf '  missing from system:\n'
    sed 's/^/    /' "$missing_file"
  fi

  if [[ -s "$extra_file" ]]; then
    printf '  extra on system:\n'
    sed 's/^/    /' "$extra_file"
  fi

  rm -f "$expected_sorted" "$actual_sorted" "$missing_file" "$extra_file"
}

expected_rpm_ostree_repo_packages() {
  awk '{ print $1 }' < <(read_list "$RPM_OSTREE_REPOS") | sort -u
}

rpm_ostree_target_json() {
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
    json.dump(target, sys.stdout)
' <<<"$status_json"
}

actual_rpm_ostree_layered_packages() {
  rpm_ostree_target_json | python3 -c '
import json
import sys

target = json.load(sys.stdin)
for package in sorted(set(target.get("requested-packages", []))):
    print(package)
'
}

actual_rpm_ostree_base_removals() {
  rpm_ostree_target_json | python3 -c '
import json
import sys

target = json.load(sys.stdin)
for package in sorted(set(target.get("requested-base-removals", []))):
    print(package)
'
}

actual_rpm_ostree_repo_packages() {
  local package
  rpm_ostree_target_json | python3 -c '
import json
import sys

target = json.load(sys.stdin)
for package in target.get("requested-local-packages", []):
    print(package)
' | while read -r package; do
    rpm -q --queryformat '%{NAME}\n' "$package"
  done | sort -u
}

actual_flatpak_user_remotes() {
  flatpak remotes --user --columns=name | sort -u
}

actual_user_flatpaks() {
  flatpak list --user --app --columns=origin,application,branch |
    awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' |
    sort -u
}

audit_rpm_ostree_packages() {
  need_cmd rpm-ostree
  need_cmd python3

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$RPM_OSTREE_PACKAGES" | sort -u >"$expected"
  actual_rpm_ostree_layered_packages >"$actual"

  print_diff 'rpm-ostree layered packages' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_rpm_ostree_base_removals() {
  need_cmd rpm-ostree
  need_cmd python3

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$RPM_OSTREE_BASE_REMOVALS" | sort -u >"$expected"
  actual_rpm_ostree_base_removals >"$actual"

  print_diff 'rpm-ostree base removals' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_rpm_ostree_repo_packages() {
  need_cmd rpm
  need_cmd rpm-ostree
  need_cmd python3

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  expected_rpm_ostree_repo_packages >"$expected"
  actual_rpm_ostree_repo_packages >"$actual"

  print_diff 'rpm-ostree repo packages' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_flatpak_remotes() {
  need_cmd flatpak

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$USER_FLATPAK_REMOTES" | awk '{ print $1 }' | sort -u >"$expected"
  actual_flatpak_user_remotes >"$actual"

  print_diff 'flatpak user remote names' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_flatpaks() {
  need_cmd flatpak

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$USER_FLATPAKS" | awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' | sort -u >"$expected"
  actual_user_flatpaks >"$actual"

  print_diff 'flatpak user apps' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_vscode_extensions() {
  need_cmd code

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$VSCODE_EXTENSIONS" | sort -u >"$expected"
  code --list-extensions | sort -u >"$actual"

  print_diff 'VS Code extensions' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_firewall_ports() {
  need_cmd firewall-cmd

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$FIREWALL_PORTS" | sort -u >"$expected"
  firewall-cmd --permanent --zone=public --list-ports |
    tr ' ' '\n' | sed '/^$/d' | sort -u >"$actual"

  print_diff 'firewalld public-zone ports' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_home_directory() {
  need_cmd getent

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  printf '/home/stella\n' >"$expected"
  getent passwd stella | cut -d: -f6 >"$actual"

  print_diff 'stella passwd home' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

main() {
  audit_rpm_ostree_packages
  audit_rpm_ostree_base_removals
  audit_rpm_ostree_repo_packages
  audit_flatpak_remotes
  audit_flatpaks
  audit_vscode_extensions
  audit_firewall_ports
  audit_home_directory
}

main "$@"
