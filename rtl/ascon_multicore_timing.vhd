library ieee;
use ieee.std_logic_1164.all;

-- Registered integration boundary for OOC implementation. The packed ports
-- retain the full datapath and all control; no constant test data is synthesized.
entity ascon_multicore_timing is
  generic(G_CORES : positive := 2; G_BOUNDARY_REGISTERS : boolean := false;
    G_LOCAL_CONTROL : boolean := false);
  port(clk_i, rst_i, abort_i, bus_enable_i : in std_logic;
    file_valid_i : in std_logic; file_ready_o : out std_logic;
    file_data_i : in std_logic_vector(800 downto 0);
    source_valid_i : in std_logic_vector(G_CORES-1 downto 0);
    source_ready_o : out std_logic_vector(G_CORES-1 downto 0);
    source_data_i : in std_logic_vector(G_CORES*182-1 downto 0);
    out_valid_o : out std_logic; out_ready_i : in std_logic;
    out_data_o : out std_logic_vector(181 downto 0);
    status_o : out std_logic_vector(127 downto 0));
end entity;
architecture rtl of ascon_multicore_timing is
  signal file_data : std_logic_vector(800 downto 0);
  signal fv, fr : std_logic;
  signal sv, sr, sl, st : std_logic_vector(G_CORES-1 downto 0);
  signal sd : std_logic_vector(G_CORES*128-1 downto 0);
  signal sk : std_logic_vector(G_CORES*16-1 downto 0);
  signal si : std_logic_vector(G_CORES*4-1 downto 0);
  signal sp : std_logic_vector(G_CORES*32-1 downto 0);
  signal raw_out : std_logic_vector(181 downto 0);
  signal ov, ready_out : std_logic;
  signal status : std_logic_vector(127 downto 0) := (others=>'0');
  signal abort_reg, enable_reg : std_logic := '0';
begin
  file_boundary : entity work.ascon_elastic_stage generic map(801,true)
    port map(clk_i,rst_i,file_valid_i,file_ready_o,file_data_i,fv,fr,file_data);
  lane_boundary : for i in 0 to G_CORES-1 generate
    signal beat : std_logic_vector(181 downto 0);
  begin
    stage : entity work.ascon_elastic_stage generic map(182,true)
      port map(clk_i,rst_i,source_valid_i(i),source_ready_o(i),
        source_data_i(i*182+181 downto i*182),sv(i),sr(i),beat);
    sd(i*128+127 downto i*128) <= beat(127 downto 0);
    sk(i*16+15 downto i*16) <= beat(143 downto 128);
    sl(i) <= beat(144); st(i) <= beat(145);
    sp(i*32+31 downto i*32) <= beat(177 downto 146);
    si(i*4+3 downto i*4) <= beat(181 downto 178);
  end generate;
  multicore : entity work.ascon_multicore
    generic map(G_CORES=>G_CORES,G_BOUNDARY_REGISTERS=>G_BOUNDARY_REGISTERS,G_LOCAL_CONTROL=>G_LOCAL_CONTROL)
    port map(clk_i=>clk_i,rst_i=>rst_i,file_valid_i=>fv,file_ready_o=>fr,
      key_i=>file_data(127 downto 0),nonce_base_i=>file_data(255 downto 128),
      model_id_i=>file_data(511 downto 256),manifest_id_i=>file_data(767 downto 512),
      chunk_bytes_i=>file_data(799 downto 768),decrypt_i=>file_data(800),abort_i=>abort_reg,
      bus_in_enable_i=>enable_reg,source_valid_i=>sv,source_ready_o=>sr,
      source_data_i=>sd,source_keep_i=>sk,source_last_i=>sl,source_tag_i=>st,
      source_chunk_i=>si,source_offset_i=>sp,out_valid_o=>ov,out_ready_i=>ready_out,
      out_data_o=>raw_out(127 downto 0),out_keep_o=>raw_out(143 downto 128),
      out_last_o=>raw_out(144),out_tag_o=>raw_out(145),out_offset_o=>raw_out(177 downto 146),
      out_chunk_o=>raw_out(181 downto 178),busy_o=>status(0),done_o=>status(1),
      commit_o=>status(2),discard_o=>status(3),core_busy_o=>status(4+G_CORES-1 downto 4),
      chunk_start_o=>status(8+G_CORES-1 downto 8),chunk_done_o=>status(12+G_CORES-1 downto 12),
      input_starved_o=>status(16+G_CORES-1 downto 16),output_blocked_o=>status(20+G_CORES-1 downto 20),
      tail_missed_o=>status(24+G_CORES-1 downto 24),chunk_id_o=>status(28+G_CORES*4-1 downto 28),
      bus_in_valid_o=>status(44),bus_in_ready_o=>status(45),bus_in_payload_o=>status(46),
      bus_in_lane_o=>status(48 downto 47));
  output_boundary : entity work.ascon_elastic_stage generic map(182,true)
    port map(clk_i,rst_i,ov,ready_out,raw_out,out_valid_o,out_ready_i,out_data_o);
  process(clk_i) begin
    if rising_edge(clk_i) then
      if rst_i = '1' then status_o <= (others=>'0'); abort_reg <= '0'; enable_reg <= '0';
      else status_o <= status; abort_reg <= abort_i; enable_reg <= bus_enable_i; end if;
    end if;
  end process;
end architecture;
