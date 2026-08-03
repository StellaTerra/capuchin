# Capuchin Provisioning

This repository is the rebuild recipe for Stella's Aurora-DX laptop. The
bootstrap is idempotent: it installs missing software and managed files without
deleting unmanaged system state. One known legacy root-slice oomd override is
explicitly removed by the `host` scope.

## Managed State

- explicitly layered RPM packages and the 1Password RPM repository
- Homebrew formulae and personal system-scoped Flatpaks declared in `Brewfile`
- VS Code extensions
- VS Code, Toshy, shell, SSH, Readaloud, and selected application configuration
- selected KDE Plasma settings, the thermal-monitor plasmoid, and five wallpapers
- device-specific WirePlumber workarounds for the Kanto ORA speakers
- independent Borgmatic configurations and logs for the local Marmoset and
  off-site BorgBase repositories, orchestrated by one low-priority service
- a 16 GiB low-priority disk swapfile on encrypted Btrfs storage
- Fedora's default pressure-based systemd-oomd policy, without the legacy
  root-slice swap-triggered kill override
- Seafile/application autostart, MIME associations, and the `marmoset` hosts entry

Toshy chooses and layers its own native dependencies. They are listed in
`packages/rpm-ostree-allowed.txt` so drift auditing recognizes them without
bootstrap trying to install or version them.

Aurora manages graphical applications system-wide through Bazaar and Brewfile
`flatpak` entries. Aurora's default Flatpaks remain owned by Aurora; this repo's
`Brewfile` declares only Stella's personal additions. Secrets, account
sessions, fingerprints, TPM tokens, VPN profiles, printer queues, browser
profiles, monitor layout, wallets, and mutable application databases are
restored separately.
`~/Downloads` is disposable, excluded from Borg, and must not contain
rebuild-critical state.

## Bootstrap Scopes

```bash
./bootstrap.sh host      # encrypted disk swap and systemd-oomd root policy
./bootstrap.sh packages  # RPM layering, Brew, system Flatpaks, VS Code extensions
./bootstrap.sh home      # apply the Chezmoi source
./bootstrap.sh borg      # Borg package, config, service, and timer
./bootstrap.sh all       # host plus all other scopes; also the default
```

The scopes make it possible to provision Borg without touching the desktop.
The `home` scope intentionally performs the normal Chezmoi apply. During
development, preview and review changes in small batches before invoking it.

## Rebuilding Capuchin

1. Install the Aurora-DX image. During installation, create user `stella`,
   enable password-based disk encryption, connect Wi-Fi, and set the hostname
   to `capuchin`. Aurora-DX can be installed directly; if standard Aurora was
   installed instead, use `ujust devmode` to switch to the Developer
   Experience image.

   Aurora records the account home as `/var/home/stella`; `/home/stella` is
   the corresponding compatibility path on the Atomic filesystem.

2. Add the 1Password RPM repository and layer 1Password and its CLI:

   ```bash
   curl -fsSL \
     https://downloads.1password.com/linux/keys/1password.asc \
     -o /tmp/1password.asc
   sudo install -Dm644 /tmp/1password.asc \
     /etc/pki/rpm-gpg/1password.asc
   sudo tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
   [1password]
   name=1Password Stable Channel
   baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
   enabled=1
   gpgcheck=1
   repo_gpgcheck=1
   gpgkey=file:///etc/pki/rpm-gpg/1password.asc
   EOF
   rpm-ostree install 1password 1password-cli
   systemctl reboot
   ```

3. Sign in to 1Password. Enable its SSH agent and CLI integration under
   **Settings > Developer**, then verify GitHub access:

   ```bash
   SSH_AUTH_SOCK="$HOME/.1password/agent.sock" ssh -T git@github.com
   ```

4. Clone Capuchin:

   ```bash
   cd /home/stella
   SSH_AUTH_SOCK="$HOME/.1password/agent.sock" \
     git clone git@github.com:StellaTerra/capuchin.git
   cd capuchin
   ```

5. Install Toshy before applying the managed home configuration. Download the
   current Toshy source from its upstream repository and run its standard
   installer:

   ```bash
   cd /home/stella
   git clone https://github.com/RedBearAK/Toshy.git
   cd Toshy
   ./setup_toshy.py install
   systemctl reboot
   ```

   Toshy owns its virtual environment, native dependency choices, user
   services, helper scripts, KWin integration, and preferences database.
   Chezmoi owns only `~/.config/toshy/toshy_config.py`, including the Keychron,
   VS Code, and terminal overrides in Toshy's protected editable slices.

6. Provision packages and home configuration. A Toshy installation may stage
   an rpm-ostree deployment; reboot first when requested.

   ```bash
   cd /home/stella/capuchin
   ./bootstrap.sh host
   ./bootstrap.sh packages
   systemctl reboot
   cd /home/stella/capuchin
   ./bootstrap.sh packages
   ./bootstrap.sh home
   ```

7. Enroll the encrypted disk with the TPM using Aurora's supported recipe.
   Preview it first, then follow the interactive prompts:

   ```bash
   ujust -n toggle-tpm2
   ujust toggle-tpm2
   systemctl reboot
   ```

8. Clone and install Readaloud:

   ```bash
   cd /home/stella
   git clone git@github.com:StellaTerra/readaloud.git
   cd readaloud
   ./install.sh
   install -Dm755 examples/speak-selection-wayland \
     /home/stella/.local/bin/speak-selection
   ```

9. Enroll fingerprints in **System Settings > Users > Configure Fingerprint
   Authentication**. Lock the session and confirm fingerprint authentication.
   For command-line diagnostics, `fprintd-verify` remains available.

10. Fetch fresh VPN profiles from their authoritative sources. Create a private
    staging directory outside `Downloads`:

    ```bash
    install -d -m 700 /home/stella/.config/vpn
    ```

    Download a current OpenVPN profile from the PIA account website, place it
    at `/home/stella/.config/vpn/pia-france.ovpn`, and import it:

    ```bash
    chmod 600 /home/stella/.config/vpn/pia-france.ovpn
    nmcli connection import type openvpn \
      file /home/stella/.config/vpn/pia-france.ovpn
    nmcli connection up "PIA - France" --ask
    ```

    Use the credentials from the 1Password item **Private Internet Access**.
    Rename the imported connection before bringing it up if NetworkManager
    chose a different name.

    While connected to the home network, copy Capuchin's generated WireGuard
    peer configuration directly from Marmoset and import it:

    ```bash
    ssh marmoset \
      'sudo cat /var/marmoset/vpn/wireguard/peer_capuchin/peer_capuchin.conf' \
      > /home/stella/.config/vpn/marmoset-capuchin.conf
    chmod 600 /home/stella/.config/vpn/marmoset-capuchin.conf
    nmcli connection import type wireguard \
      file /home/stella/.config/vpn/marmoset-capuchin.conf
    nmcli connection show
    ```

    NetworkManager keeps its own imported copies. Remove the staging files
    after both connections work:

    ```bash
    rm /home/stella/.config/vpn/pia-france.ovpn \
       /home/stella/.config/vpn/marmoset-capuchin.conf
    rmdir /home/stella/.config/vpn
    ```

11. Build Codex Desktop in an Ubuntu toolbox so compiler and build dependencies
    stay off the Atomic host. Install the project's user-local integration; an
    AppImage build is not needed:

    ```bash
    cd /home/stella
    git clone https://github.com/ilysenko/codex-desktop-linux.git
    cd codex-desktop-linux
    toolbox create --distro ubuntu --release 26.04 ubuntu-toolbox-26.04
    toolbox run --container ubuntu-toolbox-26.04 \
      bash -lc 'cd /home/stella/codex-desktop-linux && bash scripts/install-deps.sh'
    ./contrib/user-local-install/install-user-local.sh
    toolbox run --container ubuntu-toolbox-26.04 \
      bash -lc '/home/stella/.local/bin/codex-desktop-update --force'
    ```

12. Restore the Borg credentials from their 1Password item. Substitute that
    item's vault and title if necessary:

    ```bash
    sudo install -d -o root -g root -m 0700 /etc/borg-marmoset
    op read 'op://Private/Marmoset Borg Capuchin/private key' | \
      sudo install -o root -g root -m 0600 /dev/stdin /etc/borg-marmoset/ssh_key
    op read 'op://Private/Marmoset Borg Capuchin/public key' | \
      sudo install -o root -g root -m 0644 /dev/stdin /etc/borg-marmoset/ssh_key.pub
    op read 'op://Private/Marmoset Borg Capuchin/Repo Encryption Passphrase' | \
      sudo install -o root -g root -m 0600 /dev/stdin /etc/borg-marmoset/passphrase
    ssh-keyscan -t ed25519 marmoset | \
      sudo install -o root -g root -m 0644 /dev/stdin /etc/borg-marmoset/known_hosts
    ```

    Deploy only the Borg scope, then validate ownership, configuration, and
    repository access. The directory should be `root:root 700`; the private
    key and passphrase `600`; and the public key and known-hosts file `644`.

    ```bash
    cd /home/stella/capuchin
    ./bootstrap.sh borg
    sudo stat -c '%U:%G %a %n' /etc/borg-marmoset /etc/borg-marmoset/*
    sudo borgmatic --config /etc/borgmatic/config.yaml config validate
    sudo borgmatic --config /etc/borgmatic/config.yaml \
      list --archive latest --path etc/passwd --short
    ```

    Codex transcripts live under `~/.codex/sessions` and are backed up. To
    restore task history before launching Codex:

    ```bash
    sudo borgmatic --config /etc/borgmatic/config.yaml \
      extract --archive latest --path var/home/stella/.codex --destination /
    sudo chown -R stella:stella /home/stella/.codex
    ```

    Provision the independent BorgBase credentials from the 1Password item
    **BorgBase Borg Capuchin**. The assigned SSH key is append-only; the
    protected personal management key is not installed on Capuchin.

    ```bash
    sudo install -d -o root -g root -m 0700 /etc/borgbase-capuchin
    op read 'op://Private/BorgBase Borg Capuchin/private key' | \
      sudo install -o root -g root -m 0600 /dev/stdin /etc/borgbase-capuchin/ssh_key
    op read 'op://Private/BorgBase Borg Capuchin/public key' | \
      sudo install -o root -g root -m 0644 /dev/stdin /etc/borgbase-capuchin/ssh_key.pub
    op read 'op://Private/BorgBase Borg Capuchin/Repo Encryption Passphrase' | \
      sudo install -o root -g root -m 0600 /dev/stdin /etc/borgbase-capuchin/passphrase
    ```

    Populate `/etc/borgbase-capuchin/known_hosts` only after comparing the
    scanned keys with BorgBase's published SSH host-key fingerprints:

    ```bash
    ssh-keyscan tqqo6ove.repo.borgbase.com | \
      sudo install -o root -g root -m 0644 /dev/stdin /etc/borgbase-capuchin/known_hosts
    sudo stat -c '%U:%G %a %n' /etc/borgbase-capuchin /etc/borgbase-capuchin/*
    ```

    `./bootstrap.sh borg` installs and enables one combined Capuchin timer. It
    always runs the existing Marmoset backup first. The BorgBase step requires
    the root-owned `/etc/borgbase-capuchin/enable-full-backup` marker, so a
    routine bootstrap cannot upload the full workstation before its smoke
    restore and quota validation are complete.

    Finally, audit the workstation and run one backup:

    ```bash
    cd /home/stella/capuchin
    ./audit.sh
    chezmoi --source /home/stella/capuchin diff
    code --list-extensions
    toshy-services-status
    readaloud doctor
    sudo systemctl start borgmatic-capuchin.service
    systemctl status borgmatic-capuchin.service --no-pager
    ```

## BorgBase Off-site Backup

The existing Marmoset backup remains unchanged as a destination. BorgBase is a
second repository with its own config, credentials, log, and notification.
Both destination configs deep-merge `capuchin-common.yaml`, which owns the
shared source directories and exclusion policy. Change those paths only in the
common file so the local and off-site archives cannot drift apart.
The root-only Borg client credential directories are exact exclusions because
their authoritative copies and recovery material live in 1Password.
One persistent timer invokes `/usr/local/sbin/borgmatic-capuchin-backup`, which
runs Marmoset first and BorgBase second. If Marmoset fails, BorgBase is still
attempted; the combined service fails if either enabled destination fails.

The script holds `/run/lock/borgmatic-capuchin.lock` for the complete sequence,
preventing another scheduled or manual run from competing for resources. The
service uses the idle CPU and I/O scheduling classes, nice level 19, and the
minimum cgroup CPU and I/O weights. These are priorities rather than a hard CPU
limit: desktop work takes precedence, while backups can use otherwise-idle
capacity and still finish.

The BorgBase policy is:

- daily start at 03:17 with up to 10 minutes of jitter
- both repositories retain 14 daily, 8 weekly, 12 monthly, and 5 yearly
  archives
- a repository consistency check no more than monthly
- three retries with increasing 10-second waits for transient failures
- client-side `repokey-blake2` encryption when the repository is initialized
- no client compaction; BorgBase performs the enabled server-side compaction
  monthly
- a 100 GB hard repository quota, initially using about 20.23 GB

The BorgBase repository currently follows BorgBase's `Latest stable` setting,
while Capuchin uses the Borg client supplied by Aurora. Check compatibility
before either side moves to a new Borg major version.

### Repository initialization and activation

On a new or rebuilt client, do not create the enable marker yet. The combined
timer can safely remain enabled because it skips BorgBase while the marker is
absent. After reviewing and deploying this configuration, initialize the empty
repository and create only a tiny test archive with the same root-only
credentials used by the service:

```bash
borgbase_repo='ssh://tqqo6ove@tqqo6ove.repo.borgbase.com/./repo'
borgbase_rsh='ssh -i /etc/borgbase-capuchin/ssh_key -o UserKnownHostsFile=/etc/borgbase-capuchin/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes'

sudo env \
  BORG_RSH="$borgbase_rsh" \
  BORG_PASSCOMMAND='cat /etc/borgbase-capuchin/passphrase' \
  borg init --encryption=repokey-blake2 "$borgbase_repo"

sudo env \
  BORG_RSH="$borgbase_rsh" \
  BORG_PASSCOMMAND='cat /etc/borgbase-capuchin/passphrase' \
  borg create --stats \
  "$borgbase_repo"::capuchin-smoke-{now:%Y-%m-%dT%H:%M:%S} /etc/hostname
```

Export the Borg encryption key as the Private-vault 1Password Document
**BorgBase Borg Capuchin Repo Encryption Key** before relying on the repository.
The passphrase remains in the **BorgBase Borg Capuchin** SSH Key item. Do not
leave the exported recovery file on Capuchin. Listing and extracting
`/etc/hostname` from the smoke archive are the next verification checkpoint.

Only after the smoke restore succeeds, recovery material is safely stored,
and the paid-plan quota is configured should the full backup be activated:

```bash
sudo install -o root -g root -m 0600 /dev/null \
  /etc/borgbase-capuchin/enable-full-backup
```

The next combined run will perform Marmoset and then BorgBase. To run it
immediately, explicitly start `borgmatic-capuchin.service`.

Inspect failures with:

```bash
systemctl status borgmatic-capuchin.service --no-pager
sudo journalctl -u borgmatic-capuchin.service
sudo less /var/log/borgmatic-marmoset.log
sudo less /var/log/borgmatic-borgbase-capuchin.log
```

BorgBase stale-backup alerts remain intentionally disabled for now. Enable
them when alerting is desired; the daily timer is already authoritative.

## Device Notes

The `host` scope creates `/var/swap` as a dedicated Btrfs subvolume and a
16 GiB `/var/swap/swapfile`. Because `/var` resides on the installer's LUKS
volume, disk swap inherits full-disk encryption. The native
`var-swap-swapfile.swap` unit activates it at priority 10, after Aurora's
priority-100 zram. Only after disk swap is active does provisioning remove the
legacy `/etc/systemd/system/-.slice.d/50-managed-oom.conf` override. Fedora's
pressure-based systemd-oomd defaults remain active.

Aurora provides the system Flathub remote and its application-management tools
use that installation. Bootstrap validates and consumes it through `Brewfile`;
it does not create a separate user remote or duplicate applications per-user.

Aurora's default `FedoraWorkstation` firewalld zone permits high TCP and UDP
ports, including LocalSend's port 53317. Do not add a special rule unless
LocalSend stops working and the active zone no longer permits that port.

Aurora ships `/usr/lib/udev/rules.d/92-viia.rules`, which grants the hidraw
access needed by the Keychron keyboard. A repo-owned Keychron rule is not
needed while that hardware enablement remains present.

The Kanto ORA reports an unusable ALSA dB curve, so
`51-kanto-ora-volume.conf` tells WirePlumber to ignore it. The ORA and Fractal
Scape dongle also share a nested full-speed USB hub; forcing S16LE/48 kHz keeps
their combined isochronous bandwidth schedulable. Re-test the second rule if
the devices move to independent USB paths.

## Day-To-Day Maintenance

Update `Brewfile` for Brew formulae and personal Flatpaks, or the appropriate
file under `packages/` for other software. Add home configuration through
Chezmoi in small reviewed batches:

```bash
chezmoi --source /home/stella/capuchin add <path>
chezmoi --source /home/stella/capuchin diff <path>
git diff -- home
chezmoi --source /home/stella/capuchin apply --dry-run --verbose <path>
chezmoi --source /home/stella/capuchin apply <path>
```

Before a full home apply:

```bash
chezmoi --source /home/stella/capuchin status
chezmoi --source /home/stella/capuchin diff
./bootstrap.sh home
```

Do not add monitor layout, app databases, authentication files, browser
profiles, keyrings, caches, logs, Toshy's virtual environment, or its SQLite
preferences database.

## Drift Auditing

`./audit.sh` is read-only. It compares managed state with the current system:

- `missing from system`: tracked in the repo but absent on the machine.
- `extra on system`: directly requested state absent from the repo.

Toshy-owned layered packages are accepted through
`packages/rpm-ostree-allowed.txt`. The Flatpak audit checks only that personal
additions from this repo are present; Aurora's own defaults are expected extras.
An extra item is not automatically bad; it identifies state that is not in the
declared recipe.
