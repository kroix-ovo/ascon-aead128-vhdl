# Live ASCII encryption comparison

## Tools

- **Your core:** Vivado 2023.2 XSim, driven by `verification/live_demo.py`.
- **Independent online reference:** [Crypto Lab Ascon demo](https://systemslibrarian.github.io/crypto-lab-ascon/), section **AEAD Encryption — Live**. Select its Ascon-AEAD128 encryptor.

The helper does not change the RTL. It replaces one record in a temporary copy
of the 1,089-case test-vector file, runs the existing VHDL testbench, and shows
the actual core output in normal byte order. The other 1,088 official records
remain in the run. The local reference model supplies the expected result for
the new phrase. The web output provides the separate, visible comparison.

## Before the presentation

Open PowerShell and the online demo side by side. From the root of a current
GitHub clone, generate the official vectors if needed and do a practice run:

```powershell
python verification\fetch_vectors.py
python verification\live_demo.py 'Hello Ascon!'
```

XSim takes roughly 30 seconds on this machine. Keep the PowerShell window open.
Use any **1–32 character ASCII** phrase. For example:

```powershell
python verification\live_demo.py 'Professor123!'
```

PowerShell single quotes preserve spaces and symbols. For an apostrophe inside
the phrase, write it twice: `'Bob''s message'` means `Bob's message`.

## Enter the same inputs on the website

In **AEAD Encryption — Live**, enter:

| Field | Value |
|---|---|
| Key (16-byte hex) | `000102030405060708090A0B0C0D0E0F` |
| Nonce (16-byte hex) | `101112131415161718191A1B1C1D1E1F` |
| Associated Data | Leave empty |
| Plaintext | The exact phrase passed to `live_demo.py` |

Click **Encrypt**. Compare the site's **Ciphertext (hex)** with `Core
ciphertext`, and its **Tag (16 bytes hex)** with `Core tag` in PowerShell.
Uppercase versus lowercase hex does not matter. Compare all digits. Some other
Ascon websites implement the older Ascon-128 or Ascon-128a; use **Ascon-AEAD128**
as standardized in NIST SP 800-232.

For `Hello Ascon!`, both sides should show:

```text
Plaintext hex:  48656C6C6F204173636F6E21
Ciphertext:     808790A16F69A2BEA8AE363B
Tag:            D0EBA208C97B341CA194423A02C59225
```

The ciphertext has the same byte count as the plaintext. The tag is an
additional 16 bytes used to authenticate the result. On the VHDL ports, each
128-bit block is displayed with its bytes reversed; the helper converts the
actual output to normal byte order before printing it.

## If something differs

Check the plaintext character for character, including spaces and case. Check
that associated data is empty and that the key and nonce match the table. The
website's random-key and random-nonce buttons must not be pressed after you
enter the fixed demo values. The helper prints the ASCII bytes in hex so you
can distinguish a normal space (`20`) from no space.

XSim's full log and raw result records are in `build/live_demo`. The last line
of `simulation_results.txt` should report `pass=2178 fail=0`: 1,088 official
cases and the custom case were each checked in encryption and decryption.
Only the current run's output is kept there, so copy a result elsewhere if you
need a permanent presentation receipt.

The fixed key and nonce are classroom test values. Never encrypt real messages
under the same key and nonce more than once.
