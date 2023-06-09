#!/bin/sh
set -e

SELF=$(readlink "$0" || true)
if [ -z "$SELF" ]; then SELF="$0"; fi
RELEASE_ROOT="$(CDPATH='' cd "$(dirname "$SELF")/.." && pwd -P)"
export RELEASE_ROOT
RELEASE_NAME="${RELEASE_NAME:-"<%= release.name %>"}"
export RELEASE_NAME
RELEASE_VSN="${RELEASE_VSN:-"$(cut -d' ' -f2 "$RELEASE_ROOT/releases/start_erl.data")"}"
export RELEASE_VSN
RELEASE_COMMAND="$1"
export RELEASE_COMMAND
RELEASE_PROG="${RELEASE_PROG:-"$(echo "$0" | sed 's/.*\///')"}"
export RELEASE_PROG

REL_VSN_DIR="$RELEASE_ROOT/releases/$RELEASE_VSN"
. "$REL_VSN_DIR/env.sh"

RELEASE_COOKIE="${RELEASE_COOKIE:-"$(cat "$RELEASE_ROOT/releases/COOKIE")"}"
export RELEASE_COOKIE
RELEASE_MODE="${RELEASE_MODE:-"embedded"}"
export RELEASE_MODE
RELEASE_NODE="${RELEASE_NODE:-"$RELEASE_NAME"}"
export RELEASE_NODE
RELEASE_TMP="${RELEASE_TMP:-"$RELEASE_ROOT/tmp"}"
export RELEASE_TMP
RELEASE_VM_ARGS="${RELEASE_VM_ARGS:-"$REL_VSN_DIR/vm.args"}"
export RELEASE_VM_ARGS
RELEASE_REMOTE_VM_ARGS="${RELEASE_REMOTE_VM_ARGS:-"$REL_VSN_DIR/remote.vm.args"}"
export RELEASE_REMOTE_VM_ARGS
RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"sname"}"
export RELEASE_DISTRIBUTION
RELEASE_BOOT_SCRIPT="${RELEASE_BOOT_SCRIPT:-"start"}"
export RELEASE_BOOT_SCRIPT
RELEASE_BOOT_SCRIPT_CLEAN="${RELEASE_BOOT_SCRIPT_CLEAN:-"start_clean"}"
export RELEASE_BOOT_SCRIPT_CLEAN

rand () {
  dd count=1 bs=2 if=/dev/urandom 2> /dev/null | od -x | awk 'NR==1{print $2}'
}

release_distribution () {
  case $RELEASE_DISTRIBUTION in
    none)
      ;;

    name | sname)
      echo "--$RELEASE_DISTRIBUTION $1"
      ;;

    *)
      echo "ERROR: Expected sname, name, or none in RELEASE_DISTRIBUTION, got: $RELEASE_DISTRIBUTION" >&2
      exit 1
      ;;
  esac
}

rpc () {
  exec "$REL_VSN_DIR/elixir" \
       --hidden --cookie "$RELEASE_COOKIE" \
       $(release_distribution "rpc-$(rand)-$RELEASE_NODE") \
       --boot "$REL_VSN_DIR/$RELEASE_BOOT_SCRIPT_CLEAN" \
       --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \
       --vm-args "$RELEASE_REMOTE_VM_ARGS" \
       --rpc-eval "$RELEASE_NODE" "$1"
}

start () {
  "$REL_VSN_DIR/elixir" \
       --cookie "$RELEASE_COOKIE" \
       --erl-config "$REL_VSN_DIR/build" \
       --boot "$REL_VSN_DIR/preboot" \
       --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \
       --vm-args "$RELEASE_VM_ARGS" --eval "Castle.generate(~s($RELEASE_VSN));Castle.make_releases()" \
  || { echo "sys.config generation failed"; exit 1; }
  REL_EXEC="$1"
  shift
  exec "$REL_VSN_DIR/$REL_EXEC" \
       --cookie "$RELEASE_COOKIE" \
       $(release_distribution "$RELEASE_NODE") \
       --erl "-mode $RELEASE_MODE" \
       --erl-config "$REL_VSN_DIR/sys" \
       --boot "$REL_VSN_DIR/$RELEASE_BOOT_SCRIPT" \
       --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \
       --vm-args "$RELEASE_VM_ARGS" "$@"
}

export_release_sys_config () {
  DEFAULT_SYS_CONFIG="${RELEASE_SYS_CONFIG:-"$REL_VSN_DIR/sys"}"
  RELEASE_SYS_CONFIG="$DEFAULT_SYS_CONFIG"
  export RELEASE_SYS_CONFIG
}

case $1 in
  start)
    start "elixir" --no-halt
    ;;

  start_iex)
    start "iex" --werl
    ;;

  daemon)
    start "elixir" --no-halt --pipe-to "${RELEASE_TMP}/pipe" "${RELEASE_TMP}/log"
    ;;

  daemon_iex)
    start "iex" --pipe-to "${RELEASE_TMP}/pipe" "${RELEASE_TMP}/log"
    ;;

  eval)
    if [ -z "$2" ]; then
      echo "ERROR: EVAL expects an expression as argument" >&2
      exit 1
    fi

    export_release_sys_config
    exec "$REL_VSN_DIR/elixir" \
       --cookie "$RELEASE_COOKIE" \
       --erl-config "$RELEASE_SYS_CONFIG" \
       --boot "$REL_VSN_DIR/$RELEASE_BOOT_SCRIPT_CLEAN" \
       --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \
       --vm-args "$RELEASE_VM_ARGS" --eval "$2"
    ;;

  remote)
    exec "$REL_VSN_DIR/iex" \
         --werl --hidden --cookie "$RELEASE_COOKIE" \
         $(release_distribution "rem-$(rand)-$RELEASE_NODE") \
         --boot "$REL_VSN_DIR/$RELEASE_BOOT_SCRIPT_CLEAN" \
         --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \
         --vm-args "$RELEASE_REMOTE_VM_ARGS" \
         --remsh "$RELEASE_NODE"
    ;;

  rpc)
    if [ -z "$2" ]; then
      echo "ERROR: RPC expects an expression as argument" >&2
      exit 1
    fi
    rpc "$2"
    ;;

  restart|stop)
    rpc "System.$1()"
    ;;

  pid)
    rpc "IO.puts System.pid()"
    ;;

  version)
    echo "$RELEASE_NAME $RELEASE_VSN"
    ;;

  releases)
    rpc "Castle.$1()"
    ;;

  unpack)
    rpc "Castle.$1(~s($RELEASE_NAME-$2))"
    ;;

  install|commit|remove)
    rpc "Castle.$1(~s($2))"
    ;;

  *)
    echo "Usage: $(basename "$0") COMMAND [ARGS]

The known commands are:

    start          Starts the system
    start_iex      Starts the system with IEx attached
    daemon         Starts the system as a daemon
    daemon_iex     Starts the system as a daemon with IEx attached
    eval \"EXPR\"    Executes the given expression on a new, non-booted system
    rpc \"EXPR\"     Executes the given expression remotely on the running system
    remote         Connects to the running system via a remote shell
    restart        Restarts the running system via a remote command
    stop           Stops the running system via a remote command
    pid            Prints the operating system PID of the running system via a remote command
    version        Prints the release name and version to be booted

Additional commands for release handling are:

    releases       Lists the releases currently known to the system, and their status
    unpack \"VSN\"   Unpacks $RELEASE_NAME-<VSN>.tar.gz
    install \"VSN\"  Installs $RELEASE_NAME-<VSN> and makes it the current version.
    commit \"VSN\"   Commits $RELEASE_NAME-<VSN> so it becomes the version that runs on restart
    remove \"VSN\"   Uninstalls $RELEASE_NAME-<VSN> from the system.

" >&2

    if [ -n "$1" ]; then
      echo "ERROR: Unknown command $1" >&2
      exit 1
    fi
    ;;
esac
