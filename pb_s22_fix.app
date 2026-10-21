#!/bin/sh

# Logging is disabled by default. To enable timestamped logs, comment out
# LOG=/dev/null and uncomment the STAMP/LOG lines below.

if [ "$1" = "--elevated" ] && [ -n "$2" ]; then
	LOG=$2
else
	LOG=/dev/null
	# STAMP=$(date '+%Y%m%d_%H%M%S' 2>/dev/null)
	# [ -n "$STAMP" ] || STAMP=unknown
	# LOG="${0}.${STAMP}.log"
	if [ "$(id -u)" != "0" ]; then
		if [ ! -x /mnt/secure/su ]; then
			printf 'ERROR: /mnt/secure/su is unavailable. Run Jailbreak.app first.\n' >"$LOG"
			exit 1
		fi
		exec /mnt/secure/su /bin/sh "$0" --elevated "$LOG" >"$LOG" 2>&1
	fi
fi

exec >"$LOG" 2>&1

printf 'PocketBook S22 HID binding fix\n'
printf 'log=%s\n' "$LOG"
date
printf 'uid=%s\n' "$(id -u)"

if [ "$(id -u)" != "0" ]; then
	printf 'ERROR: /mnt/secure/su did not elevate this app to root.\n'
	exit 1
fi

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
	printf 'ERROR: S22 HID device was not found after 30 seconds. Connect the remote and retry.\n'
	exit 1
fi

if [ "$(readlink "$DEVICE/driver" 2>/dev/null)" = "../../../../../bus/hid/drivers/hid-generic" ]; then
	printf 'S22_FIX_READY=1\n'
	printf 'device=%s\n' "$DEVICE"
	printf 'status=already-bound\n'
	exit 0
fi

printf '0005 05AC 022C\n' >"$DRIVER/new_id"
sleep 1

if [ "$(readlink "$DEVICE/driver" 2>/dev/null)" != "../../../../../bus/hid/drivers/hid-generic" ]; then
	printf 'ERROR: S22 did not bind to hid-generic.\n'
	exit 1
fi

if ! grep -q 'N: Name="S22"' /proc/bus/input/devices; then
	printf 'ERROR: hid-generic bound, but the S22 input device is absent.\n'
	exit 1
fi

printf 'S22_FIX_READY=1\n'
printf 'device=%s\n' "$DEVICE"
printf 'status=bound\n'
grep -A8 -B1 'N: Name="S22"' /proc/bus/input/devices
printf 'The fix remains active until reboot.\n'
