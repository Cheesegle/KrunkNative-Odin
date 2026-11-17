#!/usr/bin/env bash
# Linux version of tools/server-bot-test.ps1: starts a Krodin dedicated server
# plus headless bots (krodin_netbot) that each play with a random simulated
# latency, so you can join and test a "real" match.
#
#   ./tools/server-bot-test.sh                       # 6 bots, 20-60 ms, 64 tick
#   ./tools/server-bot-test.sh --bots 7 --tick-rate 128
#   ./tools/server-bot-test.sh --no-server --host 192.168.1.20   # bots only
#
# Join from Krodin: Join -> tcp://<this machine's IP>:21015. Ctrl+C stops
# everything. Logs go to logs/bot-test/. Run it from the folder that holds
# bin/ and assets/ (the repo root, or a deployed server folder).
set -euo pipefail

BOTS=6 MIN_LATENCY=20 MAX_LATENCY=60 JITTER=2 TICK_RATE=64 PORT=21015
HOST=127.0.0.1 SEED="" DURATION=0 BUILD=0 NO_SERVER=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; cat <<'EOF'
Options:
  --bots N          number of bots (1-15, default 6)
  --min-latency MS  lowest simulated round trip (default 20)
  --max-latency MS  highest simulated round trip (default 60)
  --jitter MS       +- jitter per packet (default 2)
  --tick-rate N     server tick rate, 30-128 (default 64)
  --port N          server port (default 21015)
  --host H          where the bots connect (default 127.0.0.1)
  --seed N          random seed for the bot latencies
  --duration S      stop after S seconds (default 0 = until Ctrl+C)
  --build           rebuild bin/krodin_server and bin/krodin_netbot first
  --no-server       only start bots, against a server already at --host
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bots) BOTS=$2; shift 2 ;;
        --min-latency) MIN_LATENCY=$2; shift 2 ;;
        --max-latency) MAX_LATENCY=$2; shift 2 ;;
        --jitter) JITTER=$2; shift 2 ;;
        --tick-rate) TICK_RATE=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --host) HOST=$2; shift 2 ;;
        --seed) SEED=$2; shift 2 ;;
        --duration) DURATION=$2; shift 2 ;;
        --build) BUILD=1; shift ;;
        --no-server) NO_SERVER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [ "$BOTS" -lt 1 ] || [ "$BOTS" -gt 15 ]; then echo "--bots must be 1-15" >&2; exit 2; fi
if [ "$MAX_LATENCY" -lt "$MIN_LATENCY" ]; then echo "--max-latency must be at least --min-latency" >&2; exit 2; fi

# The repo root when run from tools/, otherwise the current folder.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -d "$ROOT/assets" ] || ROOT=$(pwd)
cd "$ROOT"
SERVER=bin/krodin_server
BOT=bin/krodin_netbot
LOG_DIR=logs/bot-test
mkdir -p "$LOG_DIR"

if [ "$BUILD" = 1 ] || [ ! -x "$BOT" ] || { [ "$NO_SERVER" = 0 ] && [ ! -x "$SERVER" ]; }; then
    command -v odin >/dev/null || { echo "Odin is needed to build (or copy prebuilt bin/ files here)." >&2; exit 1; }
    mkdir -p bin
    if [ "$NO_SERVER" = 0 ]; then echo "Building server..."; odin build src/server -out:$SERVER -o:speed; fi
    echo "Building bots..."; odin build tools/netbot -out:$BOT -o:speed
fi

[ -n "$SEED" ] && RANDOM=$SEED
PIDS=()
cleanup() {
    echo "Stopping server and bots..."
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$NO_SERVER" = 0 ]; then
    "$SERVER" --bind 0.0.0.0 --port "$PORT" --tick-rate "$TICK_RATE" --max-players $((BOTS + 2)) --stats-interval 10 \
        >"$LOG_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    PIDS+=("$SERVER_PID")
    echo "Server started at $TICK_RATE tick on port $PORT (log: $LOG_DIR/server.log)"
    # Wait until it accepts connections (up to 15 s).
    ready=0
    for _ in $(seq 60); do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then ready=1; break; fi
        sleep 0.25
    done
    [ "$ready" = 1 ] || { echo "The server did not start listening on port $PORT. See $LOG_DIR/server.log" >&2; exit 1; }
fi

echo
echo "Bots (simulated round-trip latency):"
for i in $(seq "$BOTS"); do
    latency=$((MIN_LATENCY + RANDOM % (MAX_LATENCY - MIN_LATENCY + 1)))
    "$BOT" --host "$HOST" --port "$PORT" --latency "$latency" --jitter "$JITTER" \
        --seed $((RANDOM * 32768 + RANDOM + 1)) --name "bot$i" --report 10 >"$LOG_DIR/bot$i.log" 2>&1 &
    PIDS+=("$!")
    echo "  bot$i: $latency ms"
    sleep 0.15
done

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$IP" ] || IP="<this machine's IP>"
echo
echo "Join from Krodin: Join -> tcp://$IP:$PORT"
echo "Press Ctrl+C to stop. Status every 10 s; full logs in $LOG_DIR"

START=$(date +%s)
while true; do
    sleep 10
    elapsed=$(( $(date +%s) - START ))
    printf -- '--- %02d:%02d:%02d ---\n' $((elapsed / 3600)) $((elapsed % 3600 / 60)) $((elapsed % 60))
    if [ "$NO_SERVER" = 0 ]; then
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "Server exited. See $LOG_DIR/server.log"; break; fi
        line=$(grep -a "tick" "$LOG_DIR/server.log" | tail -n 1 || true)
        [ -n "$line" ] && echo "  server: $line"
    fi
    alive=0
    for i in $(seq "$BOTS"); do
        pid=${PIDS[$((i - 1 + (1 - NO_SERVER)))]}
        if ! kill -0 "$pid" 2>/dev/null; then echo "  bot$i: stopped (see $LOG_DIR/bot$i.log)"; continue; fi
        alive=$((alive + 1))
        line=$(grep -a "ping" "$LOG_DIR/bot$i.log" | tail -n 1 || true)
        [ -n "$line" ] && echo "  $line"
    done
    [ "$alive" -gt 0 ] || { echo "All bots stopped."; break; }
    if [ "$DURATION" -gt 0 ] && [ "$elapsed" -ge "$DURATION" ]; then echo "Duration reached."; break; fi
done
