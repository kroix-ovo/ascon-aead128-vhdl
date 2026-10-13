"""Measure the existing Ascon VHDL core on a 1 KiB trained-weight sample.

Runs Windows Vivado XSim in its own project directory. The public key and
nonce are demonstration inputs only. Reports simulated command-to-done
latency, including empty AD, stream handshakes, and the authentication tag.
"""
# These standard Python modules handle command-line arguments, file paths,
# checksums, readable JSON reports, text searches, and launching Vivado.
# An import makes another module's functions available in this script.
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

# __file__ is this script's filename. resolve() gives its full path, and
# parents[1] moves up two directories to find the repository root.
# This lets the runner locate the RTL even when launched from another folder.
ROOT = Path(__file__).resolve().parents[1]
# Python searches sys.path for imported modules. Putting our model directory
# first lets us import the local Ascon reference without installing a package.
# With Path objects, / joins folder names; it does not divide numbers.
sys.path.insert(0, str(ROOT / "verification" / "model"))
# The reference calculates the expected ciphertext and checks decryption.
from ascon_ref import encrypt, decrypt
# The vector reader lives in verification, so add that folder as well.
sys.path.insert(0, str(ROOT / "verification"))
# parse_kats reads the official known-answer tests into Python dictionaries.
from fetch_vectors import parse_kats


# def introduces a function: a named operation we can call again later.
# Here we convert ordinary file bytes into the text expected by a VHDL port.
def port_hex(data):
    # ljust pads a short block to 16 bytes with zeros. [::-1] reverses the
    # byte order because the VHDL port puts the first byte in its low bits.
    # hex() writes two hex digits per byte; upper() capitalizes A through F.
    return data.ljust(16, b"\0")[::-1].hex().upper()


# Build the inputs and simulation files, then return the expected answers.
# sample and output are Path objects naming the input file and results folder.
def prepare(sample, output):
    # Validate the Python oracle against the pinned official vectors first.
    # Known-answer tests already include the correct ciphertext and tag.
    # Checking our reference against them makes it a useful comparison oracle.
    kat = ROOT / "verification/vectors/LWC_AEAD_KAT_128_128.txt"
    # Start the test counter at zero before walking through the vectors.
    count = 0
    # A for loop repeats this indented block for every vector. v is a
    # dictionary; v["key"], for example, selects the value stored under key.
    for v in parse_kats(kat.read_bytes()):
        # The function returns two values, assigned here to two variables.
        ct, tag = encrypt(v["key"], v["nonce"], v["ad"], v["pt"])
        # assert stops execution if the condition is false. The f-string
        # inserts the failing vector number into the error message.
        assert (ct, tag) == (v["ct"], v["tag"]), f"Oracle KAT {v['count']} failed"
        # += 1 adds one to the number of vectors checked.
        count += 1
    # Require the complete pinned vector set, rather than a partial file.
    assert count == 1089
    # Read the weight file as raw bytes, not as text or floating-point values.
    plaintext = sample.read_bytes()
    # len counts bytes here. This testbench is designed for exactly 1 KiB.
    if len(plaintext) != 1024:
        # raise stops the run and explains why this input cannot be used.
        raise ValueError("Expected exactly 1024 sample bytes")
    # bytes(range(16)) creates the byte values 0 through 15. These are public
    # demonstration inputs, not a protected key suitable for real deployment.
    key = bytes(range(16))
    # The demo nonce contains values 16 through 31. Real encryption needs
    # a nonce that is never reused with the same key for another message.
    nonce = bytes(range(16, 32))
    # b"" means an empty byte string: this experiment has no associated data.
    # The tag is the authentication value produced alongside the ciphertext.
    ciphertext, tag = encrypt(key, nonce, b"", plaintext)
    # Check that the reference recovers every input byte and accepts the tag.
    assert decrypt(key, nonce, b"", ciphertext, tag) == (plaintext, True)
    # Create missing parent folders; an existing output folder is allowed.
    output.mkdir(parents=True, exist_ok=True)
    # The text vector begins with case number, AD length, message length,
    # key, nonce, and two unused zero AD blocks required by the file format.
    vector = ["1", "0", "1024", port_hex(key), port_hex(nonce), "0" * 32, "0" * 32]
    # A list comprehension builds one entry per 16-byte slice. range steps
    # through offsets 0, 16, ... 1008, giving all 64 plaintext blocks.
    vector += [port_hex(plaintext[i:i+16]) for i in range(0, 1024, 16)]
    # Append the corresponding 64 expected ciphertext blocks in the same order.
    vector += [port_hex(ciphertext[i:i+16]) for i in range(0, 1024, 16)]
    # The final entry is the expected 16-byte authentication tag.
    vector += [port_hex(tag)]
    # join separates entries with spaces; \n finishes the single text line.
    (output / "weights_vector.txt").write_text(" ".join(vector) + "\n", encoding="ascii")

    # Adapt a copy of the proven testbench; leave the official testbench intact.
    # Read the original testbench into a string. Changes below affect only
    # this in-memory copy and the generated file in the build directory.
    tb = (ROOT / "verification/vhdl/tb_ascon_aead128.vhd").read_text()
    # Give the copy its own VHDL entity name so Vivado can select it as top.
    tb = tb.replace("tb_ascon_aead128", "tb_gpt2_weights")
    # Expand storage from two blocks to the 64 blocks in the weight sample.
    tb = tb.replace("array (0 to 1)", "array (0 to 63)")
    # Initialize every block to zero, including unused associated-data slots.
    tb = tb.replace("variable ad_blocks, plain_blocks, cipher_blocks : block_pair_t;",
                    "variable ad_blocks, plain_blocks, cipher_blocks : block_pair_t := (others => (others => '0'));")
    # Find the boundaries of the old payload procedure in the source text.
    start = tb.index("    procedure send_payload(")
    # Starting this search at start selects the procedure immediately after it.
    end = tb.index("    procedure write_readable_result(", start)
    # Slicing keeps the text before and after the old procedure. The triple
    # quotes enclose VHDL source, not Python instructions. The replacement
    # sends one full block, captures its output, and acknowledges it before
    # sending the next block. Only the last of the 64 beats marks message end.
    tb = tb[:start] + '''    -- The sample is 64 full 16-byte beats in one AEAD message.
    procedure send_payload(
      constant length_value : natural;
      constant input_blocks : block_pair_t;
      variable captured_blocks : out block_pair_t
    ) is
      variable final_beat : std_logic;
    begin
      assert length_value = 1024 severity failure;
      captured_blocks := (others => (others => '0'));
      for i in input_blocks'range loop
        final_beat := '0';
        if i = input_blocks'high then final_beat := '1'; end if;
        send_beat('1', input_blocks(i), x"FFFF", final_beat);
        wait_ready(out_valid);
        assert out_keep = x"FFFF" and out_last = final_beat
          report "Unexpected output keep/last" severity failure;
        captured_blocks(i) := out_data;
        out_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        out_ready <= '0';
      end loop;
    end procedure;

''' + tb[end:]
    # Match the original four reads, which only loaded two blocks per direction.
    old = '''      hread(input_line, plain_blocks(0));
      hread(input_line, plain_blocks(1));
      hread(input_line, cipher_blocks(0));
      hread(input_line, cipher_blocks(1));'''
    # Replace those reads with VHDL loops covering the entire expanded arrays.
    new = '''      for i in plain_blocks'range loop
        hread(input_line, plain_blocks(i));
      end loop;
      for i in cipher_blocks'range loop
        hread(input_line, cipher_blocks(i));
      end loop;'''
    # Fail clearly if the original testbench layout has changed unexpectedly.
    assert old in tb
    # Apply the verified replacement to our copy.
    tb = tb.replace(old, new)
    # Add a separate output file that will preserve every simulated data block.
    tb = tb.replace('    file input_file     : text;',
                    '    file input_file     : text;\n    file dump_file : text open write_mode is "full_output.txt";')
    # Preserve all 64 blocks, rather than only the first two in the old log.
    # Run this same operation for encryption and then for decryption.
    for mode in ("ENCRYPT", "DECRYPT"):
        # Locate the existing summary call for this direction in the VHDL.
        marker = f'      write_readable_result("{mode}", passed,'
        # Build VHDL that writes a direction heading followed by all 64 blocks.
        dump = f'''      write(output_line, string'("{mode}"));
      writeline(dump_file, output_line);
      for i in actual_blocks'range loop
        hwrite(output_line, actual_blocks(i));
        writeline(dump_file, output_line);
      end loop;
'''
        # Require the insertion point to exist before changing the source.
        assert marker in tb
        # Put the full dump before the original concise result summary.
        tb = tb.replace(marker, dump + marker)
    # This generated bench has one case with two checks: encrypt and decrypt.
    # Adjust its final counts and source description to match that workload.
    tb = tb.replace("assert case_count = 1089", "assert case_count = 1")
    tb = tb.replace("assert pass_count = 2178", "assert pass_count = 2")
    tb = tb.replace("The compact file did not contain all 1089 vectors", "Expected one 1 KiB weight vector")
    tb = tb.replace("Vector source: ascon-c 446347f21b209f3921c65ece70027c366cbe1693",
                    "Vector source: trained GPT-2 sample; KAT-validated Python oracle")
    # Add a simulation watchdog. If the design stalls, fail after 1 ms of
    # simulated time instead of leaving the testbench waiting indefinitely.
    tb = tb.replace("  stimulus : process", '''  watchdog : process
  begin
    wait for 1 ms;
    assert false report "Weight benchmark timed out" severity failure;
    wait;
  end process;

  stimulus : process''')
    # Save the adapted bench beside its input vector, leaving source RTL intact.
    (output / "tb_gpt2_weights.vhd").write_text(tb, encoding="ascii")
    # A dictionary stores named facts for the report. SHA-256 identifies the
    # exact input bytes so results can be tied back to this weight sample.
    metadata = dict(sample=str(sample), sample_sha256=hashlib.sha256(plaintext).hexdigest(),
                    plaintext_bytes=1024, key_hex=key.hex(), nonce_hex=nonce.hex(),
                    associated_data_bytes=0, tag_hex=tag.hex(), oracle_kats_passed=count,
                    measurement="behavioral simulation, command offered to done; includes AD, I/O handshakes and tag",
                    clock_hz=100_000_000)
    # JSON is a readable data format. indent=2 formats nested fields neatly.
    (output / "inputs.json").write_text(json.dumps(metadata, indent=2))
    # Vivado follows this Tcl text to create an isolated project, add the
    # three RTL files and generated bench as VHDL-2008, and launch XSim.
    # It then copies the simulation logs into our results folder. This is
    # behavioral simulation; it does not program or measure a physical FPGA.
    tcl = '''set run_dir [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
create_project -force gpt2_weights [file join $run_dir project] -part xc7a100tcsg324-1
foreach name {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd} {
  set source_file [file join $root rtl $name]
  add_files -norecurse $source_file
  set_property file_type {VHDL 2008} [get_files $source_file]
}
set_property top ascon_aead128_core [get_filesets sources_1]
set bench [file join $run_dir tb_gpt2_weights.vhd]
add_files -fileset sim_1 -norecurse $bench
set_property file_type {VHDL 2008} [get_files $bench]
set_property top tb_gpt2_weights [get_filesets sim_1]
set_property generic [list G_VECTOR_FILE=[file join $run_dir weights_vector.txt]] [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
set sim_dir [file join $run_dir project gpt2_weights.sim sim_1 behav xsim]
foreach name {simulation_results.txt simulation_vectors.txt full_output.txt} {
  file copy -force [file join $sim_dir $name] [file join $run_dir $name]
}
close_project
'''
    # Save the instructions that Vivado will execute in batch mode.
    (output / "run.tcl").write_text(tcl, encoding="ascii")
    # Hand these four values back to the calling function for later checks.
    return plaintext, ciphertext, tag, metadata


# main coordinates preparation, the Vivado run, and the final result checks.
def main():
    # argparse turns the words supplied after the script name into values.
    parser = argparse.ArgumentParser(description=__doc__)
    # The required sample argument is converted directly into a Path object.
    parser.add_argument("sample", type=Path)
    # This optional switch becomes True when present and False when omitted.
    parser.add_argument("--prepare-only", action="store_true")
    # Parse the command line; missing or invalid arguments produce usage help.
    args = parser.parse_args()
    # Resolve the input to a full path before launching an external program.
    sample = args.sample.resolve()
    # Generated files always go to this repository's dedicated build folder.
    output = ROOT / "build/gpt2_weights_demo"
    # Prepare inputs first and retain the expected answers for verification.
    plaintext, expected, tag, metadata = prepare(sample, output)
    # Preparation-only mode writes the files without starting Vivado.
    if args.prepare_only:
        print(f"Prepared {output}; oracle passed 1089 official vectors")
        # Leave main here when the caller requested preparation only.
        return
    # which searches PATH for an executable. or uses the second choice if
    # the first lookup returns no result.
    vivado = shutil.which("vivado.bat") or shutil.which("vivado")
    # If PATH did not locate Vivado, try the known Windows installation.
    if not vivado:
        # The r prefix keeps Windows backslashes literal in this string.
        candidate = Path(r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat")
        # Stop with a short error if that installation is missing as well.
        if not candidate.exists():
            raise SystemExit("Vivado not found")
        # Convert the Path to the text required by the process launcher.
        vivado = str(candidate)
    # A list holds the executable and its individual arguments. -tclargs
    # passes the output directory and repository root to the generated Tcl.
    command = [vivado, "-mode", "batch", "-source", str(output / "run.tcl"),
               "-tclargs", str(output), str(ROOT)]
    # with opens a log and closes it automatically when this block finishes.
    # Mode w replaces an existing log from an earlier run.
    with (output / "vivado_console.log").open("w") as log:
        # Start Vivado and wait for it. cwd sets its working directory; both
        # output streams go into our log. check=True rejects a failed process,
        # and timeout=300 limits real elapsed time to five minutes.
        subprocess.run(command, cwd=output, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    # Read the complete block dump and split it into a list of text lines.
    lines = (output / "full_output.txt").read_text().splitlines()
    # Expect two headings plus 64 blocks for each direction: 130 lines total.
    assert len(lines) == 130 and lines[0] == "ENCRYPT" and lines[65] == "DECRYPT"
    # Decode each hex line, reverse the port byte order back into file order,
    # then join the 64 byte strings into one 1,024-byte ciphertext.
    actual = b"".join(bytes.fromhex(x)[::-1] for x in lines[1:65])
    # Perform the same conversion on the decryption output lines.
    recovered = b"".join(bytes.fromhex(x)[::-1] for x in lines[66:130])
    # Compare every ciphertext byte against the independent Python reference.
    assert actual == expected, "Ciphertext mismatch"
    # Compare every recovered byte against the original weight file.
    assert recovered == plaintext, "Decrypted weights mismatch"
    # The summary file holds pass/fail status and measured clock-cycle counts.
    records = (output / "simulation_results.txt").read_text()
    # Require both testbench checks to pass before reporting success.
    assert "checks=2 pass=2 fail=0" in records
    # Collect separate timing entries for encryption and decryption.
    measurements = {}
    # Run this same operation for encryption and then for decryption.
    for mode in ("ENCRYPT", "DECRYPT"):
        # A regular expression finds the PASS line and captures the digits
        # after cycles=. The rf prefix allows both a raw pattern and mode text.
        match = re.search(rf"CASE 1 {mode} .* cycles=(\d+) PASS", records)
        # Missing PASS evidence is a failure, not an empty timing result.
        assert match, f"Missing {mode} PASS"
        # group(1) is the captured digit string; int converts it to a number.
        cycles = int(match.group(1))
        # At 100 MHz there are 100 cycles per microsecond, so divide by 100.
        # Payload rate is 1,024 × 8 bits divided by elapsed microseconds;
        # bits per microsecond numerically equal megabits per second.
        # This includes the measured transaction overhead, but no host transfer.
        measurements[mode.lower()] = dict(cycles=cycles, microseconds=cycles / 100,
                                         payload_mbps=1024 * 8 * 100 / cycles)
    # Save binary outputs for inspection or reuse after all checks pass.
    (output / "ciphertext.bin").write_bytes(actual)
    # The tag comes from the oracle; the testbench has checked the hardware tag.
    (output / "tag.bin").write_bytes(tag)
    # Save the verified decryption output in the original byte order.
    (output / "recovered_weights.bin").write_bytes(recovered)
    # Add measured timings and the successful outcome to the input facts.
    metadata.update(measurements=measurements, result="PASS")
    # Write the final machine-readable receipt, replacing the previous report.
    (output / "report.json").write_text(json.dumps(metadata, indent=2))
    # Print the same report in the terminal so the caller sees the results.
    print(json.dumps(metadata, indent=2))


# Python sets __name__ to __main__ when this file is run directly.
# Importing the file from another script therefore does not start Vivado.
if __name__ == "__main__":
    main()
