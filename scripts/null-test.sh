#!/bin/bash
# Bit-exact check of the flat-equalizer path (docs/audio-path.md#null-test).
# Quits the running app, starts the installed app with --null-test (it plays ~3 s of soft
# −48 dBFS noise on the current macOS output, three times), prints the verdicts, relaunches it.
# Run it when nobody is listening and nothing else is playing.
set -uo pipefail
APP="$HOME/Applications/HiFiCompanion.app"
[ -d "$APP" ] || { echo "Not installed: $APP"; exit 2; }
REPORT="$(mktemp -t hifi-null-test)"

was_running=0
relaunch() {
    pkill -x afplay 2>/dev/null || true
    [ "$was_running" = 1 ] && ! pgrep -x HiFiCompanion >/dev/null && open "$APP"
    rm -f "$REPORT"
}
trap relaunch EXIT
trap 'exit 130' INT TERM

if pgrep -x HiFiCompanion >/dev/null; then
    was_running=1
    pkill -x HiFiCompanion
    # Its tap would also capture the test file (through the user's EQ): wait until it is gone.
    for _ in $(seq 1 50); do pgrep -x HiFiCompanion >/dev/null || break; sleep 0.1; done
    pkill -9 -x HiFiCompanion 2>/dev/null || true
    sleep 0.5
fi

# `open` (not the binary from this shell) so the tap runs under the app's own System Audio
# Recording permission. The app writes its report to $REPORT; 60 s safety timeout.
open -W -n "$APP" --args --null-test "$REPORT" &
opener=$!
for _ in $(seq 1 600); do kill -0 "$opener" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$opener" 2>/dev/null; then
    echo "Timed out after 60 s"
    pkill -x HiFiCompanion 2>/dev/null || true
fi
wait "$opener" 2>/dev/null

cat "$REPORT"
if grep -q "→ BIT-EXACT" "$REPORT" && ! grep -q "→ NOT\|→ INCOMPLETE\|failed\|no output" "$REPORT" \
    && [ "$(grep -c '→ BIT-EXACT' "$REPORT")" -ge 3 ]; then
    echo "Result: bit-exact in every pass"
    exit 0
fi
echo "Result: not bit-exact in every pass (see above)"
exit 1
