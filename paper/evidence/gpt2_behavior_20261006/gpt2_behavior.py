"""Reproducible RTL behavior tests on the actual trained 1 KiB sample.

Creates a separate XSim project; never changes the RTL or original evidence.
Public fixed keys/nonces are test fixtures. Failed-auth plaintext is provisional.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from gpt2_weights_demo import ROOT, prepare, port_hex, encrypt, decrypt


def flip(data, offset=0):
    result = bytearray(data)
    result[offset] ^= 1
    return bytes(result)


def main():
    output = ROOT / "build/gpt2_behavior_20261006"
    sample = Path(r"C:\Users\Symok\Downloads\gpt2_trained_weights_1KiB.bin")
    pt, ct, tag, metadata = prepare(sample, output)
    key, nonce = bytes(range(16)), bytes(range(16, 32))
    cases = []

    def add(name, k=key, n=nonce, ad=b"", c=ct, t=tag, valid=False, stall=0, delay=0):
        provisional, accepted = decrypt(k, n, ad, c, t)
        assert accepted == valid
        cases.append(dict(name=name, key=k, nonce=n, ad=ad, ct=c, tag=t,
                          plaintext=provisional, valid=valid, stall=stall, delay=delay))

    add("baseline", valid=True)
    for offset in (0, 512, 1023):
        add(f"ciphertext_bit_flip_byte_{offset}", c=flip(ct, offset))
    add("tag_bit_flip", t=flip(tag))
    add("wrong_key", k=flip(key))
    add("wrong_nonce", n=flip(nonce))
    add("valid_after_failures", valid=True)
    ad = b"GPT2-weights-v1!"
    assert len(ad) == 16
    adct, adtag = encrypt(key, nonce, ad, pt)
    add("associated_data_valid", ad=ad, c=adct, t=adtag, valid=True)
    add("associated_data_bit_flip", ad=flip(ad), c=adct, t=adtag)
    add("input_output_stalls_delayed_tag", valid=True, stall=3, delay=7)
    newnonce = flip(nonce)
    newct, newtag = encrypt(key, newnonce, b"", pt)
    assert newct != ct and newtag != tag
    add("new_nonce_valid", n=newnonce, c=newct, t=newtag, valid=True)
    rows = []
    for index, case in enumerate(cases, 1):
        values = [str(index), str(len(case["ad"])), "1024", port_hex(case["key"]),
                  port_hex(case["nonce"]), port_hex(case["ad"]), "0" * 32]
        for field in ("plaintext", "ct"):
            values.extend(port_hex(case[field][i:i+16]) for i in range(0, 1024, 16))
        values.extend([port_hex(case["tag"]), str(int(case["valid"])),
                       str(case["stall"]), str(case["delay"])])
        rows.append(" ".join(values))
    (output / "weights_vector.txt").write_text("\n".join(rows) + "\n")
    bench = (output / "tb_gpt2_weights.vhd").read_text()
    bench = bench.replace("    variable key_value", "    variable expected_auth, stall_cycles, tag_delay : natural;\n    variable key_value")
    bench = bench.replace("      wait_ready(in_ready);", "      for j in 1 to stall_cycles loop\n        wait until rising_edge(clk); wait for 1 ns;\n      end loop;\n      wait_ready(in_ready);")
    bench = bench.replace("        captured_blocks(i) := out_data;", """        captured_blocks(i) := out_data;
        for j in 1 to stall_cycles loop
          wait until rising_edge(clk); wait for 1 ns;
          assert out_valid = '1' and out_data = captured_blocks(i) and
                 out_keep = x"FFFF" and out_last = final_beat
            report "Output changed while stalled" severity failure;
        end loop;""")
    start = bench.index("    procedure run_vector is")
    end = bench.index("  begin\n    file_open", start)
    bench = bench[:start] + '''    procedure run_vector is
      variable actual_blocks : block_pair_t;
      variable actual_tag : block_t;
      variable start_cycle, elapsed_cycles : natural;
      variable sampled_auth, sampled_commit, sampled_discard : std_logic;
    begin
      if expected_auth = 1 then
        start_command('0', key_value, nonce_value, start_cycle);
        send_ad(ad_length, ad_blocks);
        send_payload(message_length, plain_blocks, actual_blocks);
        wait_ready(tag_out_valid);
        actual_tag := tag_out;
        for j in 1 to tag_delay loop
          wait until rising_edge(clk); wait for 1 ns;
          assert tag_out_valid = '1' and tag_out = actual_tag
            report "Tag changed while stalled" severity failure;
        end loop;
        tag_out_ready <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        tag_out_ready <= '0';
        wait_ready(done);
        elapsed_cycles := simulation_cycle - start_cycle;
        assert actual_blocks = cipher_blocks and actual_tag = tag_value and error_status = '0'
          report "Encryption mismatch" severity failure;
        pass_count := pass_count + 1;
        write(output_line, case_count); write(output_line, string'("|ENC|"));
        write(output_line, elapsed_cycles); write(output_line, string'("|PASS"));
        writeline(record_file, output_line);
        if case_count = 1 then
          write(output_line, string'("ENCRYPT")); writeline(dump_file, output_line);
          for i in actual_blocks'range loop
            hwrite(output_line, actual_blocks(i)); writeline(dump_file, output_line);
          end loop;
        end if;
      end if;
      start_command('1', key_value, nonce_value, start_cycle);
      send_ad(ad_length, ad_blocks);
      send_payload(message_length, cipher_blocks, actual_blocks);
      wait_ready(tag_in_ready);
      for j in 1 to tag_delay loop
        assert auth_valid = '0' and commit = '0' and discard = '0'
          report "Authentication occurred before tag acceptance" severity failure;
        wait until rising_edge(clk); wait for 1 ns;
      end loop;
      tag_in <= tag_value; tag_in_valid <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      assert auth_valid = '1' report "Missing authentication event" severity failure;
      sampled_auth := auth_ok; sampled_commit := commit; sampled_discard := discard;
      tag_in_valid <= '0';
      wait_ready(done);
      elapsed_cycles := simulation_cycle - start_cycle;
      assert actual_blocks = plain_blocks and error_status = '0'
        report "Provisional plaintext mismatch or protocol error" severity failure;
      if expected_auth = 1 then
        assert sampled_auth = '1' and sampled_commit = '1' and sampled_discard = '0'
          report "Valid transaction rejected" severity failure;
      else
        assert sampled_auth = '0' and sampled_commit = '0' and sampled_discard = '1'
          report "Tampered transaction accepted" severity failure;
      end if;
      assert auth_valid = '0' and out_valid = '0' and auth_ok = '0'
        report "Completion failed to clear valid/auth state" severity failure;
      pass_count := pass_count + 1;
      write(output_line, case_count); write(output_line, string'("|DEC|"));
      write(output_line, elapsed_cycles); write(output_line, string'("|"));
      write(output_line, sampled_auth); write(output_line, string'("|"));
      write(output_line, sampled_commit); write(output_line, string'("|"));
      write(output_line, sampled_discard); write(output_line, string'("|PASS"));
      writeline(record_file, output_line);
      if case_count = 1 then
        write(output_line, string'("DECRYPT")); writeline(dump_file, output_line);
        for i in actual_blocks'range loop
          hwrite(output_line, actual_blocks(i)); writeline(dump_file, output_line);
        end loop;
      end if;
    end procedure;
''' + bench[end:]
    bench = bench.replace("      hread(input_line, tag_value);", "      hread(input_line, tag_value);\n      read(input_line, expected_auth);\n      read(input_line, stall_cycles);\n      read(input_line, tag_delay);")
    bench = bench.replace("assert case_count = 1 ", "assert case_count = 12 ")
    bench = bench.replace("assert pass_count = 2 ", "assert pass_count = 17 ")
    (output / "tb_gpt2_weights.vhd").write_text(bench, encoding="ascii")
    vivado = shutil.which("vivado.bat") or r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"
    with (output / "vivado_console.log").open("w") as log:
        subprocess.run([vivado, "-mode", "batch", "-source", str(output / "run.tcl"),
                        "-tclargs", str(output), str(ROOT)], cwd=output, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=300)
    console = (output / "vivado_console.log").read_text()
    assert "Failure:" not in console and "Error:" not in console, "XSim assertion/error; inspect log"
    assert "checks=17 pass=17 fail=0" in (output / "simulation_results.txt").read_text()
    dump = (output / "full_output.txt").read_text().splitlines()
    assert len(dump) == 130
    recovered = b"".join(bytes.fromhex(row)[::-1] for row in dump[66:])
    assert recovered == pt
    (output / "recovered_weights.bin").write_bytes(recovered)
    results = []
    for line in (output / "simulation_vectors.txt").read_text().splitlines():
        if not line[:1].isdigit():
            continue
        fields = line.split("|")
        assert fields[-1] == "PASS"
        row = dict(case=int(fields[0]), name=cases[int(fields[0])-1]["name"],
                   mode=fields[1], cycles=int(fields[2]), result=fields[-1])
        if fields[1] == "DEC":
            row.update(auth=int(fields[3].strip("'")), commit=int(fields[4].strip("'")),
                       discard=int(fields[5].strip("'")))
        results.append(row)
    assert len(results) == 17
    metadata.update(result="PASS", cases=12, checks=17, rejected_tamper_cases=7,
                    recovered_sha256=hashlib.sha256(recovered).hexdigest(), results=results,
                    rtl_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in (ROOT / "rtl").glob("*.vhd")})
    (output / "report.json").write_text(json.dumps(metadata, indent=2))
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
