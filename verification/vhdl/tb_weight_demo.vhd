library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_weight_demo is
 generic (G_ROUNDS_PER_CYCLE : positive := 3; G_BUFFERING_ENABLE : boolean := true);
end entity;
architecture sim of tb_weight_demo is
 signal clk : std_logic := '0'; signal rst : std_logic := '1';
 signal sw : std_logic_vector(9 downto 0);signal start,done,pass,fail : std_logic;
 signal led : std_logic_vector(12 downto 0);signal idx : std_logic_vector(2 downto 0);
 signal cycles : std_logic_vector(31 downto 0);
begin
 clk<=not clk after 5 ns;
 auto_u : entity work.ascon_demo_autotest port map(clk,rst,'1','1',(others=>'0'),'0',led,sw,start,done,pass,fail,idx,cycles);
 demo_u : entity work.ascon_demo_top generic map(G_ROUNDS_PER_CYCLE=>G_ROUNDS_PER_CYCLE,G_BUFFERING_ENABLE=>G_BUFFERING_ENABLE)
  port map(CLK100MHZ=>clk,SW=>sw,BTNC=>start,BTNU=>rst,LED=>led);
 process begin
 wait for 30 ns;wait until falling_edge(clk);rst<='0';
 wait until done='1' for 1 ms;
 assert done='1' and pass='1' and fail='0' report "DEMO FAIL case=" & integer'image(to_integer(unsigned(idx))) severity failure;
 report "DEMO PASS cases=8 cycles=" & integer'image(to_integer(unsigned(cycles))) severity note;
 finish;
 end process;
end architecture;
