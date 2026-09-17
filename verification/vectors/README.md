# Official known-answer vectors

`fetch_vectors.py` validates or downloads `LWC_AEAD_KAT_128_128.txt` from the official
`ascon/ascon-c` repository at commit
`446347f21b209f3921c65ece70027c366cbe1693`.

The downloaded file is ignored by Git because it is generated from the pinned
upstream revision. Run:

```sh
make vectors
```

The file contains 1,089 Ascon-AEAD128 cases covering every combination of
associated-data and plaintext lengths from 0 through 32 bytes.

The same command creates `xsim_vectors.txt`. Each whitespace-delimited record
contains the case number, AD length, plaintext length, key, nonce, two AD
blocks, two plaintext blocks, two ciphertext blocks, and tag. The 128-bit hex
fields are already byte-reversed into VHDL port order, so the TextIO bench does
not need a second byte-order implementation.
