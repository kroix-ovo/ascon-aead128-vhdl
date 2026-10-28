-- Permutation-engine bench for the p8 pipelining experiment.
--
-- G_CLOCKS_PER_ROUND states how many busy clocks one complete round takes in
-- the variant under test (1 for the baseline, 2 for a two-stage round).  The
-- bench checks, against the independent Python trace:
--   * state_o after every completed round, and that state_o never changes
--     between completed-round boundaries (no partial round is exposed);
--   * done_o pulses exactly once, on the clock where the final state appears,
--     and busy_o falls with it;
--   * start_i held high with a different state while busy is ignored;
--   * reset at a chosen busy clock (covering every round phase) clears
--     state_o, busy_o and done_o, and the same vector then completes;
--   * the total number of done pulses equals the number of completed runs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

use work.ascon_pkg.all;

entity tb_perm_rounds is
  generic (
    G_VECTOR_FILE      : string := "perm_vectors.txt";
    G_RESULT_FILE      : string := "perm_results.txt";
    G_CLOCKS_PER_ROUND : positive := 1
  );
end entity;

architecture sim of tb_perm_rounds is
  type trace_t is array (0 to 12) of state_t;
  signal clk, rst, start, busy, done : std_logic := '0';
  signal rounds   : unsigned(3 downto 0) := (others => '0');
  signal state_in : state_t := (others => '0');
  signal state_out: state_t;
  signal done_count : natural := 0;
begin
  clk <= not clk after 5 ns;

  dut : entity work.ascon_permutation
    port map (clk_i => clk, rst_i => rst, start_i => start, rounds_i => rounds,
              state_i => state_in, busy_o => busy, done_o => done,
              state_o => state_out);

  process (clk)
  begin
    if rising_edge(clk) and done = '1' then
      done_count <= done_count + 1;
    end if;
  end process;

  stimulus : process
    file vec_file : text;
    file res_file : text open write_mode is G_RESULT_FILE;
    variable st : file_open_status;
    variable l, o : line;
    variable n_rounds, reset_at : natural;
    variable trace : trace_t;
    variable vector_index, runs, pass_count, fail_count, resets : natural := 0;
    variable ok, completed : boolean;
    variable latency : natural;

    procedure tick is
    begin
      wait until rising_edge(clk);
      wait for 1 ns;
    end procedure;

    -- Returns true when the run finished, false when it was reset.
    procedure run(constant reset_clock : natural; variable finished : out boolean;
                  variable good : inout boolean; variable edges : out natural) is
      variable total : natural := n_rounds * G_CLOCKS_PER_ROUND;
      variable expected : state_t;
      variable done_before : natural;
    begin
      finished := false;
      edges := 0;
      done_before := done_count;
      assert busy = '0' report "engine busy before start" severity error;
      rounds <= to_unsigned(n_rounds, 4);
      state_in <= trace(0);
      start <= '1';
      tick;
      if state_out /= trace(0) or busy /= '1' or done /= '0' then
        good := false;
        report "load edge mismatch, vector " & integer'image(vector_index) severity error;
      end if;
      -- Hold start high with a different state for the whole busy period.
      state_in <= not trace(0);

      for edge in 1 to total loop
        if reset_clock = edge then
          rst <= '1';
          tick;
          rst <= '0';
          start <= '0';
          if state_out /= (state_out'range => '0') or busy /= '0' or done /= '0' then
            good := false;
            report "reset did not clear engine at busy clock " & integer'image(edge) severity error;
          end if;
          tick;
          if busy /= '0' or done /= '0' then
            good := false;
            report "engine active after reset" severity error;
          end if;
          return;
        end if;
        tick;
        expected := trace(edge / G_CLOCKS_PER_ROUND);
        if state_out /= expected then
          good := false;
          report "state mismatch after busy clock " & integer'image(edge) &
                 ", vector " & integer'image(vector_index) severity error;
        end if;
        if edge = total then
          if done /= '1' or busy /= '0' then
            good := false;
            report "done/busy wrong on final round, vector " & integer'image(vector_index) severity error;
          end if;
        elsif done /= '0' or busy /= '1' then
          good := false;
          report "early done or busy drop at busy clock " & integer'image(edge) severity error;
        end if;
      end loop;
      edges := total;
      start <= '0';
      tick;
      if done /= '0' or busy /= '0' or state_out /= trace(n_rounds) then
        good := false;
        report "repeated done, restart, or unstable output after completion" severity error;
      end if;
      if done_count /= done_before + 1 then
        good := false;
        report "done pulse count wrong" severity error;
      end if;
      finished := true;
    end procedure;
  begin
    file_open(st, vec_file, G_VECTOR_FILE, read_mode);
    assert st = open_ok report "cannot open " & G_VECTOR_FILE severity failure;
    rst <= '1';
    tick; tick;
    rst <= '0';
    tick;

    while not endfile(vec_file) loop
      readline(vec_file, l);
      read(l, n_rounds);
      read(l, reset_at);
      for i in 0 to n_rounds loop
        hread(l, trace(i));
      end loop;
      ok := true;
      if reset_at /= 0 then
        run(reset_at, completed, ok, latency);
        if reset_at <= n_rounds * G_CLOCKS_PER_ROUND then
          resets := resets + 1;
        end if;
      end if;
      run(0, completed, ok, latency);
      ok := ok and completed;
      runs := runs + 1;
      if ok then pass_count := pass_count + 1; else fail_count := fail_count + 1; end if;
      write(o, string'("PERM|")); write(o, vector_index);
      write(o, string'("|ROUNDS|")); write(o, n_rounds);
      write(o, string'("|RESET_AT|")); write(o, reset_at);
      write(o, string'("|START_TO_DONE_EDGES|")); write(o, latency);
      if ok then write(o, string'("|PASS")); else write(o, string'("|FAIL")); end if;
      writeline(res_file, o);
      vector_index := vector_index + 1;
    end loop;

    write(o, string'("TOTAL runs=")); write(o, runs);
    write(o, string'(" pass=")); write(o, pass_count);
    write(o, string'(" fail=")); write(o, fail_count);
    write(o, string'(" resets=")); write(o, resets);
    write(o, string'(" done_pulses=")); write(o, done_count);
    writeline(res_file, o);
    assert fail_count = 0 report "permutation bench failures" severity failure;
    finish;
    wait;
  end process;
end architecture;
