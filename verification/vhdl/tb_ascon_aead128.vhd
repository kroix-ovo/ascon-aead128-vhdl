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

entity tb_ascon_aead128 is
  generic (
    G_VECTOR_FILE : string := "verification/vectors/xsim_vectors.txt"
  );
end entity;

architecture sim of tb_ascon_aead128 is
  subtype block_t is std_logic_vector(127 downto 0);
  type block_pair_t is array (0 to 1) of block_t;
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

  stimulus : process
    file input_file     : text;
    file readable_file : text open write_mode is "simulation_results.txt";
    file record_file   : text open write_mode is "simulation_vectors.txt";
    variable open_status : file_open_status;
    variable input_line, output_line : line;
    variable pass_count, fail_count : natural := 0;
    variable case_count, ad_length, message_length : natural;
    variable key_value, nonce_value, tag_value : block_t;
    variable ad_blocks, plain_blocks, cipher_blocks : block_pair_t;

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

    procedure send_payload(
      constant length_value : natural;
      constant input_blocks : block_pair_t;
      variable captured_blocks : out block_pair_t
    ) is
    begin
      captured_blocks := (others => (others => '0'));
      if length_value = 0 then
        send_beat('1', (others => '0'), x"0000", '1');
      elsif length_value <= 16 then
        send_beat('1', input_blocks(0), keep_for_bytes(length_value), '1');
        wait_ready(out_valid);
        captured_blocks(0) := out_data;
        out_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        out_ready <= '0';
      else
        send_beat('1', input_blocks(0), x"FFFF", '0');
        wait_ready(out_valid);
        captured_blocks(0) := out_data;
        out_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        out_ready <= '0';
        send_beat('1', input_blocks(1), keep_for_bytes(length_value - 16), '1');
        wait_ready(out_valid);
        captured_blocks(1) := out_data;
        out_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        out_ready <= '0';
      end if;
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
      variable actual_tag : block_t := (others => '0');
      variable start_cycle, elapsed_cycles : natural;
      variable passed : boolean;
      variable sampled_auth, sampled_commit, sampled_discard : std_logic;
    begin
      start_command('0', key_value, nonce_value, start_cycle);
      send_ad(ad_length, ad_blocks);
      send_payload(message_length, plain_blocks, actual_blocks);
      wait_ready(tag_out_valid);
      actual_tag := tag_out;
      tag_out_ready <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      tag_out_ready <= '0';
      wait_ready(done);
      elapsed_cycles := simulation_cycle - start_cycle;
      passed := actual_blocks = cipher_blocks and actual_tag = tag_value and
                error_status = '0';
      write_readable_result("ENCRYPT", passed, case_count, ad_length,
                            message_length, cipher_blocks(0), cipher_blocks(1),
                            actual_blocks(0), actual_blocks(1), tag_value,
                            actual_tag, '1', elapsed_cycles);
      write_machine_result(case_count, "ENC", ad_length, message_length,
                           key_value, nonce_value, ad_blocks, plain_blocks,
                           actual_blocks, actual_tag, '1', elapsed_cycles, passed);

      start_command('1', key_value, nonce_value, start_cycle);
      send_ad(ad_length, ad_blocks);
      send_payload(message_length, cipher_blocks, actual_blocks);
      wait_ready(tag_in_ready);
      tag_in <= tag_value;
      tag_in_valid <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      sampled_auth := auth_ok;
      sampled_commit := commit;
      sampled_discard := discard;
      tag_in_valid <= '0';
      wait_ready(done);
      elapsed_cycles := simulation_cycle - start_cycle;
      passed := actual_blocks = plain_blocks and auth_valid = '0' and
                sampled_auth = '1' and sampled_commit = '1' and
                sampled_discard = '0' and error_status = '0';
      write_readable_result("DECRYPT", passed, case_count, ad_length,
                            message_length, plain_blocks(0), plain_blocks(1),
                            actual_blocks(0), actual_blocks(1), tag_value,
                            tag_value, sampled_auth, elapsed_cycles);
      write_machine_result(case_count, "DEC", ad_length, message_length,
                           key_value, nonce_value, ad_blocks, cipher_blocks,
                           actual_blocks, tag_value, sampled_auth,
                           elapsed_cycles, passed);
    end procedure;
  begin
    file_open(open_status, input_file, G_VECTOR_FILE, read_mode);
    assert open_status = open_ok
      report "Could not open compact KAT file: " & G_VECTOR_FILE severity failure;

    write(output_line, string'("NIST Ascon-AEAD128 VHDL simulation results"));
    writeline(readable_file, output_line);
    write(output_line, string'("Vector source: ascon-c 446347f21b209f3921c65ece70027c366cbe1693"));
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
      hread(input_line, plain_blocks(0));
      hread(input_line, plain_blocks(1));
      hread(input_line, cipher_blocks(0));
      hread(input_line, cipher_blocks(1));
      hread(input_line, tag_value);
      run_vector;
    end loop;
    file_close(input_file);

    write(output_line, string'("TOTAL vectors=")); write(output_line, case_count);
    write(output_line, string'(" checks=")); write(output_line, pass_count + fail_count);
    write(output_line, string'(" pass=")); write(output_line, pass_count);
    write(output_line, string'(" fail=")); write(output_line, fail_count);
    writeline(readable_file, output_line);
    assert case_count = 1089 report "The compact file did not contain all 1089 vectors"
      severity failure;
    assert pass_count = 2178 and fail_count = 0
      report "One or more Ascon-AEAD128 encryption or decryption cases failed"
      severity failure;
    finish;
    wait;
  end process;
end architecture;
