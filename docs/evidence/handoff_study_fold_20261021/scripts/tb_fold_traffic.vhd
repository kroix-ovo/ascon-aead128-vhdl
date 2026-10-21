-- FOLD STUDY ONLY (copy of build/handoff_sim/scripts/tb_handoff_traffic.vhd with
-- G_FOLDED_ABSORB and FIFO depth generics added; behaviour otherwise unchanged).
-- Synchronous traffic bench for ascon_aead128_core: AD, partial endings, source
-- gaps, sink backpressure, bad tags. Every handshake is sampled on the rising
-- edge (pre-update values), so cycle offsets are exact. A transaction's cycle
-- count uses the tb_weight_file convention: clocks from the cycle in which
-- cmd_valid is first driven to the cycle in which done_o becomes visible.
-- Python (run_traffic.py) generates traffic_in.txt and checks traffic_out.txt
-- against the reference model.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

entity tb_fold_traffic is
  generic (
    G_ROUNDS_PER_CYCLE : positive := 1;
    G_BUFFERING_ENABLE : boolean := false;
    G_FOLDED_ABSORB : boolean := false;
    G_IN_DEPTH : positive := 2;
    G_OUT_DEPTH : positive := 2;
    G_RUN_DIR : string := ".";
    G_GAP_PERIOD : natural := 0;    -- source offers a NEW beat only when (t mod P) >= LEN
    G_GAP_LEN : natural := 0;
    G_STALL_PERIOD : natural := 0;  -- sink ready is low when (t mod P) < LEN
    G_STALL_LEN : natural := 0;
    G_TAG_EARLY : boolean := true   -- decrypt: offer tag_in from command acceptance
  );
end entity;

architecture sim of tb_fold_traffic is
  subtype block_t is std_logic_vector(127 downto 0);
  type beat_t is record
    kind, last : std_logic;
    keep : std_logic_vector(15 downto 0);
    data : block_t;
  end record;
  type beat_array_t is array (0 to 4095) of beat_t;
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
begin
  clk <= not clk after CLOCK_PERIOD / 2;
  dut : entity work.ascon_aead128_core
    generic map (G_ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE,
                 G_BUFFERING_ENABLE => G_BUFFERING_ENABLE,
                 G_INPUT_FIFO_DEPTH => G_IN_DEPTH,
                 G_OUTPUT_FIFO_DEPTH => G_OUT_DEPTH,
                 G_FOLDED_ABSORB => G_FOLDED_ABSORB)
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
    wait for 100 ms;
    assert false report "traffic bench timed out" severity failure;
    wait;
  end process;

  driver : process
    file fin : text open read_mode is G_RUN_DIR & "/traffic_in.txt";
    file fout : text open write_mode is G_RUN_DIR & "/traffic_out.txt";
    variable l, o : line;
    variable ntx, nbeats, dec, k, lst, sent, t, e, k0 : integer;
    variable beats : beat_array_t;
    variable kv, nv, tv, dv : block_t;
    variable keepv : std_logic_vector(15 downto 0);
    variable cmd_accepted, tag_done, in_pending, last_seen : boolean;
    variable first_in, first_out, last_out, n_out, in_stall, out_stall, n_auth, n_commit, n_discard, n_error, auth_ok_seen : integer;
    variable got_tag : block_t;

    function gap_blocks(tt : integer) return boolean is
    begin
      return G_GAP_PERIOD > 0 and (tt mod G_GAP_PERIOD) < G_GAP_LEN;
    end function;
    function stalled(tt : integer) return boolean is
    begin
      return G_STALL_PERIOD > 0 and (tt mod G_STALL_PERIOD) < G_STALL_LEN;
    end function;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    e := 0;
    readline(fin, l); read(l, ntx);
    for x in 0 to ntx - 1 loop
      readline(fin, l);
      read(l, dec); hread(l, kv); hread(l, nv); hread(l, tv); read(l, nbeats);
      for b in 0 to nbeats - 1 loop
        readline(fin, l);
        read(l, k); hread(l, keepv); read(l, lst); hread(l, dv);
        if k = 1 then beats(b).kind := '1'; else beats(b).kind := '0'; end if;
        if lst = 1 then beats(b).last := '1'; else beats(b).last := '0'; end if;
        beats(b).keep := keepv; beats(b).data := dv;
      end loop;
      -- wait for command readiness (sampled on edges)
      while cmd_ready /= '1' loop
        wait until rising_edge(clk); e := e + 1;
      end loop;
      k0 := e;  -- cmd_valid is driven during the cycle that ends at edge k0+1 (offset 0)
      if dec = 1 then cmd_decrypt <= '1'; else cmd_decrypt <= '0'; end if;
      key <= kv; nonce <= nv; cmd_valid <= '1';
      tag_in <= tv; tag_in_valid <= '0'; tag_out_ready <= '0';
      out_ready <= '1';
      if stalled(0) then out_ready <= '0'; end if;
      cmd_accepted := false; tag_done := false; in_pending := false; last_seen := false; sent := 0;
      first_in := -1; first_out := -1; last_out := -1; n_out := 0; in_stall := 0; out_stall := 0;
      n_auth := 0; n_commit := 0; n_discard := 0; n_error := 0; auth_ok_seen := 0;
      got_tag := (others => '0');
      loop
        wait until rising_edge(clk); e := e + 1;
        t := e - k0 - 1;  -- offset of the cycle that just ended
        -- sample handshakes of cycle t
        if cmd_valid = '1' and cmd_ready = '1' then cmd_accepted := true; end if;
        if in_valid = '1' then
          if in_ready = '1' then
            if first_in < 0 then first_in := t; end if;
            sent := sent + 1; in_pending := false;
          else
            in_stall := in_stall + 1;
          end if;
        end if;
        if out_valid = '1' then
          if out_ready = '1' then
            if first_out < 0 then first_out := t; end if;
            last_out := t; n_out := n_out + 1;
            if out_last = '1' then last_seen := true; end if;
            write(o, string'("OUT ")); hwrite(o, out_keep); write(o, string'(" "));
            write(o, to_string(out_last)); write(o, string'(" ")); hwrite(o, out_data);
            write(o, string'(" ")); write(o, t);
            writeline(fout, o);
          else
            out_stall := out_stall + 1;
          end if;
        end if;
        if tag_out_valid = '1' and tag_out_ready = '1' then
          got_tag := tag_out; tag_done := true;
          write(o, string'("TAGOUT ")); hwrite(o, tag_out); write(o, string'(" ")); write(o, t); writeline(fout, o);
        end if;
        if tag_in_valid = '1' and tag_in_ready = '1' then
          tag_done := true;
          write(o, string'("TAGIN ")); write(o, t); writeline(fout, o);
        end if;
        if auth_valid = '1' then n_auth := n_auth + 1; if auth_ok = '1' then auth_ok_seen := 1; end if; end if;
        if commit = '1' then n_commit := n_commit + 1;
          write(o, string'("COMMIT ")); write(o, t); writeline(fout, o); end if;
        if discard = '1' then write(o, string'("DISCARD ")); write(o, t); writeline(fout, o); end if;
        if error_status = '1' then write(o, string'("ERROR ")); write(o, t); writeline(fout, o); end if;
        if discard = '1' then n_discard := n_discard + 1; end if;
        if error_status = '1' then n_error := n_error + 1; end if;
        exit when done = '1';
        -- drive the next cycle (t+1)
        if cmd_accepted then cmd_valid <= '0'; end if;
        if cmd_accepted and sent < nbeats and (in_pending or (in_valid = '1' and in_ready = '0') or not gap_blocks(t + 1)) then
          in_valid <= '1'; in_pending := true;
          in_kind <= beats(sent).kind; in_keep <= beats(sent).keep;
          in_last <= beats(sent).last; in_data <= beats(sent).data;
        else
          in_valid <= '0';
        end if;
        if stalled(t + 1) then out_ready <= '0'; else out_ready <= '1'; end if;
        if stalled(t + 1) then tag_out_ready <= '0'; else tag_out_ready <= '1'; end if;
        if tag_done then tag_out_ready <= '0'; end if;
        if dec = 1 and cmd_accepted and not tag_done and (G_TAG_EARLY or last_seen) then
          tag_in_valid <= '1';
        else
          tag_in_valid <= '0';
        end if;
      end loop;
      -- done visible during cycle t; bench convention counts up to (not including) it
      in_valid <= '0'; tag_in_valid <= '0'; tag_out_ready <= '0';
      write(o, string'("TX ")); write(o, x); write(o, string'(" dec=")); write(o, dec);
      write(o, string'(" cycles=")); write(o, t);
      write(o, string'(" first_in=")); write(o, first_in);
      write(o, string'(" first_out=")); write(o, first_out);
      write(o, string'(" last_out=")); write(o, last_out);
      write(o, string'(" n_out=")); write(o, n_out);
      write(o, string'(" in_stall=")); write(o, in_stall);
      write(o, string'(" out_stall=")); write(o, out_stall);
      write(o, string'(" auth=")); write(o, n_auth);
      write(o, string'(" auth_ok=")); write(o, auth_ok_seen);
      write(o, string'(" commit=")); write(o, n_commit);
      write(o, string'(" discard=")); write(o, n_discard);
      write(o, string'(" error=")); write(o, n_error);
      writeline(fout, o);
    end loop;
    write(o, string'("END")); writeline(fout, o);
    file_close(fout);
    finish;
    wait;
  end process;
end architecture;
