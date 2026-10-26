#!/usr/bin/env bash
# Prove the protocol properties for every possible input sequence.
#
#   formal/prove.sh                 prove the controller as written
#   formal/prove.sh BUG_NO_TRAS     same, with one injected bug (expected to fail)
#
# Prints PROVED or FAILED and exits 0 / 1 accordingly.
set -u
cd "$(dirname "$0")"
defs=""
name="work"
for d in "$@"; do defs="$defs -D$d"; name="${name}_$d"; done
python3 gen.py gen
sed "s/DEFINES/$defs/" mem_ctrl.sby > "$name.sby"
yowasp-sby --yosys yowasp-yosys --smtbmc yowasp-yosys-smtbmc --abc yosys-abc -f "$name.sby" > "$name.log" 2>&1
if [ ! -f "$name/model/design_aiger.aig" ]; then
  echo "model build failed, see formal/$name.log"; exit 2
fi
out=$(cd "$name" && yosys-abc -c 'read_aiger model/design_aiger.aig; fold; strash; pdr' 2>&1)
echo "$out" | grep -E "Invariant|Property proved|was asserted|Time" | tail -3
if echo "$out" | grep -q "Property proved"; then echo "PROVED"; exit 0; fi
echo "FAILED"; exit 1
