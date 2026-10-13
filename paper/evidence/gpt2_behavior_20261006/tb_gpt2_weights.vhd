-- Pure VHDL self-checking testbench for Vivado XSim and GHDL.
--
-- The testbench reads a compact copy of all official Ascon-AEAD128 known-
-- answer vectors. It runs encryption and decryption for every record, checks
-- the result in the simulator, and writes two durable text files. The first
-- file is readable as a research log. The second uses stable pipe-delimited
-- fields so scripts can calculate latency and throughput without a waveform.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

entity tb_gpt2_weights is
  generic (
    G_VECTOR_FILE : string := "verification/vectors/xsim_vectors.txt"
  );
end entity;

architecture sim of tb_gpt2_weights is
  subtype block_t is std_logic_vector(127 downto 0);
  type block_pair_t is array (0 to 63) of block_t;
  constant CLOCK_PERIOD : time := 10 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '0';
  signal cmd_valid, cmd_ready, cmd_decrypt : std_logic := '0';
  signal key, nonce : block_t := (others => '0');
  signal in_valid, in_ready, in_kind, in_last : std_logic := '0';
  signal in_data : block_t := (others => '0');
  signal in_keep : std_logic_vector(15 downto 0) := (others => '0');
  signal tag_in_valid, tag_in_ready : std_logic := '0';
  signal tag_in : block_t := (others => '0');
  signal out_valid, out_ready, out_last : std_logic := '0';
  signal out_data : block_t;
  signal out_keep : std_logic_vector(15 downto 0);
  signal tag_out_valid, tag_out_ready : std_logic := '0';
  signal tag_out : block_t;
  signal busy, done, auth_valid, auth_ok, commit, discard, error_status : std_logic;
  signal simulation_cycle : natural := 0;

  function keep_for_bytes(byte_count : natural) return std_logic_vector is
  begin
    if byte_count = 0 then
      return x"0000";
    elsif byte_count >= 16 then
      return x"FFFF";
    else
      return std_logic_vector(to_unsigned((2 ** byte_count) - 1, 16));
    end if;
  end function;
begin
  clk <= not clk after CLOCK_PERIOD / 2;

  -- This counter is independent of the DUT reset. A case records its value
  -- when the command is offered and again when done is observed.
  process (clk)
  begin
    if rising_edge(clk) then
      simulation_cycle <= simulation_cycle + 1;
    end if;
  end process;

  dut : entity work.ascon_aead128_core
    port map (
      clk_i => clk, rst_i => rst,
      cmd_valid_i => cmd_valid, cmd_ready_o => cmd_ready,
      cmd_decrypt_i => cmd_decrypt, key_i => key, nonce_i => nonce,
      in_valid_i => in_valid, in_ready_o => in_ready, in_kind_i => in_kind,
      in_data_i => in_data, in_keep_i => in_keep, in_last_i => in_last,
      tag_in_valid_i => tag_in_valid, tag_in_ready_o => tag_in_ready,
      tag_in_i => tag_in,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_data_o => out_data, out_keep_o => out_keep, out_last_o => out_last,
      tag_out_valid_o => tag_out_valid, tag_out_ready_i => tag_out_ready,
      tag_out_o => tag_out,
      busy_o => busy, done_o => done, auth_valid_o => auth_valid,
      auth_ok_o => auth_ok, commit_o => commit, discard_o => discard,
      error_o => error_status
    );

  watchdog : process
  begin
    wait for 1 ms;
    assert false report "Weight benchmark timed out" severity failure;
    wait;
  end process;

  stimulus : process
    file input_file     : text;
    file dump_file : text open write_mode is "full_output.txt";
    file readable_file : text open write_mode is "simulation_results.txt";
    file record_file   : text open write_mode is "simulation_vectors.txt";
    variable open_status : file_open_status;
    variable input_line, output_line : line;
    variable pass_count, fail_count : natural := 0;
    variable case_count, ad_length, message_length : natural;
    variable expected_auth, stall_cycles, tag_delay : natural;
    variable key_value, nonce_value, tag_value : block_t;
    variable ad_blocks, plain_blocks, cipher_blocks : block_pair_t := (others => (others => '0'));

    procedure wait_ready(signal ready_signal : in std_logic) is
    begin
      while ready_signal /= '1' loop
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;
    end procedure;

    procedure start_command(
      constant decrypt_mode : std_logic;
      constant key_argument : block_t;
      constant nonce_argument : block_t;
      variable start_cycle : out natural
    ) is
    begin
      wait_ready(cmd_ready);
      start_cycle := simulation_cycle;
      cmd_decrypt <= decrypt_mode;
      key <= key_argument;
      nonce <= nonce_argument;
      cmd_valid <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      cmd_valid <= '0';
    end procedure;

    procedure send_beat(
      constant kind_value : std_logic;
      constant data_value : block_t;
      constant keep_value : std_logic_vector(15 downto 0);
      constant last_value : std_logic
    ) is
    begin
      for j in 1 to stall_cycles loop
        wait until rising_edge(clk); wait for 1 ns;
      end loop;
      wait_ready(in_ready);
      in_kind <= kind_value;
      in_data <= data_value;
      in_keep <= keep_value;
      in_last <= last_value;
      in_valid <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      in_valid <= '0';
    end procedure;

    procedure send_ad(
      constant length_value : natural;
      constant blocks : block_pair_t
    ) is
    begin
      if length_value = 0 then
        send_beat('0', (others => '0'), x"0000", '1');
      elsif length_value <= 16 then
        send_beat('0', blocks(0), keep_for_bytes(length_value), '1');
      else
        send_beat('0', blocks(0), x"FFFF", '0');
        send_beat('0', blocks(1), keep_for_bytes(length_value - 16), '1');
      end if;
    end procedure;

    -- The sample is 64 full 16-byte beats in one AEAD message.
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
        for j in 1 to stall_cycles loop
          wait until rising_edge(clk); wait for 1 ns;
          assert out_valid = '1' and out_data = captured_blocks(i) and
                 out_keep = x"FFFF" and out_last = final_beat
            report "Output changed while stalled" severity failure;
        end loop;
        out_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        out_ready <= '0';
      end loop;
    end procedure;

    procedure write_readable_result(
      constant mode_name : string;
      constant passed : boolean;
      constant count_value, ad_length_value, message_length_value : natural;
      constant expected0, expected1, actual0, actual1 : block_t;
      constant expected_tag_value, actual_tag_value : block_t;
      constant auth_value : std_logic;
      constant cycle_value : natural
    ) is
    begin
      write(output_line, string'("CASE ")); write(output_line, count_value);
      write(output_line, string'(" ") & mode_name & " ad_len=");
      write(output_line, ad_length_value);
      write(output_line, string'(" msg_len=")); write(output_line, message_length_value);
      write(output_line, string'(" expected0=")); hwrite(output_line, expected0);
      write(output_line, string'(" expected1=")); hwrite(output_line, expected1);
      write(output_line, string'(" actual0=")); hwrite(output_line, actual0);
      write(output_line, string'(" actual1=")); hwrite(output_line, actual1);
      write(output_line, string'(" expected_tag=")); hwrite(output_line, expected_tag_value);
      write(output_line, string'(" actual_tag=")); hwrite(output_line, actual_tag_value);
      write(output_line, string'(" auth=")); write(output_line, auth_value);
      write(output_line, string'(" cycles=")); write(output_line, cycle_value);
      if passed then
        write(output_line, string'(" PASS")); pass_count := pass_count + 1;
      else
        write(output_line, string'(" FAIL")); fail_count := fail_count + 1;
      end if;
      writeline(readable_file, output_line);
    end procedure;

    procedure write_machine_result(
      constant count_value : natural;
      constant mode_name : string;
      constant ad_length_value, message_length_value : natural;
      constant key_argument, nonce_argument : block_t;
      constant ad_argument, input_argument, output_argument : block_pair_t;
      constant tag_argument : block_t;
      constant auth_value : std_logic;
      constant cycle_value : natural;
      constant passed : boolean
    ) is
    begin
      write(output_line, string'("CASE|")); write(output_line, count_value);
      write(output_line, string'("|MODE|") & mode_name);
      write(output_line, string'("|AD_LEN|")); write(output_line, ad_length_value);
      write(output_line, string'("|MSG_LEN|")); write(output_line, message_length_value);
      write(output_line, string'("|KEY|")); hwrite(output_line, key_argument);
      write(output_line, string'("|NONCE|")); hwrite(output_line, nonce_argument);
      write(output_line, string'("|AD0|")); hwrite(output_line, ad_argument(0));
      write(output_line, string'("|AD1|")); hwrite(output_line, ad_argument(1));
      write(output_line, string'("|INPUT0|")); hwrite(output_line, input_argument(0));
      write(output_line, string'("|INPUT1|")); hwrite(output_line, input_argument(1));
      write(output_line, string'("|OUTPUT0|")); hwrite(output_line, output_argument(0));
      write(output_line, string'("|OUTPUT1|")); hwrite(output_line, output_argument(1));
      write(output_line, string'("|TAG|")); hwrite(output_line, tag_argument);
      write(output_line, string'("|AUTH|")); write(output_line, auth_value);
      write(output_line, string'("|CYCLES|")); write(output_line, cycle_value);
      write(output_line, string'("|RESULT|"));
      if passed then write(output_line, string'("PASS"));
      else write(output_line, string'("FAIL")); end if;
      writeline(record_file, output_line);
    end procedure;

    procedure run_vector is
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
  begin
    file_open(open_status, input_file, G_VECTOR_FILE, read_mode);
    assert open_status = open_ok
      report "Could not open compact KAT file: " & G_VECTOR_FILE severity failure;

    write(output_line, string'("NIST Ascon-AEAD128 VHDL simulation results"));
    writeline(readable_file, output_line);
    write(output_line, string'("Vector source: trained GPT-2 sample; KAT-validated Python oracle"));
    writeline(readable_file, output_line);
    write(output_line, string'("FORMAT|CASE|N|MODE|ENC_OR_DEC|AD_LEN|BYTES|MSG_LEN|BYTES|KEY|HEX|NONCE|HEX|AD0|HEX|AD1|HEX|INPUT0|HEX|INPUT1|HEX|OUTPUT0|HEX|OUTPUT1|HEX|TAG|HEX|AUTH|BIT|CYCLES|N|RESULT|PASS_OR_FAIL"));
    writeline(record_file, output_line);

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;

    while not endfile(input_file) loop
      readline(input_file, input_line);
      read(input_line, case_count);
      read(input_line, ad_length);
      read(input_line, message_length);
      hread(input_line, key_value);
      hread(input_line, nonce_value);
      hread(input_line, ad_blocks(0));
      hread(input_line, ad_blocks(1));
      for i in plain_blocks'range loop
        hread(input_line, plain_blocks(i));
      end loop;
      for i in cipher_blocks'range loop
        hread(input_line, cipher_blocks(i));
      end loop;
      hread(input_line, tag_value);
      read(input_line, expected_auth);
      read(input_line, stall_cycles);
      read(input_line, tag_delay);
      run_vector;
    end loop;
    file_close(input_file);

    write(output_line, string'("TOTAL vectors=")); write(output_line, case_count);
    write(output_line, string'(" checks=")); write(output_line, pass_count + fail_count);
    write(output_line, string'(" pass=")); write(output_line, pass_count);
    write(output_line, string'(" fail=")); write(output_line, fail_count);
    writeline(readable_file, output_line);
    assert case_count = 12 report "Expected one 1 KiB weight vector"
      severity failure;
    assert pass_count = 17 and fail_count = 0
      report "One or more Ascon-AEAD128 encryption or decryption cases failed"
      severity failure;
    finish;
    wait;
  end process;
end architecture;
