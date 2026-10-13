-- Stream a complete, full-block weight file through the existing Ascon RTL.
-- Each direction is one AEAD message, with empty associated data.
-- Vector lines contain one input block and one independently expected block.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

entity tb_weight_file is
  generic (G_RUN_DIR : string := ".");
end entity;

architecture sim of tb_weight_file is
  subtype block_t is std_logic_vector(127 downto 0);
  constant CLOCK_PERIOD : time := 10 ns;
  signal clk, rst : std_logic := '0';
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
begin
  clk <= not clk after CLOCK_PERIOD / 2;
  process(clk)
  begin
    if rising_edge(clk) then simulation_cycle <= simulation_cycle + 1; end if;
  end process;
  dut : entity work.ascon_aead128_core
    port map (
      clk_i => clk, rst_i => rst,
      cmd_valid_i => cmd_valid, cmd_ready_o => cmd_ready,
      cmd_decrypt_i => cmd_decrypt, key_i => key, nonce_i => nonce,
      in_valid_i => in_valid, in_ready_o => in_ready, in_kind_i => in_kind,
      in_data_i => in_data, in_keep_i => in_keep, in_last_i => in_last,
      tag_in_valid_i => tag_in_valid, tag_in_ready_o => tag_in_ready, tag_in_i => tag_in,
      out_valid_o => out_valid, out_ready_i => out_ready, out_data_o => out_data,
      out_keep_o => out_keep, out_last_o => out_last,
      tag_out_valid_o => tag_out_valid, tag_out_ready_i => tag_out_ready, tag_out_o => tag_out,
      busy_o => busy, done_o => done, auth_valid_o => auth_valid,
      auth_ok_o => auth_ok, commit_o => commit, discard_o => discard, error_o => error_status);

  watchdog : process
  begin
    wait for 1 sec;
    assert false report "Weight-file simulation timed out" severity failure;
    wait;
  end process;

  stimulus : process
    file result_file : text open write_mode is G_RUN_DIR & "/simulation_results.txt";
    variable result_line : line;

    procedure wait_ready(signal s : in std_logic) is
    begin
      while s /= '1' loop
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;
    end procedure;

    procedure send_beat(constant kind : std_logic; constant data : block_t;
                        constant keep : std_logic_vector(15 downto 0);
                        constant last : std_logic) is
    begin
      wait_ready(in_ready);
      in_kind <= kind; in_data <= data; in_keep <= keep; in_last <= last;
      in_valid <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      in_valid <= '0';
    end procedure;

    procedure run_message(constant decrypt_mode : std_logic;
                          constant mode_name, input_name, output_name : string) is
      file vectors, dump, tag_dump : text;
      variable status : file_open_status;
      variable input_line, output_line : line;
      variable key_value, nonce_value, expected_tag, input_block, expected_block : block_t;
      variable blocks : positive;
      variable start_cycle, elapsed_cycles : natural;
      variable final_beat, sampled_auth, sampled_commit, sampled_discard : std_logic;
    begin
      file_open(status, vectors, G_RUN_DIR & "/" & input_name, read_mode);
      assert status = open_ok report "Cannot open weight vectors" severity failure;
      file_open(dump, G_RUN_DIR & "/" & output_name, write_mode);
      readline(vectors, input_line);
      read(input_line, blocks);
      hread(input_line, key_value); hread(input_line, nonce_value); hread(input_line, expected_tag);
      wait_ready(cmd_ready);
      start_cycle := simulation_cycle;
      cmd_decrypt <= decrypt_mode; key <= key_value; nonce <= nonce_value; cmd_valid <= '1';
      wait until rising_edge(clk); wait for 1 ns; cmd_valid <= '0';
      send_beat('0', (others => '0'), x"0000", '1');
      for i in 0 to blocks-1 loop
        assert not endfile(vectors) report "Truncated weight vectors" severity failure;
        readline(vectors, input_line);
        hread(input_line, input_block); hread(input_line, expected_block);
        final_beat := '0';
        if i = blocks-1 then final_beat := '1'; end if;
        send_beat('1', input_block, x"FFFF", final_beat);
        wait_ready(out_valid);
        assert out_data = expected_block report mode_name & " block mismatch " & integer'image(i) severity failure;
        assert out_keep = x"FFFF" and out_last = final_beat report "Unexpected output keep/last" severity failure;
        hwrite(output_line, out_data); writeline(dump, output_line);
        out_ready <= '1';
        wait until rising_edge(clk); wait for 1 ns; out_ready <= '0';
        if (i+1) mod 16384 = 0 then
          report mode_name & " blocks=" & integer'image(i+1) severity note;
        end if;
      end loop;
      assert endfile(vectors) report "Extra weight vectors" severity failure;
      file_close(vectors); file_close(dump);
      if decrypt_mode = '0' then
        wait_ready(tag_out_valid);
        assert tag_out = expected_tag report "Encryption tag mismatch" severity failure;
        file_open(tag_dump, G_RUN_DIR & "/rtl_tag.txt", write_mode);
        hwrite(output_line, tag_out); writeline(tag_dump, output_line); file_close(tag_dump);
        tag_out_ready <= '1';
        wait until rising_edge(clk); wait for 1 ns; tag_out_ready <= '0';
        wait_ready(done);
      else
        wait_ready(tag_in_ready);
        tag_in <= expected_tag; tag_in_valid <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        sampled_auth := auth_ok; sampled_commit := commit; sampled_discard := discard;
        tag_in_valid <= '0';
        wait_ready(done);
        assert sampled_auth = '1' and sampled_commit = '1' and sampled_discard = '0'
          report "Decryption did not authenticate and commit" severity failure;
      end if;
      elapsed_cycles := simulation_cycle - start_cycle;
      assert error_status = '0' report "Core reported error" severity failure;
      write(result_line, mode_name & " bytes="); write(result_line, blocks*16);
      write(result_line, string'(" cycles=")); write(result_line, elapsed_cycles);
      write(result_line, string'(" PASS")); writeline(result_file, result_line);
      report mode_name & " cycles=" & integer'image(elapsed_cycles) & " PASS" severity note;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    run_message('0', "ENCRYPT", "encrypt_vectors.txt", "ciphertext_blocks.txt");
    run_message('1', "DECRYPT", "decrypt_vectors.txt", "recovered_blocks.txt");
    write(result_line, string'("checks=2 pass=2 fail=0")); writeline(result_file, result_line);
    file_close(result_file);
    finish;
    wait;
  end process;
end architecture;
