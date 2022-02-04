#!/bin/sh
#
# Launch "sigstore-the-local-way" daemons into a tmux session
#
# This script assumes you have gone through the tutorial once
# and would like to resume environmental testing.
#
# USAGE:
#   ./launch_sigstore.sh
#
# REQUIREMENTS:
#   * The configuration files/data created through the tutorial
#   * tmux: https://github.com/tmux/tmux/wiki
#   * A UNIX-like operating-system

SESSION="sigstore"

SOFTHSM2_CONF="$HOME/sigstore-local/softhsm2.conf"

TRILLIAN_LOG="$HOME/go/bin/trillian_log_server -http_endpoint=localhost:8090 -rpc_endpoint=localhost:8091 --logtostderr"
TRILLIAN_SIGN="$HOME/go/bin/trillian_log_signer --logtostderr --force_master --http_endpoint=localhost:8190 -rpc_endpoint=localhost:8191"
REKOR="$HOME/go/bin/rekor-server serve --trillian_log_server.port=8091 --enable_retrieve_api=false"
DEX="$HOME/go/bin/dex serve $HOME/sigstore-local/dex-config.yaml"
FULCIO="$HOME/go/bin/fulcio serve --config-path=config/fulcio.json --ca=pkcs11ca --hsm-caroot-id=1 --ct-log-url=http://localhost:6105/sigstore --host=127.0.0.1 --port=5000"
CT="$HOME/go/bin/ct_server -logtostderr -log_config $HOME/sigstore-local/ct.cfg -log_rpc_server localhost:8091 -http_endpoint 127.0.0.1:6105"
REGISTRY="$HOME/go/bin/registry"

if [ ! -f "$SOFTHSM2_CONF" ]; then
  echo "Exiting as $SOFTHSM2_CONF does not exist (did you finish the tutorial?)"
  exit 1
fi

export SOFTHSM2_CONF
cd $HOME/sigstore-local

attach() {
    [ -n "${TMUX:-}" ] \
      && tmux switch-client -t "=$SESSION" \
      || tmux attach-session -t "=$SESSION"
}

if tmux has-session -t "=$SESSION" 2>/dev/null; then
    echo "Found \"$SESSION\" session - attaching to it instead of relaunching"
    sleep 1
    attach
    exit
fi


tmux new-window -d -t "=$SESSION" -n registry
tmux send-keys -t "=$SESSION:=registry" "$REGISTRY" Enter

tmux new-session -d -s $SESSION -n "trillian_log"
tmux send-keys -t "=$SESSION:=trillian_log" "$TRILLIAN_LOG" Enter

# small delay for the trillian_log server to listen
sleep 1

tmux new-window -d -t "=$SESSION" -n trillian_sign
tmux send-keys -t "=$SESSION:=trillian_sign" "$TRILLIAN_SIGN" Enter

tmux new-window -d -t "=$SESSION" -n rekor
tmux send-keys -t "=$SESSION:=rekor" "$REKOR" Enter

tmux new-window -d -t "=$SESSION" -n dex
tmux send-keys -t "=$SESSION:=dex" "$DEX" Enter

# small delay for dex
sleep 1

tmux new-window -d -t "=$SESSION" -n fulcio
tmux send-keys -t "=$SESSION:=fulcio" "$FULCIO" Enter

tmux new-window -d -t "=$SESSION" -n ct
tmux send-keys -t "=$SESSION:=ct" "$CT" Enter

attach

