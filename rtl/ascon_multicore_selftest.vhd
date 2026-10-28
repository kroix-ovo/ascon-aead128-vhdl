library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.multicore_board_vectors.all;

-- Bounded 12-layer adapter fixtures. Comparison occurs on each accepted beat.
-- Plaintext observations stay inside this trusted selftest; only status leaves.
entity ascon_multicore_selftest is
  generic(G_CORES : positive := 2; G_INJECT_FAILURE : boolean := false);
  port(clk_i, rst_i : in std_logic;
    done_o, pass_o, fail_o : out std_logic;
    case_o : out std_logic_vector(3 downto 0);
    failure_o : out std_logic_vector(7 downto 0);
    passed_o : out std_logic_vector(9 downto 0);
    cycles_o : out std_logic_vector(319 downto 0));
end entity;

architecture rtl of ascon_multicore_selftest is
  type states_t is (BOOT, RESET_DUT, COMMAND, RUN, NEXT_CASE, FINISHED);
  type counts_t is array(0 to 11) of natural range 0 to 17;
  signal state : states_t := BOOT;
  signal test_case : natural range 0 to 9 := 0;
  signal boot_count : natural range 0 to 255 := 0;
  signal cycles : unsigned(31 downto 0) := (others=>'0');
  signal sent, received : counts_t := (others=>0);
  signal got_tags : std_logic_vector(11 downto 0) := (others=>'0');
  signal completed_chunks : natural range 0 to 12 := 0;
  signal fv, fr, reset_dut_s, dec_s, abort_s, enable_in : std_logic;
  signal sv, sr, sl, st : std_logic_vector(G_CORES-1 downto 0);
  signal sd : std_logic_vector(G_CORES*128-1 downto 0);
  signal sk : std_logic_vector(G_CORES*16-1 downto 0);
  signal si : std_logic_vector(G_CORES*4-1 downto 0);
  signal sp : std_logic_vector(G_CORES*32-1 downto 0);
  signal ov, ready_out, ol, ot, busy, done_s, commit_s, discard_s : std_logic;
  signal od : std_logic_vector(127 downto 0);
  signal ok : std_logic_vector(15 downto 0);
  signal oi : std_logic_vector(3 downto 0);
  signal op : std_logic_vector(31 downto 0);
  signal raw_ov, raw_ol, raw_ot : std_logic;
  signal raw_od : std_logic_vector(127 downto 0);
  signal raw_ok : std_logic_vector(15 downto 0);
  signal raw_oi : std_logic_vector(3 downto 0);
  signal raw_op : std_logic_vector(31 downto 0);
  signal cd : std_logic_vector(G_CORES-1 downto 0);
  signal ci : std_logic_vector(G_CORES*4-1 downto 0);
begin
  case_o <= std_logic_vector(to_unsigned(test_case,4));
  dec_s <= '0' when test_case = 0 or test_case = 2 else '1';
  fv <= '1' when state = COMMAND else '0';
  reset_dut_s <= '1' when rst_i='1' or state=BOOT or state=RESET_DUT or
    (state=RUN and test_case=8 and (cycles=80 or cycles=81)) else '0';
  abort_s <= '1' when state=RUN and test_case=7 and cycles=80 else '0';
  enable_in <= '0' when (test_case=2 or test_case=3) and cycles(3 downto 0)<4 else '1';
  ready_out <= '0' when (test_case=2 or test_case=3) and cycles(4 downto 0)<11 else '1';

  source : process(all)
    variable chunk : natural range 0 to 15;
    variable word_index : natural range 0 to 17;
    variable data : std_logic_vector(127 downto 0);
  begin
    sv <= (others=>'0'); sd <= (others=>'0'); sk <= (others=>'1');
    sl <= (others=>'0'); st <= (others=>'0'); si <= ci; sp <= (others=>'0');
    for lane in 0 to G_CORES-1 loop
      chunk := to_integer(unsigned(ci(lane*4+3 downto lane*4)));
      if chunk<12 then
        word_index := sent(chunk);
        sp(lane*32+31 downto lane*32) <= std_logic_vector(to_unsigned(word_index*16,32));
        if state=RUN and word_index<16 then
          sv(lane) <= '1';
          if dec_s='1' then data := CIPHER(chunk*16+word_index);
          else data := PLAIN(chunk*16+word_index); end if;
          if test_case=5 and chunk=0 and word_index=0 then data(0):=not data(0); end if;
          sd(lane*128+127 downto lane*128) <= data;
          if word_index=15 then sl(lane)<='1'; end if;
          if test_case=6 and chunk=0 and word_index=0 then si(lane*4+3 downto lane*4)<=x"b"; end if;
        elsif state=RUN and word_index=16 and dec_s='1' then
          sv(lane)<='1'; st(lane)<='1'; sl(lane)<='1'; data:=TAGS(chunk);
          if test_case=4 and chunk=11 then data(0):=not data(0); end if;
          sd(lane*128+127 downto lane*128)<=data;
        end if;
      end if;
    end loop;
  end process;

  dut : entity work.ascon_multicore
    generic map(G_CORES=>G_CORES,G_BOUNDARY_REGISTERS=>true,G_LOCAL_CONTROL=>true)
    port map(clk_i=>clk_i,rst_i=>reset_dut_s,file_valid_i=>fv,file_ready_o=>fr,
      decrypt_i=>dec_s,key_i=>TEST_KEY,nonce_base_i=>TEST_NONCE,
      model_id_i=>TEST_MODEL,manifest_id_i=>TEST_MANIFEST,chunk_bytes_i=>x"00000100",
      abort_i=>abort_s,bus_in_enable_i=>enable_in,
      source_valid_i=>sv,source_ready_o=>sr,source_data_i=>sd,source_keep_i=>sk,
      source_last_i=>sl,source_tag_i=>st,source_chunk_i=>si,source_offset_i=>sp,
      out_valid_o=>raw_ov,out_ready_i=>ready_out,out_data_o=>raw_od,out_keep_o=>raw_ok,out_last_o=>raw_ol,
      out_tag_o=>raw_ot,out_chunk_o=>raw_oi,out_offset_o=>raw_op,busy_o=>busy,done_o=>done_s,
      commit_o=>commit_s,discard_o=>discard_s,core_busy_o=>open,chunk_start_o=>open,chunk_done_o=>cd,
      input_starved_o=>open,output_blocked_o=>open,tail_missed_o=>open,
      chunk_id_o=>ci,bus_in_valid_o=>open,bus_in_ready_o=>open,bus_in_payload_o=>open,bus_in_lane_o=>open);

  -- Observation pipeline only: this never changes the DUT output handshake or
  -- its completion timestamps. Break collector -> large ROM comparison paths.
  observe : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if reset_dut_s='1' then ov<='0';
      else
        ov<=raw_ov and ready_out;
        if raw_ov='1' and ready_out='1' then
          od<=raw_od; ok<=raw_ok; ol<=raw_ol; ot<=raw_ot; oi<=raw_oi; op<=raw_op;
        end if;
      end if;
    end if;
  end process;

  check : process(clk_i)
    variable error_code : natural range 0 to 13;
    variable chunk, position : natural range 0 to 15;
    variable count_done : natural range 0 to G_CORES;
    variable wanted : std_logic_vector(127 downto 0);
    variable good_case, reject_case : boolean;
  begin
    if rising_edge(clk_i) then
      if rst_i='1' then
        state<=BOOT; boot_count<=0; test_case<=0; cycles<=(others=>'0');
        sent<=(others=>0); received<=(others=>0); got_tags<=(others=>'0'); completed_chunks<=0;
        done_o<='0'; pass_o<='0'; fail_o<='0'; failure_o<=(others=>'0');
        passed_o<=(others=>'0'); cycles_o<=(others=>'0');
      else
        error_code:=0;
        good_case:=test_case=0 or test_case=1 or test_case=2 or test_case=3 or test_case=9;
        reject_case:=test_case>=4 and test_case<=7;
        case state is
          when BOOT =>
            if boot_count=255 then state<=RESET_DUT; else boot_count<=boot_count+1; end if;
          when RESET_DUT =>
            sent<=(others=>0); received<=(others=>0); got_tags<=(others=>'0'); completed_chunks<=0;
            cycles<=(others=>'0'); state<=COMMAND;
          when COMMAND => if fr='1' then state<=RUN; end if;
          when RUN =>
            cycles<=cycles+1;
            count_done:=0;
            for lane in 0 to G_CORES-1 loop
              if cd(lane)='1' then count_done:=count_done+1; end if;
              if sv(lane)='1' and sr(lane)='1' then
                chunk:=to_integer(unsigned(ci(lane*4+3 downto lane*4)));
                if chunk<12 then sent(chunk)<=sent(chunk)+1; else error_code:=1; end if;
              end if;
            end loop;
            if completed_chunks+count_done<=12 then completed_chunks<=completed_chunks+count_done;
            else error_code:=2; end if;
            if ov='1' then
              chunk:=to_integer(unsigned(oi)); position:=to_integer(unsigned(op(7 downto 4)));
              if chunk>=12 or ok/=x"ffff" then error_code:=3;
              elsif ot='1' then
                if dec_s='1' or got_tags(chunk)='1' or op/=x"00000100" or ol/='1' or
                  od/=TAGS(chunk) then error_code:=4; end if;
                got_tags(chunk)<='1';
              else
                if dec_s='1' then wanted:=PLAIN(chunk*16+position);
                else wanted:=CIPHER(chunk*16+position); end if;
                if G_INJECT_FAILURE then wanted(0):=not wanted(0); end if;
                if received(chunk)>=16 or unsigned(op)/=received(chunk)*16 or
                  (ol='1')/=(position=15) then error_code:=5; end if;
                if test_case/=5 and od/=wanted then error_code:=6; end if;
                if received(chunk)<16 then received(chunk)<=received(chunk)+1; end if;
              end if;
            end if;
            if commit_s='1' then
              if not good_case or done_s/='1' or discard_s='1' or completed_chunks/=12 then error_code:=7; end if;
              for i in 0 to 11 loop
                if received(i)/=16 or (dec_s='0' and got_tags(i)/='1') then error_code:=8; end if;
              end loop;
            end if;
            if done_s='1' then
              if good_case and (commit_s/='1' or discard_s='1') then error_code:=9; end if;
              if reject_case and (discard_s/='1' or commit_s='1') then error_code:=10; end if;
              if test_case=8 then error_code:=11; end if;
              passed_o(test_case)<='1';
              cycles_o(test_case*32+31 downto test_case*32)<=std_logic_vector(cycles);
              state<=NEXT_CASE;
            end if;
            if test_case=8 and cycles=84 then
              if busy/='0' or raw_ov/='0' or ov/='0' or commit_s/='0' then error_code:=12; end if;
              passed_o(test_case)<='1';
              cycles_o(test_case*32+31 downto test_case*32)<=std_logic_vector(cycles);
              state<=NEXT_CASE;
            end if;
            if cycles=100000 then error_code:=13; end if;
          when NEXT_CASE =>
            if test_case=9 then done_o<='1'; pass_o<='1'; state<=FINISHED;
            else test_case<=test_case+1; state<=RESET_DUT; end if;
          when FINISHED => null;
        end case;
        if error_code/=0 then
          failure_o<=std_logic_vector(to_unsigned(error_code,8));
          fail_o<='1'; pass_o<='0'; done_o<='1'; state<=FINISHED;
        end if;
      end if;
    end if;
  end process;
end architecture;
