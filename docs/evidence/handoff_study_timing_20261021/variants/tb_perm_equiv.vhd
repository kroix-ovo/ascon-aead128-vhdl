-- Equivalence check: variant permutation vs committed one, random states, p8/p12.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all; use ieee.math_real.all;
use work.ascon_pkg.all;
entity tb_perm_equiv is generic (G_R : positive := 3; G_N : positive := 400); end entity;
architecture sim of tb_perm_equiv is
  signal clk, rst, start : std_logic := '0';
  signal rounds : unsigned(3 downto 0) := to_unsigned(8,4);
  signal sin, so_a, so_b : state_t := (others => '0');
  signal busy_a, busy_b, done_a, done_b : std_logic;
  signal finished : boolean := false;
begin
  clk <= not clk after 5 ns when not finished;
  a : entity work.ascon_permutation_orig generic map (G_ROUNDS_PER_CYCLE => G_R)
    port map (clk, rst, start, rounds, sin, busy_a, done_a, so_a);
  b : entity work.ascon_permutation generic map (G_ROUNDS_PER_CYCLE => G_R)
    port map (clk, rst, start, rounds, sin, busy_b, done_b, so_b);
  process(clk) begin
    if rising_edge(clk) then
      assert busy_a = busy_b and done_a = done_b report "handshake mismatch" severity failure;
      if done_a = '1' then assert so_a = so_b report "state mismatch" severity failure; end if;
    end if;
  end process;
  process
    variable s1, s2 : positive := 7; variable x : real; variable v : state_t;
  begin
    rst <= '1'; wait until rising_edge(clk); rst <= '0';
    for t in 0 to G_N-1 loop
      for i in v'range loop uniform(s1, s2, x); if x > 0.5 then v(i) := '1'; else v(i) := '0'; end if; end loop;
      sin <= v; if t mod 2 = 0 then rounds <= to_unsigned(8,4); else rounds <= to_unsigned(12,4); end if;
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until rising_edge(clk) and done_a = '1';
    end loop;
    report "EQUIV PASS R=" & integer'image(G_R) & " N=" & integer'image(G_N) severity note;
    finished <= true; wait;
  end process;
end architecture;
