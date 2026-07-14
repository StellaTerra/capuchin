# Capuchin Provisioning

This repository is the rebuild recipe for Stella's Fedora COSMIC Atomic laptop.
`bootstrap.sh` is idempotent: it installs missing software and managed files
without deleting unmanaged state.

## Managed State

- rpm-ostree packages, removals, RPM repositories, and signing keys
- Flathub/COSMIC remotes and user Flatpaks
- VS Code settings and extensions
- Codex `config.toml`; Codex sessions and history are retained by Borg
- shell, SSH, WirePlumber, Readaloud, and selected application configuration
- selected COSMIC settings and five custom wallpapers
- Borgmatic configuration, service, and timer
- LocalSend firewall access, Seafile autostart, and MIME associations
- Keychron udev access and the `marmoset` LAN hosts entry

Secrets, account sessions, fingerprints, TPM tokens, VPN profiles, printer
queues, browser profiles, and monitor layout are restored separately.
`~/Downloads` is disposable, excluded from Borg, and must not contain any
rebuild-critical state.

## Rebuilding Capuchin

1. Install Fedora COSMIC Atomic. During installation, create user `stella`,
   enable password-based disk encryption, connect Wi-Fi, and set the hostname
   to `capuchin`. The bootstrap changes Stella's passwd entry to
   `/home/stella` without moving data; Fedora maps that path to `/var/home`.

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

4. Clone and provision Capuchin:

   ```bash
   cd /home/stella
   SSH_AUTH_SOCK="$HOME/.1password/agent.sock" \
     git clone git@github.com:StellaTerra/capuchin.git
   cd capuchin
   ./bootstrap.sh
   systemctl reboot
   cd /home/stella/capuchin
   ./bootstrap.sh
   ```

5. Enroll the encrypted disk with the TPM. First verify the LUKS device with
   `lsblk -f`; it is currently `/dev/nvme0n1p3`:

   ```bash
   sudo systemd-cryptenroll \
     --wipe-slot=tpm2 \
     --tpm2-device=auto \
     --tpm2-pcrs=7 \
     /dev/nvme0n1p3
   sudo rpm-ostree initramfs --enable \
     --arg=--force-add --arg=tpm2-tss \
     --arg=-I --arg=/etc/crypttab
   systemctl reboot
   ```

6. Clone and install Readaloud:

   ```bash
   cd /home/stella
   git clone git@github.com:StellaTerra/readaloud.git
   cd readaloud
   ./install.sh
   install -Dm755 examples/speak-selection-wayland \
     /home/stella/.local/bin/speak-selection
   ```

7. Enroll fingerprints:

   ```bash
   fprintd-enroll
   fprintd-verify
   ```

8. Fetch fresh VPN profiles from their authoritative sources. Create a private
   staging directory outside `Downloads`:

   ```bash
   install -d -m 700 /home/stella/.config/vpn
   ```

   Download a current OpenVPN profile from the PIA account website, place the
   selected `.ovpn` file at
   `/home/stella/.config/vpn/pia-france.ovpn`, and import it:

   ```bash
   chmod 600 /home/stella/.config/vpn/pia-france.ovpn
   nmcli connection import type openvpn \
     file /home/stella/.config/vpn/pia-france.ovpn
   nmcli connection up "PIA - France" --ask
   ```

   Use the credentials from the 1Password item **Private Internet Access**.
   Rename the imported connection before bringing it up if NetworkManager chose
   a different name.

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

   NetworkManager keeps its own imported copies. Remove the staging files after
   both connections work:

   ```bash
   rm /home/stella/.config/vpn/pia-france.ovpn \
      /home/stella/.config/vpn/marmoset-capuchin.conf
   rmdir /home/stella/.config/vpn
   ```

9. Build Codex Desktop in an Ubuntu toolbox so its compiler and build
   dependencies do not need to be layered onto the Atomic host. Install the
   project's user-local integration; an AppImage build is not needed:

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

10. Restore the Borg credentials from their 1Password item. Substitute that
    item's vault and title in these references if necessary:

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

    Validate file ownership and modes, Borg's configuration, and access to the
    latest archive. The directory should be `root:root 700`; the private key
    and passphrase `root:root 600`; and the public key and known-hosts file
    `root:root 644`. The final command should list `etc/passwd`:

    ```bash
    sudo stat -c '%U:%G %a %n' /etc/borg-marmoset /etc/borg-marmoset/*
    sudo borgmatic --config /etc/borgmatic/config.yaml config validate
    sudo borgmatic --config /etc/borgmatic/config.yaml \
      list --archive latest --path etc/passwd --short
    ```

    Codex transcripts live under `~/.codex/sessions` and are backed up. To
    restore local task history before launching Codex:

    ```bash
    sudo borgmatic --config /etc/borgmatic/config.yaml \
      extract --archive latest --path var/home/stella/.codex --destination /
    sudo chown -R stella:stella /home/stella/.codex
    ```

    Finally, verify the workstation and run one backup:

    ```bash
    cd /home/stella/capuchin
    ./audit.sh
    chezmoi --source /home/stella/capuchin diff
    code --list-extensions
    readaloud doctor
    sudo systemctl start borgmatic-marmoset.service
    systemctl status borgmatic-marmoset.service --no-pager
    ```

## Day-To-Day Maintenance

Update the appropriate file under `packages/` when packages, Flatpaks, or VS
Code extensions change. Add home configuration through chezmoi:

```bash
chezmoi --source /home/stella/capuchin add <path>
chezmoi --source /home/stella/capuchin diff
git diff
git add home
git commit
```

Then run `./bootstrap.sh` and `./audit.sh`. Do not add app databases, auth
files, browser profiles, keyrings, caches, or logs.

## Drift Auditing

`./audit.sh` is read-only. It compares the repo against the current system and
reports both directions:

- `missing from system`: tracked in the repo but absent on the machine.
- `extra on system`: present on the machine but absent from the repo.

An extra item is not automatically bad; it identifies state that is not in the
declared recipe.
