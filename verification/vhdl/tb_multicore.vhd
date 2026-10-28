library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

entity tb_multicore is
  generic(G_CORES : positive := 2; G_BYTES : positive := 256;
    G_REGISTERS : boolean := false; G_LOCAL_CONTROL : boolean := false;
    G_DECRYPT : boolean := false; G_PROFILE : natural := 0;
    G_FAULT : natural := 0; G_DIR : string := ".");
end entity;
architecture sim of tb_multicore is
  function minimum(a,b : natural) return natural is
  begin if a < b then return a; else return b; end if; end function;
  constant BLOCKS : positive := (G_BYTES+15)/16;
  type memory_t is array(0 to 12*BLOCKS-1) of std_logic_vector(127 downto 0);
  type tags_t is array(0 to 11) of std_logic_vector(127 downto 0);
  type counts_t is array(0 to 11) of natural;
  signal clk, rst, fv, fr, abort_s, enable_in : std_logic := '0';
  signal key, nonce : std_logic_vector(127 downto 0) := (others=>'0');
  signal model_id, manifest_id : std_logic_vector(255 downto 0) := (others=>'0');
  signal dec_s : std_logic := '0';
  signal sv, sr, sl, st : std_logic_vector(G_CORES-1 downto 0) := (others=>'0');
  signal sd : std_logic_vector(G_CORES*128-1 downto 0) := (others=>'0');
  signal sk : std_logic_vector(G_CORES*16-1 downto 0) := (others=>'0');
  signal si : std_logic_vector(G_CORES*4-1 downto 0) := (others=>'0');
  signal sp : std_logic_vector(G_CORES*32-1 downto 0) := (others=>'0');
  signal ov, ready_out, ol, ot, busy, done_s, commit_s, discard_s : std_logic := '0';
  signal od : std_logic_vector(127 downto 0);
  signal ok : std_logic_vector(15 downto 0);
  signal oi : std_logic_vector(3 downto 0);
  signal op : std_logic_vector(31 downto 0);
  signal cb, cs, cd, starvation, blockage, missed : std_logic_vector(G_CORES-1 downto 0);
  signal source_phase, source_capacity, collector_pending, collector_ready : std_logic_vector(G_CORES-1 downto 0);
  signal ci : std_logic_vector(G_CORES*4-1 downto 0);
  signal biv, bir, bip : std_logic;
  signal bil : std_logic_vector(1 downto 0);
begin
  clk <= not clk after 5 ns;
  dut : entity work.ascon_multicore
    generic map(G_CORES=>G_CORES, G_BOUNDARY_REGISTERS=>G_REGISTERS, G_LOCAL_CONTROL=>G_LOCAL_CONTROL)
    port map(clk_i=>clk,rst_i=>rst,file_valid_i=>fv,file_ready_o=>fr,
      decrypt_i=>dec_s,key_i=>key,nonce_base_i=>nonce,model_id_i=>model_id,manifest_id_i=>manifest_id,
      chunk_bytes_i=>std_logic_vector(to_unsigned(G_BYTES,32)), abort_i=>abort_s,bus_in_enable_i=>enable_in,
      source_valid_i=>sv,source_ready_o=>sr,source_data_i=>sd,source_keep_i=>sk,
      source_last_i=>sl,source_tag_i=>st,source_chunk_i=>si,source_offset_i=>sp,
      out_valid_o=>ov,out_ready_i=>ready_out,out_data_o=>od,out_keep_o=>ok,out_last_o=>ol,
      out_tag_o=>ot,out_chunk_o=>oi,out_offset_o=>op,busy_o=>busy,done_o=>done_s,
      commit_o=>commit_s,discard_o=>discard_s,core_busy_o=>cb,chunk_start_o=>cs,chunk_done_o=>cd,
      input_starved_o=>starvation,output_blocked_o=>blockage,tail_missed_o=>missed,
      source_phase_o=>source_phase,source_capacity_o=>source_capacity,
      collector_pending_o=>collector_pending,collector_ready_o=>collector_ready,
      chunk_id_o=>ci,bus_in_valid_o=>biv,bus_in_ready_o=>bir,bus_in_payload_o=>bip,bus_in_lane_o=>bil);

  stimulus : process
    file vectors : text open read_mode is G_DIR & "/vectors.txt";
    file metrics : text open write_mode is G_DIR & "/metrics.txt";
    file recovered : text open write_mode is G_DIR & "/output.txt";
    variable row, line_out : line;
    variable inputs, expected, quarantine : memory_t;
    variable tags : tags_t;
    variable sent, got, starts, ends, busy_cycles, starved_cycles, blocked_cycles, missed_cycles,
      waits, input_stalls, output_stalls, lane_beats, chunk_counts : counts_t := (others=>0);
    variable arb_input, setup_input, bandwidth_input, arb_output, external_output : counts_t := (others=>0);
    variable fair_input, fair_output : counts_t := (others=>0);
    variable sent_tag, got_tag : std_logic_vector(11 downto 0) := (others=>'0');
    variable cycles, first_output, last_input, last_output, bus_input, bus_payload, bus_output,
      bus_output_payload, chunk_number, offset, n, idx, credit, available, reset_count : natural := 0;
    variable source_holds : std_logic_vector(G_CORES-1 downto 0) := (others=>'0');
    variable next_valid, old_valid, old_ready : std_logic_vector(G_CORES-1 downto 0);
    variable output_held : boolean := false;
    variable held_output : std_logic_vector(181 downto 0);
    variable offered_output : std_logic_vector(181 downto 0);
    variable input_held : boolean := false;
    variable held_lane : natural := 0;
    variable rng : unsigned(31 downto 0) := x"8135a77d";
    variable grant_in, grant_out, source_allowed : boolean;
    variable input_accept, output_accept : boolean;
    variable rate_read : std_logic_vector(127 downto 0);
    variable hash_read : std_logic_vector(255 downto 0);
    procedure metric(name : string; value : natural) is
      variable l : line;
    begin write(l,name & " "); write(l,value); writeline(metrics,l); end procedure;
  begin
    readline(vectors,row); hread(row,rate_read); key <= rate_read;
    readline(vectors,row); hread(row,rate_read); nonce <= rate_read;
    readline(vectors,row); hread(row,hash_read); model_id <= hash_read;
    readline(vectors,row); hread(row,hash_read); manifest_id <= hash_read;
    for layer in 0 to 11 loop
      readline(vectors,row); hread(row,tags(layer));
      for block_index in 0 to BLOCKS-1 loop
        readline(vectors,row); hread(row,inputs(layer*BLOCKS+block_index));
        hread(row,expected(layer*BLOCKS+block_index));
      end loop;
    end loop;
    if G_DECRYPT then dec_s <= '1'; end if;
    rst <= '1'; wait until falling_edge(clk); wait until falling_edge(clk);
    rst <= '0'; fv <= '1'; enable_in <= '1'; ready_out <= '1';
    wait until rising_edge(clk); assert fr = '1' severity failure;
    wait until falling_edge(clk); fv <= '0';
    if G_FAULT = 12 then
      assert done_s = '1' and discard_s = '1' and commit_s = '0'
        report "nonce overflow accepted" severity failure;
      metric("discard_pass",1); stop;
    end if;
    loop
      cycles := cycles+1;
      assert cycles < 20_000_000 report "multicore timeout" severity failure;
      rng := rng xor shift_left(rng,13); rng := rng xor shift_right(rng,17); rng := rng xor shift_left(rng,5);
      grant_in := true; grant_out := true; source_allowed := true;
      case G_PROFILE is
        when 1 => source_allowed := cycles mod 8 = 0;
        when 2 => grant_out := cycles mod 8 = 0;
        when 3 => source_allowed := cycles mod 97 > 20; grant_out := cycles mod 113 > 31;
          if rng(3 downto 0) = 0 then source_allowed := false; end if;
          if rng(7 downto 4) = 0 then grant_out := false; end if;
        when 4 | 5 =>
          if G_PROFILE = 4 then credit := minimum(credit+10,32);
          else credit := minimum(credit+13,32); end if;
          -- Shared-memory service grants compete for the SAME byte credits.
          -- Rotate preferred direction; unused reserved slots cost no credits.
          available := credit;
          grant_in := false; grant_out := false;
          if cycles mod 2 = 0 then
            if available >= 16 then grant_in := true; available := available-16; end if;
            if available >= 16 then grant_out := true; end if;
          else
            if available >= 16 then grant_out := true; available := available-16; end if;
            if available >= 16 then grant_in := true; end if;
          end if;
        when others => null;
      end case;
      enable_in <= '0'; if grant_in then enable_in <= '1'; end if;
      ready_out <= '0'; if grant_out then ready_out <= '1'; end if;
      if G_FAULT = 8 and cycles = 80 then abort_s <= '1'; end if;
      if G_FAULT = 9 and cycles = 80 then rst <= '1'; reset_count := 1; end if;
      if G_FAULT = 9 and cycles = 81 then rst <= '0'; end if;
      next_valid := sv and not source_holds; -- source_holds is previous accepted mask
      for lane in 0 to G_CORES-1 loop
        chunk_number := to_integer(unsigned(ci(lane*4+3 downto lane*4)));
        if next_valid(lane) = '0' and chunk_number < 12 then
          offset := sent(chunk_number);
          if offset < G_BYTES and source_allowed and not (G_FAULT = 7 and chunk_number = 11) and
            (G_PROFILE /= 6 or lane /= 0 or cycles mod 31 = 0) then
            next_valid(lane) := '1'; idx := chunk_number*BLOCKS+offset/16;
            sd(lane*128+127 downto lane*128) <= inputs(idx);
            n := minimum(16,G_BYTES-offset);
            sk(lane*16+15 downto lane*16) <= std_logic_vector(to_unsigned(2**n-1,16));
            sl(lane) <= '0'; if offset+n = G_BYTES then sl(lane) <= '1'; end if;
            st(lane) <= '0';
          elsif offset = G_BYTES and G_DECRYPT and sent_tag(chunk_number) = '0' then
            next_valid(lane) := '1'; sd(lane*128+127 downto lane*128) <= tags(chunk_number);
            sk(lane*16+15 downto lane*16) <= x"ffff"; sl(lane) <= '1'; st(lane) <= '1';
          end if;
          if next_valid(lane) = '1' then
            si(lane*4+3 downto lane*4) <= std_logic_vector(to_unsigned(chunk_number,4));
            sp(lane*32+31 downto lane*32) <= std_logic_vector(to_unsigned(offset,32));
            if chunk_number = 0 and offset = 0 then
              if G_FAULT = 3 then si(lane*4+3 downto lane*4) <= x"1"; end if;
              if G_FAULT = 4 then sp(lane*32+31 downto lane*32) <= x"00000010"; end if;
              if G_FAULT = 5 then sk(lane*16+15 downto lane*16) <= x"fffd"; end if;
              if G_FAULT = 16 then sl(lane) <= '1'; end if;
            end if;
            if G_FAULT = 6 and chunk_number = G_CORES and offset = 0 then
              si(lane*4+3 downto lane*4) <= x"0";
            end if;
          end if;
        end if;
      end loop;
      sv <= next_valid;
      if G_FAULT = 7 and cycles = 1000 then abort_s <= '1'; end if;
      wait for 1 ns;
      offered_output := oi & op & ot & ol & ok & od;
      if output_held and rst = '0' and abort_s = '0' then
        assert ov = '1' and offered_output = held_output report "output changed while stalled" severity failure;
      end if;
      output_held := ov = '1' and ready_out = '0'; held_output := offered_output;
      if input_held and rst = '0' and abort_s = '0' then
        assert biv = '1' and to_integer(unsigned(bil)) = held_lane report "input grant changed while stalled" severity failure;
      end if;
      input_held := biv = '1' and bir = '0'; held_lane := to_integer(unsigned(bil));
      input_accept := biv = '1' and bir = '1'; output_accept := ov = '1' and ready_out = '1';
      source_holds := sv and sr;
      for lane in 0 to G_CORES-1 loop
        if sv = (sv'range=>'1') and source_phase = (source_phase'range=>'1') and
          source_capacity = (source_capacity'range=>'1') and enable_in = '1' and sr(lane) = '0' then
          fair_input(lane) := fair_input(lane)+1;
        else fair_input(lane) := 0; end if;
        if collector_pending = (collector_pending'range=>'1') and ready_out = '1' and collector_ready(lane) = '0' then
          fair_output(lane) := fair_output(lane)+1;
        else fair_output(lane) := 0; end if;
        assert fair_input(lane) < G_CORES and fair_output(lane) < G_CORES report "round-robin fairness failure" severity failure;
        chunk_number := to_integer(unsigned(ci(lane*4+3 downto lane*4)));
        if cb(lane) = '1' then busy_cycles(lane) := busy_cycles(lane)+1; end if;
        if starvation(lane) = '1' then starved_cycles(lane) := starved_cycles(lane)+1; end if;
        if blockage(lane) = '1' then blocked_cycles(lane) := blocked_cycles(lane)+1; end if;
        if missed(lane) = '1' then missed_cycles(lane) := missed_cycles(lane)+1; end if;
        if sv(lane) = '1' and sr(lane) = '0' then waits(lane) := waits(lane)+1; end if;
        if sv(lane) = '1' then
          if source_phase(lane) = '0' then setup_input(lane) := setup_input(lane)+1;
          elsif source_capacity(lane) = '0' then input_stalls(lane) := input_stalls(lane)+1;
          elsif enable_in = '0' then bandwidth_input(lane) := bandwidth_input(lane)+1;
          elsif sr(lane) = '0' then arb_input(lane) := arb_input(lane)+1; end if;
        end if;
        if collector_pending(lane) = '1' then
          if ready_out = '0' then external_output(lane) := external_output(lane)+1;
          elsif collector_ready(lane) = '0' then arb_output(lane) := arb_output(lane)+1; end if;
        end if;
        if source_holds(lane) = '1' then
          if st(lane) = '1' then sent_tag(chunk_number) := '1';
          else
            sent(chunk_number) := sent(chunk_number)+minimum(16,G_BYTES-sent(chunk_number));
            lane_beats(lane) := lane_beats(lane)+1; last_input := cycles;
          end if;
        end if;
      end loop;
      if input_accept then
        bus_input := bus_input+1; if bip = '1' then bus_payload := bus_payload+1; end if;
        if G_PROFILE = 4 or G_PROFILE = 5 then credit := credit-16; end if;
      end if;
      if output_accept then
        bus_output := bus_output+1; last_output := cycles;
        chunk_number := to_integer(unsigned(oi)); offset := to_integer(unsigned(op));
        assert chunk_number < 12 severity failure;
        if ot = '1' then
          assert not G_DECRYPT and got_tag(chunk_number) = '0' severity failure;
          assert od = tags(chunk_number) report "tag mismatch" severity failure;
          got_tag(chunk_number) := '1';
        else
          if first_output = 0 then first_output := cycles; end if;
          assert offset = got(chunk_number) report "output offset/order mismatch" severity failure;
          assert offset < G_BYTES severity failure;
          idx := chunk_number*BLOCKS+offset/16; n := minimum(16,G_BYTES-offset);
          -- Faulted decryption can emit corrupted provisional bytes. They are
          -- retained only inside this quarantine and must never be released.
          if G_FAULT /= 1 and G_FAULT /= 2 and G_FAULT /= 10 and G_FAULT /= 11 and G_FAULT /= 13 and G_FAULT /= 14 and G_FAULT /= 15 then
            assert od(n*8-1 downto 0) = expected(idx)(n*8-1 downto 0) report "payload mismatch" severity failure;
          end if;
          assert unsigned(ok) = to_unsigned(2**n-1,16) severity failure;
          assert (ol = '1') = (offset+n = G_BYTES) severity failure;
          quarantine(idx) := od;
          got(chunk_number) := got(chunk_number)+n; bus_output_payload := bus_output_payload+1;
        end if;
        if G_PROFILE = 4 or G_PROFILE = 5 then credit := credit-16; end if;
      end if;
      wait until rising_edge(clk); wait for 1 ns;
      for lane in 0 to G_CORES-1 loop
        chunk_number := to_integer(unsigned(ci(lane*4+3 downto lane*4)));
        if cs(lane) = '1' then assert starts(chunk_number) = 0 severity failure; starts(chunk_number) := cycles; end if;
        if cd(lane) = '1' then ends(chunk_number) := cycles; chunk_counts(lane) := chunk_counts(lane)+1; end if;
      end loop;
      if commit_s = '1' then
        assert done_s = '1' and discard_s = '0' and G_FAULT = 0 report "premature/failed file commit" severity failure;
        for layer in 0 to 11 loop
          assert got(layer) = G_BYTES and ends(layer) > 0 report "commit before all chunks complete" severity failure;
        end loop;
      end if;
      if G_FAULT = 9 and reset_count = 1 and cycles = 85 then
        assert busy = '0' and commit_s = '0' and ov = '0' report "reset failed to flush" severity failure;
        metric("reset_flush_pass",1); stop;
      end if;
      if done_s = '1' then
        if G_FAULT /= 0 then
          assert discard_s = '1' and commit_s = '0' report "failed file released" severity failure;
          metric("discard_pass",1); stop;
        end if;
        assert commit_s = '1' and discard_s = '0' report "valid file failed" severity failure;
        for layer in 0 to 11 loop
          assert sent(layer) = G_BYTES and got(layer) = G_BYTES severity failure;
          if not G_DECRYPT then assert got_tag(layer) = '1' severity failure; end if;
          assert starts(layer) > 0 and ends(layer) > starts(layer) severity failure;
          for block_index in 0 to BLOCKS-1 loop
            hwrite(line_out,quarantine(layer*BLOCKS+block_index)); writeline(recovered,line_out);
          end loop;
          metric("chunk_start_" & integer'image(layer),starts(layer));
          metric("chunk_end_" & integer'image(layer),ends(layer));
        end loop;
        metric("cycles",cycles); metric("first_output",first_output);
        metric("last_input",last_input); metric("last_output",last_output);
        metric("bus_input",bus_input); metric("bus_payload",bus_payload);
        metric("bus_output",bus_output); metric("bus_output_payload",bus_output_payload);
        for lane in 0 to G_CORES-1 loop
          metric("busy_" & integer'image(lane),busy_cycles(lane));
          metric("starved_" & integer'image(lane),starved_cycles(lane));
          metric("blocked_" & integer'image(lane),blocked_cycles(lane));
          metric("missed_tail_" & integer'image(lane),missed_cycles(lane));
          metric("source_wait_" & integer'image(lane),waits(lane));
          metric("input_arbitration_wait_" & integer'image(lane),arb_input(lane));
          metric("input_capacity_wait_" & integer'image(lane),input_stalls(lane));
          metric("input_setup_wait_" & integer'image(lane),setup_input(lane));
          metric("input_bandwidth_wait_" & integer'image(lane),bandwidth_input(lane));
          metric("output_arbitration_wait_" & integer'image(lane),arb_output(lane));
          metric("output_external_wait_" & integer'image(lane),external_output(lane));
          metric("input_beats_" & integer'image(lane),lane_beats(lane));
          metric("chunks_" & integer'image(lane),chunk_counts(lane));
        end loop;
        report "MULTICORE_PASS"; stop;
      end if;
      wait until falling_edge(clk);
    end loop;
  end process;
end architecture;
