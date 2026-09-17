-- SPDX-License-Identifier: UNLICENSED
--
-- Shared types and combinational functions for NIST Ascon-AEAD128.
--
-- The package keeps byte ordering explicit.  A 128-bit stream word uses byte
-- lane zero in bits 7 downto 0.  The first eight stream bytes therefore form
-- the least-significant-to-most-significant bytes of the first 64-bit Ascon
-- word, exactly as specified by NIST SP 800-232.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package ascon_pkg is
  subtype word64_t is std_logic_vector(63 downto 0);
  subtype rate_t is std_logic_vector(127 downto 0);
  subtype state_t is std_logic_vector(319 downto 0);

  constant ASCON_AEAD128_IV_C : word64_t := x"00001000808C0001";
  constant ASCON_DSEP_C       : word64_t := x"8000000000000000";

  function state_word(s : state_t; index : natural) return word64_t;
  function set_state_word(
    s     : state_t;
    index : natural;
    value : word64_t
  ) return state_t;
  function state_rate(s : state_t) return rate_t;
  function set_state_rate(s : state_t; value : rate_t) return state_t;

  function round_constant(round_index : natural) return std_logic_vector;
  function ascon_round(s : state_t; round_index : natural) return state_t;

  function keep_is_contiguous(keep : std_logic_vector(15 downto 0)) return boolean;
  function keep_count(keep : std_logic_vector(15 downto 0)) return natural;
  function keep_mask(keep : std_logic_vector(15 downto 0)) return rate_t;
  function padding_bit(valid_bytes : natural) return rate_t;
end package;

package body ascon_pkg is
  function state_word(s : state_t; index : natural) return word64_t is
  begin
    return s((index * 64) + 63 downto index * 64);
  end function;

  function set_state_word(
    s     : state_t;
    index : natural;
    value : word64_t
  ) return state_t is
    variable result : state_t := s;
  begin
    result((index * 64) + 63 downto index * 64) := value;
    return result;
  end function;

  function state_rate(s : state_t) return rate_t is
  begin
    return s(127 downto 0);
  end function;

  function set_state_rate(s : state_t; value : rate_t) return state_t is
    variable result : state_t := s;
  begin
    result(127 downto 0) := value;
    return result;
  end function;

  function rotate_right_64(value : word64_t; amount : natural) return word64_t is
  begin
    return std_logic_vector(rotate_right(unsigned(value), amount));
  end function;

  function round_constant(round_index : natural) return std_logic_vector is
    variable high_nibble : natural;
    variable low_nibble  : natural;
  begin
    -- The twelve constants are F0, E1, D2, ..., 4B.  An eight-round
    -- permutation starts at index four and therefore begins with B4.
    high_nibble := 15 - round_index;
    low_nibble  := round_index;
    return std_logic_vector(to_unsigned((16 * high_nibble) + low_nibble, 8));
  end function;

  function ascon_round(s : state_t; round_index : natural) return state_t is
    variable x0, x1, x2, x3, x4 : word64_t;
    variable t0, t1, t2, t3, t4 : word64_t;
    variable result              : state_t := (others => '0');
  begin
    x0 := state_word(s, 0);
    x1 := state_word(s, 1);
    x2 := state_word(s, 2);
    x3 := state_word(s, 3);
    x4 := state_word(s, 4);

    -- The round constant occupies the least-significant byte of x2 in the
    -- standardized little-endian representation.
    x2(7 downto 0) := x2(7 downto 0) xor round_constant(round_index);

    -- Substitution layer.  These word-wide Boolean equations implement 64
    -- identical five-input S-boxes in parallel, one for every bit position.
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

    -- Linear diffusion layer.  Every state word has its own two rotation
    -- distances, so all five equations can be evaluated concurrently.
    x0 := t0 xor rotate_right_64(t0, 19) xor rotate_right_64(t0, 28);
    x1 := t1 xor rotate_right_64(t1, 61) xor rotate_right_64(t1, 39);
    x2 := t2 xor rotate_right_64(t2, 1)  xor rotate_right_64(t2, 6);
    x3 := t3 xor rotate_right_64(t3, 10) xor rotate_right_64(t3, 17);
    x4 := t4 xor rotate_right_64(t4, 7)  xor rotate_right_64(t4, 41);

    result := set_state_word(result, 0, x0);
    result := set_state_word(result, 1, x1);
    result := set_state_word(result, 2, x2);
    result := set_state_word(result, 3, x3);
    result := set_state_word(result, 4, x4);
    return result;
  end function;

  function keep_is_contiguous(keep : std_logic_vector(15 downto 0)) return boolean is
    variable seen_zero : boolean := false;
  begin
    for i in 0 to 15 loop
      if keep(i) = '0' then
        seen_zero := true;
      elsif seen_zero then
        return false;
      end if;
    end loop;
    return true;
  end function;

  function keep_count(keep : std_logic_vector(15 downto 0)) return natural is
    variable count : natural := 0;
  begin
    for i in 0 to 15 loop
      if keep(i) = '1' then
        count := count + 1;
      end if;
    end loop;
    return count;
  end function;

  function keep_mask(keep : std_logic_vector(15 downto 0)) return rate_t is
    variable result : rate_t := (others => '0');
  begin
    for i in 0 to 15 loop
      if keep(i) = '1' then
        result((8 * i) + 7 downto 8 * i) := x"FF";
      end if;
    end loop;
    return result;
  end function;

  function padding_bit(valid_bytes : natural) return rate_t is
    variable result : rate_t := (others => '0');
  begin
    if valid_bytes < 16 then
      -- Padding is the byte value 01 immediately after the final input byte.
      result(8 * valid_bytes) := '1';
    end if;
    return result;
  end function;
end package body;
