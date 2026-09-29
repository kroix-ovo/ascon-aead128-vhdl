#!/usr/bin/env bash
# Run the GitHub Ascon VHDL TextIO testbench from a fresh Ubuntu clone.
# Usage: bash run_ubuntu_vivado_tb.sh
# Optional: PYTHON_BIN=python3.10 VIVADO_BIN=/path/to/vivado bash run_ubuntu_vivado_tb.sh

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VIVADO_BIN="${VIVADO_BIN:-vivado}"
LOG_DIR="$REPO_ROOT/build/vivado/debug_logs"
RESULT_FILE="$REPO_ROOT/build/vivado/simulation/simulation_results.txt"

cd "$REPO_ROOT"

if [[ ! -f vivado/run_sim.tcl || ! -f verification/fetch_vectors.py ]]; then
  echo "Error: place this script in the root of the Ascon GitHub repository." >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*run[[:space:]]+all([[:space:]]|$)' vivado/run_sim.tcl; then
  echo "Error: this copy has an older run_sim.tcl with an extra 'run all'." >&2
  echo "Use the current GitHub main version before running the testbench." >&2
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Error: Python executable '$PYTHON_BIN' was not found." >&2
  exit 1
fi
if ! "$PYTHON_BIN" -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
  echo "Error: vector generation needs Python 3.9 or newer. Set PYTHON_BIN to a newer Python." >&2
  exit 1
fi
if ! command -v "$VIVADO_BIN" >/dev/null 2>&1; then
  echo "Error: Vivado was not found. Source settings64.sh or set VIVADO_BIN." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
echo "Ubuntu: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "Python: $("$PYTHON_BIN" --version 2>&1)"
echo "Vivado: $("$VIVADO_BIN" -version | head -n 1)"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Repository commit: $(git rev-parse --short HEAD)"
fi

"$PYTHON_BIN" -m venv .venv
.venv/bin/python -m pip install 'certifi==2026.2.25'
.venv/bin/python verification/fetch_vectors.py
test -s verification/vectors/xsim_vectors.txt

echo "Starting Vivado testbench. Console log: $LOG_DIR/vivado_tb_console.log"
if ! "$VIVADO_BIN" -mode batch -source vivado/run_sim.tcl \
    -log "$LOG_DIR/vivado_tb.log" \
    -journal "$LOG_DIR/vivado_tb.jou" \
    2>&1 | tee "$LOG_DIR/vivado_tb_console.log"; then
  echo "Vivado failed. Check the first ERROR above and the logs in $LOG_DIR." >&2
  exit 1
fi

if [[ ! -f "$RESULT_FILE" ]]; then
  echo "Error: Vivado exited, but the testbench result file was not created." >&2
  echo "Confirm the simulation top is tb_ascon_aead128; logs are in $LOG_DIR." >&2
  exit 1
fi

grep '^TOTAL vectors=' "$RESULT_FILE" || true
if ! grep -Fq 'TOTAL vectors=1089 checks=2178 pass=2178 fail=0' "$RESULT_FILE"; then
  echo "Error: the result file does not show all 2178 checks passing." >&2
  echo "Read $RESULT_FILE for the failed case." >&2
  exit 1
fi

echo "PASS: all 1089 vectors passed in encryption and decryption."
echo "Results: $RESULT_FILE"
