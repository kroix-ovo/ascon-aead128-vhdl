-- SPDX-License-Identifier: UNLICENSED
--
-- Variant B: iterative Ascon permutation with each round split into two
-- registered stages.
--
--   stage 1: constant injection + substitution layer  -> sbox_reg
--   stage 2: linear diffusion layer                   -> state_reg
--
-- A round therefore takes two clocks.  The next round's stage 1 reads only
-- state_reg, which is written only when stage 2 finishes, so a dependent
-- round can never start on a partial result.  phase_reg selects which stage
-- runs; the round counter advances only on a stage-2 edge, so the constant
-- used in stage 1 always matches the round whose result stage 2 completes.
--
-- The external contract is unchanged: start is sampled while idle, state_o
-- only ever shows a completed-round state, and done pulses for one clock on
-- the edge after state_reg holds the final permutation output.  sbox_reg is
-- cleared by reset and on the final stage-2 edge so that no intermediate
-- S-box state outlives the permutation.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.ascon_pkg.all;

entity ascon_permutation is
  port (
    clk_i    : in  std_logic;
    rst_i    : in  std_logic;
    start_i  : in  std_logic;
    rounds_i : in  unsigned(3 downto 0);
    state_i  : in  state_t;
    busy_o   : out std_logic;
    done_o   : out std_logic;
    state_o  : out state_t
  );
end entity;

architecture rtl of ascon_permutation is
  signal state_reg       : state_t := (others => '0');
  signal sbox_reg        : state_t := (others => '0');
  signal phase_reg       : std_logic := '0';
  signal round_number_reg: natural range 0 to 11 := 0;
  signal busy_reg        : std_logic := '0';
  signal done_reg        : std_logic := '0';

  function rotate_right_64(value : word64_t; amount : natural) return word64_t is
  begin
    return std_logic_vector(rotate_right(unsigned(value), amount));
  end function;

  -- Constant addition and the substitution layer of ascon_round.
  function round_substitution(s : state_t; round_index : natural) return state_t is
    variable x0, x1, x2, x3, x4 : word64_t;
    variable t0, t1, t2, t3, t4 : word64_t;
    variable result              : state_t := (others => '0');
  begin
    x0 := state_word(s, 0);
    x1 := state_word(s, 1);
    x2 := state_word(s, 2);
    x3 := state_word(s, 3);
    x4 := state_word(s, 4);

    x2(7 downto 0) := x2(7 downto 0) xor round_constant(round_index);

    x0 := x0 xor x4;
    x4 := x4 xor x3;
    x2 := x2 xor x1;

    t0 := x0 xor ((not x1) and x2);
    t1 := x1 xor ((not x2) and x3);
    t2 := x2 xor ((not x3) and x4);
    t3 := x3 xor ((not x4) and x0);
    t4 := x4 xor ((not x0) and x1);

    t1 := t1 xor t0;
    t0 := t0 xor t4;
    t3 := t3 xor t2;
    t2 := not t2;

    result := set_state_word(result, 0, t0);
    result := set_state_word(result, 1, t1);
    result := set_state_word(result, 2, t2);
    result := set_state_word(result, 3, t3);
    result := set_state_word(result, 4, t4);
    return result;
  end function;

  -- Linear diffusion layer of ascon_round.
  function round_diffusion(t : state_t) return state_t is
    variable t0, t1, t2, t3, t4 : word64_t;
    variable result              : state_t := (others => '0');
  begin
    t0 := state_word(t, 0);
    t1 := state_word(t, 1);
    t2 := state_word(t, 2);
    t3 := state_word(t, 3);
    t4 := state_word(t, 4);
    result := set_state_word(result, 0, t0 xor rotate_right_64(t0, 19) xor rotate_right_64(t0, 28));
    result := set_state_word(result, 1, t1 xor rotate_right_64(t1, 61) xor rotate_right_64(t1, 39));
    result := set_state_word(result, 2, t2 xor rotate_right_64(t2, 1)  xor rotate_right_64(t2, 6));
    result := set_state_word(result, 3, t3 xor rotate_right_64(t3, 10) xor rotate_right_64(t3, 17));
    result := set_state_word(result, 4, t4 xor rotate_right_64(t4, 7)  xor rotate_right_64(t4, 41));
    return result;
  end function;
begin
  busy_o  <= busy_reg;
  done_o  <= done_reg;
  state_o <= state_reg;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      done_reg <= '0';

      if rst_i = '1' then
        state_reg        <= (others => '0');
        sbox_reg         <= (others => '0');
        phase_reg        <= '0';
        round_number_reg <= 0;
        busy_reg         <= '0';
        done_reg         <= '0';
      elsif busy_reg = '0' then
        if start_i = '1' then
          state_reg        <= state_i;
          round_number_reg <= 12 - to_integer(rounds_i);
          phase_reg        <= '0';
          busy_reg         <= '1';
        end if;
      elsif phase_reg = '0' then
        sbox_reg  <= round_substitution(state_reg, round_number_reg);
        phase_reg <= '1';
      else
        state_reg <= round_diffusion(sbox_reg);
        phase_reg <= '0';
        if round_number_reg = 11 then
          sbox_reg <= (others => '0');
          busy_reg <= '0';
          done_reg <= '1';
        else
          round_number_reg <= round_number_reg + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
