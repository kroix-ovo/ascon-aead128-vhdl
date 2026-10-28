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

entity ascon_aead128_engine is
  generic (
    G_ROUNDS_PER_CYCLE : positive range 1 to 12 := 1;
    G_OVERLAP_OUTPUT : boolean := false;
    G_FULL_BLOCK_FAST_PATH : boolean := false
  );
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

architecture rtl of ascon_aead128_engine is
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
  -- Set once any non-empty AD beat has been absorbed.  An empty last AD beat
  -- then terminates non-empty AD and must still absorb the padded block.
  signal ad_seen_reg       : std_logic := '0';
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

  signal perm_reset        : std_logic;
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
  -- Erase the permutation's private state along with the controller state.
  perm_reset <= '1' when rst_i = '1' or controller_state = ST_ZEROIZE else '0';
  permutation_u : entity work.ascon_permutation
    generic map (G_ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE)
    port map (
      clk_i    => clk_i,
      rst_i    => perm_reset,
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
  -- During decryption tag_reg holds the expected tag; exposing it would let an
  -- observer replay it on tag_in_i and authenticate a forged message.  The
  -- encryption tag stays visible until ST_ZEROIZE clears both registers.
  tag_out_o       <= tag_reg when decrypt_reg = '0' else (others => '0');

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
                            controller_state = ST_FINAL_START or
                            (G_OVERLAP_OUTPUT and controller_state = ST_MSG_OUTPUT and
                             out_valid_reg = '1' and out_ready_i = '1' and msg_full_reg = '1') else '0';
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
        ad_seen_reg     <= '0';
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
              ad_seen_reg <= '0';
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
                if in_last_i = '1' and ad_seen_reg = '1' then
                  -- An empty terminator after full AD beats ends non-empty AD
                  -- on a rate boundary: absorb the padded empty block and its
                  -- p8 before domain separation (SP 800-232).
                  rate_after := state_rate(state_reg) xor padding_bit(0);
                  state_reg <= set_state_rate(state_reg, rate_after);
                  controller_state <= ST_AD_PAD_START;
                elsif in_last_i = '1' then
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
                ad_seen_reg      <= '1';
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
                if G_FULL_BLOCK_FAST_PATH and in_keep_i = x"FFFF" then
                  mask := (others => '1');
                else
                  mask := keep_mask(in_keep_i);
                end if;
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
                if G_OVERLAP_OUTPUT then
                  -- The output queue accepts this block on the same edge
                  -- that launches p8. state_reg already holds its absorbed rate.
                  controller_state <= ST_MSG_PERM_WAIT;
                else
                  controller_state <= ST_MSG_PERM_START;
                end if;
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
            ad_seen_reg      <= '0';
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
        assert perm_state_out = (perm_state_out'range => '0')
          report "permutation state was not cleared before ST_DONE" severity failure;
        assert key_reg = (key_reg'range => '0')
          report "key register was not cleared before ST_DONE" severity failure;
        assert decrypt_reg = '0' and ad_last_reg = '0' and
               ad_full_last_reg = '0' and ad_seen_reg = '0' and
               msg_last_reg = '0' and
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

-- SPDX-License-Identifier: UNLICENSED
--
-- Folded-absorb streaming core, selected by G_FOLDED_ABSORB (three rounds per
-- clock, queues enabled).
--
-- The buffered engine above keeps one 320-bit state register in the
-- controller and a second one in the permutation, joined by a registered
-- start/done handshake.  Every p8 therefore pays an absorb clock, a load
-- clock and a copy-back clock besides its three round clocks.  This variant
-- owns a single state register and drives the three-round datapath itself:
--
--   p12 = 3+3+3+3 rounds (constants F0..4B), one group per clock.
--   p8  = 3+3+2 rounds   (constants B4..4B).  The two-round tail clock also
--         absorbs the next queued block (XOR on encryption, ciphertext
--         replacement on decryption, padding prepared when the beat was
--         queued) and writes the matching output beat.  That absorb logic
--         follows two rounds only; it is never in series with three rounds.
--
-- If the next block is not queued, or the output queue has no space, when a
-- tail clock arrives, the tail simply finishes p8.  A separate absorb-only
-- clock then takes the block when it arrives, so a stall never corrupts the
-- state.  Key additions, domain separation and final padding use that same
-- XOR-only leg or ride on a tail clock.  The tag is the state's last two
-- words XOR the key.  An encryption tag is shown while it is offered and in
-- the following (erasure) clock, as the other configurations' tag register
-- is; otherwise tag_out_o is zero, so a decryption never exposes its
-- expected tag.
--
-- Queues follow the buffered wrapper's contract: plaintext is provisional
-- until commit_o, a tag handshake waits until the output queue is empty, and
-- an error, a reset or the end of a transaction discards every queued beat.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;

entity ascon_aead128_fold is
  generic (
    G_INPUT_FIFO_DEPTH  : positive := 2;
    G_OUTPUT_FIFO_DEPTH : positive := 2
  );
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
    in_kind_i        : in  std_logic;
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
    error_o          : out std_logic;
    -- Observation only: cycles waiting to absorb, not normal round clocks.
    input_starved_o  : out std_logic := '0';
    output_blocked_o : out std_logic := '0';
    tail_missed_o    : out std_logic := '0'
  );
end entity;

architecture rtl of ascon_aead128_fold is
  type fsm_t is (F_IDLE, F_INIT, F_AD_ABS, F_AD_P8, F_MSG_ABS, F_MSG_P8,
                 F_FINAL, F_TAG_OUT, F_TAG_IN, F_ZEROIZE, F_DONE);
  -- Which leg loads the state register on this edge.
  type sel_t is (SEL_HOLD, SEL_XF, SEL_R3, SEL_TAIL);
  subtype keep_t is std_logic_vector(15 downto 0);
  subtype rc_t is std_logic_vector(7 downto 0);

  -- An input beat is decoded once, when the queue accepts it, so the absorb
  -- logic sees plain register bits instead of keep-count and padding logic.
  type in_beat_t is record
    x     : rate_t;    -- (data and byte mask), plus the pad bit of a last beat
    keep  : keep_t;
    rep   : std_logic; -- decryption payload: masked rate bytes are replaced
    kind  : std_logic;
    last  : std_logic;
    full  : std_logic;
    empty : std_logic;
    err   : std_logic; -- non-contiguous keep, or a short or empty non-last beat
  end record;
  type out_beat_t is record
    data : rate_t;
    keep : keep_t;
    last : std_logic;
  end record;
  constant IN_ZERO  : in_beat_t := ((others => '0'), (others => '0'),
                                    '0', '0', '0', '0', '0', '0');
  constant OUT_ZERO : out_beat_t := ((others => '0'), (others => '0'), '0');
  type in_mem_t is array (0 to G_INPUT_FIFO_DEPTH - 1) of in_beat_t;
  type out_mem_t is array (0 to G_OUTPUT_FIFO_DEPTH - 1) of out_beat_t;

  -- One Ascon round with an explicit (registered) round constant.  Apart from
  -- the constant input this is ascon_pkg.ascon_round.
  function round_rc(s : state_t; rc : rc_t) return state_t is
    variable x0, x1, x2, x3, x4 : word64_t;
    variable t0, t1, t2, t3, t4 : word64_t;
    variable result             : state_t := (others => '0');
  begin
    x0 := state_word(s, 0);
    x1 := state_word(s, 1);
    x2 := state_word(s, 2);
    x3 := state_word(s, 3);
    x4 := state_word(s, 4);
    x2(7 downto 0) := x2(7 downto 0) xor rc;
    x0 := x0 xor x4;
    x4 := x4 xor x3;
    x2 := x2 xor x1;
    t0 := x0 xor ((not x1) and x2);
    t1 := x1 xor ((not x2) and x3);
    t2 := x2 xor ((not x3) and x4);
    t3 := x3 xor ((not x4) and x0);
    t4 := x4 xor ((not x0) and x1);
    t1 := t1 xor t0;
    t0 := t0 xor t4;
    t3 := t3 xor t2;
    t2 := not t2;
    x0 := t0 xor std_logic_vector(rotate_right(unsigned(t0), 19))
             xor std_logic_vector(rotate_right(unsigned(t0), 28));
    x1 := t1 xor std_logic_vector(rotate_right(unsigned(t1), 61))
             xor std_logic_vector(rotate_right(unsigned(t1), 39));
    x2 := t2 xor std_logic_vector(rotate_right(unsigned(t2), 1))
             xor std_logic_vector(rotate_right(unsigned(t2), 6));
    x3 := t3 xor std_logic_vector(rotate_right(unsigned(t3), 10))
             xor std_logic_vector(rotate_right(unsigned(t3), 17));
    x4 := t4 xor std_logic_vector(rotate_right(unsigned(t4), 7))
             xor std_logic_vector(rotate_right(unsigned(t4), 41));
    result := set_state_word(result, 0, x0);
    result := set_state_word(result, 1, x1);
    result := set_state_word(result, 2, x2);
    result := set_state_word(result, 3, x3);
    result := set_state_word(result, 4, x4);
    return result;
  end function;

  -- Constant for one lane of the group that runs in state st, group g.
  -- p12 groups start at constants 0, 3, 6, 9; p8 groups at 4, 7, 10.  The p8
  -- tail uses lanes 0 and 1 only (constants 10 and 11).
  function rc_for(st : fsm_t; g : natural; lane : natural) return rc_t is
    variable index : natural;
  begin
    case st is
      when F_INIT | F_FINAL   => index := 3 * g + lane;
      when F_AD_P8 | F_MSG_P8 => index := 4 + 3 * g + lane;
      when others             => return x"00";
    end case;
    if index > 11 then
      return x"00";
    end if;
    return round_constant(index);
  end function;

  function predecode(
    data : rate_t; keep : keep_t; kind, last, decrypt : std_logic
  ) return in_beat_t is
    variable b : in_beat_t;
  begin
    b.keep := keep;
    b.x := data and keep_mask(keep);
    if last = '1' then
      -- The pad byte 01 follows the final valid byte (contiguous keep).
      if keep(0) = '0' then
        b.x(0) := '1';
      end if;
      for i in 1 to 15 loop
        if keep(i) = '0' and keep(i - 1) = '1' then
          b.x(8 * i) := '1';
        end if;
      end loop;
    end if;
    b.kind := kind;
    b.last := last;
    b.rep := decrypt and kind;
    if keep = x"FFFF" then b.full := '1'; else b.full := '0'; end if;
    if keep = x"0000" then b.empty := '1'; else b.empty := '0'; end if;
    if not keep_is_contiguous(keep) or (last = '0' and keep /= x"FFFF") then
      b.err := '1';
    else
      b.err := '0';
    end if;
    return b;
  end function;

  signal fsm          : fsm_t := F_IDLE;
  signal grp          : natural range 0 to 3 := 0;
  signal s_reg        : state_t := (others => '0');
  signal key_reg      : std_logic_vector(127 downto 0) := (others => '0');
  signal dec_reg      : std_logic := '0';
  -- XOR terms waiting for the next absorb-only clock.
  signal key34_pend   : std_logic := '0'; -- key after initialization
  signal dsep_pend    : std_logic := '0'; -- empty AD consumed during p12
  signal ad_started   : std_logic := '0';
  signal ad_last      : std_logic := '0';
  signal ad_full_last : std_logic := '0';
  signal msg_last     : std_logic := '0';
  signal closed       : std_logic := '0';
  signal tag_gate     : std_logic := '0'; -- tag_out_o shows the tag
  signal rc0, rc1, rc2 : rc_t := (others => '0');

  signal done_reg, auth_valid_reg, auth_ok_reg : std_logic := '0';
  signal commit_reg, discard_reg, error_reg    : std_logic := '0';

  signal iq : in_mem_t := (others => IN_ZERO);
  signal oq : out_mem_t := (others => OUT_ZERO);
  signal ic : natural range 0 to G_INPUT_FIFO_DEPTH := 0;
  signal oc : natural range 0 to G_OUTPUT_FIFO_DEPTH := 0;

  signal head  : in_beat_t;
  signal hv    : boolean;
  signal space : boolean;
  signal lane0, lane1, lane2 : state_t;
  signal xf_val, tail_val    : state_t;
  signal tag_val   : rate_t;
  signal tag_match : boolean;
  signal out_new   : out_beat_t;

  -- Decisions, all computed from registered state and queue heads.
  signal sel       : sel_t;
  signal pop, opush, err_now, cmd_acc, tag_acc : boolean;
  signal n_fsm     : fsm_t;
  signal n_grp     : natural range 0 to 3;
  signal n_key34, n_dsep, n_ad_started, n_ad_last, n_ad_full_last,
         n_msg_last : std_logic;
  signal t_en, t_pad, tc_key23, tc_dsep : std_logic;
  signal f_load, f_x, f_key34, f_key23, f_dsep : std_logic;

  signal accepting  : boolean;
  signal in_ready_s, out_valid_s : std_logic;
  signal ipush, opop : boolean;
begin
  head  <= iq(0);
  hv    <= ic > 0;
  space <= oc < G_OUTPUT_FIFO_DEPTH;
  input_starved_o <= '1' when (fsm = F_MSG_ABS or fsm = F_AD_ABS) and not hv else '0';
  output_blocked_o <= '1' when fsm = F_MSG_ABS and hv and
    head.kind = '1' and head.empty = '0' and not space else '0';
  tail_missed_o <= '1' when fsm = F_MSG_P8 and grp = 2 and msg_last = '0' and
    (not hv or not space) else '0';

  -- Three cascaded rounds.  lane2 ends a 3-round group; lane1 ends the
  -- 2-round p8 tail, where the absorb logic is attached.
  lane0 <= round_rc(s_reg, rc0);
  lane1 <= round_rc(lane0, rc1);
  lane2 <= round_rc(lane1, rc2);

  tag_val   <= s_reg(319 downto 192) xor key_reg;
  tag_match <= tag_in_i = tag_val;

  decide : process (all)
    variable ns : fsm_t;
    variable ng : natural range 0 to 3;
    variable vs : sel_t;
    variable vpop, vpush, verr, vcmd, vtag : boolean;
    variable k34, dsp, ads, adl, adf, ml : std_logic;
    variable ten, tpad, tk23, tdsep : std_logic;
    variable fload, fx, fk34, fk23, fdsep : std_logic;
    variable ad_ok, msg_ok, msg_room : boolean;
  begin
    ns := fsm; ng := grp; vs := SEL_HOLD;
    vpop := false; vpush := false; verr := false; vcmd := false; vtag := false;
    k34 := key34_pend; dsp := dsep_pend; ads := ad_started;
    adl := ad_last; adf := ad_full_last; ml := msg_last;
    ten := '0'; tpad := '0'; tk23 := '0'; tdsep := '0';
    fload := '0'; fx := '0'; fk34 := '0'; fk23 := '0'; fdsep := '0';
    ad_ok    := hv and head.kind = '0' and head.err = '0';
    msg_ok   := hv and head.kind = '1' and head.err = '0';
    msg_room := space or head.empty = '1';

    case fsm is
      when F_IDLE =>
        if cmd_valid_i = '1' then
          vcmd := true; vs := SEL_XF; fload := '1';
          ns := F_INIT; ng := 0;
          k34 := '1'; dsp := '0'; ads := '0'; adl := '0'; adf := '0'; ml := '0';
        end if;

      when F_INIT =>
        vs := SEL_R3;
        -- An empty final AD beat ("no associated data") needs no state, so
        -- it is consumed while p12 runs; DSEP joins the first payload absorb.
        if dsep_pend = '0' and hv and head.kind = '0' and
           head.empty = '1' and head.last = '1' then
          vpop := true; dsp := '1';
        end if;
        if grp = 3 then
          ng := 0;
          if dsp = '1' then ns := F_MSG_ABS; else ns := F_AD_ABS; end if;
        else
          ng := grp + 1;
        end if;

      when F_AD_ABS =>
        if hv then
          if not ad_ok then
            verr := true;
          elsif head.empty = '1' and ad_started = '0' then
            -- No associated data: key and domain separation only.
            vs := SEL_XF; fk34 := key34_pend; fdsep := '1';
            vpop := true; k34 := '0'; ns := F_MSG_ABS;
          else
            -- Absorb-only clock for an AD block (an empty final beat after
            -- earlier AD is the padded empty block).
            vs := SEL_XF; fx := '1'; fk34 := key34_pend;
            vpop := true; k34 := '0'; ads := '1';
            adl := head.last; adf := head.last and head.full;
            ns := F_AD_P8; ng := 0;
          end if;
        end if;

      when F_AD_P8 =>
        if grp < 2 then
          vs := SEL_R3; ng := grp + 1;
        else
          vs := SEL_TAIL; ng := 0;
          if ad_last = '1' and ad_full_last = '1' then
            -- A full final AD block is followed by the padded empty block.
            tpad := '1'; adf := '0'; ns := F_AD_P8;
          elsif ad_last = '1' then
            -- AD is complete: apply DSEP and fold the first payload block.
            tdsep := '1';
            if msg_ok and msg_room then
              ten := '1'; vpop := true; vpush := head.empty = '0';
              if head.full = '1' then
                ml := head.last; ns := F_MSG_P8;
              else
                tk23 := '1'; ns := F_FINAL;
              end if;
            elsif hv and not msg_ok then
              verr := true;
            else
              ns := F_MSG_ABS;
            end if;
          else
            if ad_ok then
              ten := '1'; vpop := true;
              adl := head.last; adf := head.last and head.full;
              ns := F_AD_P8;
            elsif hv then
              verr := true;
            else
              ns := F_AD_ABS;
            end if;
          end if;
        end if;

      when F_MSG_ABS =>
        if hv then
          if not msg_ok then
            verr := true;
          elsif msg_room then
            vs := SEL_XF; fx := '1'; fk34 := key34_pend; fdsep := dsep_pend;
            k34 := '0'; dsp := '0';
            vpop := true; vpush := head.empty = '0';
            if head.full = '1' then
              ml := head.last; ns := F_MSG_P8; ng := 0;
            else
              fk23 := '1'; ns := F_FINAL; ng := 0;
            end if;
          end if;
        end if;

      when F_MSG_P8 =>
        if grp < 2 then
          vs := SEL_R3; ng := grp + 1;
        else
          vs := SEL_TAIL; ng := 0;
          if msg_last = '1' then
            -- Full final block: padded empty block and key before p12.
            tpad := '1'; tk23 := '1'; ns := F_FINAL;
          elsif msg_ok and msg_room then
            ten := '1'; vpop := true; vpush := head.empty = '0';
            if head.full = '1' then
              ml := head.last; ns := F_MSG_P8;
            else
              tk23 := '1'; ns := F_FINAL;
            end if;
          elsif hv and not msg_ok then
            verr := true;
          else
            ns := F_MSG_ABS;
          end if;
        end if;

      when F_FINAL =>
        vs := SEL_R3;
        if grp = 3 then
          ng := 0;
          if dec_reg = '1' then ns := F_TAG_IN; else ns := F_TAG_OUT; end if;
        else
          ng := grp + 1;
        end if;

      when F_TAG_OUT =>
        if oc = 0 and tag_out_ready_i = '1' then
          ns := F_ZEROIZE;
        end if;

      when F_TAG_IN =>
        if oc = 0 and tag_in_valid_i = '1' then
          vtag := true; ns := F_ZEROIZE;
        end if;

      when F_ZEROIZE =>
        ns := F_DONE; ng := 0;
        k34 := '0'; dsp := '0'; ads := '0'; adl := '0'; adf := '0'; ml := '0';

      when F_DONE =>
        ns := F_IDLE;
    end case;

    if verr then
      ns := F_ZEROIZE; ng := 0; vs := SEL_HOLD; vpop := false; vpush := false;
    end if;

    n_fsm <= ns; n_grp <= ng; sel <= vs;
    pop <= vpop; opush <= vpush; err_now <= verr; cmd_acc <= vcmd; tag_acc <= vtag;
    n_key34 <= k34; n_dsep <= dsp; n_ad_started <= ads;
    n_ad_last <= adl; n_ad_full_last <= adf; n_msg_last <= ml;
    t_en <= ten; t_pad <= tpad; tc_key23 <= tk23; tc_dsep <= tdsep;
    f_load <= fload; f_x <= fx; f_key34 <= fk34; f_key23 <= fk23; f_dsep <= fdsep;
  end process;

  -- XOR-only leg: command load, absorb without rounds, key and DSEP terms.
  xor_leg : process (all)
    variable v, ops : state_t;
  begin
    ops := (others => '0');
    if f_x = '1' then
      ops(127 downto 0) := head.x;
    end if;
    if f_key34 = '1' then
      ops(255 downto 192) := ops(255 downto 192) xor key_reg(63 downto 0);
      ops(319 downto 256) := ops(319 downto 256) xor key_reg(127 downto 64);
    end if;
    if f_key23 = '1' then
      ops(191 downto 128) := ops(191 downto 128) xor key_reg(63 downto 0);
      ops(255 downto 192) := ops(255 downto 192) xor key_reg(127 downto 64);
    end if;
    if f_dsep = '1' then
      ops(319) := not ops(319);
    end if;
    v := s_reg;
    if f_x = '1' and head.rep = '1' then
      v(127 downto 0) := v(127 downto 0) and not keep_mask(head.keep);
    end if;
    if f_load = '1' then
      v := (others => '0');
      v := set_state_word(v, 0, ASCON_AEAD128_IV_C);
      v := set_state_word(v, 1, key_i(63 downto 0));
      v := set_state_word(v, 2, key_i(127 downto 64));
      v := set_state_word(v, 3, nonce_i(63 downto 0));
      v := set_state_word(v, 4, nonce_i(127 downto 64));
      ops := (others => '0');
    end if;
    xf_val <= v xor ops;
  end process;

  -- Tail leg: p8 rounds 10 and 11, then the folded absorb and XOR terms.
  tail_leg : process (all)
    variable v : state_t;
    variable t : rate_t;
  begin
    v := lane1;
    t := (others => '0');
    if t_en = '1' then
      if head.rep = '1' then
        v(127 downto 0) := v(127 downto 0) and not keep_mask(head.keep);
      end if;
      t := head.x;
    end if;
    if t_pad = '1' then
      t(0) := not t(0);
    end if;
    v(127 downto 0) := v(127 downto 0) xor t;
    if tc_key23 = '1' then
      v(191 downto 128) := v(191 downto 128) xor key_reg(63 downto 0);
      v(255 downto 192) := v(255 downto 192) xor key_reg(127 downto 64);
    end if;
    if tc_dsep = '1' then
      v(319) := not v(319);
    end if;
    tail_val <= v;
  end process;

  -- Output beat: rate (before absorption) XOR input, masked.  The rate comes
  -- from the tail rounds when folded, otherwise from the state register.
  out_new.data <= (lane1(127 downto 0) xor head.x) and keep_mask(head.keep)
                    when sel = SEL_TAIL else
                  (s_reg(127 downto 0) xor head.x) and keep_mask(head.keep);
  out_new.keep <= head.keep;
  out_new.last <= head.last;

  state_update : process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' or fsm = F_ZEROIZE then
        s_reg <= (others => '0');
      else
        case sel is
          when SEL_XF   => s_reg <= xf_val;
          when SEL_R3   => s_reg <= lane2;
          when SEL_TAIL => s_reg <= tail_val;
          when SEL_HOLD => null;
        end case;
      end if;
    end if;
  end process;

  control : process (clk_i)
  begin
    if rising_edge(clk_i) then
      done_reg       <= '0';
      auth_valid_reg <= '0';
      commit_reg     <= '0';
      discard_reg    <= '0';
      error_reg      <= '0';
      if rst_i = '1' then
        fsm <= F_IDLE; grp <= 0;
        key_reg <= (others => '0'); dec_reg <= '0';
        key34_pend <= '0'; dsep_pend <= '0'; ad_started <= '0';
        ad_last <= '0'; ad_full_last <= '0'; msg_last <= '0';
        rc0 <= (others => '0'); rc1 <= (others => '0'); rc2 <= (others => '0');
        auth_ok_reg <= '0'; tag_gate <= '0';
      else
        fsm <= n_fsm; grp <= n_grp;
        if n_fsm = F_TAG_OUT or (fsm = F_TAG_OUT and n_fsm = F_ZEROIZE) then
          tag_gate <= '1';
        else
          tag_gate <= '0';
        end if;
        key34_pend <= n_key34; dsep_pend <= n_dsep; ad_started <= n_ad_started;
        ad_last <= n_ad_last; ad_full_last <= n_ad_full_last; msg_last <= n_msg_last;
        -- Round constants are registered one clock ahead of their group.
        rc0 <= rc_for(n_fsm, n_grp, 0);
        rc1 <= rc_for(n_fsm, n_grp, 1);
        rc2 <= rc_for(n_fsm, n_grp, 2);
        if cmd_acc then
          key_reg <= key_i; dec_reg <= cmd_decrypt_i; auth_ok_reg <= '0';
        end if;
        if err_now then
          error_reg <= '1';
          discard_reg <= dec_reg;
        end if;
        if tag_acc then
          auth_valid_reg <= '1';
          if tag_match then
            auth_ok_reg <= '1'; commit_reg <= '1';
          else
            auth_ok_reg <= '0'; discard_reg <= '1';
          end if;
        end if;
        if fsm = F_ZEROIZE then
          key_reg <= (others => '0'); dec_reg <= '0'; auth_ok_reg <= '0';
        end if;
        if fsm = F_DONE then
          done_reg <= '1';
        end if;
      end if;
    end if;
  end process;

  accepting <= fsm = F_INIT or fsm = F_AD_ABS or fsm = F_AD_P8 or
               fsm = F_MSG_ABS or fsm = F_MSG_P8;
  -- Ready depends on registered state only (no path from in_valid_i or
  -- out_ready_i).  A full queue accepts a replacement on the edge it pops.
  in_ready_s <= '1' when accepting and closed = '0' and rst_i = '0' and
                         not err_now and (ic < G_INPUT_FIFO_DEPTH or pop) else '0';
  out_valid_s <= '1' when oc > 0 and rst_i = '0' else '0';
  ipush <= in_valid_i = '1' and in_ready_s = '1';
  opop  <= out_valid_s = '1' and out_ready_i = '1';

  queues : process (clk_i)
    variable nq : in_mem_t;
    variable n  : natural range 0 to G_INPUT_FIFO_DEPTH;
    variable mq : out_mem_t;
    variable m  : natural range 0 to G_OUTPUT_FIFO_DEPTH;
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' or fsm = F_ZEROIZE or err_now then
        iq <= (others => IN_ZERO); ic <= 0;
        oq <= (others => OUT_ZERO); oc <= 0;
        closed <= '0';
      else
        -- Heads stay at index 0, so the absorb logic reads registers
        -- directly; consumed entries are erased as they shift out.
        nq := iq; n := ic;
        if pop then
          for i in 0 to G_INPUT_FIFO_DEPTH - 2 loop
            nq(i) := nq(i + 1);
          end loop;
          nq(G_INPUT_FIFO_DEPTH - 1) := IN_ZERO;
          n := n - 1;
        end if;
        if ipush then
          nq(n) := predecode(in_data_i, in_keep_i, in_kind_i, in_last_i, dec_reg);
          n := n + 1;
          if in_kind_i = '1' and in_last_i = '1' then
            closed <= '1';
          end if;
        end if;
        iq <= nq; ic <= n;

        mq := oq; m := oc;
        if opop then
          for i in 0 to G_OUTPUT_FIFO_DEPTH - 2 loop
            mq(i) := mq(i + 1);
          end loop;
          mq(G_OUTPUT_FIFO_DEPTH - 1) := OUT_ZERO;
          m := m - 1;
        end if;
        if opush then
          mq(m) := out_new;
          m := m + 1;
        end if;
        oq <= mq; oc <= m;
      end if;
    end if;
  end process;

  cmd_ready_o     <= '1' when fsm = F_IDLE else '0';
  in_ready_o      <= in_ready_s;
  out_valid_o     <= out_valid_s;
  out_data_o      <= oq(0).data;
  out_keep_o      <= oq(0).keep;
  out_last_o      <= oq(0).last;
  tag_in_ready_o  <= '1' when fsm = F_TAG_IN and oc = 0 else '0';
  tag_out_valid_o <= '1' when fsm = F_TAG_OUT and oc = 0 else '0';
  tag_out_o       <= tag_val when tag_gate = '1' else (others => '0');
  busy_o          <= '0' when fsm = F_IDLE else '1';
  done_o          <= done_reg;
  auth_valid_o    <= auth_valid_reg;
  auth_ok_o       <= auth_ok_reg;
  commit_o        <= commit_reg;
  discard_o       <= discard_reg;
  error_o         <= error_reg;

  -- synthesis translate_off
  checks : process (clk_i)
  begin
    if rising_edge(clk_i) and rst_i = '0' then
      assert not (ipush and ic = G_INPUT_FIFO_DEPTH and not pop)
        report "fold input overflow" severity failure;
      assert not (pop and ic = 0) report "fold input underflow" severity failure;
      assert not (opush and not space) report "fold output overflow" severity failure;
      assert not (opop and oc = 0) report "fold output underflow" severity failure;
      assert not ((commit_reg = '1' or auth_valid_reg = '1') and oc /= 0)
        report "authentication preceded output drain" severity failure;
      if fsm = F_IDLE then
        assert s_reg = (s_reg'range => '0')
          report "fold state register not clear while idle" severity failure;
      end if;
      if fsm = F_DONE then
        assert s_reg = (s_reg'range => '0') and key_reg = (key_reg'range => '0')
          report "fold state or key was not cleared before DONE" severity failure;
        assert dec_reg = '0' and key34_pend = '0' and dsep_pend = '0' and
               ad_started = '0' and ad_last = '0' and ad_full_last = '0' and
               msg_last = '0' and closed = '0' and auth_ok_reg = '0'
          report "fold phase storage was not cleared before DONE" severity failure;
        assert ic = 0 and oc = 0 and iq = (iq'range => IN_ZERO) and
               oq = (oq'range => OUT_ZERO)
          report "fold queues were not cleared before DONE" severity failure;
      end if;
    end if;
  end process;
  -- synthesis translate_on
end architecture;

-- SPDX-License-Identifier: UNLICENSED
-- Optional transaction-local elastic queues. Plaintext remains provisional
-- until commit_o. The consumer must quarantine and erase it on discard_o.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ascon_pkg.all;
entity ascon_aead128_core is
  generic (
    G_ROUNDS_PER_CYCLE : positive range 1 to 12 := 1;
    G_BUFFERING_ENABLE : boolean := false;
    G_INPUT_FIFO_DEPTH : positive := 2;
    G_OUTPUT_FIFO_DEPTH : positive := 2;
    G_FULL_BLOCK_FAST_PATH : boolean := false;
    -- Experimental single-state-register core that folds the next absorb
    -- into the two-round p8 tail.  Requires three rounds per clock and
    -- buffering.  False keeps the configurations above unchanged.
    G_FOLDED_ABSORB : boolean := false
  );
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

architecture elastic of ascon_aead128_core is
  -- Elaboration-time configuration check for the folded core.
  function fold_configuration_ok(folded, buffered : boolean; rounds : positive)
    return boolean is
  begin
    assert not folded or (buffered and rounds = 3)
      report "G_FOLDED_ABSORB requires G_BUFFERING_ENABLE and G_ROUNDS_PER_CYCLE = 3"
      severity failure;
    return true;
  end function;
  constant FOLD_CONFIGURATION_CHECKED : boolean :=
    fold_configuration_ok(G_FOLDED_ABSORB, G_BUFFERING_ENABLE, G_ROUNDS_PER_CYCLE);
begin
  fold_g : if G_FOLDED_ABSORB generate
    fold_u : entity work.ascon_aead128_fold
      generic map (G_INPUT_FIFO_DEPTH => G_INPUT_FIFO_DEPTH,
                   G_OUTPUT_FIFO_DEPTH => G_OUTPUT_FIFO_DEPTH)
      port map (
        clk_i => clk_i,
        rst_i => rst_i,
        cmd_valid_i => cmd_valid_i,
        cmd_ready_o => cmd_ready_o,
        cmd_decrypt_i => cmd_decrypt_i,
        key_i => key_i,
        nonce_i => nonce_i,
        in_valid_i => in_valid_i,
        in_ready_o => in_ready_o,
        in_kind_i => in_kind_i,
        in_data_i => in_data_i,
        in_keep_i => in_keep_i,
        in_last_i => in_last_i,
        tag_in_valid_i => tag_in_valid_i,
        tag_in_ready_o => tag_in_ready_o,
        tag_in_i => tag_in_i,
        out_valid_o => out_valid_o,
        out_ready_i => out_ready_i,
        out_data_o => out_data_o,
        out_keep_o => out_keep_o,
        out_last_o => out_last_o,
        tag_out_valid_o => tag_out_valid_o,
        tag_out_ready_i => tag_out_ready_i,
        tag_out_o => tag_out_o,
        busy_o => busy_o,
        done_o => done_o,
        auth_valid_o => auth_valid_o,
        auth_ok_o => auth_ok_o,
        commit_o => commit_o,
        discard_o => discard_o,
        error_o => error_o);
  end generate;
  bypass_g : if not G_BUFFERING_ENABLE and not G_FOLDED_ABSORB generate
    engine_u : entity work.ascon_aead128_engine
      generic map (G_ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE,
                   G_FULL_BLOCK_FAST_PATH => G_FULL_BLOCK_FAST_PATH)
      port map (
        clk_i => clk_i,
        rst_i => rst_i,
        cmd_valid_i => cmd_valid_i,
        cmd_ready_o => cmd_ready_o,
        cmd_decrypt_i => cmd_decrypt_i,
        key_i => key_i,
        nonce_i => nonce_i,
        in_valid_i => in_valid_i,
        in_ready_o => in_ready_o,
        in_kind_i => in_kind_i,
        in_data_i => in_data_i,
        in_keep_i => in_keep_i,
        in_last_i => in_last_i,
        tag_in_valid_i => tag_in_valid_i,
        tag_in_ready_o => tag_in_ready_o,
        tag_in_i => tag_in_i,
        out_valid_o => out_valid_o,
        out_ready_i => out_ready_i,
        out_data_o => out_data_o,
        out_keep_o => out_keep_o,
        out_last_o => out_last_o,
        tag_out_valid_o => tag_out_valid_o,
        tag_out_ready_i => tag_out_ready_i,
        tag_out_o => tag_out_o,
        busy_o => busy_o,
        done_o => done_o,
        auth_valid_o => auth_valid_o,
        auth_ok_o => auth_ok_o,
        commit_o => commit_o,
        discard_o => discard_o,
        error_o => error_o);
  end generate;
  buffered_g : if G_BUFFERING_ENABLE and not G_FOLDED_ABSORB generate
    type input_beat_t is record
      data : std_logic_vector(127 downto 0);
      keep : std_logic_vector(15 downto 0);
      kind, last : std_logic;
    end record;
    type output_beat_t is record
      data : std_logic_vector(127 downto 0);
      keep : std_logic_vector(15 downto 0);
      last : std_logic;
    end record;
    constant INPUT_ZERO : input_beat_t := ((others => '0'), (others => '0'), '0', '0');
    constant OUTPUT_ZERO : output_beat_t := ((others => '0'), (others => '0'), '0');
    type input_memory_t is array(natural range <>) of input_beat_t;
    type output_memory_t is array(natural range <>) of output_beat_t;
    signal iq : input_memory_t(0 to G_INPUT_FIFO_DEPTH-1) := (others => INPUT_ZERO);
    signal oq : output_memory_t(0 to G_OUTPUT_FIFO_DEPTH-1) := (others => OUTPUT_ZERO);
    signal ir, iw : natural range 0 to G_INPUT_FIFO_DEPTH-1 := 0;
    signal orp, ow : natural range 0 to G_OUTPUT_FIFO_DEPTH-1 := 0;
    signal ic : natural range 0 to G_INPUT_FIFO_DEPTH := 0;
    signal oc : natural range 0 to G_OUTPUT_FIFO_DEPTH := 0;
    signal active, closed, aborted : std_logic := '0';
    signal ei_ready, ei_valid, eo_ready, eo_valid : std_logic;
    signal e_cmd_ready, e_done, e_error, e_busy : std_logic;
    signal et_ready, et_valid, drained : std_logic;
    signal eo_data : std_logic_vector(127 downto 0);
    signal eo_keep : std_logic_vector(15 downto 0);
    signal eo_last : std_logic;
    signal input_head : input_beat_t;
    signal ipush, ipop, opush, opop : boolean;
    function advance(p, depth : natural) return natural is
    begin
      if p = depth-1 then return 0; else return p+1; end if;
    end function;
  begin
    input_head <= iq(ir);
    cmd_ready_o <= e_cmd_ready and not e_done;
    busy_o <= e_busy;
    done_o <= e_done;
    error_o <= e_error;
    -- Full queues can accept a replacement on the same edge as a pop.
    in_ready_o <= '1' when active = '1' and closed = '0' and aborted = '0'
      and e_error = '0' and rst_i = '0' and (ic < G_INPUT_FIFO_DEPTH or ipop) else '0';
    ei_valid <= '1' when ic > 0 and aborted = '0' and e_error = '0' else '0';
    ipush <= in_valid_i = '1' and in_ready_o = '1';
    ipop <= ei_valid = '1' and ei_ready = '1';
    out_valid_o <= '1' when oc > 0 and aborted = '0' and e_error = '0' and rst_i = '0' else '0';
    out_data_o <= oq(orp).data;
    out_keep_o <= oq(orp).keep;
    out_last_o <= oq(orp).last;
    opop <= out_valid_o = '1' and out_ready_i = '1';
    eo_ready <= '1' when oc < G_OUTPUT_FIFO_DEPTH or opop else '0';
    opush <= eo_valid = '1' and eo_ready = '1';
    drained <= '1' when oc = 0 else '0';
    -- Final status must follow every provisional payload transfer. In
    -- particular a valid tag cannot race queued plaintext or cleanup.
    tag_in_ready_o <= et_ready and drained;
    tag_out_valid_o <= et_valid and drained;
    engine_u : entity work.ascon_aead128_engine
      generic map (G_ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE,
                   G_OVERLAP_OUTPUT => true,
                   G_FULL_BLOCK_FAST_PATH => G_FULL_BLOCK_FAST_PATH)
      port map (
        clk_i => clk_i,
        rst_i => rst_i,
        cmd_valid_i => cmd_valid_i and not e_done,
        cmd_ready_o => e_cmd_ready,
        cmd_decrypt_i => cmd_decrypt_i,
        key_i => key_i,
        nonce_i => nonce_i,
        in_valid_i => ei_valid,
        in_ready_o => ei_ready,
        in_kind_i => input_head.kind,
        in_data_i => input_head.data,
        in_keep_i => input_head.keep,
        in_last_i => input_head.last,
        tag_in_valid_i => tag_in_valid_i and drained,
        tag_in_ready_o => et_ready,
        tag_in_i => tag_in_i,
        out_valid_o => eo_valid,
        out_ready_i => eo_ready,
        out_data_o => eo_data,
        out_keep_o => eo_keep,
        out_last_o => eo_last,
        tag_out_valid_o => et_valid,
        tag_out_ready_i => tag_out_ready_i and drained,
        tag_out_o => tag_out_o,
        busy_o => e_busy,
        done_o => e_done,
        auth_valid_o => auth_valid_o,
        auth_ok_o => auth_ok_o,
        commit_o => commit_o,
        discard_o => discard_o,
        error_o => e_error);
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        if rst_i = '1' or e_error = '1' or e_done = '1' then
          iq <= (others => INPUT_ZERO); oq <= (others => OUTPUT_ZERO);
          ir <= 0; iw <= 0; orp <= 0; ow <= 0; ic <= 0; oc <= 0;
          closed <= '0';
          if rst_i = '1' or e_done = '1' then
            active <= '0'; aborted <= '0';
          else
            aborted <= '1';
          end if;
        else
          if cmd_valid_i = '1' and cmd_ready_o = '1' then
            active <= '1'; closed <= '0'; aborted <= '0';
          end if;
          if ipop then iq(ir) <= INPUT_ZERO; ir <= advance(ir, G_INPUT_FIFO_DEPTH); end if;
          if ipush then
            iq(iw) <= (in_data_i, in_keep_i, in_kind_i, in_last_i);
            iw <= advance(iw, G_INPUT_FIFO_DEPTH);
            if in_kind_i = '1' and in_last_i = '1' then closed <= '1'; end if;
          end if;
          if ipush and not ipop then ic <= ic+1;
          elsif ipop and not ipush then ic <= ic-1; end if;
          if opop then oq(orp) <= OUTPUT_ZERO; orp <= advance(orp, G_OUTPUT_FIFO_DEPTH); end if;
          if opush then
            oq(ow) <= (eo_data, eo_keep, eo_last);
            ow <= advance(ow, G_OUTPUT_FIFO_DEPTH);
          end if;
          if opush and not opop then oc <= oc+1;
          elsif opop and not opush then oc <= oc-1; end if;
        end if;
      end if;
    end process;
    -- synthesis translate_off
    process(clk_i)
    begin
      if rising_edge(clk_i) and rst_i = '0' then
        assert not (ipush and ic = G_INPUT_FIFO_DEPTH and not ipop) report "input overflow" severity failure;
        assert not (ipop and ic = 0) report "input underflow" severity failure;
        assert not (opush and oc = G_OUTPUT_FIFO_DEPTH and not opop) report "output overflow" severity failure;
        assert not (opop and oc = 0) report "output underflow" severity failure;
        assert not ((commit_o = '1' or auth_valid_o = '1') and oc /= 0)
          report "authentication preceded output drain" severity failure;
        if e_done = '1' then
          assert ic = 0 and oc = 0 report "transaction ended with queued beats" severity failure;
        end if;
      end if;
    end process;
    -- synthesis translate_on
  end generate;
end architecture;
