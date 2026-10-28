-- Streaming-protocol bench for the p8 pipelining experiment.
--
-- Reads core_vectors.txt from scripts/gen_vectors.py (independent Python
-- model) and drives complete AEAD transactions through ascon_aead128_core.
--
-- G_STALL = false  architectural run: every valid is offered as early as the
--                  protocol allows and out_ready / tag_out_ready stay high.
--                  Event cycles from this run give the latency tables.
-- G_STALL = true   randomized input gaps, output stalls, delayed tags, and
--                  command requests while busy (fixed seed).
--
-- Checked on every transaction: payload output data/keep/last, tag or
-- authentication result, exactly one done pulse after the tag, no error,
-- commit/discard/auth_valid counts, output stability while stalled, and that
-- out_data_o is zero whenever out_valid_o is low (no plaintext is visible
-- outside an output handshake).  A transaction with RESET_AT > 0 is reset
-- that many clocks after its command; the bench then checks that the core
-- is idle, emits nothing, and the next transaction still passes.
--
-- Event lines "EV|tx|kind|edge" let scripts/analyze.py compute block
-- intervals and latencies without a waveform.  "edge" is the index of the
-- rising clock edge at which the handshake or level was sampled; both the
-- stimulus and the monitor use this convention.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

entity tb_core_pipeline is
  generic (
    G_VECTOR_FILE : string := "core_vectors.txt";
    G_RESULT_FILE : string := "core_results.txt";
    G_STALL       : boolean := false;
    G_SEED        : positive := 20261027
  );
end entity;

architecture sim of tb_core_pipeline is
  subtype block_t is std_logic_vector(127 downto 0);
  subtype keep_t is std_logic_vector(15 downto 0);
  constant QDEPTH : natural := 1024;
  type data_q_t is array (0 to QDEPTH - 1) of block_t;
  type keep_q_t is array (0 to QDEPTH - 1) of keep_t;
  type last_q_t is array (0 to QDEPTH - 1) of std_logic;

  signal clk : std_logic := '0';
  signal rst : std_logic := '0';
  signal cmd_valid, cmd_ready, cmd_decrypt : std_logic := '0';
  signal key, nonce : block_t := (others => '0');
  signal in_valid, in_ready, in_kind, in_last : std_logic := '0';
  signal in_data : block_t := (others => '0');
  signal in_keep : keep_t := (others => '0');
  signal tag_in_valid, tag_in_ready : std_logic := '0';
  signal tag_in : block_t := (others => '0');
  signal out_valid, out_ready, out_last : std_logic := '0';
  signal out_data : block_t;
  signal out_keep : keep_t;
  signal tag_out_valid, tag_out_ready : std_logic := '0';
  signal tag_out : block_t;
  signal busy, done, auth_valid, auth_ok, commit, discard, error_status : std_logic;

  signal cycle : natural := 0;
  signal tx_index : natural := 0;

  signal exp_data : data_q_t := (others => (others => '0'));
  signal exp_keep : keep_q_t := (others => (others => '0'));
  signal exp_last : last_q_t := (others => '0');
  signal wr_count : natural := 0;
  signal rd_count : natural := 0;

  signal done_cnt, err_cnt, auth_cnt, commit_cnt, discard_cnt, mon_errors : natural := 0;

  file res_file : text open write_mode is G_RESULT_FILE;

  function to_sl(n : natural) return std_logic is
  begin
    if n = 0 then return '0'; else return '1'; end if;
  end function;
begin
  clk <= not clk after 5 ns;

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

  -- Output-side monitor: drives out_ready, checks every output handshake
  -- against the expected queue, stability under stall, and quarantine.
  monitor : process (clk)
    variable rd : natural := 0;
    variable prev_valid, prev_ready, prev_last : std_logic := '0';
    variable prev_data : block_t := (others => '0');
    variable prev_keep : keep_t := (others => '0');
    variable s1, s2 : positive := G_SEED + 7;
    variable r : real;
    variable o : line;
    variable errors : natural := 0;
  begin
    if rising_edge(clk) then
      cycle <= cycle + 1;
      if done = '1' then done_cnt <= done_cnt + 1; end if;
      if error_status = '1' then err_cnt <= err_cnt + 1; end if;
      if auth_valid = '1' then auth_cnt <= auth_cnt + 1; end if;
      if commit = '1' then commit_cnt <= commit_cnt + 1; end if;
      if discard = '1' then discard_cnt <= discard_cnt + 1; end if;

      if done = '1' then
        write(o, string'("EV|")); write(o, tx_index);
        write(o, string'("|DONE|")); write(o, cycle + 1);
        writeline(res_file, o);
      end if;

      if out_valid = '0' and out_data /= (out_data'range => '0') then
        errors := errors + 1;
        report "out_data visible while out_valid is low" severity error;
      end if;
      if prev_valid = '1' and prev_ready = '0' and rst = '0' then
        if out_valid /= '1' or out_data /= prev_data or out_keep /= prev_keep or
           out_last /= prev_last then
          errors := errors + 1;
          report "output changed while stalled" severity error;
        end if;
      end if;
      if out_valid = '1' and prev_valid = '0' then
        write(o, string'("EV|")); write(o, tx_index);
        write(o, string'("|OUTV|")); write(o, cycle + 1);
        writeline(res_file, o);
      end if;

      if out_valid = '1' and out_ready = '1' and rst = '0' then
        if rd >= wr_count then
          errors := errors + 1;
          report "unexpected output beat" severity error;
        elsif out_data /= exp_data(rd mod QDEPTH) or out_keep /= exp_keep(rd mod QDEPTH) or
              out_last /= exp_last(rd mod QDEPTH) then
          errors := errors + 1;
          report "output beat mismatch in transaction " & integer'image(tx_index) severity error;
        end if;
        rd := rd + 1;
        write(o, string'("EV|")); write(o, tx_index);
        write(o, string'("|OUT|")); write(o, cycle + 1);
        writeline(res_file, o);
      end if;

      prev_valid := out_valid;
      prev_ready := out_ready;
      prev_data := out_data;
      prev_keep := out_keep;
      prev_last := out_last;

      if rst = '1' then
        rd := wr_count;
        prev_valid := '0';
      end if;
      rd_count <= rd;
      mon_errors <= errors;

      if G_STALL then
        uniform(s1, s2, r);
        if r < 0.45 then out_ready <= '0'; else out_ready <= '1'; end if;
      else
        out_ready <= '1';
      end if;
    end if;
  end process;

  stimulus : process
    file vec_file : text;
    variable st : file_open_status;
    variable l, o : line;
    variable tok : character;
    variable good : boolean;
    variable rv : real;
    variable s1, s2 : positive := G_SEED;
    variable dec, expect_auth, reset_at, last_v : natural;
    variable key_v, nonce_v, data_v, out_v, tag_v : block_t;
    variable keep_v : keep_t;
    variable label_v : string(1 to 40);
    variable label_len : natural;
    variable reset_target : natural := 0;
    variable reset_hit : boolean := false;
    variable tx_count, pass_count, fail_count, reset_count : natural := 0;
    variable done_base, err_base, auth_base, commit_base, discard_base, mon_base : natural;
    variable wr : natural := 0;
    variable sampled_ok, sampled_commit, sampled_discard : std_logic;

    procedure log_event(constant kind : string) is
    begin
      write(o, string'("EV|")); write(o, tx_count);
      write(o, string'("|") & kind & "|"); write(o, cycle);
      writeline(res_file, o);
    end procedure;

    -- One clock.  Reset injection happens here so that every wait loop can
    -- be interrupted at any clock of the transaction.
    procedure tick is
    begin
      if reset_target /= 0 and not reset_hit and cycle + 1 = reset_target then
        rst <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        rst <= '0';
        reset_hit := true;
        log_event("RESET");
      else
        wait until rising_edge(clk);
        wait for 1 ns;
      end if;
    end procedure;

    procedure random_gap(constant max_cycles : natural) is
      variable n : natural;
    begin
      if G_STALL then
        uniform(s1, s2, rv);
        n := natural(floor(rv * real(max_cycles + 1)));
        for i in 1 to n loop
          exit when reset_hit;
          -- Requests for a new command while a transaction is in progress
          -- must be ignored.
          uniform(s1, s2, rv);
          if rv < 0.3 and busy = '1' then
            cmd_valid <= '1';
            key <= not key_v;
            nonce <= not nonce_v;
          end if;
          tick;
          cmd_valid <= '0';
        end loop;
      end if;
    end procedure;

    procedure send_beat(constant kind : std_logic) is
    begin
      random_gap(3);
      in_kind <= kind;
      in_data <= data_v;
      in_keep <= keep_v;
      in_last <= to_sl(last_v);
      in_valid <= '1';
      loop
        exit when reset_hit;
        if in_ready = '1' then
          tick;
          exit;
        end if;
        tick;
      end loop;
      in_valid <= '0';
    end procedure;

    procedure fail(constant msg : string) is
    begin
      good := false;
      report "transaction " & integer'image(tx_count) & ": " & msg severity error;
    end procedure;
  begin
    file_open(st, vec_file, G_VECTOR_FILE, read_mode);
    assert st = open_ok report "cannot open " & G_VECTOR_FILE severity failure;
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;

    while not endfile(vec_file) loop
      readline(vec_file, l);
      read(l, tok);
      case tok is
        when 'C' =>
          read(l, dec); hread(l, key_v); hread(l, nonce_v);
          read(l, expect_auth); read(l, reset_at);
          label_v := (others => ' ');
          label_len := 0;
          read(l, tok); -- separating space
          while l'length > 0 and label_len < label_v'length loop
            read(l, tok);
            label_len := label_len + 1;
            label_v(label_len) := tok;
          end loop;
          good := true;
          reset_hit := false;
          reset_target := 0;
          done_base := done_cnt; err_base := err_cnt; auth_base := auth_cnt;
          commit_base := commit_cnt; discard_base := discard_cnt; mon_base := mon_errors;
          tx_index <= tx_count;
          random_gap(2);
          while cmd_ready /= '1' loop tick; end loop;
          cmd_decrypt <= to_sl(dec);
          key <= key_v;
          nonce <= nonce_v;
          cmd_valid <= '1';
          tick;
          cmd_valid <= '0';
          log_event("CMD");
          if reset_at /= 0 then
            reset_target := cycle + reset_at;
          end if;

        when 'A' =>
          hread(l, data_v); hread(l, keep_v); read(l, last_v);
          if not reset_hit then
            send_beat('0');
            if not reset_hit then log_event("AD"); end if;
          end if;

        when 'M' =>
          hread(l, data_v); hread(l, keep_v); read(l, last_v); hread(l, out_v);
          if not reset_hit then
            if keep_v /= x"0000" then
              exp_data(wr mod QDEPTH) <= out_v;
              exp_keep(wr mod QDEPTH) <= keep_v;
              exp_last(wr mod QDEPTH) <= to_sl(last_v);
              wr := wr + 1;
              wr_count <= wr;
            end if;
            send_beat('1');
            if not reset_hit then log_event("MSG"); end if;
          end if;

        when 'T' =>
          hread(l, tag_v);
          if not reset_hit then
            if dec = 0 then
              while tag_out_valid /= '1' and not reset_hit loop tick; end loop;
              if not reset_hit then
                log_event("TAGV");
                random_gap(4);
                if not reset_hit and tag_out_valid /= '1' then
                  fail("tag_out_valid dropped before acceptance");
                end if;
                if not reset_hit then
                  if tag_out /= tag_v then fail("tag mismatch"); end if;
                  tag_out_ready <= '1';
                  tick;
                  tag_out_ready <= '0';
                  log_event("TAG");
                end if;
              end if;
            else
              random_gap(4);
              tag_in <= tag_v;
              tag_in_valid <= '1';
              loop
                exit when reset_hit;
                if tag_in_ready = '1' then
                  tick;
                  sampled_ok := auth_ok;
                  sampled_commit := commit;
                  sampled_discard := discard;
                  log_event("TAG");
                  if expect_auth = 1 then
                    if sampled_ok /= '1' or sampled_commit /= '1' or sampled_discard /= '0' then
                      fail("valid tag not committed");
                    end if;
                  else
                    if sampled_ok /= '0' or sampled_commit /= '0' or sampled_discard /= '1' then
                      fail("forged tag not discarded");
                    end if;
                  end if;
                  exit;
                end if;
                tick;
              end loop;
              tag_in_valid <= '0';
            end if;
          end if;

        when 'E' =>
          -- Wait for completion.  Reset may still land in this window; it
          -- is disarmed once done has been observed.
          if not reset_hit then
            for i in 1 to 40 loop
              exit when done = '1' or reset_hit;
              tick;
            end loop;
            reset_target := 0;
          end if;
          if reset_hit then
            in_valid <= '0'; tag_in_valid <= '0'; tag_out_ready <= '0'; cmd_valid <= '0';
            tick;
            if busy /= '0' or cmd_ready /= '1' or out_valid /= '0' or tag_out_valid /= '0' or
               out_data /= (out_data'range => '0') then
              fail("core not idle after reset");
            end if;
            if done_cnt /= done_base then fail("done pulse during reset transaction"); end if;
            reset_count := reset_count + 1;
          else
            if done /= '1' then fail("missing done"); end if;
            tick;
            tick;
            if done_cnt /= done_base + 1 then fail("done pulse count wrong"); end if;
            if err_cnt /= err_base then fail("error asserted"); end if;
            if rd_count /= wr then fail("not every expected output beat appeared"); end if;
            if mon_errors /= mon_base then fail("output monitor reported errors"); end if;
            if dec = 1 then
              if auth_cnt /= auth_base + 1 then fail("auth_valid count wrong"); end if;
              if commit_cnt /= commit_base + expect_auth then fail("commit count wrong"); end if;
              if discard_cnt /= discard_base + 1 - expect_auth then fail("discard count wrong"); end if;
            elsif auth_cnt /= auth_base or commit_cnt /= commit_base or discard_cnt /= discard_base then
              fail("authentication status pulsed during encryption");
            end if;
          end if;
          write(o, string'("TX|")); write(o, tx_count);
          write(o, string'("|")); write(o, label_v(1 to label_len));
          if dec = 1 then write(o, string'("|DEC")); else write(o, string'("|ENC")); end if;
          if reset_hit then write(o, string'("|RESET")); else write(o, string'("|FULL")); end if;
          if good then write(o, string'("|PASS")); else write(o, string'("|FAIL")); end if;
          writeline(res_file, o);
          if good then pass_count := pass_count + 1; else fail_count := fail_count + 1; end if;
          tx_count := tx_count + 1;

        when others =>
          report "bad vector line" severity failure;
      end case;
    end loop;

    write(o, string'("TOTAL transactions=")); write(o, tx_count);
    write(o, string'(" pass=")); write(o, pass_count);
    write(o, string'(" fail=")); write(o, fail_count);
    write(o, string'(" resets=")); write(o, reset_count);
    write(o, string'(" stall=")); write(o, G_STALL);
    writeline(res_file, o);
    assert fail_count = 0 report "core pipeline bench failures" severity failure;
    finish;
    wait;
  end process;
end architecture;
