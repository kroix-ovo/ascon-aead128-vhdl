# Fold absorb publication validation

Fresh tests ran against an isolated copy of the final patched RTL. `validation.json` binds source hashes to the logs. `check_0` is the original full-KAT handshake suite, `check_1` buffered u3, `check_2` fold, `check_3` folded intermediate-state/error tests and `check_4` folded cycle regressions. Both board simulation targets passed, including the original one-round demo.

These runs do not repeat the full adapter, Vivado implementation or physical programming. Their earlier receipts retain their own source snapshots. The folded entity is unchanged by the later legacy-only fixes. The final legacy tag gate has not been rerouted. Negative-control failures in the earlier tag-gate folder are expected checks, not passing configurations.

`external_link_audit.json` records URL reachability, not scientific verification. HTTP rejection or a HEAD-only failure is not proof a source does not exist. The final standard is linked through its official publication page; the AMD source now uses its official documentation URL. One unavailable third-party repository was removed as a live citation. Abstract-only and unverified sources remain labeled in the ledger. GitHub Actions results are available on the published branch; this local receipt does not predeclare their outcome.
