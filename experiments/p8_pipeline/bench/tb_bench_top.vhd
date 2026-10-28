-- Clock and reset wrapper so the timing harness can be simulated; the
-- harness itself reports how many transactions completed (see
-- scripts/check_harness.sh).
library ieee;
use ieee.std_logic_1164.all;

entity tb_bench_top is
end entity;

architecture sim of tb_bench_top is
  signal clk : std_logic := '0';
  signal btn : std_logic := '1';
  signal led : std_logic_vector(0 downto 0);
begin
  clk <= not clk after 5 ns;
  btn <= '0' after 50 ns;
  dut : entity work.ascon_bench_top port map (CLK100MHZ => clk, BTNC => btn, LED => led);
end architecture;
