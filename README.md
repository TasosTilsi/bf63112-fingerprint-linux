# bf63112-fingerprint-linux

One-shot installer for the **Betterlife BF63112** SPI fingerprint sensor on
Debian/Ubuntu-family Linux, including getting it working on the graphical login
screen.

This is deliberately a **thin wrapper**, not a fork. All driver work belongs to
[dedbin/libfprint-bf63112](https://github.com/dedbin/libfprint-bf63112), which
this project clones at a pinned commit and never redistributes. This repo adds
the packaging that a normal person actually needs: one script, English output,
automated matcher download with hash pinning, the `fprintd` state-directory fix,
and opt-in PAM wiring.

```
git clone https://github.com/TasosTilsi/bf63112-fingerprint-linux
cd bf63112-fingerprint-linux
./install.sh
```

## Verified on

| Item | Value |
|---|---|
| Sensor | Betterlife BF63112, ACPI `BF63112`, sensor ID `0x5f83`, revision `0x03` |
| Bus | Intel LPSS SPI, `0000:00:12.6`, `spi-BF63112:00` on `spi0` |
| Board | `GLX258-R V0.0.6` |
| Distro | elementary OS 8 (Ubuntu 24.04 noble base) |
| Kernel | 7.0.0-38-generic |

Result: enrollment, verification, wrong-finger rejection, login-screen
fingerprint, and persistence across reboot were all confirmed on that machine.
Other hardware may work. Unknown hardware should be probed first.

## What it actually does

1. Checks for the `BF63112` SPI device.
2. Installs build/runtime packages.
3. Reads the sensor ID over SPI and refuses to continue unless it is `0x5f83`.
4. Downloads the OEM Blestech package from Microsoft Update Catalog and verifies
   size `2121392` and SHA-256 `9f85fbdb17794d33ec021dcbcacf90733e0a055f80dd77cea6e305c96678fdeb`.
5. Clones the upstream driver at commit `2e6bcf04950e02e25099f4257d042c4617cef6f6`.
6. On non-Ubuntu-24.04 systems, relaxes exactly one distro-identity predicate in
   the upstream installer, keeping every real check, with a backup.
7. Imports the matcher, fixes `/var/lib/fprint` to mode `0700`, installs.
8. Tests enrollment, verification, and that a **different finger is rejected**.
9. Optionally wires `pam_fprintd` into the login screen and/or `sudo`.

Nothing is written outside `/opt/bf63112`, `/etc/systemd/system/fprintd.service.d`,
`/etc/udev/rules.d`, `/etc/modprobe.d`, `/var/lib/fprint`, and, only with your
consent, `/etc/pam.d`.

## Options

```
--with-login   enable fingerprint at the graphical login screen
--with-sudo    enable fingerprint for sudo
--no-pam       never touch PAM
--rollback     remove the integration and restore PAM backups
--yes          unattended package installation and prompts
```

Default is interactive: it asks before touching any PAM file.

## Read this before enabling PAM

- **Password always keeps working.** The PAM lines use `sufficient` with
  `max-tries=3 timeout=30`, so a failed or slow touch falls through to the
  password prompt. Those are the module defaults: a single attempt with a
  10 second window was observed to give up before a first-login prompt appeared.
- **Keep a root TTY open** (`Ctrl+Alt+F3`) until you have logged in once. A broken
  PAM file can lock you out of the graphical session.
- **The login keyring will not unlock on a fingerprint login**, because no
  password reaches PAM. Applications that store secrets may ask for your password
  once. This is normal and matches GNOME behaviour.
- **The matcher is proprietary.** It is Blestech's Windows DLL, run through Wine
  inside bubblewrap. It is never bundled here. If you want no proprietary code in
  your authentication path, see the open alternative below.

## Rollback

```
./install.sh --rollback
```

Restores PAM backups and runs upstream's system rollback. Enrolled prints stay in
`/var/lib/fprint` unless you delete them.

After a `fprintd`, `libfprint`, or Wine upgrade, re-run `./install.sh`. The private
build under `/opt/bf63112` links against specific library versions.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). It documents every failure
hit while bringing this up, with symptom, cause, and fix.

## Credits and tribute

This project exists because of other people's work, in particular:

- **[dedbin/libfprint-bf63112](https://github.com/dedbin/libfprint-bf63112)** - the
  actual BF63112 driver, the native SPI capture, the vendor-engine ABI
  documentation, the isolation design, and the installer this wraps. LGPL-2.1.
  This repo is a derived wrapper and would be nothing without it.
- **[pythontyphon](https://github.com/pythontyphon)** - an alternative route with a
  fully open SIGFM matcher and no proprietary code, tested on ONEXPLAYER 3. If you
  want to avoid the Blestech DLL, start there.
- **[libfprint](https://gitlab.freedesktop.org/libfprint/libfprint)** and
  **fprintd**, the framework everything plugs into.
- **[linux-fingerprint-drivers](https://github.com/jedbillyb/linux-fingerprint-drivers)**
  - the community catalogue of unsupported sensors, which is how this sensor was
  identified.

## License

LGPL-2.1-or-later, matching upstream libfprint. See `COPYING` and `NOTICE`. The
proprietary Blestech matcher is not distributed here and is not covered.
