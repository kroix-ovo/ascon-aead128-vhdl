-- SPDX-License-Identifier: UNLICENSED
--
-- Nexys A7 demonstration wrapper for the Ascon-AEAD128 core.
--
-- Four official known-answer tests are stored as constants.  The switches
-- choose a test, encryption or decryption, and the byte to display.  This is
-- a demonstration interface rather than a general data-loading interface;
-- the reusable streaming interface remains in ascon_aead128_core.vhd.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ascon_demo_top is
  port (
    CLK100MHZ : in  std_logic;
    SW        : in  std_logic_vector(9 downto 0);
    BTNC      : in  std_logic;
    BTNU      : in  std_logic;
    LED       : out std_logic_vector(12 downto 0)
  );
end entity;

architecture rtl of ascon_demo_top is
  subtype block_t is std_logic_vector(127 downto 0);
  type demo_state_t is (
    UI_IDLE, UI_COMMAND, UI_AD0, UI_AD1, UI_MSG0, UI_MSG1,
    UI_WAIT_PAYLOAD, UI_TAG_IN, UI_TAG_OUT, UI_FINISH
  );

  constant KEY_C   : block_t := x"0F0E0D0C0B0A09080706050403020100";
  constant NONCE_C : block_t := x"1F1E1D1C1B1A19181716151413121110";

  signal ui_state       : demo_state_t := UI_IDLE;
  signal vector_reg     : unsigned(1 downto 0) := (others => '0');
  signal decrypt_reg    : std_logic := '0';
  signal start_meta     : std_logic := '0';
  signal start_sync     : std_logic := '0';
  signal start_previous : std_logic := '0';

  signal cmd_valid      : std_logic := '0';
  signal cmd_ready      : std_logic;
  signal in_valid       : std_logic := '0';
  signal in_ready       : std_logic;
  signal in_kind        : std_logic := '0';
  signal in_data        : block_t := (others => '0');
  signal in_keep        : std_logic_vector(15 downto 0) := (others => '0');
  signal in_last        : std_logic := '0';
  signal tag_in_valid   : std_logic := '0';
  signal tag_in_ready   : std_logic;
  signal tag_in         : block_t := (others => '0');
  signal out_valid      : std_logic;
  signal out_data       : block_t;
  signal out_keep       : std_logic_vector(15 downto 0);
  signal out_last       : std_logic;
  signal tag_out_valid  : std_logic;
  signal tag_out        : block_t;
  signal core_busy      : std_logic;
  signal core_done      : std_logic;
  signal auth_valid     : std_logic;
  signal auth_ok        : std_logic;
  signal commit         : std_logic;
  signal discard        : std_logic;
  signal core_error     : std_logic;

  signal result_block0  : block_t := (others => '0');
  signal result_block1  : block_t := (others => '0');
  signal result_tag     : block_t := (others => '0');
  signal result_count   : natural range 0 to 2 := 0;
  signal payload_match  : std_logic := '1';
  signal done_latched   : std_logic := '0';
  signal pass_latched   : std_logic := '0';
  signal fail_latched   : std_logic := '0';
  signal error_latched  : std_logic := '0';

  function ad_block(index : unsigned(1 downto 0); second : boolean) return block_t is
  begin
    case to_integer(index) is
      when 0 => return (others => '0');
      when 1 => return x"00000000000000000000000000000030";
      when 2 => return x"3F3E3D3C3B3A39383736353433323130";
      when others =>
        if second then return x"00000000000000000000000000000040";
        else return x"3F3E3D3C3B3A39383736353433323130"; end if;
    end case;
  end function;

  function plain_block(index : unsigned(1 downto 0); second : boolean) return block_t is
  begin
    case to_integer(index) is
      when 0 => return (others => '0');
      when 1 => return x"00000000000000000000000000000020";
      when 2 => return x"2F2E2D2C2B2A29282726252423222120";
      when others =>
        if second then return x"00000000000000000000000000000030";
        else return x"2F2E2D2C2B2A29282726252423222120"; end if;
    end case;
  end function;

  function cipher_block(index : unsigned(1 downto 0); second : boolean) return block_t is
  begin
    case to_integer(index) is
      when 0 => return (others => '0');
      when 1 => return x"00000000000000000000000000000096";
      when 2 => return x"F13EC199F30C09AC9B7CE98BB2EB7363";
      when others =>
        if second then return x"000000000000000000000000000000E9";
        else return x"9BE8083A27EF72B3C5F1E93D1BC777BF"; end if;
    end case;
  end function;

  function expected_tag(index : unsigned(1 downto 0)) return block_t is
  begin
    case to_integer(index) is
      when 0 => return x"C62E8BEE468FF66B31C9BE1182279C4F";
      when 1 => return x"86D845A28C586668D8A7756C8316802B";
      when 2 => return x"592CF3134D81904C84F4E809D2C0BF3A";
      when others => return x"35660D97F791E71179E9AEC2B3D707D5";
    end case;
  end function;

  function phase_keep(index : unsigned(1 downto 0); second : boolean)
    return std_logic_vector is
  begin
    case to_integer(index) is
      when 0 => return x"0000";
      when 1 => return x"0001";
      when 2 => return x"FFFF";
      when others =>
        if second then return x"0001"; else return x"FFFF"; end if;
    end case;
  end function;
begin
  core_u : entity work.ascon_aead128_core
    port map (
      clk_i => CLK100MHZ, rst_i => BTNU,
      cmd_valid_i => cmd_valid, cmd_ready_o => cmd_ready,
      cmd_decrypt_i => decrypt_reg, key_i => KEY_C, nonce_i => NONCE_C,
      in_valid_i => in_valid, in_ready_o => in_ready, in_kind_i => in_kind,
      in_data_i => in_data, in_keep_i => in_keep, in_last_i => in_last,
      tag_in_valid_i => tag_in_valid, tag_in_ready_o => tag_in_ready,
      tag_in_i => tag_in,
      out_valid_o => out_valid, out_ready_i => '1', out_data_o => out_data,
      out_keep_o => out_keep, out_last_o => out_last,
      tag_out_valid_o => tag_out_valid, tag_out_ready_i => '1',
      tag_out_o => tag_out,
      busy_o => core_busy, done_o => core_done, auth_valid_o => auth_valid,
      auth_ok_o => auth_ok, commit_o => commit, discard_o => discard,
      error_o => core_error
    );

  -- The center button passes through two flip-flops before edge detection.
  -- This protects the controller from metastability.  The wrapper accepts one
  -- start edge; a mechanical bounce after the controller leaves idle has no
  -- effect on the active transaction.
  process (CLK100MHZ)
  begin
    if rising_edge(CLK100MHZ) then
      if BTNU = '1' then
        start_meta <= '0';
        start_sync <= '0';
        start_previous <= '0';
      else
        start_meta <= BTNC;
        start_sync <= start_meta;
        start_previous <= start_sync;
      end if;
    end if;
  end process;

  -- This small controller converts a selected constant vector into the same
  -- ready/valid transactions that a processor or DMA engine would send.
  process (CLK100MHZ)
    variable is_second : boolean;
  begin
    if rising_edge(CLK100MHZ) then
      cmd_valid    <= '0';
      in_valid     <= '0';
      tag_in_valid <= '0';

      if BTNU = '1' then
        ui_state      <= UI_IDLE;
        vector_reg    <= (others => '0');
        decrypt_reg   <= '0';
        result_block0 <= (others => '0');
        result_block1 <= (others => '0');
        result_tag    <= (others => '0');
        result_count  <= 0;
        payload_match <= '1';
        done_latched  <= '0';
        pass_latched  <= '0';
        fail_latched  <= '0';
        error_latched <= '0';
      else
        if out_valid = '1' then
          if result_count = 0 then result_block0 <= out_data;
          elsif result_count = 1 then result_block1 <= out_data; end if;
          is_second := result_count = 1;
          if (decrypt_reg = '0' and out_data /= cipher_block(vector_reg, is_second)) or
             (decrypt_reg = '1' and out_data /= plain_block(vector_reg, is_second)) then
            payload_match <= '0';
          end if;
          if result_count < 2 then result_count <= result_count + 1; end if;
        end if;
        if tag_out_valid = '1' then result_tag <= tag_out; end if;
        if auth_valid = '1' then
          pass_latched <= auth_ok and payload_match;
          fail_latched <= not (auth_ok and payload_match);
        end if;
        if core_error = '1' then error_latched <= '1'; end if;

        case ui_state is
          when UI_IDLE =>
            if start_sync = '1' and start_previous = '0' then
              vector_reg    <= unsigned(SW(1 downto 0));
              decrypt_reg   <= SW(2);
              result_block0 <= (others => '0');
              result_block1 <= (others => '0');
              result_tag    <= (others => '0');
              result_count  <= 0;
              payload_match <= '1';
              done_latched  <= '0';
              pass_latched  <= '0';
              fail_latched  <= '0';
              error_latched <= '0';
              ui_state      <= UI_COMMAND;
            end if;

          when UI_COMMAND =>
            if cmd_ready = '1' then
              cmd_valid <= '1';
              ui_state <= UI_AD0;
            end if;

          when UI_AD0 | UI_AD1 =>
            if in_ready = '1' then
              is_second := ui_state = UI_AD1;
              in_kind  <= '0';
              in_data  <= ad_block(vector_reg, is_second);
              in_keep  <= phase_keep(vector_reg, is_second);
              if vector_reg = 3 and not is_second then in_last <= '0';
              else in_last <= '1'; end if;
              in_valid <= '1';
              if vector_reg = 3 and not is_second then ui_state <= UI_AD1;
              else ui_state <= UI_MSG0; end if;
            end if;

          when UI_MSG0 | UI_MSG1 =>
            if in_ready = '1' then
              is_second := ui_state = UI_MSG1;
              in_kind <= '1';
              if decrypt_reg = '1' then in_data <= cipher_block(vector_reg, is_second);
              else in_data <= plain_block(vector_reg, is_second); end if;
              in_keep <= phase_keep(vector_reg, is_second);
              if vector_reg = 3 and not is_second then in_last <= '0';
              else in_last <= '1'; end if;
              in_valid <= '1';
              if vector_reg = 3 and not is_second then ui_state <= UI_MSG1;
              else ui_state <= UI_WAIT_PAYLOAD; end if;
            end if;

          when UI_WAIT_PAYLOAD =>
            if decrypt_reg = '1' and tag_in_ready = '1' then ui_state <= UI_TAG_IN;
            elsif decrypt_reg = '0' and tag_out_valid = '1' then ui_state <= UI_TAG_OUT;
            end if;

          when UI_TAG_IN =>
            tag_in       <= expected_tag(vector_reg);
            tag_in_valid <= '1';
            ui_state     <= UI_FINISH;

          when UI_TAG_OUT =>
            result_tag <= tag_out;
            pass_latched <= '1' when tag_out = expected_tag(vector_reg) and payload_match = '1' else '0';
            fail_latched <= '0' when tag_out = expected_tag(vector_reg) and payload_match = '1' else '1';
            ui_state <= UI_FINISH;

          when UI_FINISH =>
            if core_done = '1' then
              done_latched <= '1';
              ui_state <= UI_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- The display multiplexer is combinational.  SW[9:8] chooses one of the
  -- two captured payload blocks and SW[7:4] chooses a byte lane.  SW[3]
  -- changes the source from payload to the 128-bit tag.
  process (all)
    variable selected_block : block_t;
    variable byte_index     : natural range 0 to 15;
  begin
    if SW(3) = '1' then
      selected_block := result_tag;
    elsif SW(9 downto 8) = "01" then
      selected_block := result_block1;
    else
      selected_block := result_block0;
    end if;
    byte_index := to_integer(unsigned(SW(7 downto 4)));
    LED(7 downto 0) <= selected_block((8 * byte_index) + 7 downto 8 * byte_index);
    LED(8)  <= core_busy;
    LED(9)  <= done_latched;
    LED(10) <= pass_latched;
    LED(11) <= fail_latched;
    LED(12) <= error_latched;
  end process;
end architecture;
