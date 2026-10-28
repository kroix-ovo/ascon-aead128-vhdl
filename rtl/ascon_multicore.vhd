library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Twelve independent layer messages. The lane sources are views of a
-- scatter/gather reader; only ONE lane beat crosses the shared input per clock.
-- Output handshakes acknowledge trusted quarantine writes, never public release.
entity ascon_multicore is
  generic (G_CORES : positive := 2;
    G_INPUT_FIFO_DEPTH : positive := 2; G_OUTPUT_FIFO_DEPTH : positive := 2;
    G_BOUNDARY_REGISTERS : boolean := false;
    G_LOCAL_CONTROL : boolean := false);
  port (
    clk_i, rst_i : in std_logic;
    file_valid_i : in std_logic; file_ready_o : out std_logic;
    decrypt_i : in std_logic; key_i, nonce_base_i : in std_logic_vector(127 downto 0);
    model_id_i, manifest_id_i : in std_logic_vector(255 downto 0);
    chunk_bytes_i : in std_logic_vector(31 downto 0);
    abort_i : in std_logic;
    bus_in_enable_i : in std_logic := '1';
    source_valid_i : in std_logic_vector(G_CORES-1 downto 0);
    source_ready_o : out std_logic_vector(G_CORES-1 downto 0);
    source_data_i : in std_logic_vector(G_CORES*128-1 downto 0);
    source_keep_i : in std_logic_vector(G_CORES*16-1 downto 0);
    source_last_i, source_tag_i : in std_logic_vector(G_CORES-1 downto 0);
    source_chunk_i : in std_logic_vector(G_CORES*4-1 downto 0);
    source_offset_i : in std_logic_vector(G_CORES*32-1 downto 0);
    out_valid_o : out std_logic; out_ready_i : in std_logic;
    out_data_o : out std_logic_vector(127 downto 0);
    out_keep_o : out std_logic_vector(15 downto 0);
    out_last_o, out_tag_o : out std_logic;
    out_chunk_o : out std_logic_vector(3 downto 0);
    out_offset_o : out std_logic_vector(31 downto 0);
    busy_o, done_o, commit_o, discard_o : out std_logic;
    core_busy_o, chunk_start_o, chunk_done_o : out std_logic_vector(G_CORES-1 downto 0);
    input_starved_o, output_blocked_o, tail_missed_o : out std_logic_vector(G_CORES-1 downto 0);
    -- Observation-only aliases. Unconnected in the timing harness.
    source_phase_o, source_capacity_o, collector_pending_o, collector_ready_o :
      out std_logic_vector(G_CORES-1 downto 0) := (others=>'0');
    chunk_id_o : out std_logic_vector(G_CORES*4-1 downto 0);
    -- Shared input bus observation includes internally generated AD.
    bus_in_valid_o, bus_in_ready_o, bus_in_payload_o : out std_logic;
    bus_in_lane_o : out std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of ascon_multicore is
  constant RX_W : positive := 147; -- tag, kind, last, keep, data
  constant TX_W : positive := 182; -- chunk, offset, tag, last, keep, data
  type rx_array is array(natural range <>) of std_logic_vector(RX_W-1 downto 0);
  type tx_array is array(natural range <>) of std_logic_vector(TX_W-1 downto 0);
  type rate_array is array(natural range <>) of std_logic_vector(127 downto 0);
  type keep_array is array(natural range <>) of std_logic_vector(15 downto 0);
  type count_array is array(natural range <>) of unsigned(31 downto 0);
  type int_array is array(natural range <>) of natural range 0 to 15;
  type ad_array is array(natural range <>) of natural range 0 to 6;
  type lane_state is (L_PREP, L_START, L_RUN, L_DRAIN, L_FINISHED);
  type state_array is array(natural range <>) of lane_state;
  signal state : state_array(0 to G_CORES-1) := (others => L_FINISHED);
  signal chunk : int_array(0 to G_CORES-1) := (others => 0);
  signal ad_index : ad_array(0 to G_CORES-1) := (others => 0);
  signal received, produced : count_array(0 to G_CORES-1) := (others => (others => '0'));
  signal tag_received : std_logic_vector(G_CORES-1 downto 0) := (others => '0');
  signal active, kill, dec_reg : std_logic := '0';
  signal key_reg, nonce_base : std_logic_vector(127 downto 0) := (others => '0');
  signal model_id, manifest_id : std_logic_vector(255 downto 0) := (others => '0');
  signal length_reg : unsigned(31 downto 0) := (others => '0');
  signal last_offset : unsigned(31 downto 0) := (others=>'0');
  signal last_keep : std_logic_vector(15 downto 0) := (others=>'0');
  signal malformed_lane : std_logic_vector(G_CORES-1 downto 0);
  signal lane_key, lane_nonce : rate_array(0 to G_CORES-1);
  signal lane_dec : std_logic_vector(G_CORES-1 downto 0);
  signal reset_core : std_logic;
  signal rx_in, rx_out : rx_array(0 to G_CORES-1);
  signal tx_in, tx_out : tx_array(0 to G_CORES-1);
  signal rv, rr, cv, cr, ov, ory, tv, tr : std_logic_vector(G_CORES-1 downto 0);
  signal c_cmd, c_ready, c_in_ready, c_tag_ready : std_logic_vector(G_CORES-1 downto 0);
  signal c_valid, c_last, c_tag_valid, c_done, c_commit, c_discard, c_error : std_logic_vector(G_CORES-1 downto 0);
  signal c_data, c_tag : rate_array(0 to G_CORES-1);
  signal c_keep : keep_array(0 to G_CORES-1);
  signal input_rr, output_rr : natural range 0 to G_CORES-1 := 0;
  signal isel, osel : natural range 0 to G_CORES-1 := 0;
  signal input_lock, output_lock, input_any, output_any : std_logic := '0';
  signal input_hold, output_hold : natural range 0 to G_CORES-1 := 0;
  signal bad_input : std_logic;
  signal out_take : std_logic_vector(G_CORES-1 downto 0);

  function ad_word(index, layer : natural; size : unsigned(31 downto 0);
    model_hash, manifest_hash : std_logic_vector(255 downto 0);
    base : std_logic_vector(127 downto 0)) return std_logic_vector is
  begin
    case index is
      when 0 => return std_logic_vector(size) & x"0000000c" &
                       std_logic_vector(to_unsigned(layer,32)) & x"00000001";
      when 1 => return model_hash(127 downto 0);
      when 2 => return model_hash(255 downto 128);
      when 3 => return manifest_hash(127 downto 0);
      when 4 => return manifest_hash(255 downto 128);
      when others => return base;
    end case;
  end function;
  function byte_count(k : std_logic_vector(15 downto 0)) return natural is
    variable n : natural := 0;
  begin
    for i in 0 to 15 loop if k(i) = '1' then n := n+1; end if; end loop;
    return n;
  end function;
  function final_offset(size : unsigned(31 downto 0)) return unsigned is
    variable value : unsigned(31 downto 0);
  begin
    value := size-1; value(3 downto 0) := (others=>'0'); return value;
  end function;
  function final_keep(size : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable value : std_logic_vector(15 downto 0) := (others=>'0');
    variable n : natural range 0 to 15;
  begin
    n := to_integer(unsigned(size(3 downto 0)));
    for b in 0 to 15 loop if n = 0 or b < n then value(b) := '1'; end if; end loop;
    return value;
  end function;
begin
  assert G_CORES = 1 or G_CORES = 2 or G_CORES = 4 severity failure;
  reset_core <= rst_i or kill;
  busy_o <= active;
  file_ready_o <= not active and not kill and not rst_i;

  lanes : for i in 0 to G_CORES-1 generate
    -- All candidate checks run in parallel, before the grant mux. Final-beat
    -- geometry was registered at file-command acceptance, so no subtract/mask
    -- chain follows a core's ready signal through the shared arbiter.
    validate_candidate : process(all)
      variable bad, is_final : boolean;
      variable expected_keep : std_logic_vector(15 downto 0);
    begin
      bad := false;
      is_final := received(i) = last_offset;
      expected_keep := x"ffff";
      if is_final then expected_keep := last_keep; end if;
      if ad_index(i) = 6 then
        if source_chunk_i(i*4+3 downto i*4) /= std_logic_vector(to_unsigned(chunk(i),4)) or
           unsigned(source_offset_i(i*32+31 downto i*32)) /= received(i) then bad := true; end if;
        if source_tag_i(i) = '1' then
          if dec_reg = '0' or received(i) /= length_reg or tag_received(i) = '1' or
            source_keep_i(i*16+15 downto i*16) /= x"ffff" or source_last_i(i) /= '1' then bad := true; end if;
        elsif received(i) >= length_reg or source_keep_i(i*16+15 downto i*16) /= expected_keep or
          (source_last_i(i) = '1') /= is_final then bad := true;
        end if;
      end if;
      malformed_lane(i) <= '0'; if bad then malformed_lane(i) <= '1'; end if;
    end process;
    source_phase_o(i) <= '1' when state(i) = L_RUN and ad_index(i) = 6 else '0';
    source_capacity_o(i) <= rr(i);
    collector_pending_o(i) <= ov(i);
    collector_ready_o(i) <= out_take(i);
    -- Candidate data is independent of arbitration. In bypass mode readiness
    -- depends on whether this lane offers a payload or a tag, so zeroing
    -- unselected packets would create a ready/selection combinational loop.
    rx_in(i) <= '0' & '0' & '1' & x"ffff" &
      ad_word(ad_index(i),chunk(i),length_reg,model_id,manifest_id,nonce_base) when ad_index(i) = 5 else
      '0' & '0' & '0' & x"ffff" &
      ad_word(ad_index(i),chunk(i),length_reg,model_id,manifest_id,nonce_base) when ad_index(i) < 6 else
      source_tag_i(i) & '1' & source_last_i(i) & source_keep_i(i*16+15 downto i*16) &
      source_data_i(i*128+127 downto i*128);
    chunk_id_o(i*4+3 downto i*4) <= std_logic_vector(to_unsigned(chunk(i),4));
    c_cmd(i) <= '1' when active = '1' and state(i) = L_START else '0';
    direct_control : if not G_LOCAL_CONTROL generate
      lane_key(i) <= key_reg; lane_dec(i) <= dec_reg;
      lane_nonce(i) <= std_logic_vector(unsigned(nonce_base)+chunk(i));
    end generate;
    local_control : if G_LOCAL_CONTROL generate
      signal local_key, local_nonce : std_logic_vector(127 downto 0) := (others=>'0');
      signal local_dec : std_logic := '0';
      -- Keep these physically local when the high-fanout mitigation is enabled.
      attribute dont_touch : string;
      attribute dont_touch of local_key : signal is "true";
      attribute dont_touch of local_nonce : signal is "true";
      attribute dont_touch of local_dec : signal is "true";
    begin
      lane_key(i) <= local_key; lane_nonce(i) <= local_nonce; lane_dec(i) <= local_dec;
      process(clk_i) begin
        if rising_edge(clk_i) then
          if reset_core = '1' then
            local_key <= (others => '0'); local_nonce <= (others => '0'); local_dec <= '0';
          elsif state(i) /= L_RUN then
            local_key <= key_reg; local_dec <= dec_reg;
            local_nonce <= std_logic_vector(unsigned(nonce_base)+chunk(i));
          end if;
        end if;
      end process;
    end generate;
    rx_boundary : entity work.ascon_elastic_stage
      generic map(RX_W, G_BOUNDARY_REGISTERS, true)
      port map(clk_i, reset_core, rv(i), rr(i), rx_in(i), cv(i), cr(i), rx_out(i));
    cr(i) <= c_tag_ready(i) when rx_out(i)(146) = '1' else c_in_ready(i);
    core : entity work.ascon_aead128_fold
      generic map(G_INPUT_FIFO_DEPTH, G_OUTPUT_FIFO_DEPTH)
      port map(clk_i=>clk_i, rst_i=>reset_core,
        cmd_valid_i=>c_cmd(i), cmd_ready_o=>c_ready(i), cmd_decrypt_i=>lane_dec(i),
        key_i=>lane_key(i), nonce_i=>lane_nonce(i),
        in_valid_i=>cv(i) and not rx_out(i)(146), in_ready_o=>c_in_ready(i),
        in_kind_i=>rx_out(i)(145), in_last_i=>rx_out(i)(144),
        in_keep_i=>rx_out(i)(143 downto 128), in_data_i=>rx_out(i)(127 downto 0),
        tag_in_valid_i=>cv(i) and rx_out(i)(146), tag_in_ready_o=>c_tag_ready(i),
        tag_in_i=>rx_out(i)(127 downto 0), out_valid_o=>c_valid(i), out_ready_i=>ory(i),
        out_data_o=>c_data(i), out_keep_o=>c_keep(i), out_last_o=>c_last(i),
        tag_out_valid_o=>c_tag_valid(i), tag_out_ready_i=>tr(i), tag_out_o=>c_tag(i),
        busy_o=>core_busy_o(i), done_o=>c_done(i), auth_valid_o=>open, auth_ok_o=>open,
        commit_o=>c_commit(i), discard_o=>c_discard(i), error_o=>c_error(i),
        input_starved_o=>input_starved_o(i), output_blocked_o=>output_blocked_o(i), tail_missed_o=>tail_missed_o(i));
    tv(i) <= c_valid(i) or c_tag_valid(i);
    tx_in(i) <= std_logic_vector(to_unsigned(chunk(i),4)) & std_logic_vector(produced(i)) &
      '0' & c_last(i) & c_keep(i) & c_data(i) when c_valid(i) = '1' else
      std_logic_vector(to_unsigned(chunk(i),4)) & std_logic_vector(length_reg) &
      '1' & '1' & x"ffff" & c_tag(i);
    ory(i) <= tr(i) when c_valid(i) = '1' else '0';
    tx_boundary : entity work.ascon_elastic_stage
      generic map(TX_W, G_BOUNDARY_REGISTERS, true)
      port map(clk_i, reset_core, tv(i), tr(i), tx_in(i), ov(i), out_take(i), tx_out(i));
  end generate;

  -- Choose eligible lanes before blocked lanes. A stalled selection is locked
  -- until acceptance, so ready changes can never change a presented beat.
  input_select : process(all)
    variable pick : natural range 0 to G_CORES-1;
    variable found : boolean;
    variable eligible : boolean;
  begin
    pick := input_rr; found := false;
    if input_lock = '1' then pick := input_hold; found := true;
    else
      for pass in 0 to 1 loop
        for step in 0 to G_CORES-1 loop
          eligible := state((input_rr+step) mod G_CORES) = L_RUN and
            (ad_index((input_rr+step) mod G_CORES) < 6 or source_valid_i((input_rr+step) mod G_CORES) = '1');
          if not found and eligible and (pass = 1 or rr((input_rr+step) mod G_CORES) = '1') then
            pick := (input_rr+step) mod G_CORES; found := true;
          end if;
        end loop;
      end loop;
    end if;
    isel <= pick; input_any <= '0';
    if found and active = '1' and reset_core = '0' then input_any <= '1'; end if;
  end process;

  dispatch : process(all) begin
    rv <= (others=>'0'); source_ready_o <= (others=>'0');
    bad_input <= '0';
    if ad_index(isel) = 6 then
      if input_any = '1' then source_ready_o(isel) <= rr(isel) and bus_in_enable_i; end if;
    end if;
    if input_any = '1' then
      rv(isel) <= bus_in_enable_i;
      if malformed_lane(isel) = '1' and rr(isel) = '1' and bus_in_enable_i = '1' then
        bad_input <= '1'; rv(isel) <= '0';
      end if;
    end if;
    bus_in_payload_o <= '1' when ad_index(isel) = 6 and source_tag_i(isel) = '0' else '0';
  end process;
  bus_in_valid_o <= input_any;
  bus_in_ready_o <= rr(isel) and bus_in_enable_i and not reset_core;
  bus_in_lane_o <= std_logic_vector(to_unsigned(isel,2));

  collect : process(all)
    variable pick : natural range 0 to G_CORES-1;
    variable found : boolean;
  begin
    pick := output_rr; found := false;
    if output_lock = '1' then pick := output_hold; found := true;
    else
      for step in 0 to G_CORES-1 loop
        if not found and ov((output_rr+step) mod G_CORES) = '1' then
          pick := (output_rr+step) mod G_CORES; found := true;
        end if;
      end loop;
    end if;
    osel <= pick; output_any <= '0'; out_take <= (others=>'0');
    if found and active = '1' and reset_core = '0' then
      output_any <= '1'; out_take(pick) <= out_ready_i;
    end if;
  end process;
  out_valid_o <= output_any;
  out_data_o <= tx_out(osel)(127 downto 0);
  out_keep_o <= tx_out(osel)(143 downto 128);
  out_last_o <= tx_out(osel)(144);
  out_tag_o <= tx_out(osel)(145);
  out_offset_o <= tx_out(osel)(177 downto 146);
  out_chunk_o <= tx_out(osel)(181 downto 178);

  control : process(clk_i)
    variable failed, finished : boolean;
  begin
    if rising_edge(clk_i) then
      done_o <= '0'; commit_o <= '0'; discard_o <= '0';
      chunk_start_o <= (others=>'0'); chunk_done_o <= (others=>'0');
      kill <= '0';
      if rst_i = '1' then
        active <= '0'; state <= (others=>L_FINISHED);
        input_lock <= '0'; output_lock <= '0'; input_rr <= 0; output_rr <= 0;
        received <= (others=>(others=>'0')); produced <= (others=>(others=>'0'));
        tag_received <= (others=>'0'); ad_index <= (others=>0);
        key_reg <= (others=>'0'); nonce_base <= (others=>'0'); dec_reg <= '0';
        model_id <= (others=>'0'); manifest_id <= (others=>'0'); length_reg <= (others=>'0');
        last_offset <= (others=>'0'); last_keep <= (others=>'0');
      elsif file_valid_i = '1' and file_ready_o = '1' then
        if unsigned(nonce_base_i) > unsigned'(x"fffffffffffffffffffffffffffffff4") or
          unsigned(chunk_bytes_i) = 0 then
          done_o <= '1'; discard_o <= '1';
        else
          active <= '1'; key_reg <= key_i; nonce_base <= nonce_base_i;
          dec_reg <= decrypt_i; model_id <= model_id_i; manifest_id <= manifest_id_i;
          length_reg <= unsigned(chunk_bytes_i);
          last_offset <= final_offset(unsigned(chunk_bytes_i)); last_keep <= final_keep(chunk_bytes_i);
          for i in 0 to G_CORES-1 loop chunk(i) <= i; state(i) <= L_PREP; end loop;
          ad_index <= (others=>0); received <= (others=>(others=>'0'));
          produced <= (others=>(others=>'0')); tag_received <= (others=>'0');
          input_rr <= 0; output_rr <= 0; input_lock <= '0'; output_lock <= '0';
        end if;
      elsif active = '1' then
        failed := abort_i = '1' or bad_input = '1'; finished := true;
        for i in 0 to G_CORES-1 loop
          if c_discard(i) = '1' or c_error(i) = '1' then failed := true; end if;
          if state(i) /= L_FINISHED then finished := false; end if;
          case state(i) is
            when L_PREP => state(i) <= L_START;
            when L_START =>
              if c_ready(i) = '1' then state(i) <= L_RUN; chunk_start_o(i) <= '1'; end if;
            when L_RUN =>
              if c_commit(i) = '1' or (dec_reg = '0' and c_done(i) = '1') then
                state(i) <= L_DRAIN; chunk_done_o(i) <= '1';
              end if;
            when L_DRAIN =>
              if ov(i) = '0' and tv(i) = '0' and core_busy_o(i) = '0' then
                if chunk(i)+G_CORES < 12 then
                  chunk(i) <= chunk(i)+G_CORES; state(i) <= L_PREP;
                  ad_index(i) <= 0; received(i) <= (others=>'0'); produced(i) <= (others=>'0');
                  tag_received(i) <= '0';
                else state(i) <= L_FINISHED; end if;
              end if;
            when others => null;
          end case;
          if c_valid(i) = '1' and ory(i) = '1' then
            if c_last(i) = '1' then produced(i) <= length_reg;
            else produced(i) <= produced(i)+16; end if;
          end if;
        end loop;
        if input_any = '1' then
          if rr(isel) = '1' and bus_in_enable_i = '1' then
            input_lock <= '0'; input_rr <= (isel+1) mod G_CORES;
            if ad_index(isel) < 6 then ad_index(isel) <= ad_index(isel)+1;
            elsif source_tag_i(isel) = '1' then tag_received(isel) <= '1';
            elsif source_last_i(isel) = '1' then received(isel) <= length_reg;
            else received(isel) <= received(isel)+16; end if;
          else input_lock <= '1'; input_hold <= isel; end if;
        end if;
        if output_any = '1' then
          if out_ready_i = '1' then output_lock <= '0'; output_rr <= (osel+1) mod G_CORES;
          else output_lock <= '1'; output_hold <= osel; end if;
        end if;
        if failed or finished then
          active <= '0'; done_o <= '1'; kill <= '1';
          input_lock <= '0'; output_lock <= '0'; state <= (others=>L_FINISHED);
          key_reg <= (others=>'0'); nonce_base <= (others=>'0');
          if failed then discard_o <= '1'; else commit_o <= '1'; end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
