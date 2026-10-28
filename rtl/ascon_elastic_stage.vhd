library ieee;
use ieee.std_logic_1164.all;

-- One elastic register, or a wire. Reset/abort invalidates buffered secrets.
entity ascon_elastic_stage is
  generic (G_WIDTH : positive; G_REGISTER : boolean := false;
    G_REGISTER_READY : boolean := false);
  port (clk_i, rst_i : in std_logic;
    valid_i : in std_logic; ready_o : out std_logic;
    data_i : in std_logic_vector(G_WIDTH-1 downto 0);
    valid_o : out std_logic; ready_i : in std_logic;
    data_o : out std_logic_vector(G_WIDTH-1 downto 0));
end entity;
architecture rtl of ascon_elastic_stage is
  signal v : std_logic := '0';
  signal d : std_logic_vector(G_WIDTH-1 downto 0) := (others => '0');
  signal second : std_logic_vector(G_WIDTH-1 downto 0) := (others => '0');
  signal count : natural range 0 to 2 := 0;
begin
  bypass_g : if not G_REGISTER generate
    ready_o <= ready_i and not rst_i;
    valid_o <= valid_i and not rst_i;
    data_o <= data_i;
  end generate;
  register_g : if G_REGISTER and not G_REGISTER_READY generate
    ready_o <= (not v or ready_i) and not rst_i;
    valid_o <= v and not rst_i;
    data_o <= d;
    process(clk_i) begin
      if rising_edge(clk_i) then
        if rst_i = '1' then v <= '0'; d <= (others => '0');
        elsif v = '0' or ready_i = '1' then
          v <= valid_i;
          if valid_i = '1' then d <= data_i; else d <= (others => '0'); end if;
        end if;
      end if;
    end process;
  end generate;
  registered_ready_g : if G_REGISTER and G_REGISTER_READY generate
    -- Two entries absorb the beat already in flight when backpressure starts.
    -- Ready depends only on occupancy, cutting the cross-core ready chain.
    ready_o <= '1' when count < 2 and rst_i = '0' else '0';
    valid_o <= '1' when count > 0 and rst_i = '0' else '0';
    data_o <= d;
    process(clk_i)
      variable push, pop : boolean;
    begin
      if rising_edge(clk_i) then
        if rst_i = '1' then
          count <= 0; d <= (others=>'0'); second <= (others=>'0');
        else
          push := valid_i = '1' and count < 2;
          pop := ready_i = '1' and count > 0;
          if pop then
            if count = 2 then d <= second; else d <= (others=>'0'); end if;
            second <= (others=>'0');
          end if;
          if push then
            if count = 0 or (count = 1 and pop) then d <= data_i;
            else second <= data_i; end if;
          end if;
          if push and not pop then count <= count+1;
          elsif pop and not push then count <= count-1; end if;
        end if;
      end if;
    end process;
  end generate;
end architecture;
