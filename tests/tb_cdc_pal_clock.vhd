library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Separate PAL clock test so the original CDC without PALSW can still compile
-- the unchanged NTSC fail-first bench.
entity tb_cdc_pal_clock is end entity;
architecture test of tb_cdc_pal_clock is
  constant CLOCK_PERIOD : time := 18.796 ns; -- PAL clk_sys 53.203423 MHz
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal di : std_logic_vector(7 downto 0) := x"00";
  signal cs_n, rs, wr_n : std_logic := '1';
  signal int_n : std_logic;
  signal phase : unsigned(1 downto 0) := "00";
  signal ce_p, ce_n : std_logic;
begin
  clk <= not clk after CLOCK_PERIOD/2;
  process(clk) begin if rising_edge(clk) then phase <= phase + 1; end if; end process;
  ce_p <= '1' when phase = "01" else '0';
  ce_n <= '1' when phase = "11" else '0';
  dut: entity work.CDC port map (
    CLK=>clk, RESET_N=>reset_n, ENABLE=>'1', PALSW=>'1',
    CLKEN_P=>ce_p, CLKEN_N=>ce_n, DI=>di, DO=>open, CS_N=>cs_n,
    RS=>rs, RD_N=>'1', WR_N=>wr_n, INT_N=>int_n,
    HDO=>open, HRD_N=>'1', DTEN_N=>open, WAIT_N=>open,
    CD_DI=>x"0000", CD_WR=>'0', RAM_A_WR=>open, RAM_A_RD=>open,
    RAM_DI=>x"00", RAM_DO=>open, RAM_WE=>open
  );
  process
    variable previous_edge, current_edge : time;
    procedure tick(constant cycles : positive := 1) is
    begin for i in 1 to cycles loop wait until falling_edge(clk); end loop; end procedure;
    procedure write_port(constant address_port : std_logic; constant data : natural) is
    begin
      tick; cs_n<='0'; rs<=address_port; di<=std_logic_vector(to_unsigned(data,8)); wr_n<='0';
      tick(8); wr_n<='1'; tick(8); cs_n<='1';
    end procedure;
  begin
    tick(8); reset_n<='1'; tick(8);
    write_port('0',1); write_port('1',16#20#);
    write_port('0',10); write_port('1',16#80#); write_port('1',16#E0#);
    wait until int_n='0' for 15 ms;
    assert int_n='0' report "PAL decoder interrupt missing" severity failure;
    previous_edge:=now;
    for i in 1 to 3 loop
      wait until int_n='1' for 6 ms;
      assert int_n='1' report "PAL DECI did not clear" severity failure;
      assert now-previous_edge > 5 ms and now-previous_edge < 5.7 ms
        report "PAL DECI active phase differs" severity failure;
      wait until int_n='0' for 15 ms;
      assert int_n='0' report "PAL decoder did not recur" severity failure;
      current_edge:=now;
      assert current_edge-previous_edge > 13.332 ms and current_edge-previous_edge < 13.334 ms
        report "PAL decoder recurrence is not 75Hz" severity failure;
      previous_edge:=current_edge;
    end loop;
    report "PASS CDC PAL timing" severity note; stop; wait;
  end process;
end architecture;
