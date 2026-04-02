#!/usr/bin/env bash
# catnip-sshdump.sh — stream CatSniffer LoRa capture to stdout for Wireshark sshdump.
#
# Usage (Wireshark sshdump "Remote capture command" field):
#   /path/to/catnip-sshdump.sh
#
# Override defaults via environment variables in the sshdump command, e.g.:
#   CATNIP_FREQ=915000000 CATNIP_SF=11 CATNIP_BW=250 /path/to/catnip-sshdump.sh
#
# Port defaults match the standard catnip device layout:
#   catnip devices -> ACM0=Bridge  ACM1=Cat-LoRa  ACM2=Cat-Shell

SHELL_PORT="${CATNIP_SHELL_PORT:-/dev/ttyACM2}"
LORA_PORT="${CATNIP_LORA_PORT:-/dev/ttyACM1}"
FREQUENCY="${CATNIP_FREQ:-915000000}"
TXPOWER="${CATNIP_TXPOWER:-20}"

# Meshtastic channel presets: name -> SF BW CR PREAMBLE
# Source: meshtastic firmware ChannelFile / RadioInterface defaults
declare -A PRESETS=(
    [ShortTurbo]="7 500 5 8"
    [ShortFast]="8 250 5 8"
    [ShortSlow]="9 250 5 8"
    [MediumFast]="9 250 5 8"
    [MediumSlow]="10 250 5 8"
    [LongFast]="11 250 5 8"
    [LongMod]="11 250 6 8"
    [LongSlow]="12 250 5 8"
    [VLongSlow]="12 125 5 8"
)

PRESET="${CATNIP_PRESET:-MediumFast}"
if [[ -n "${PRESETS[$PRESET]+x}" ]]; then
    read -r _P_SF _P_BW _P_CR _P_PL <<< "${PRESETS[$PRESET]}"
else
    echo "WARNING: Unknown preset '$PRESET', falling back to MediumFast" >&2
    read -r _P_SF _P_BW _P_CR _P_PL <<< "${PRESETS[MediumFast]}"
fi

# Individual env vars override the preset values
SF="${CATNIP_SF:-$_P_SF}"
BW="${CATNIP_BW:-$_P_BW}"
CR="${CATNIP_CR:-$_P_CR}"
PREAMBLE="${CATNIP_PREAMBLE:-$_P_PL}"
SYNCWORD="${CATNIP_SYNCWORD:-0x2B}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${SCRIPT_DIR}/.venv/bin/python3"
LORA_EXTCAP="${SCRIPT_DIR}/lora_extcap.py"
FIFO=/tmp/fcatnip
LOG=/tmp/catnip-sshdump.log
EXTCAP_PID=""

# Kill any stale lora_extcap from a previous run that did not clean up
pkill -f "lora_extcap.py.*--capture" 2>/dev/null
rm -f "$FIFO"

# Kill lora_extcap when this script exits for any reason (stop, SSH disconnect, etc.)
cleanup() {
    [ -n "$EXTCAP_PID" ] && kill "$EXTCAP_PID" 2>/dev/null
    rm -f "$FIFO"
}
trap cleanup EXIT INT TERM HUP

# Log radio settings so they can be verified
{
    echo "=== catnip-sshdump started $(date) ==="
    echo "  Shell port:       $SHELL_PORT"
    echo "  LoRa port:        $LORA_PORT"
    echo "  Frequency:        $FREQUENCY Hz ($(awk "BEGIN{printf \"%.3f\", $FREQUENCY/1000000}") MHz)"
    echo "  Spreading factor: SF${SF}"
    echo "  Bandwidth:        ${BW} kHz"
    echo "  Coding rate:      4/${CR}"
    echo "  TX power:         ${TXPOWER} dBm"
    echo "  Preamble length:  ${PREAMBLE}"
    echo "  Sync word:        ${SYNCWORD}"
    echo "  Preset:           ${PRESET}"
    echo "==="
} > "$LOG"

# Start lora_extcap in the background writing to the FIFO
"$PYTHON" "$LORA_EXTCAP" \
    --capture \
    --extcap-interface catnip_lora \
    --fifo "$FIFO" \
    --shell-port  "$SHELL_PORT" \
    --lora-port   "$LORA_PORT" \
    --frequency   "$FREQUENCY" \
    --spread-factor "$SF" \
    --bandwidth   "$BW" \
    --coding-rate "$CR" \
    --preamble    "$PREAMBLE" \
    --syncword    "$SYNCWORD" \
    --tx-power    "$TXPOWER" \
    >>"$LOG" 2>&1 &
EXTCAP_PID=$!

# Wait up to 10 s for the FIFO to be created by UnixPipe.create()
for i in $(seq 1 20); do
    [ -p "$FIFO" ] && break
    kill -0 "$EXTCAP_PID" 2>/dev/null || { echo "lora_extcap failed to start:" >&2; cat "$LOG" >&2; exit 1; }
    sleep 0.5
done

if [ ! -p "$FIFO" ]; then
    echo "ERROR: FIFO $FIFO was not created" >&2
    cat "$LOG" >&2
    exit 1
fi

# Stream PCAP bytes to stdout — sshdump reads this as a live capture.
# No exec: shell must stay alive so the EXIT trap fires when cat finishes.
cat "$FIFO"