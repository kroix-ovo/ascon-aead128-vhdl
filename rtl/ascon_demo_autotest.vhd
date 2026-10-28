-- Automatic physical check of the existing demo in all eight vector/mode pairs.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity ascon_demo_autotest is
 port(clk_i,rst_i,selftest_done_i,selftest_pass_i : in std_logic;
      switches_i : in std_logic_vector(9 downto 0); start_i : in std_logic;
      demo_led_i : in std_logic_vector(12 downto 0);
      switches_o : out std_logic_vector(9 downto 0); start_o : out std_logic;
      done_o,pass_o,fail_o : out std_logic;
      case_o : out std_logic_vector(2 downto 0); cycles_o : out std_logic_vector(31 downto 0));
end entity;
architecture rtl of ascon_demo_autotest is
 type state_t is (WAIT_SELFTEST, PREPARE, PULSE_START, WAIT_BUSY, WAIT_DONE, FINISHED, FAILED);
 signal state : state_t := WAIT_SELFTEST;
 signal test_id : unsigned(2 downto 0) := (others=>'0');
 signal pulse_count : natural range 0 to 3 := 0;
 signal elapsed : unsigned(31 downto 0) := (others=>'0');
 signal watchdog : natural range 0 to 4095 := 0;
begin
 done_o <= '1' when state=FINISHED or state=FAILED else '0';
 pass_o <= '1' when state=FINISHED else '0';
 fail_o <= '1' when state=FAILED else '0';
 case_o <= std_logic_vector(test_id);cycles_o<=std_logic_vector(elapsed);
 switches_o <= switches_i when done_o='1' else "0000000" & std_logic_vector(test_id);
 start_o <= start_i when done_o='1' else '1' when state=PULSE_START else '0';
 process(clk_i)
 begin
  if rising_edge(clk_i) then
   if rst_i='1' then
    state<=WAIT_SELFTEST;test_id<=(others=>'0');pulse_count<=0;elapsed<=(others=>'0');watchdog<=0;
   else
    if state/=WAIT_SELFTEST and state/=FINISHED and state/=FAILED then
     elapsed<=elapsed+1;
     if watchdog=4095 then state<=FAILED;else watchdog<=watchdog+1;end if;
    end if;
    case state is
     when WAIT_SELFTEST =>
      if selftest_done_i='1' then
       if selftest_pass_i='1' then state<=PREPARE;else state<=FAILED;end if;
      end if;
     when PREPARE => pulse_count<=3;state<=PULSE_START;watchdog<=0;
     when PULSE_START =>
      if pulse_count=0 then state<=WAIT_BUSY;else pulse_count<=pulse_count-1;end if;
     when WAIT_BUSY => if demo_led_i(8)='1' then state<=WAIT_DONE;end if;
     when WAIT_DONE =>
      if demo_led_i(9)='1' then
       if demo_led_i(10)/='1' or demo_led_i(11)='1' or demo_led_i(12)='1' then state<=FAILED;
       elsif test_id=7 then state<=FINISHED;
       else test_id<=test_id+1;state<=PREPARE;end if;
      end if;
     when others => null;
    end case;
    if watchdog=4095 and state/=FINISHED and state/=FAILED then state<=FAILED;end if;
   end if;
  end if;
 end process;
end architecture;
