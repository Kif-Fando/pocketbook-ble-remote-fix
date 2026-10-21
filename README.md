# Bluetooth LE page-turner remotes do not work on PocketBook Verse Pro (and other Linux 3.10 models)

**Short version:** the remote pairs and connects fine, but no button press ever reaches the reader. The cause is not the remote and not the pairing — it is the `hid-generic` driver in PocketBook's Linux 3.10 kernel refusing to bind to the uHID device that BlueZ creates for Bluetooth LE HID devices. A single write to sysfs fixes it until the next reboot.

If you bought a cheap BLE page-turner, it shows up as connected, you can see it in the reader's Bluetooth menu, and absolutely nothing happens when you press the buttons — this is probably your problem. The remote is most likely fine. Do not return it yet.

## Affected hardware

Confirmed on:

- **PocketBook Verse Pro (PB634)**, firmware `U634.6.10.3425`, kernel `3.10.65+` — **broken**
- **PocketBook Verse Pro Color (PB634K3)**, firmware `U634k3.6.10.2544`, kernel `4.9.56+` — **works out of the box**

The same remote was used on both readers. It worked immediately on the Color model and never worked on the non-color one, which is what made the kernel version the prime suspect.

Any PocketBook model running a 3.10 kernel is expected to have the same problem, and any model on 4.9 or newer is expected to be fine. If you can check your kernel version, that is the single best predictor.

The remote in this case was a no-name BLE "TikTok/Instagram scrolling" clicker that identifies itself as:

```
I: Bus=0005 Vendor=05ac Product=022c Version=011b
N: Name="S22"
```

Vendor `05ac` is Apple's ID — these remotes impersonate an Apple keyboard, which is extremely common for this class of device. The exact vendor/product pair will differ for your remote; see below for how to find yours.

## Symptoms

- The remote pairs successfully and stays connected.
- The reader's Bluetooth screen lists it, often labelled `U-HID`.
- The key-assignment dialog never registers a press, so you cannot map the buttons.
- Nothing happens in the reading application.
- Factory reset and firmware reinstallation change nothing.

## Root cause

Everything in the Bluetooth stack works correctly. The breakage is in the very last step.

When a Bluetooth LE HID device connects, BlueZ (5.52 on this firmware) does its job properly: it discovers the HID-over-GATT service (UUID `0x1812`), reads the Report Map, enables notifications, and creates a kernel uHID device. The log line confirming this is:

```
HoG created uHID device
```

The device then appears in sysfs:

```
/sys/bus/hid/devices/0005:05AC:022C.0006
```

But it has **no driver and no input device**. Its modalias ends in `g0000`, meaning HID group `0x0000` (`HID_GROUP_DEFAULT`).

And that is the whole problem. In Linux 3.10, `hid-generic` declares its device table with a hardcoded group:

```c
static const struct hid_device_id hid_table[] = {
	{ HID_DEVICE(HID_BUS_ANY, HID_GROUP_GENERIC, HID_ANY_ID, HID_ANY_ID) },
	{ }
};
```

It only accepts `HID_GROUP_GENERIC` (`0x0001`). The uHID device created by BlueZ's HoG module stays at group `0x0000`, so `hid-generic` never matches it. Trying to force the bind manually returns `ENODEV`.

In Linux 4.9 the same table uses `HID_GROUP_ANY`, which is why the Verse Pro Color — and any modern Linux desktop — works with these remotes without anyone noticing there was ever an issue.

So the chain is: pairing OK → LE connection OK → GATT HID service OK → uHID device created OK → **driver bind fails** → no `/dev/input/event*` → no key events anywhere in the system.

## The fix

Register the device's ID dynamically with `hid-generic`. Dynamic IDs are matched with group `HID_GROUP_ANY`, which bypasses the hardcoded restriction entirely:

```sh
printf '0005 05AC 022C\n' > /sys/bus/hid/drivers/hid-generic/new_id
```

The format is `bus vendor product` in hex, where bus `0005` is `BUS_BLUETOOTH`. Substitute your own vendor and product IDs.

The bind happens immediately. Within a second the input device appears:

```
I: Bus=0005 Vendor=05ac Product=022c Version=011b
N: Name="S22"
P: Phys=88:6F:29:21:F9:E9
S: Sysfs=/devices/virtual/misc/uhid/input6
H: Handlers=kbd mouse0 event6
B: EV=1f
```

After this the reader's key-assignment dialog registers presses normally and page turning works.

### Requirements and limitations

- **Root is required.** `/sys/bus/hid/drivers/hid-generic/new_id` is writable only by root, and PocketBook's `sudo` requires a password that is not available to users. In practice this means a jailbreak such as [ezdiy/pbjb](https://github.com/ezdiy/pbjb) is needed. That carries its own risks — read its documentation before installing.
- **The effect does not survive a reboot.** Dynamic IDs live in kernel memory only. After every restart you have to connect the remote and run the command again.
- **The remote must already be connected** when you run the command, otherwise there is no sysfs device to bind.
- **Nothing persistent is modified.** No system file is touched, no partition is remounted. A reboot removes all traces. This is about as low-risk as a root-level change gets.

### Ready-to-use script

Saved as a `.app` file in `/mnt/ext1/applications/`, this appears in the reader's application list and can be launched by tapping it. It waits for the remote, applies the fix, and verifies the result:

```sh
#!/bin/sh

if [ "$1" = "--elevated" ] && [ -n "$2" ]; then
	LOG=$2
else
	LOG=/dev/null
	if [ "$(id -u)" != "0" ]; then
		if [ ! -x /mnt/secure/su ]; then
			printf 'ERROR: /mnt/secure/su is unavailable. Install the jailbreak first.\n' >"$LOG"
			exit 1
		fi
		exec /mnt/secure/su /bin/sh "$0" --elevated "$LOG" >"$LOG" 2>&1
	fi
fi

exec >"$LOG" 2>&1

DRIVER=/sys/bus/hid/drivers/hid-generic
if [ ! -w "$DRIVER/new_id" ]; then
	printf 'ERROR: hid-generic new_id is unavailable.\n'
	exit 1
fi

DEVICE=
COUNT=0
while [ "$COUNT" -lt 30 ]; do
	for candidate in /sys/bus/hid/devices/0005:05AC:022C.*; do
		[ -e "$candidate" ] || continue
		DEVICE=$candidate
		break
	done
	[ -n "$DEVICE" ] && break
	sleep 1
	COUNT=$((COUNT + 1))
done

if [ -z "$DEVICE" ]; then
	printf 'ERROR: remote not found after 30 seconds. Connect it and retry.\n'
	exit 1
fi

printf '0005 05AC 022C\n' >"$DRIVER/new_id"
sleep 1

if ! grep -q 'N: Name="S22"' /proc/bus/input/devices; then
	printf 'ERROR: bound, but no input device appeared.\n'
	exit 1
fi

printf 'FIX_READY=1\n'
printf 'The fix remains active until reboot.\n'
```

Replace `05AC:022C` and `Name="S22"` with the values for your own remote. Set `LOG` to a real path instead of `/dev/null` if you want to see what happened — the script is silent by design, since the reader gives no feedback when an app exits.

## How to find your remote's IDs

With the remote connected, as root:

```sh
ls /sys/bus/hid/devices/
```

You are looking for an entry starting with `0005:` (Bluetooth bus). The format is `0005:VVVV:PPPP.000N` where `VVVV` is the vendor and `PPPP` the product ID.

To confirm you are hitting this exact bug rather than something else, check that the device has no driver and no input device:

```sh
ls -l /sys/bus/hid/devices/0005:*/driver   # should fail: no such file
cat /sys/bus/hid/devices/0005:*/modalias   # should end in g0000
grep -c 'Bus=0005' /proc/bus/input/devices # should be 0
```

If `modalias` ends in `g0000` and there is no `driver` symlink, this fix applies to you.

Useful for deeper diagnosis, all present on the firmware:

```sh
hcitool con                  # shows whether the link is LE or BR/EDR
btmon                        # live HCI trace
bluetoothd -n -d             # bluetoothd in foreground with debug output
dmesg                        # kernel messages, including uhid
```

## What a proper fix would look like

This is a kernel-side bug and PocketBook can fix it properly in firmware. Either backport the 4.9 behaviour:

```c
{ HID_DEVICE(HID_BUS_ANY, HID_GROUP_ANY, HID_ANY_ID, HID_ANY_ID) },
```

or have the HoG code set `HID_GROUP_GENERIC` on devices it creates. Both are one-line changes affecting every BLE HID peripheral — remotes, keyboards, page-turners — on every PocketBook still shipping a 3.10 kernel.

Until that happens, the sysfs workaround above is the only option that does not involve building and flashing a custom kernel, which is not worth the risk for a page-turner.

## Credits

Diagnosed in October 2026 on a Verse Pro / Verse Pro Color pair by comparing both firmware images offline, then confirming live over a temporary SSH session on the reader. The jailbreak used for root access came from the [ezdiy/pbjb](https://github.com/ezdiy/pbjb) project, found via [MobileRead thread 325185](https://www.mobileread.com/forums/showthread.php?t=325185).

Shared in the hope that the next person searching for "PocketBook Bluetooth remote not working" finds an answer faster than we did.
