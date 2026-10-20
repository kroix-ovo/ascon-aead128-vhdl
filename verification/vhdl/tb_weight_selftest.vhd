library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_weight_selftest is end entity;
architecture sim of tb_weight_selftest is
 signal clk : std_logic := '0';
 signal rst : std_logic := '1';
 signal done, pass, fail : std_logic;
 signal case_id : std_logic_vector(7 downto 0);
 signal cycles : std_logic_vector(31 downto 0);
begin
 clk <= not clk after 5 ns;
 dut : entity work.ascon_weight_selftest port map(clk,rst,done,pass,fail,case_id,cycles);
 process begin
 wait for 30 ns; wait until falling_edge(clk);rst<='0';
 wait until done='1' for 1 ms;
 assert done='1' and pass='1' and fail='0'
   report "Selftest failed case=" & integer'image(to_integer(unsigned(case_id))) severity failure;
 report "SELFTEST PASS cycles=" & integer'image(to_integer(unsigned(cycles))) severity note;
 finish;
 end process;
end architecture;
