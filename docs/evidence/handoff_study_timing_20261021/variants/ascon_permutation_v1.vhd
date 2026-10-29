-- TIMING EXPERIMENT ONLY (handoff study, 2026-10-21). Not committed RTL.
-- Same ports/behaviour as rtl/ascon_permutation.vhd for rounds_i in {8, 12}:
--   * the short group of a p8/p12 that R does not divide runs FIRST, so the
--     only bypass muxes sit on the leading lanes (statically known), and the
--     last lane is a plain round whose XOR3 can absorb the state_i load mux;
--   * lane enables are registered one-hot bits (no decode of a 4-bit count
--     fanning out to 320 LUTs); lanes that can never be skipped have no mux;
--   * final_round_reg (a register only because of its reset) is removed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;

entity ascon_permutation is
  generic (G_ROUNDS_PER_CYCLE : positive range 1 to 12 := 1);
  port (
    clk_i    : in  std_logic;
    rst_i    : in  std_logic;
    start_i  : in  std_logic;
    rounds_i : in  unsigned(3 downto 0);
    state_i  : in  state_t;
    busy_o   : out std_logic;
    done_o   : out std_logic;
    state_o  : out state_t);
end entity;

architecture rtl of ascon_permutation is
  constant R : positive := G_ROUNDS_PER_CYCLE;
  -- leading lanes skipped on the first step of p8 / p12
  constant PAD8  : natural := (R - (8 mod R)) mod R;
  constant PAD12 : natural := (R - (12 mod R)) mod R;
  function may_skip(l : natural) return boolean is
  begin
    return l < PAD8 or l < PAD12;
  end function;
  signal state_reg  : state_t := (others => '0');
  -- virtual round index of lane 0; may be negative on a padded first step
  signal base_reg   : integer range -12 to 11 := 0;
  signal lane_en    : std_logic_vector(R-1 downto 0) := (others => '0');
  signal busy_reg   : std_logic := '0';
  signal done_reg   : std_logic := '0';
begin
  busy_o  <= busy_reg;
  done_o  <= done_reg;
  state_o <= state_reg;

  process (clk_i)
    variable next_state : state_t;
    variable pad        : natural;
  begin
    if rising_edge(clk_i) then
      done_reg <= '0';
      if rst_i = '1' then
        state_reg <= (others => '0');
        base_reg  <= 0;
        lane_en   <= (others => '0');
        busy_reg  <= '0';
        done_reg  <= '0';
      elsif busy_reg = '0' then
        if start_i = '1' then
          if rounds_i = to_unsigned(12, 4) then pad := PAD12; else pad := PAD8; end if;
          state_reg <= state_i;
          base_reg  <= 12 - to_integer(rounds_i) - pad;
          for l in 0 to R-1 loop
            if l < pad then lane_en(l) <= '0'; else lane_en(l) <= '1'; end if;
          end loop;
          busy_reg <= '1';
        end if;
      else
        next_state := state_reg;
        for l in 0 to R-1 loop
          if may_skip(l) then
            if lane_en(l) = '1' then
              next_state := ascon_round(next_state, (base_reg + l) mod 16);
            end if;
          else
            next_state := ascon_round(next_state, (base_reg + l) mod 16);
          end if;
        end loop;
        state_reg <= next_state;
        lane_en   <= (others => '1');
        if base_reg + R > 11 then
          busy_reg <= '0';
          done_reg <= '1';
        else
          base_reg <= base_reg + R;
        end if;
      end if;
    end if;
  end process;
end architecture;
