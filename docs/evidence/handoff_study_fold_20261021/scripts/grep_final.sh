#!/usr/bin/env bash
grep -E "TESTS=|rc=|exit=|PASS|FAIL|identical|differing|traffic|checked|TOTAL" "$HOME/ascon_fold_scratch/final_regression.txt" | sed 's/  */ /g' | cut -c1-220
