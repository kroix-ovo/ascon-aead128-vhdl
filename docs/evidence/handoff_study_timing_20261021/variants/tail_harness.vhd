-- TIMING HARNESS ONLY (handoff study 2026-10-21). Not a functional design.
-- Question: does "2-round p8 tail group + absorb XOR (+ decrypt select)" fit
-- in the same clock as a 3-round group?  The harness holds one 320-bit
-- state register whose next value is
--     load ? state_i : (tail ? absorb(round11(round10(s)), din) : r3(s))
-- where r3 uses three rounds with a run-time round index (as the core does)
-- and the tail uses the fixed constants of rounds 10 and 11.
-- G_TAIL=false builds the 3-round-only reference. The two datapaths are in
-- separate entities so a keep_hierarchy run can time them separately.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;

entity h_chain3 is
  port (s : in state_t; rn : in unsigned(3 downto 0); o : out state_t);
end entity;
architecture rtl of h_chain3 is
begin
  process (s, rn)
    variable v : state_t;
  begin
    v := s;
    for l in 0 to 2 loop
      v := ascon_round(v, (to_integer(rn) + l) mod 16);
    end loop;
    o <= v;
  end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;
entity h_tail2 is
  port (s : in state_t; din : in rate_t; dec : in std_logic; o : out state_t; ct : out rate_t);
end entity;
architecture rtl of h_tail2 is
begin
  process (s, din, dec)
    variable v : state_t;
    variable r : rate_t;
  begin
    v := ascon_round(ascon_round(s, 10), 11);
    r := state_rate(v);
    ct <= r xor din;                       -- ciphertext / plaintext output
    if dec = '1' then
      o <= set_state_rate(v, din);         -- decrypt: ciphertext replaces rate
    else
      o <= set_state_rate(v, r xor din);   -- encrypt: absorb plaintext
    end if;
  end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;
entity tail_harness is
  generic (G_TAIL : boolean := true);
  port (
    clk_i   : in  std_logic;
    rst_i   : in  std_logic;
    load_i  : in  std_logic;
    tail_i  : in  std_logic;
    dec_i   : in  std_logic;
    rn_i    : in  unsigned(3 downto 0);
    state_i : in  state_t;
    din_i   : in  rate_t;
    state_o : out state_t;
    out_o   : out rate_t);
end entity;
architecture rtl of tail_harness is
  signal state_reg : state_t := (others => '0');
  signal din_reg, out_reg : rate_t := (others => '0');
  signal rn_reg : unsigned(3 downto 0) := (others => '0');
  signal load_reg, tail_reg, dec_reg : std_logic := '0';
  signal r3, r2 : state_t;
  signal ct : rate_t;
begin
  state_o <= state_reg;
  out_o <= out_reg;
  c3 : entity work.h_chain3 port map (state_reg, rn_reg, r3);
  t_g : if G_TAIL generate
    c2 : entity work.h_tail2 port map (state_reg, din_reg, dec_reg, r2, ct);
  end generate;
  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        state_reg <= (others => '0'); din_reg <= (others => '0'); out_reg <= (others => '0');
        rn_reg <= (others => '0'); load_reg <= '0'; tail_reg <= '0'; dec_reg <= '0';
      else
        din_reg <= din_i; rn_reg <= rn_i; load_reg <= load_i; tail_reg <= tail_i; dec_reg <= dec_i;
        if load_reg = '1' then
          state_reg <= state_i;
        elsif G_TAIL and tail_reg = '1' then
          state_reg <= r2;
          out_reg <= ct;
        else
          state_reg <= r3;
        end if;
      end if;
    end if;
  end process;
end architecture;
