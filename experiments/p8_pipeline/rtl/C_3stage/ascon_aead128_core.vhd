-- SPDX-License-Identifier: UNLICENSED
--
-- Streaming NIST Ascon-AEAD128 encryption and decryption controller.
--
-- The controller is intentionally written as a direct digital-logic story.
-- Each named state corresponds to a visible hardware action: accepting a
-- command, waiting for a block, running the shared permutation, presenting an
-- output, checking a tag, or erasing secrets.  The long comments describe the
-- protocol and state updates so a reader can follow the circuit without first
-- learning every VHDL language feature.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.ascon_pkg.all;

entity ascon_aead128_core is
  port (
    clk_i            : in  std_logic;
    rst_i            : in  std_logic;

    cmd_valid_i      : in  std_logic;
    cmd_ready_o      : out std_logic;
    cmd_decrypt_i    : in  std_logic;
    key_i            : in  std_logic_vector(127 downto 0);
    nonce_i          : in  std_logic_vector(127 downto 0);

    in_valid_i       : in  std_logic;
    in_ready_o       : out std_logic;
    in_kind_i        : in  std_logic; -- 0 = associated data, 1 = payload
    in_data_i        : in  std_logic_vector(127 downto 0);
    in_keep_i        : in  std_logic_vector(15 downto 0);
    in_last_i        : in  std_logic;

    tag_in_valid_i   : in  std_logic;
    tag_in_ready_o   : out std_logic;
    tag_in_i         : in  std_logic_vector(127 downto 0);

    out_valid_o      : out std_logic;
    out_ready_i      : in  std_logic;
    out_data_o       : out std_logic_vector(127 downto 0);
    out_keep_o       : out std_logic_vector(15 downto 0);
    out_last_o       : out std_logic;

    tag_out_valid_o  : out std_logic;
    tag_out_ready_i  : in  std_logic;
    tag_out_o        : out std_logic_vector(127 downto 0);

    busy_o           : out std_logic;
    done_o           : out std_logic;
    auth_valid_o     : out std_logic;
    auth_ok_o        : out std_logic;
    commit_o         : out std_logic;
    discard_o        : out std_logic;
    error_o          : out std_logic
  );
end entity;

architecture rtl of ascon_aead128_core is
  type controller_state_t is (
    ST_IDLE,
    ST_INIT_START, ST_INIT_WAIT,
    ST_AD_WAIT, ST_AD_PERM_START, ST_AD_PERM_WAIT,
    ST_AD_PAD_START, ST_AD_PAD_WAIT,
    ST_MSG_WAIT, ST_MSG_OUTPUT,
    ST_MSG_PERM_START, ST_MSG_PERM_WAIT,
    ST_FINAL_START, ST_FINAL_WAIT,
    ST_TAG_OUT, ST_TAG_IN,
    ST_ZEROIZE,
    ST_DONE
  );

  signal controller_state : controller_state_t := ST_IDLE;
  signal state_reg         : state_t := (others => '0');
  signal key_reg           : std_logic_vector(127 downto 0) := (others => '0');
  signal decrypt_reg       : std_logic := '0';

  signal ad_last_reg       : std_logic := '0';
  signal ad_full_last_reg  : std_logic := '0';
  signal msg_last_reg      : std_logic := '0';
  signal msg_full_reg      : std_logic := '0';

  signal out_valid_reg     : std_logic := '0';
  signal out_data_reg      : rate_t := (others => '0');
  signal out_keep_reg      : std_logic_vector(15 downto 0) := (others => '0');
  signal out_last_reg      : std_logic := '0';
  signal tag_reg           : rate_t := (others => '0');

  signal done_reg          : std_logic := '0';
  signal auth_valid_reg    : std_logic := '0';
  signal auth_ok_reg       : std_logic := '0';
  signal commit_reg        : std_logic := '0';
  signal discard_reg       : std_logic := '0';
  signal error_reg         : std_logic := '0';

  signal perm_start        : std_logic := '0';
  signal perm_rounds       : unsigned(3 downto 0) := (others => '0');
  signal perm_state_in     : state_t := (others => '0');
  signal perm_done         : std_logic;
  signal perm_state_out    : state_t;

  function xor_key_after_initialization(
    s : state_t;
    k : std_logic_vector(127 downto 0)
  ) return state_t is
    variable result : state_t := s;
  begin
    result := set_state_word(result, 3, state_word(result, 3) xor k(63 downto 0));
    result := set_state_word(result, 4, state_word(result, 4) xor k(127 downto 64));
    return result;
  end function;

  function xor_key_before_finalization(
    s : state_t;
    k : std_logic_vector(127 downto 0)
  ) return state_t is
    variable result : state_t := s;
  begin
    result := set_state_word(result, 2, state_word(result, 2) xor k(63 downto 0));
    result := set_state_word(result, 3, state_word(result, 3) xor k(127 downto 64));
    return result;
  end function;

  function tag_from_final_state(
    s : state_t;
    k : std_logic_vector(127 downto 0)
  ) return rate_t is
    variable result : rate_t;
  begin
    result(63 downto 0)   := state_word(s, 3) xor k(63 downto 0);
    result(127 downto 64) := state_word(s, 4) xor k(127 downto 64);
    return result;
  end function;
begin
  permutation_u : entity work.ascon_permutation
    port map (
      clk_i    => clk_i,
      rst_i    => rst_i,
      start_i  => perm_start,
      rounds_i => perm_rounds,
      state_i  => perm_state_in,
      busy_o   => open,
      done_o   => perm_done,
      state_o  => perm_state_out
    );

  cmd_ready_o     <= '1' when controller_state = ST_IDLE else '0';
  in_ready_o      <= '1' when controller_state = ST_AD_WAIT or controller_state = ST_MSG_WAIT else '0';
  tag_in_ready_o  <= '1' when controller_state = ST_TAG_IN else '0';
  tag_out_valid_o <= '1' when controller_state = ST_TAG_OUT else '0';
  tag_out_o       <= tag_reg;

  out_valid_o <= out_valid_reg;
  out_data_o  <= out_data_reg;
  out_keep_o  <= out_keep_reg;
  out_last_o  <= out_last_reg;

  busy_o       <= '0' when controller_state = ST_IDLE else '1';
  done_o       <= done_reg;
  auth_valid_o <= auth_valid_reg;
  auth_ok_o    <= auth_ok_reg;
  commit_o     <= commit_reg;
  discard_o    <= discard_reg;
  error_o      <= error_reg;

  -- The permutation request is purely a function of the controller state.
  -- START states last for one clock and are always followed by a WAIT state,
  -- so the iterative engine receives exactly one start pulse.
  perm_start    <= '1' when controller_state = ST_INIT_START or
                            controller_state = ST_AD_PERM_START or
                            controller_state = ST_AD_PAD_START or
                            controller_state = ST_MSG_PERM_START or
                            controller_state = ST_FINAL_START else '0';
  perm_rounds   <= to_unsigned(12, 4) when controller_state = ST_INIT_START or
                                             controller_state = ST_FINAL_START else
                   to_unsigned(8, 4);
  perm_state_in <= state_reg;

  process (clk_i)
    variable next_state : state_t;
    variable rate_before: rate_t;
    variable rate_after : rate_t;
    variable mask       : rate_t;
    variable valid_bytes: natural range 0 to 16;
    variable valid_keep : boolean;
    variable computed_tag : rate_t;
  begin
    if rising_edge(clk_i) then
      -- Status outputs are one-clock events.  The surrounding system can
      -- stretch or latch them when a level indication is needed.
      done_reg       <= '0';
      auth_valid_reg <= '0';
      commit_reg     <= '0';
      discard_reg    <= '0';
      error_reg      <= '0';

      if rst_i = '1' then
        controller_state <= ST_IDLE;
        state_reg       <= (others => '0');
        key_reg         <= (others => '0');
        decrypt_reg     <= '0';
        ad_last_reg     <= '0';
        ad_full_last_reg<= '0';
        msg_last_reg    <= '0';
        msg_full_reg    <= '0';
        out_valid_reg   <= '0';
        out_data_reg    <= (others => '0');
        out_keep_reg    <= (others => '0');
        out_last_reg    <= '0';
        tag_reg         <= (others => '0');
        done_reg        <= '0';
        auth_valid_reg  <= '0';
        auth_ok_reg     <= '0';
        commit_reg      <= '0';
        discard_reg     <= '0';
        error_reg       <= '0';
      else
        case controller_state is
          when ST_IDLE =>
            if cmd_valid_i = '1' then
              -- Load IV, key, and nonce into the five-word state.  Each
              -- 128-bit port is already arranged in little-endian byte lanes.
              next_state := (others => '0');
              next_state := set_state_word(next_state, 0, ASCON_AEAD128_IV_C);
              next_state := set_state_word(next_state, 1, key_i(63 downto 0));
              next_state := set_state_word(next_state, 2, key_i(127 downto 64));
              next_state := set_state_word(next_state, 3, nonce_i(63 downto 0));
              next_state := set_state_word(next_state, 4, nonce_i(127 downto 64));
              state_reg   <= next_state;
              key_reg     <= key_i;
              decrypt_reg <= cmd_decrypt_i;
              auth_ok_reg <= '0';
              tag_reg     <= (others => '0');
              controller_state <= ST_INIT_START;
            end if;

          when ST_INIT_START =>
            controller_state <= ST_INIT_WAIT;

          when ST_INIT_WAIT =>
            if perm_done = '1' then
              state_reg <= xor_key_after_initialization(perm_state_out, key_reg);
              controller_state <= ST_AD_WAIT;
            end if;

          when ST_AD_WAIT =>
            if in_valid_i = '1' then
              valid_keep  := keep_is_contiguous(in_keep_i);
              valid_bytes := keep_count(in_keep_i);

              if in_kind_i /= '0' or not valid_keep or
                 (in_last_i = '0' and in_keep_i /= x"FFFF") then
                -- A malformed stream is treated as a failed transaction.  The
                -- dedicated erasure state clears every buffered value before
                -- the controller announces completion.
                error_reg   <= '1';
                if decrypt_reg = '1' then
                  discard_reg <= '1';
                end if;
                controller_state <= ST_ZEROIZE;
              elsif valid_bytes = 0 then
                if in_last_i = '1' then
                  -- Empty associated data performs no p8.  Domain separation
                  -- still occurs before the payload phase.
                  next_state := set_state_word(
                    state_reg, 4, state_word(state_reg, 4) xor ASCON_DSEP_C);
                  state_reg <= next_state;
                  controller_state <= ST_MSG_WAIT;
                else
                  error_reg <= '1';
                  if decrypt_reg = '1' then discard_reg <= '1'; end if;
                  controller_state <= ST_ZEROIZE;
                end if;
              else
                mask := keep_mask(in_keep_i);
                rate_after := state_rate(state_reg) xor (in_data_i and mask);

                if in_last_i = '1' and valid_bytes < 16 then
                  rate_after := rate_after xor padding_bit(valid_bytes);
                end if;

                state_reg <= set_state_rate(state_reg, rate_after);
                ad_last_reg      <= in_last_i;
                if in_last_i = '1' and valid_bytes = 16 then
                  ad_full_last_reg <= '1';
                else
                  ad_full_last_reg <= '0';
                end if;
                controller_state <= ST_AD_PERM_START;
              end if;
            end if;

          when ST_AD_PERM_START =>
            controller_state <= ST_AD_PERM_WAIT;

          when ST_AD_PERM_WAIT =>
            if perm_done = '1' then
              if ad_last_reg = '0' then
                state_reg <= perm_state_out;
                controller_state <= ST_AD_WAIT;
              elsif ad_full_last_reg = '1' then
                -- A message ending on an exact rate boundary still has a
                -- separate padded empty block.  For AD that block is followed
                -- by its own p8 permutation.
                rate_after := state_rate(perm_state_out) xor padding_bit(0);
                state_reg <= set_state_rate(perm_state_out, rate_after);
                controller_state <= ST_AD_PAD_START;
              else
                next_state := set_state_word(
                  perm_state_out, 4,
                  state_word(perm_state_out, 4) xor ASCON_DSEP_C);
                state_reg <= next_state;
                controller_state <= ST_MSG_WAIT;
              end if;
            end if;

          when ST_AD_PAD_START =>
            controller_state <= ST_AD_PAD_WAIT;

          when ST_AD_PAD_WAIT =>
            if perm_done = '1' then
              next_state := set_state_word(
                perm_state_out, 4,
                state_word(perm_state_out, 4) xor ASCON_DSEP_C);
              state_reg <= next_state;
              controller_state <= ST_MSG_WAIT;
            end if;

          when ST_MSG_WAIT =>
            if in_valid_i = '1' then
              valid_keep  := keep_is_contiguous(in_keep_i);
              valid_bytes := keep_count(in_keep_i);

              if in_kind_i /= '1' or not valid_keep or
                 (in_last_i = '0' and in_keep_i /= x"FFFF") then
                error_reg     <= '1';
                if decrypt_reg = '1' then discard_reg <= '1'; end if;
                controller_state <= ST_ZEROIZE;
              elsif valid_bytes = 0 then
                if in_last_i = '1' then
                  rate_after := state_rate(state_reg) xor padding_bit(0);
                  next_state := set_state_rate(state_reg, rate_after);
                  state_reg  <= xor_key_before_finalization(next_state, key_reg);
                  controller_state <= ST_FINAL_START;
                else
                  error_reg <= '1';
                  if decrypt_reg = '1' then discard_reg <= '1'; end if;
                  controller_state <= ST_ZEROIZE;
                end if;
              else
                mask        := keep_mask(in_keep_i);
                rate_before := state_rate(state_reg);

                if decrypt_reg = '0' then
                  rate_after  := rate_before xor (in_data_i and mask);
                  out_data_reg <= rate_after and mask;
                else
                  out_data_reg <= (rate_before xor in_data_i) and mask;
                  -- During decryption the ciphertext, not the recovered
                  -- plaintext, replaces the valid rate bytes.
                  rate_after := (rate_before and (not mask)) or (in_data_i and mask);
                end if;

                if in_last_i = '1' and valid_bytes < 16 then
                  rate_after := rate_after xor padding_bit(valid_bytes);
                end if;

                state_reg       <= set_state_rate(state_reg, rate_after);
                out_keep_reg    <= in_keep_i;
                out_last_reg    <= in_last_i;
                out_valid_reg   <= '1';
                msg_last_reg    <= in_last_i;
                if valid_bytes = 16 then msg_full_reg <= '1';
                else msg_full_reg <= '0'; end if;
                controller_state <= ST_MSG_OUTPUT;
              end if;
            end if;

          when ST_MSG_OUTPUT =>
            if out_valid_reg = '1' and out_ready_i = '1' then
              out_valid_reg <= '0';
              out_data_reg  <= (others => '0');

              if msg_full_reg = '1' then
                controller_state <= ST_MSG_PERM_START;
              else
                -- A partial final block is already padded and is not followed
                -- by p8 before finalization.
                state_reg <= xor_key_before_finalization(state_reg, key_reg);
                controller_state <= ST_FINAL_START;
              end if;
            end if;

          when ST_MSG_PERM_START =>
            controller_state <= ST_MSG_PERM_WAIT;

          when ST_MSG_PERM_WAIT =>
            if perm_done = '1' then
              if msg_last_reg = '1' then
                -- The final full block was permuted as a normal full block.
                -- Add the mandatory empty padding block, then finalize.
                rate_after := state_rate(perm_state_out) xor padding_bit(0);
                next_state := set_state_rate(perm_state_out, rate_after);
                state_reg <= xor_key_before_finalization(next_state, key_reg);
                controller_state <= ST_FINAL_START;
              else
                state_reg <= perm_state_out;
                controller_state <= ST_MSG_WAIT;
              end if;
            end if;

          when ST_FINAL_START =>
            controller_state <= ST_FINAL_WAIT;

          when ST_FINAL_WAIT =>
            if perm_done = '1' then
              computed_tag := tag_from_final_state(perm_state_out, key_reg);
              tag_reg <= computed_tag;
              if decrypt_reg = '1' then
                controller_state <= ST_TAG_IN;
              else
                controller_state <= ST_TAG_OUT;
              end if;
            end if;

          when ST_TAG_OUT =>
            if tag_out_ready_i = '1' then
              -- Encryption is complete once the tag has been accepted.  All
              -- terminal paths use the same erasure state so a normal result,
              -- a failed tag, and a protocol error have one cleanup rule.
              controller_state <= ST_ZEROIZE;
            end if;

          when ST_TAG_IN =>
            if tag_in_valid_i = '1' then
              auth_valid_reg <= '1';
              if tag_in_i = tag_reg then
                auth_ok_reg <= '1';
                commit_reg  <= '1';
              else
                auth_ok_reg <= '0';
                discard_reg <= '1';
              end if;
              controller_state <= ST_ZEROIZE;
            end if;

          when ST_ZEROIZE =>
            -- This clock edge erases all transaction storage, including
            -- values that are not secret by themselves but could expose a
            -- previous phase or leave a stale valid output.  ST_DONE is
            -- reached only after these assignments have taken effect.
            state_reg        <= (others => '0');
            key_reg          <= (others => '0');
            decrypt_reg      <= '0';
            ad_last_reg      <= '0';
            ad_full_last_reg <= '0';
            msg_last_reg     <= '0';
            msg_full_reg     <= '0';
            out_valid_reg    <= '0';
            out_data_reg     <= (others => '0');
            out_keep_reg     <= (others => '0');
            out_last_reg     <= '0';
            tag_reg          <= (others => '0');
            auth_ok_reg      <= '0';
            controller_state <= ST_DONE;

          when ST_DONE =>
            done_reg <= '1';
            controller_state <= ST_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- synthesis translate_off
  -- These assertions are simulation guards for the cleanup contract.  They
  -- inspect the internal registers on the clock edge that enters ST_DONE.
  -- A failure identifies storage that was added later without also being
  -- connected to the central zeroization state.
  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '0' and controller_state = ST_DONE then
        assert state_reg = (state_reg'range => '0')
          report "state register was not cleared before ST_DONE" severity failure;
        assert key_reg = (key_reg'range => '0')
          report "key register was not cleared before ST_DONE" severity failure;
        assert decrypt_reg = '0' and ad_last_reg = '0' and
               ad_full_last_reg = '0' and msg_last_reg = '0' and
               msg_full_reg = '0'
          report "phase storage was not cleared before ST_DONE" severity failure;
        assert out_valid_reg = '0' and
               out_data_reg = (out_data_reg'range => '0') and
               out_keep_reg = (out_keep_reg'range => '0') and
               out_last_reg = '0'
          report "buffered payload was not cleared before ST_DONE" severity failure;
        assert tag_reg = (tag_reg'range => '0') and auth_ok_reg = '0'
          report "tag or authentication storage was not cleared before ST_DONE"
          severity failure;
      end if;
    end if;
  end process;
  -- synthesis translate_on
end architecture;
