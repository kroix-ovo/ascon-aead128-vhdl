-- SPDX-License-Identifier: UNLICENSED
--
-- Iterative Ascon permutation engine.
--
-- The engine owns one 320-bit state register and a configurable chain of
-- combinational rounds. G_ROUNDS_PER_CYCLE trades circuit depth and area
-- for fewer cycles; its default preserves the original circuit. A 12-round
-- request uses constants F0 through 4B; an 8-round request skips the first
-- four constants and uses B4 through 4B.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.ascon_pkg.all;

entity ascon_permutation is
  generic (
    G_ROUNDS_PER_CYCLE : positive range 1 to 12 := 1
  );
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
  signal round_number_reg: natural range 0 to 11 := 0;
  signal final_round_reg : natural range 0 to 11 := 0;
  signal busy_reg        : std_logic := '0';
  signal done_reg        : std_logic := '0';
begin
  busy_o  <= busy_reg;
  done_o  <= done_reg;
  state_o <= state_reg;

  process (clk_i)
    variable next_state : state_t;
    variable start_round: natural;
    variable rounds_this_cycle : natural;
  begin
    if rising_edge(clk_i) then
      done_reg <= '0';

      if rst_i = '1' then
        state_reg        <= (others => '0');
        round_number_reg <= 0;
        final_round_reg  <= 0;
        busy_reg         <= '0';
        done_reg         <= '0';
      elsif busy_reg = '0' then
        if start_i = '1' then
          -- Ascon-p[n] always uses the final n constants from the twelve-
          -- round sequence.  Only 8 and 12 are requested by AEAD128.
          start_round := 12 - to_integer(rounds_i);
          state_reg        <= state_i;
          round_number_reg <= start_round;
          final_round_reg  <= 11;
          busy_reg         <= '1';
        end if;
      else
        next_state := state_reg;
        rounds_this_cycle := 0;
        -- A static loop creates cascaded round logic, with no registers
        -- between rounds. The guard handles the shorter final group when
        -- the unrolling factor does not divide eight or twelve.
        for lane in 0 to G_ROUNDS_PER_CYCLE - 1 loop
          if round_number_reg + lane <= final_round_reg then
            next_state := ascon_round(next_state, round_number_reg + lane);
            rounds_this_cycle := rounds_this_cycle + 1;
          end if;
        end loop;
        state_reg  <= next_state;

        if round_number_reg + rounds_this_cycle > final_round_reg then
          busy_reg <= '0';
          done_reg <= '1';
        else
          round_number_reg <= round_number_reg + rounds_this_cycle;
        end if;
      end if;
    end if;
  end process;
end architecture;
