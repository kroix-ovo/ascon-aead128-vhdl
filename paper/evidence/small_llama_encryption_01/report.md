# Full small-LLaMA weight encryption simulation

Payload: 1,641,984 bytes, one AEAD message, empty AD. All recovered bytes match.

| Direction | Cycles | Simulated milliseconds | Payload Mb/s |
|---|---:|---:|---:|
| encrypt | 1,231,521 | 12.31521 | 1066.638 |
| decrypt | 1,231,521 | 12.31521 | 1066.638 |

Behavioral RTL simulation, command offered to done; includes empty AD, stream handshakes, padding and tag; excludes host I/O.

Clock: assumed 100 MHz, one round per cycle. These are behavioral simulation results, not measured FPGA performance or timing-closure proof.

Python reference time and Vivado wall time are recorded separately in report.json; they are not RTL latency.

Original and recovered SHA-256: `d1c38f9b274368f989a3c578bb4880003ac821e57faee985ad5bd2841d80b594`.

Ciphertext and tag match the independently KAT-checked Python reference. RTL decryption authentication and commit were asserted by the testbench.

Public fixed key/nonce are demonstration inputs. For real storage, use a protected key and a unique nonce per message.
