#!/bin/sh

# Adapter between OTP's :peer command line and the stock Mix launcher.
#
# :peer appends emulator arguments to the executable it starts. The Mix launcher
# accepts a release command instead. The origin prepares a private copy of the
# selected release's vm.args with the peer arguments appended; the adapter points
# the stock launcher at that copy. The first-start preboot VM does not read
# RELEASE_VM_ARGS, so it cannot consume the control connection.

set -eu

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: peer.sh <launcher> <unset-names> <vm-args>" >&2
  exit 64
fi

castle_peer_launcher=$1
castle_peer_unset=$2
castle_peer_vm_args=$3

castle_peer_old_ifs=$IFS
IFS=,
for castle_peer_name in $castle_peer_unset; do
  unset "$castle_peer_name"
done
IFS=$castle_peer_old_ifs

RELEASE_VM_ARGS=$castle_peer_vm_args
export RELEASE_VM_ARGS
exec "$castle_peer_launcher" start
