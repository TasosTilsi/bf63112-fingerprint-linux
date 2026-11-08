# Troubleshooting

Every entry below was actually hit while bringing a BF63112 up on elementary OS 8.
Symptom first, then cause, then fix.

## The sensor does not appear in `lsusb`

Not a fault. It is an SPI device, not USB. Look here instead:

```
ls /sys/bus/spi/devices/
cat /sys/bus/spi/devices/spi-BF63112:00/modalias     # acpi:BF63112:BF63112:
cat /sys/bus/acpi/devices/BF63112:00/status          # 15 = present and enabled
```

## `Finger detection timed out after 20000 ms`

Cause: the finger-detection window is 20 seconds per touch, armed the moment the
prompt prints. There is no visible countdown, so time spent reading the
instructions is time the sensor is not being touched.

Fix: touch immediately when the prompt appears. Each touch gets its own window.
Lift the finger cleanly between touches; the driver requires a full removal
debounced over 3 polls, so do not slide off. The constant is
`BF63112_FINGER_TIMEOUT_MS` in `libfprint/drivers/bf63112.c` and has no `#ifndef`
guard, so it can only be widened by editing the source and rebuilding.

## `Negative verification incorrectly matched the other finger`

Almost always a finger mixup, not a matcher defect. The check enrolls the RIGHT
INDEX and then requires the LEFT INDEX to be rejected. Touching the right index
at that step produces a correct match and a confusing error.

Fix: use the left index. To be certain the matcher is safe, re-run the negative
check and, if a distinct finger is ever accepted, treat the matcher as unusable
for authentication and do not enable PAM.

## Installer refuses: `only tested Ubuntu 24.04 is supported`

Cause: upstream's `install-system.sh` hard-requires `ID=ubuntu` and
`VERSION_ID=24.04`. This is a testedness gate, not a capability gate. On a
derivative such as elementary OS 8 the underlying system is still Ubuntu noble.

Fix: `install.sh` relaxes exactly that one predicate on non-Ubuntu systems,
keeps a backup beside the original, and leaves every substantive check
enforced (packages, amd64, fprintd service configuration, helper hashes, udev
rule constraints). Verified: with only that predicate relaxed, upstream's
read-only `--check` reports "check passed".

## `ERROR: /var/lib/fprint has the wrong owner/mode 0:0/755`

Cause: upstream requires `0700 root:root`. Ubuntu's fprintd package ships the
directory `0755`.

Fix: `sudo chmod 700 /var/lib/fprint`. This is the correct target:
`fprintd.service` declares `StateDirectory=fprint` with `StateDirectoryMode=0700`
and has no `User=`, so systemd would set it to `0700` anyway. `install.sh` does
this automatically.

Note: an unprivileged shell inside a user namespace may see this directory as
`65534:65534`, because host uid 0 is unmapped there. Verify with `sudo stat`.

## `BF63112 already has a bound driver`, then cleanup errors

Cause: a previous manual `spidev` bind is still active. Upstream's standalone
harness and installer require the device pristine because they bind it
themselves.

Fix, and the order matters:

```
sudo tee /sys/bus/spi/devices/spi-BF63112:00/driver_override <<<''
echo spi-BF63112:00 | sudo tee /sys/bus/spi/drivers/spidev/unbind
```

Clear the override first: `spidev`'s modalias never matches this device's ACPI
modalias, so `driver_override` is the only thing holding the bind. Unbinding
first leaves it immediately re-bindable, which is how cleanup ends up reporting
the device still bound.

Verify all three before retrying:

```
[ ! -L /sys/bus/spi/devices/spi-BF63112:00/driver ] && echo "no driver bound"
[ -z "$(< /sys/bus/spi/devices/spi-BF63112:00/driver_override)" ] && echo "override empty"
ls /dev/spidev* 2>/dev/null || echo "no spidev nodes"
```

## Login screen shows no fingerprint prompt

Check, in this order:

```
# is the PAM line in place, before @include common-auth?
grep -n fprint /etc/pam.d/lightdm

# does the stack authenticate at all? (safe: never touches the greeter)
pamtester lightdm "$USER" authenticate

# did the greeter even ask fprintd? 
journalctl -b | grep -i 'reactivated.Fprint'
```

If `pamtester` succeeds but the greeter does not prompt, the greeter is too old
to recognise it. Upstream `elementary/greeter` implements this in
`src/FPrintUtils.vala` and `src/MainWindow.vala`; rebuilding the greeter from
upstream source is the fix.

### No prompt on the FIRST login after a reboot, but it works after logout

**Status: intermittent, root cause NOT established.** Observed once on
2026-11-08 (boot 22:27: failed, password used; boot 23:03: worked, matched in 2 s).

What was ruled out, with evidence from that machine:

- **Device not ready.** udev wrote `driver_override` and bound spidev at
  `22:27:07.798`, before lightdm started at `22:27:09`. Ready in time.
- **PAM misconfiguration.** The boot attempt did reach fprintd
  (`dbus: Activated net.reactivated.Fprint, requested by lightdm --session-child`).
  `max-tries` and `timeout` parse correctly; the module logged
  `Waiting for 9 seconds (9996835 usecs)` for `timeout=10`.
- **Cold Wine start.** After `echo 3 > /proc/sys/vm/drop_caches` a verify still
  completed in 2.3 s, with `Pinned Betterlife fingerprint engine is ready`,
  `VerifyStart` and `Sensor ID 0x5f83` all in the same second.
- **A hanging verification.** fprintd is lazy about stopping: a successful boot
  kept it resident 43 s *after* login, so a long fprintd lifetime is not
  evidence of a long authentication.

Leading hypothesis, unproven: the greeter starts authentication roughly one
second after its own process starts, and the first PAM messages can arrive
before the login card is ready to display them, so no prompt is ever drawn.
That fits the failure appearing only on the first greeter after boot and never
after a logout.

Mitigation applied (not a fix): the PAM line now uses `max-tries=3 timeout=30`,
the module defaults, so a late or dropped first prompt still leaves further
attempts inside the same conversation. A single attempt with a 10 s window had
no second chance.

To actually diagnose a recurrence, the fprintd drop-in
`/etc/systemd/system/fprintd.service.d/debug.conf` with
`Environment=G_MESSAGES_DEBUG=all` must be installed *before* the failing boot,
and then:

```
journalctl -b -u fprintd --no-pager | head -60
journalctl -b --no-pager | grep -iE 'pam_fprintd|lightdm\[|reactivated.Fprint'
```

Note that enabling that logging perturbs boot timing, which may itself hide a
race. If the failure only reproduces without logging, that is the race
confirming itself.

## After typing a fingerprint at login, apps ask for my password

Expected. A finger never hands PAM your password, so the login keyring stays
locked. Type the password once to unlock it. GNOME behaves the same way.

## Fingerprint stopped working after a system update

A `fprintd`, `libfprint`, or Wine upgrade replaced libraries that
`/opt/bf63112` linked against. Re-run `./install.sh`. Your enrollment in
`/var/lib/fprint` is preserved.

## Lock screen (not login screen) ignores fingerprint

The lock screen is `gala`, which contains no fingerprint code at all, and
upstream has no such source file. This is a missing feature, not a
misconfiguration. Enabling it means writing it.
