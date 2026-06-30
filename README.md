# Capuchin Provisioning

This repository is the rebuild recipe for Capuchin, Stella's laptop. The goal is
that after wiping the OS and reinstalling the same Fedora COSMIC Atomic base,
running this repo restores the laptop's host packages, user Flatpaks, Flatpak
remotes, RPM repositories, and selected home-directory configuration.

The provisioning is intentionally additive and idempotent. It installs missing
things and applies managed dotfiles, but it does not remove packages, uninstall
Flatpaks, or delete unmanaged home files.

## Layout

- `bootstrap.sh`: main provisioning script.
- `audit.sh`: read-only drift check for packages and Flatpak remotes.
- `packages/rpm-ostree.txt`: desired rpm-ostree layered packages.
- `packages/flatpaks-user.txt`: desired user Flatpak apps as
  `remote<TAB>application<TAB>branch`.
- `repos/rpm-ostree-repos.txt`: repo-release RPMs to layer, currently RPM
  Fusion free/nonfree.
- `repos/yum.repos.d/`: external RPM repo files copied into `/etc/yum.repos.d`.
- `repos/rpm-gpg/`: GPG keys copied into `/etc/pki/rpm-gpg`.
- `repos/flatpak-remotes-user.txt`: user Flatpak remotes.
- `.chezmoiroot`: tells chezmoi to treat `home/` as the source root.
- `home/`: chezmoi-managed home-directory state.

## What Bootstrap Does

`./bootstrap.sh` runs these phases in order:

1. Copies managed RPM GPG keys into `/etc/pki/rpm-gpg`.
2. Copies managed RPM repo files into `/etc/yum.repos.d`.
3. Layers missing repo-release RPMs with `rpm-ostree install`.
4. Adds missing user Flatpak remotes.
5. Layers missing packages from `packages/rpm-ostree.txt`.
6. Installs missing user Flatpak apps from `packages/flatpaks-user.txt`.
7. Applies home configuration with `chezmoi --source "$ROOT" apply` if
   `chezmoi` is available in the current boot.

The rpm-ostree comparison prefers a staged deployment when one exists. This
keeps repeated runs clean after a package has been installed but before the
machine has rebooted or `rpm-ostree apply-live` has been run.

## What Is Covered

System/package coverage:

- rpm-ostree layered packages, including `chezmoi`, VS Code, 1Password,
  borg/borgmatic, podman-compose, btop, vim, OpenVPN NetworkManager support,
  and RPM Fusion codec support.
- External RPM repos for RPM Fusion, 1Password, and VS Code.
- User Flatpak remotes for Flathub and COSMIC.
- User Flatpak apps, not runtime dependencies. Flatpak resolves runtimes itself.

Home configuration coverage:

- Shell startup files: `.bashrc`, `.bash_profile`.
- SSH config for the 1Password SSH agent.
- VS Code user setting for Podman-backed dev containers.
- Readaloud user config and user systemd service.
- WirePlumber audio rules for hidden/internal outputs and friendly device names.
- btop config.
- MIME defaults.
- Autostart entries for 1Password, Discord, and Signal.
- Curated COSMIC preferences: keyboard/input behavior, shortcuts, tiling/focus,
  panel composition, compact window controls, file manager preferences, applet
  preferences, minimon applet layout, and COSMIC system monitor layout.
- Codex config, excluding auth, sessions, caches, history, sqlite state, skills,
  packages, and approval rules.

Deliberately not covered:

- Browser profiles and Electron app state.
- 1Password databases, keyrings, cookies, tokens, and auth files.
- Codex `auth.json`, sessions, history, sqlite databases, generated skills, and
  downloaded packages.
- Flatpak runtime dependencies.
- COSMIC wallpaper image paths, screenshot rectangle state, and monitor output
  layout.
- Downloads, Trash, recent files, application caches, and generated logs.

## Rebuilding Capuchin

These steps assume a fresh Fedora COSMIC Atomic install on this laptop.

1. Complete the base OS installer.

   Use the same Fedora COSMIC Atomic base that this repo was built against.
   Create the normal `stella` user.

2. Boot into the fresh OS.

   Connect to the network. Open a terminal.

3. Install Git if it is not available.

   On a fresh atomic install, Git is usually present. If it is missing, install
   it with rpm-ostree and reboot:

   ```bash
   rpm-ostree install git
   systemctl reboot
   ```

4. Clone this repository.

   The expected local path is:

   ```bash
   cd /var/home/stella
   git clone <repo-url> capuchin
   cd capuchin
   ```

5. Run the bootstrap.

   ```bash
   ./bootstrap.sh
   ```

   The script will install repo files, add Flatpak remotes, install missing
   rpm-ostree packages, install missing user Flatpaks, and apply chezmoi if it
   is already available.

6. Reboot if rpm-ostree staged changes.

   If the output says changes were queued for next boot, reboot:

   ```bash
   systemctl reboot
   ```

   Alternatively, for simple package additions, you can try:

   ```bash
   sudo rpm-ostree apply-live
   ```

   A reboot is the more reliable path after a full rebuild.

7. Run the bootstrap again after reboot.

   ```bash
   cd /var/home/stella/capuchin
   ./bootstrap.sh
   ```

   This second run should be mostly no-op. It is important because `chezmoi` is
   installed by rpm-ostree, so home configuration may only be applicable after
   the first reboot.

8. Verify package drift.

   ```bash
   ./audit.sh
   ```

   A fully matching system reports:

   ```text
   rpm-ostree layered packages
     ok: matches repo
   rpm-ostree repo packages
     ok: matches repo
   flatpak user remote names
     ok: matches repo
   flatpak user apps
     ok: matches repo
   ```

9. Sign in to services and restore unmanaged state.

   Some state is intentionally not stored here. Sign in or restore separately
   for 1Password, browsers, Signal, Discord, Seafile, and any other apps whose
   secrets or runtime state are not managed by chezmoi.

10. Validate expected workstation behavior.

   Suggested checks:

   ```bash
   chezmoi --source /var/home/stella/capuchin diff
   systemctl --user status readaloud.service --no-pager
   flatpak list --user --app
   rpm-ostree status
   ./audit.sh
   ```

## Day-To-Day Maintenance

When adding a new rpm-ostree package intentionally:

1. Install it normally, or add it to `packages/rpm-ostree.txt` first.
2. Run `./bootstrap.sh`.
3. Run `./audit.sh`.
4. Commit the package-list change.

When adding a new user Flatpak intentionally:

1. Install the Flatpak.
2. Add a line to `packages/flatpaks-user.txt` with its remote, application ID,
   and branch.
3. Run `./audit.sh`.
4. Commit the package-list change.

When changing home configuration intentionally:

```bash
chezmoi --source /var/home/stella/capuchin add <path>
chezmoi --source /var/home/stella/capuchin diff
git diff
git add home
git commit
```

Be selective. Do not add app databases, auth files, browser profiles, keyrings,
downloaded caches, or generated logs.

## Drift Auditing

`./audit.sh` is read-only. It compares the repo against the current system and
reports both directions:

- `missing from system`: tracked in the repo but absent on the machine.
- `extra on system`: present on the machine but absent from the repo.

An extra item is not automatically bad. It means the machine has drifted from
the declared recipe and the item should either be added to the repo or removed
manually.

## Current Limits

This repo does not yet provision every possible part of the laptop. In
particular, it does not restore private application data, service logins,
browser profiles, monitor layout, wallpaper image assets, or large local project
checkouts. Those are either intentionally excluded for safety or should be
handled by a future dedicated backup/restore layer.
