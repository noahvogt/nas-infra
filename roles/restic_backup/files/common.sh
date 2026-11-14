# shellcheck shell=bash
# Shared by the nas-backup scripts.
set -euo pipefail
# shellcheck source=/dev/null
. /etc/nas-backup/config.sh

# Only one backup job at a time (restic 0.14 has no --retry-lock): wait for the others.
with_lock() {
	exec 9>/run/lock/nas-backup.lock
	flock 9
}

# Recipient: primary address of the OMV notification settings, else root.
mail_to() {
	omv-confdbadm read conf.system.notification.email 2>/dev/null |
		python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["primaryemail"] if d.get("enable") and d.get("primaryemail") else "root")' ||
		echo root
}

# notify SUBJECT, body on stdin. OMV's postfix prefixes the subject with [hostname].
# Headers must be ASCII: the subject is RFC 2047 encoded (umlauts).
notify() {
	local to subject
	to=$(mail_to)
	subject="=?UTF-8?B?$(printf '%s' "$1" | base64 -w0)?="
	{
		printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n' "$to" "$subject"
		cat
	} | /usr/sbin/sendmail -t || echo "notify: sendmail failed" >&2
}

# Epoch seconds of the newest snapshot with tag nas in the repo given by "$@" (restic args), 0 if none.
latest_snapshot_epoch() {
	local t
	t=$(restic "$@" snapshots --tag nas --latest 1 --json |
		python3 -c 'import json, sys; s = json.load(sys.stdin) or []; print(max((x["time"] for x in s), default=""))')
	if [ -n "$t" ]; then date -d "$t" +%s; else echo 0; fi
}
