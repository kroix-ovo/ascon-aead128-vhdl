#!/bin/bash
# queue.sh JOBFILE PARALLEL ; each line: NAME key:val key:val ...  (impl_core.tcl args minus out/root)
# Retries a job (fresh dir) up to 3x when synthesis dies on a transient Windows file-read error.
W="C:/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff"
S=$W/build/handoff_vivado/scripts
one() { name=$1; shift; d="$W/build/handoff_vivado/$name"
  [ -f "$d/implementation.json" ] && { echo "$name skip"; return; }
  for try in 1 2 3 4 5 6; do
    sleep $((RANDOM % 20)); rm -rf "$d"
    "$S/run.sh" "$name" "$S/impl_core.tcl" out:"$d" root:"$W" "$@"
    [ -f "$d/implementation.json" ] && return
    grep -q "couldn't read file" "$d/vivado.log" || { echo "$name hard-fail"; return; }
    echo "$name transient-fail try $try"
  done; }
export -f one; export W S
grep -v '^#' "$1" | grep -v '^$' | xargs -P "$2" -L 1 bash -c 'one "$@"' _
