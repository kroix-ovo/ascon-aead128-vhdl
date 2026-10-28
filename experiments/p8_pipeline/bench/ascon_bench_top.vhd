-- SPDX-License-Identifier: UNLICENSED
--
-- Registered timing harness for the p8 pipelining experiment.
--
-- Every core input comes from a flip-flop and every core output is folded
-- into a flip-flop, so routed timing measures register-to-register paths that
-- begin and end at the core boundary rather than at FPGA pins.  Inputs are
-- drawn from a free-running 128-bit LFSR so synthesis cannot treat any key,
-- nonce, data, keep, or tag bit as a constant.  Outputs (data, keep, last,
-- tag, and every status flag) are compressed into a 128-bit multiple-input
-- signature register whose parity drives one LED, so no output can be pruned.
--
-- The 128-bit key, nonce, data, and tag-in registers reload from the LFSR on
-- every clock instead of on handshakes.  The core samples them only on its
-- own handshake edges, so this changes no core behaviour, and it keeps the
-- harness's own handshake fan-out (a 128-bit clock enable driven by the
-- core's combinational ready outputs) from becoming the measured limit.
-- Only the narrow controls (valid, kind, keep, last) follow the protocol.
--
-- The driver walks the same transaction shape the KAT bench uses: command,
-- one associated-data beat, a run of full payload beats, a final partial
-- beat, then the tag.  Ready on the output stream follows one LFSR bit, so the
-- stall path through ST_MSG_OUTPUT is exercised as well.  This file is a
-- timing load, not a functional check; correctness is established in GHDL.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ascon_bench_top is
  port (
    CLK100MHZ : in  std_logic;
    BTNC      : in  std_logic;
    LED       : out std_logic_vector(0 downto 0)
  );
end entity;

architecture rtl of ascon_bench_top is
  subtype block_t is std_logic_vector(127 downto 0);
  type drive_state_t is (D_CMD, D_AD, D_MSG, D_TAG, D_WAIT_DONE);

  signal rst_meta, rst_sync : std_logic := '1';
  signal lfsr               : block_t := x"0123456789ABCDEFFEDCBA9876543210";
  signal drive_state        : drive_state_t := D_CMD;
  signal beats_left         : unsigned(3 downto 0) := (others => '0');

  signal cmd_valid, cmd_decrypt   : std_logic := '0';
  signal key, nonce               : block_t := (others => '0');
  signal in_valid, in_kind, in_last : std_logic := '0';
  signal in_data                  : block_t := (others => '0');
  signal in_keep                  : std_logic_vector(15 downto 0) := (others => '0');
  signal tag_in_valid             : std_logic := '0';
  signal tag_in                   : block_t := (others => '0');
  signal out_ready, tag_out_ready : std_logic := '0';

  signal cmd_ready, in_ready, tag_in_ready : std_logic;
  signal out_valid, out_last, tag_out_valid : std_logic;
  signal out_data, tag_out                  : block_t;
  signal out_keep                           : std_logic_vector(15 downto 0);
  signal busy, done, auth_valid, auth_ok    : std_logic;
  signal commit, discard, core_error        : std_logic;

  signal signature : block_t := (others => '0');

  function thermometer(count : unsigned(3 downto 0)) return std_logic_vector is
  begin
    -- 1..16 contiguous low bytes; count 0 encodes a full 16-byte beat.
    if count = 0 then
      return x"FFFF";
    end if;
    return std_logic_vector(to_unsigned((2 ** to_integer(count)) - 1, 16));
  end function;
begin
  core_u : entity work.ascon_aead128_core
    port map (
      clk_i => CLK100MHZ, rst_i => rst_sync,
      cmd_valid_i => cmd_valid, cmd_ready_o => cmd_ready,
      cmd_decrypt_i => cmd_decrypt, key_i => key, nonce_i => nonce,
      in_valid_i => in_valid, in_ready_o => in_ready, in_kind_i => in_kind,
      in_data_i => in_data, in_keep_i => in_keep, in_last_i => in_last,
      tag_in_valid_i => tag_in_valid, tag_in_ready_o => tag_in_ready,
      tag_in_i => tag_in,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_data_o => out_data, out_keep_o => out_keep, out_last_o => out_last,
      tag_out_valid_o => tag_out_valid, tag_out_ready_i => tag_out_ready,
      tag_out_o => tag_out,
      busy_o => busy, done_o => done, auth_valid_o => auth_valid,
      auth_ok_o => auth_ok, commit_o => commit, discard_o => discard,
      error_o => core_error
    );

  LED(0) <= signature(0) xor signature(127);

  -- synthesis translate_off
  -- Simulation-only progress report used by scripts/check_harness.sh to
  -- confirm the harness completes real transactions.
  process (CLK100MHZ)
    variable transactions, errors, decrypts, clocks : natural := 0;
  begin
    if rising_edge(CLK100MHZ) then
      clocks := clocks + 1;
      if done = '1' then transactions := transactions + 1; end if;
      if core_error = '1' then errors := errors + 1; end if;
      if auth_valid = '1' then decrypts := decrypts + 1; end if;
      if clocks = 100000 then
        report "harness transactions=" & integer'image(transactions) &
               " decrypt_checks=" & integer'image(decrypts) &
               " errors=" & integer'image(errors);
      end if;
    end if;
  end process;
  -- synthesis translate_on

  process (CLK100MHZ)
    variable feedback : std_logic;
  begin
    if rising_edge(CLK100MHZ) then
      rst_meta <= BTNC;
      rst_sync <= rst_meta;

      -- x^128 + x^29 + x^27 + x^2 + 1 Fibonacci LFSR, one step per clock.
      feedback := lfsr(127) xor lfsr(28) xor lfsr(26) xor lfsr(1);
      lfsr <= lfsr(126 downto 0) & feedback;

      out_ready     <= lfsr(5) or lfsr(9);
      tag_out_ready <= '1';

      key     <= lfsr;
      nonce   <= lfsr(63 downto 0) & lfsr(127 downto 64);
      in_data <= lfsr(95 downto 0) & lfsr(127 downto 96);
      tag_in  <= lfsr(31 downto 0) & lfsr(127 downto 32);

      -- Signature register: rotate and fold every core output.
      signature <= (signature(126 downto 0) & signature(127))
                   xor out_data xor tag_out
                   xor (x"0000000000000000000000000000" & "000" & out_keep(15 downto 3))
                   xor (x"000000000000000000000000000000" & out_keep(2 downto 0) &
                        out_valid & out_last & tag_out_valid & cmd_ready & in_ready)
                   xor (x"00000000000000000000000000000" & "0" & tag_in_ready & busy &
                        done & auth_valid & auth_ok & commit & discard & core_error & "000");

      if rst_sync = '1' then
        drive_state  <= D_CMD;
        cmd_valid    <= '0';
        in_valid     <= '0';
        tag_in_valid <= '0';
        beats_left   <= (others => '0');
      else
        case drive_state is
          when D_CMD =>
            if cmd_valid = '1' and cmd_ready = '1' then
              cmd_valid   <= '0';
              in_valid    <= '1';
              in_kind     <= '0';
              in_keep     <= thermometer(unsigned(lfsr(3 downto 0)));
              in_last     <= '1';
              drive_state <= D_AD;
            elsif cmd_valid = '0' then
              cmd_valid   <= '1';
              cmd_decrypt <= lfsr(7);
            end if;

          when D_AD =>
            if in_valid = '1' and in_ready = '1' then
              in_kind     <= '1';
              in_keep     <= x"FFFF";
              in_last     <= '0';
              beats_left  <= unsigned(lfsr(11 downto 8));
              drive_state <= D_MSG;
            end if;

          when D_MSG =>
            if in_valid = '1' and in_ready = '1' then
              if in_last = '1' then
                in_valid     <= '0';
                tag_in_valid <= '1';
                drive_state  <= D_TAG;
              elsif beats_left = 0 then
                in_keep <= thermometer(unsigned(lfsr(3 downto 0)));
                in_last <= '1';
              else
                beats_left <= beats_left - 1;
              end if;
            end if;

          when D_TAG =>
            if (tag_in_valid = '1' and tag_in_ready = '1') or tag_out_valid = '1' then
              tag_in_valid <= '0';
              drive_state  <= D_WAIT_DONE;
            end if;

          when D_WAIT_DONE =>
            if done = '1' or core_error = '1' then
              drive_state <= D_CMD;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
