library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all; use std.env.all;
entity tb_multicore_selftest is
  generic(G_CORES:positive:=2; G_INJECT_FAILURE:boolean:=false);
end;
architecture sim of tb_multicore_selftest is
  signal clk,rst,done_s,pass_s,fail_s : std_logic:='0';
  signal case_s:std_logic_vector(3 downto 0);
  signal error_s:std_logic_vector(7 downto 0);
  signal mask:std_logic_vector(9 downto 0);
  signal cycles:std_logic_vector(319 downto 0);
begin
  clk<=not clk after 5 ns;
  dut:entity work.ascon_multicore_selftest generic map(G_CORES=>G_CORES,G_INJECT_FAILURE=>G_INJECT_FAILURE)
    port map(clk,rst,done_s,pass_s,fail_s,case_s,error_s,mask,cycles);
  process begin
    rst<='1'; wait for 40 ns; wait until falling_edge(clk); rst<='0';
    wait until done_s='1' for 5 ms; wait for 1 ns;
    assert done_s='1' report "selftest timeout" severity failure;
    if G_INJECT_FAILURE then
      assert fail_s='1' and pass_s='0' and error_s=x"06" report "checker injection escaped" severity failure;
      report "CHECKER_INJECTION_PASS";
    else
      assert pass_s='1' and fail_s='0' and mask="1111111111"
        report "selftest failure case=" & integer'image(to_integer(unsigned(case_s))) &
          " code=" & integer'image(to_integer(unsigned(error_s))) severity failure;
      for i in 0 to 9 loop
        report "CASE " & integer'image(i) & " CYCLES " &
          integer'image(to_integer(unsigned(cycles(i*32+31 downto i*32))));
      end loop;
      report "BOARD_SELFTEST_SIM_PASS";
    end if;
    stop;
  end process;
end;
