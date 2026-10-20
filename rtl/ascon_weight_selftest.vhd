-- SPDX-License-Identifier: UNLICENSED
-- Standalone hardware scoreboard. All fixture keys/nonces are public tests.
-- Quarantine is cleared on discard/reset; only commit publishes plaintext.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_selftest_vectors.all;
entity ascon_weight_selftest is
  port (clk_i, rst_i : in std_logic;
        done_o, pass_o, fail_o : out std_logic;
        case_o : out std_logic_vector(7 downto 0);
        cycles_o : out std_logic_vector(31 downto 0));
end entity;
architecture rtl of ascon_weight_selftest is
  type mode_t is (RESET_CORE, ABORT_COMMAND, ABORT_AD, ABORT_FILL, ABORT_RESET,
                 COMMAND, AD, AD_GAP, MESSAGE, MSG_GAP, WAIT_DONE, NEXT_CASE, FINISHED, FAILED);
  signal mode : mode_t := RESET_CORE;
  signal f : fixture_t;
  signal fixture : natural range 0 to FIXTURES'length-1 := 0;
  signal tx_index, rx_count : natural range 0 to 4 := 0;
  signal tick : unsigned(23 downto 0) := (others => '0');
  signal elapsed, cycle_latch : unsigned(31 downto 0) := (others => '0');
  signal gap_count : natural range 0 to 3 := 0;
  signal crst, cv, cr, iv, ir, ik, il, ov, ordy, ol : std_logic;
  signal tv, tr, tov, auth, ok, commit, discard, err, done : std_logic;
  signal data, od, tag, selected_nonce : block_t;
  signal keep, out_keep : std_logic_vector(15 downto 0);
  signal quarantine : blocks_t := (others => (others => '0'));
  signal published : blocks_t := (others => (others => '0'));
  signal saw_terminal, reset_verified : std_logic := '0';
  signal failure : std_logic := '0';
  signal failure_case : std_logic_vector(7 downto 0) := (others => '0');
  signal dec : std_logic;
  function blocks(n : natural) return positive is
  begin if n = 0 then return 1; else return (n+15)/16; end if; end;
  function beat_keep(n, idx : natural) return std_logic_vector is
    variable k : std_logic_vector(15 downto 0) := (others => '0');
  begin
    for b in 0 to 15 loop if idx*16+b < n then k(b) := '1'; end if; end loop;
    return k;
  end;
begin
  f <= FIXTURES(fixture);
  done_o <= '1' when mode = FINISHED or mode = FAILED else '0';
  pass_o <= '1' when mode = FINISHED and failure = '0' else '0';
  fail_o <= failure;
  case_o <= failure_case when failure = '1' else std_logic_vector(to_unsigned(fixture,8));
  cycles_o <= std_logic_vector(cycle_latch);
  crst <= '1' when rst_i = '1' or mode = RESET_CORE or mode = ABORT_RESET else '0';
  selected_nonce <= x"0000000000000000000000005354FFFF" when mode = ABORT_COMMAND else f.nonce;
  cv <= '1' when mode = COMMAND or mode = ABORT_COMMAND else '0';
  dec <= '1' when f.decrypt_mode and mode /= ABORT_COMMAND else '0';
  iv <= '1' when mode = AD or mode = MESSAGE or mode = ABORT_AD or mode = ABORT_FILL else '0';
  ik <= '1' when mode = MESSAGE or mode = ABORT_FILL else '0';
  il <= '1' when mode = ABORT_AD or
       (mode = AD and tx_index = blocks(f.ad_bytes)-1) or
       (mode = MESSAGE and tx_index = blocks(f.msg_bytes)-1) else '0';
  data <= f.ad(tx_index mod 4) when mode = AD else
          f.input_data(tx_index mod 4);
  keep <= x"0000" when mode = ABORT_AD else x"FFFF" when mode = ABORT_FILL else
          beat_keep(f.ad_bytes,tx_index) when mode = AD else
          beat_keep(f.msg_bytes,tx_index);
  ordy <= '1' when mode /= ABORT_FILL and tick(6 downto 0) >= 80 else '0';
  tv <= '1' when mode = WAIT_DONE and f.decrypt_mode else '0';
  core_u : entity work.ascon_aead128_core
    generic map (G_ROUNDS_PER_CYCLE => 3, G_BUFFERING_ENABLE => true)
    port map (
      clk_i=>clk_i, rst_i=>crst, cmd_valid_i=>cv, cmd_ready_o=>cr,
      cmd_decrypt_i=>dec, key_i=>f.key, nonce_i=>selected_nonce,
      in_valid_i=>iv,in_ready_o=>ir,in_kind_i=>ik,in_data_i=>data,in_keep_i=>keep,in_last_i=>il,
      out_valid_o=>ov,out_ready_i=>ordy,out_data_o=>od,out_keep_o=>out_keep,out_last_o=>ol,
      tag_in_valid_i=>tv,tag_in_ready_o=>tr,tag_in_i=>f.tag,
      tag_out_valid_o=>tov,tag_out_ready_i=>'1',tag_out_o=>tag,
      busy_o=>open,done_o=>done,auth_valid_o=>auth,auth_ok_o=>ok,
      commit_o=>commit,discard_o=>discard,error_o=>err);
  process(clk_i)
    variable mismatch : boolean;
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        mode <= RESET_CORE; fixture <= 0; tx_index <= 0; rx_count <= 0;
        tick <= (others=>'0'); elapsed <= (others=>'0'); cycle_latch <= (others=>'0');
        gap_count <= 0; quarantine <= (others=>(others=>'0')); published <= (others=>(others=>'0'));
        failure <= '0'; failure_case <= (others=>'0'); saw_terminal <= '0'; reset_verified <= '0';
      else
        tick <= tick+1;
        if mode /= FINISHED and mode /= FAILED then elapsed <= elapsed+1; end if;
        mismatch := false;
        if mode = COMMAND and cv = '1' and cr = '1' then
          rx_count <= 0; quarantine <= (others=>(others=>'0')); published <= (others=>(others=>'0'));
          saw_terminal <= '0';
        end if;
        if ov = '1' and ordy = '1' and mode /= ABORT_FILL then
          if rx_count >= blocks(f.msg_bytes) or f.msg_bytes = 0 then
            mismatch := true;
          else
            quarantine(rx_count) <= od;
            if not f.bad and od /= f.expected(rx_count) then mismatch := true; end if;
            if out_keep /= beat_keep(f.msg_bytes,rx_count) then mismatch := true; end if;
            if (ol='1') /= (rx_count=blocks(f.msg_bytes)-1) then mismatch := true; end if;
            rx_count <= rx_count+1;
          end if;
        end if;
        if tov = '1' then
          if tag /= f.tag or rx_count /= (f.msg_bytes+15)/16 then mismatch := true; end if;
          saw_terminal <= '1';
        end if;
        if auth = '1' then
          if rx_count /= (f.msg_bytes+15)/16 then mismatch := true; end if;
          if f.bad then
            if ok='1' or commit='1' or discard/='1' then mismatch := true; end if;
            quarantine <= (others=>(others=>'0'));
          else
            if ok/='1' or commit/='1' or discard='1' then mismatch := true; end if;
            published <= quarantine;
          end if;
          saw_terminal <= '1';
        end if;
        if f.bad and published /= blocks_t'(others=>(others=>'0')) then mismatch := true; end if;
        if err='1' then mismatch := true; end if;
        case mode is
          when RESET_CORE => mode <= ABORT_COMMAND; tick <= (others=>'0');
          when ABORT_COMMAND => if cr='1' then mode <= ABORT_AD; end if;
          when ABORT_AD => if ir='1' then mode <= ABORT_FILL; tick <= (others=>'0'); end if;
          when ABORT_FILL =>
            if tick >= 100 then
              if ov/='1' then mismatch := true; end if;
              mode <= ABORT_RESET;
            end if;
          when ABORT_RESET => mode <= COMMAND; reset_verified <= '1';
          when COMMAND => if cr='1' then mode<=AD; tx_index<=0; end if;
          when AD =>
            if ir='1' then
              if tx_index=blocks(f.ad_bytes)-1 then mode<=MESSAGE;tx_index<=0;
              else tx_index<=tx_index+1;mode<=AD_GAP;gap_count<=2; end if;
            end if;
          when AD_GAP => if gap_count=0 then mode<=AD;else gap_count<=gap_count-1;end if;
          when MESSAGE =>
            if ir='1' then
              if tx_index=blocks(f.msg_bytes)-1 then mode<=WAIT_DONE;
              else tx_index<=tx_index+1;mode<=MSG_GAP;gap_count<=2;end if;
            end if;
          when MSG_GAP => if gap_count=0 then mode<=MESSAGE;else gap_count<=gap_count-1;end if;
          when WAIT_DONE =>
            if done='1' then
              if saw_terminal/='1' or reset_verified/='1' then mismatch:=true;end if;
              if f.decrypt_mode and not f.bad then
                for j in 0 to 3 loop
                  if j*16 < f.msg_bytes and published(j) /= f.expected(j) then mismatch:=true;end if;
                end loop;
              end if;
              mode<=NEXT_CASE;
            end if;
          when NEXT_CASE =>
            published <= (others=>(others=>'0')); quarantine <= (others=>(others=>'0'));
            if fixture=FIXTURES'length-1 then mode<=FINISHED;cycle_latch<=elapsed;
            else fixture<=fixture+1;mode<=COMMAND;end if;
          when others => null;
        end case;
        if (tick = 1000000 and mode /= FINISHED and mode /= FAILED) or mismatch then
          failure<='1';failure_case<=std_logic_vector(to_unsigned(fixture,8));mode<=FAILED;cycle_latch<=elapsed;
        end if;
      end if;
    end if;
  end process;
end architecture;
