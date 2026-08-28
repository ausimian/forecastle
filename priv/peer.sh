#!/bin/sh

# Adapter between OTP's :peer command line and the stock Mix launcher.
#
# :peer appends emulator arguments to the executable it starts. The Mix launcher
# accepts a release command instead. The origin prepares an owner-only working
# directory containing the peer arguments; Forecastle's env.sh hook combines
# them with the vm.args selected by the stock launcher, after the first-start
# preboot VM has finished.

set -eu

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: peer.sh <launcher> <unset-names> <peer-work-dir>" >&2
  exit 64
fi

castle_peer_launcher=$1
castle_peer_unset=$2
castle_peer_work=$3

castle_peer_old_ifs=$IFS
IFS=,
for castle_peer_name in $castle_peer_unset; do
  unset "$castle_peer_name"
done
IFS=$castle_peer_old_ifs

FORECASTLE_PEER_WORK=$castle_peer_work
export FORECASTLE_PEER_WORK

# Keep a tiny wrapper around the launcher until the peer has either connected or
# failed. OTP closes its detached spawn port immediately, so without an explicit
# status channel a launcher that refuses in env.sh is indistinguishable from one
# still booting until wait_boot expires.
set +e
"$castle_peer_launcher" start
castle_peer_status=$?
set -e

castle_peer_status_stage="$castle_peer_work/launcher.status.$$"
(
  set -C
  umask 077
  printf '%s\n' "$castle_peer_status" > "$castle_peer_status_stage"
) 2>/dev/null &&
  mv "$castle_peer_status_stage" "$castle_peer_work/launcher.status" 2>/dev/null || :

exit "$castle_peer_status"
