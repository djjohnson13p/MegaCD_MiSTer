library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Register-level tests of the production CDC, driven only through its ports.
-- Hardware oracle: Krikzz's mcd-verificator, pinned in docs/lab-cdc-protocol.md.
entity tb_cdc_protocol is
  generic (TEST_CASE : natural := 0);
end entity;

architecture test of tb_cdc_protocol is
  constant CLOCK_PERIOD : time := 18.624 ns; -- 53.693175 MHz clk_sys
  signal clk : std_logic := '0';
  signal reset_n, enable : std_logic := '0';
  signal ce_p, ce_n : std_logic := '0';
  signal di, dout, hdo, ram_di : std_logic_vector(7 downto 0) := x"00";
  signal cs_n, rs, rd_n, wr_n : std_logic := '1';
  signal int_n, dten_n, wait_n : std_logic;
  signal hrd_n : std_logic := '1';
  signal cd_di, ram_do : std_logic_vector(15 downto 0) := x"0000";
  signal cd_wr, ram_we : std_logic := '0';
  signal ram_a_wr : std_logic_vector(15 downto 1);
  signal ram_a_rd : std_logic_vector(15 downto 0);
  signal clock_phase : unsigned(1 downto 0) := "00";
  signal ram_write_count : natural := 0;
begin
  clk <= not clk after CLOCK_PERIOD/2;
  ce_p <= '1' when clock_phase = "01" else '0';
  ce_n <= '1' when clock_phase = "11" else '0';
  process(clk) begin
    if rising_edge(clk) then
      clock_phase <= clock_phase + 1;
      if ram_we = '1' then ram_write_count <= ram_write_count + 1; end if;
    end if;
  end process;
  -- Synthetic buffer data makes DMA addressing/data checks independent of CDs.
  ram_di <= std_logic_vector(unsigned(ram_a_rd(7 downto 0)) xor x"A5");

  dut: entity work.CDC port map (
    CLK => clk, RESET_N => reset_n, ENABLE => enable,
    CLKEN_P => ce_p, CLKEN_N => ce_n,
    DI => di, DO => dout, CS_N => cs_n, RS => rs, RD_N => rd_n,
    WR_N => wr_n, INT_N => int_n, HDO => hdo, HRD_N => hrd_n,
    DTEN_N => dten_n, WAIT_N => wait_n, CD_DI => cd_di, CD_WR => cd_wr,
    RAM_A_WR => ram_a_wr, RAM_A_RD => ram_a_rd, RAM_DI => ram_di,
    RAM_DO => ram_do, RAM_WE => ram_we
  );

  process
    variable value : std_logic_vector(7 downto 0);
    variable first_edge, previous_edge, edge_time : time;
    procedure tick(constant cycles : positive := 1) is
    begin
      for i in 1 to cycles loop wait until falling_edge(clk); end loop;
    end procedure;
    procedure write_port(constant register_port : std_logic;
                         constant data : std_logic_vector(7 downto 0)) is
    begin
      tick; cs_n <= '0'; rs <= register_port; di <= data; wr_n <= '0';
      tick(8); wr_n <= '1'; tick(8); cs_n <= '1';
    end procedure;
    procedure write_reg(constant address, data : natural) is
    begin
      write_port('0', std_logic_vector(to_unsigned(address,8)));
      write_port('1', std_logic_vector(to_unsigned(data,8)));
    end procedure;
    procedure read_reg(constant address : natural;
                       variable data : out std_logic_vector(7 downto 0)) is
    begin
      write_port('0', std_logic_vector(to_unsigned(address,8)));
      tick; cs_n <= '0'; rs <= '1'; rd_n <= '0';
      tick(8); data := dout; rd_n <= '1'; tick(8); cs_n <= '1';
    end procedure;
    procedure sector is
    begin
      -- A real raw CD frame, with no game or BIOS data.
      for i in 0 to 1175 loop
        cd_di <= std_logic_vector(to_unsigned(i,16)); cd_wr <= '1';
        tick(8); cd_wr <= '0'; tick(8);
      end loop;
    end procedure;
    procedure decoder_on(constant sync_interrupt : boolean := true) is
    begin
      write_reg(1,16#20#); -- DECIEN
      write_reg(10,16#80#); -- DECEN
      if sync_interrupt then write_reg(11,16#E0#); end if;
    end procedure;
    procedure await_interrupt(variable stamp : out time) is
    begin
      wait until int_n = '0' for 15 ms;
      assert int_n = '0' report "decoder interrupt missing without CD sectors" severity failure;
      stamp := now;
    end procedure;
  begin
    tick(8); reset_n <= '1'; enable <= '1'; tick(8);
    case TEST_CASE is
      when 0 =>
        read_reg(1,value);
        assert value = x"FF" report "reset IFSTAT differs" severity failure;
        assert int_n = '1' and dten_n = '1' report "reset raised an event" severity failure;

      when 1 =>
        -- test_cdc_new.c:1177-1183: recurring decoder IRQ, without STAT3 ack.
        decoder_on;
        await_interrupt(first_edge); previous_edge := first_edge;
        for i in 1 to 3 loop
          wait until int_n = '1' for 6 ms;
          assert int_n = '1' report "DECI did not automatically clear" severity failure;
          assert now-previous_edge > 5 ms and now-previous_edge < 5.7 ms
            report "DECI active phase is not about 40% of a 75Hz frame" severity failure;
          await_interrupt(edge_time);
          assert edge_time-previous_edge > 13.332 ms and edge_time-previous_edge < 13.334 ms
            report "decoder recurrence is not 75Hz" severity failure;
          previous_edge := edge_time;
        end loop;

      when 2 =>
        -- test_cdc.c:181-184: DECEN alone cannot insert syncs. Both SYIEN
        -- and SYDEN are off here, so this input cannot supply a detected sync.
        decoder_on(false); sector;
        wait for 28 ms;
        read_reg(1,value);
        assert value(5) = '1' and int_n = '1'
          report "decoder event generated with SYIEN disabled" severity failure;

      when 3 =>
        -- test_cdc.c:273-277: disabling DECEN releases DECI immediately.
        decoder_on; sector;
        assert int_n = '0' report "synthetic sector did not raise decoder event" severity failure;
        write_reg(10,0); read_reg(1,value);
        assert value(5) = '1' and int_n = '1'
          report "disabling DECEN left decoder interrupt pending" severity failure;

      when 4 =>
        -- test_cdc_new.c:1280-1294: IFSTAT toggles with DECIEN masked.
        write_reg(10,16#80#); write_reg(11,16#E0#);
        wait for 14 ms;
        read_reg(1,value);
        assert value(5) = '0' report "masked decoder did not update IFSTAT" severity failure;
        assert int_n = '1' report "DECIEN mask did not suppress pin" severity failure;
        read_reg(15,value); read_reg(1,value);
        assert value(5) = '1' report "STAT3 did not acknowledge DECI" severity failure;

      when 5 =>
        -- Existing transfer completion must remain unchanged. HRD is the ASIC's
        -- byte prefetch, so DTEI after this final byte precedes the CPU's final
        -- word read; it must not be moved earlier based on a CPU-level guess.
        write_reg(1,16#42#); -- DOUTEN + DTEIEN
        write_reg(2,3); write_reg(3,0); -- four bytes, count-1
        write_reg(4,16#FC#); write_reg(5,0); write_reg(6,0);
        for i in 0 to 3 loop
          wait until wait_n = '1' and dten_n = '0' for 10 us;
          assert wait_n = '1' and dten_n = '0' report "DMA byte missing" severity failure;
          assert hdo = std_logic_vector(to_unsigned(16#FC#+i,8) xor x"A5")
            report "DMA source data/address differs" severity failure;
          assert int_n = '1' report "transfer interrupt too early" severity failure;
          tick(11+i); hrd_n <= '0';
          wait until wait_n = '0' for 10 us;
          assert wait_n = '0' report "DMA host request ignored" severity failure;
          tick(9); hrd_n <= '1'; tick(20);
        end loop;
        assert int_n = '0' and dten_n = '1' report "transfer completion missing" severity failure;
        read_reg(2,value);
        assert value = x"FF" report "DBC did not underflow after last byte" severity failure;
        write_reg(7,0);
        assert int_n = '1' report "DTACK failed to acknowledge transfer" severity failure;

      when 6 =>
        -- Acknowledge STAT3 mid-frame, without restarting the 75Hz cadence.
        decoder_on; await_interrupt(first_edge);
        wait for 1 ms;
        read_reg(15,value);
        assert int_n = '1' report "STAT3 did not release decoder interrupt" severity failure;
        await_interrupt(edge_time);
        assert edge_time-first_edge > 13.332 ms and edge_time-first_edge < 13.334 ms
          report "STAT3 acknowledge changed decoder period" severity failure;

      when 7 =>
        -- Enabling only the interrupt mask cannot start a disabled decoder.
        write_reg(1,16#20#); write_reg(11,16#E0#);
        wait for 28 ms;
        read_reg(1,value);
        assert value(5) = '1' and int_n = '1'
          report "disabled decoder generated event" severity failure;

      when 8 =>
        -- Keep the sector buffer/header path intact while SYIEN is disabled.
        write_reg(10,16#84#); -- DECEN + WRRQ
        sector; tick(16);
        assert ram_write_count = 1026 report "sector buffer word count differs" severity failure;
        read_reg(4,value); assert value = x"06" report "HEAD0 differs" severity failure;
        read_reg(5,value); assert value = x"00" report "HEAD1 differs" severity failure;
        read_reg(6,value); assert value = x"07" report "HEAD2 differs" severity failure;
        read_reg(7,value); assert value = x"00" report "HEAD3 differs" severity failure;
        read_reg(8,value); assert value = x"30" report "PT low differs" severity failure;
        read_reg(9,value); assert value = x"09" report "PT high differs" severity failure;

      when 9 =>
        -- Sanyo CTRL1 documentation: sync-hunt mode detects actual sectors
        -- with SYDEN, without inserting missing syncs via SYIEN.
        decoder_on(false); write_reg(11,16#40#); sector;
        assert int_n = '0' report "SYDEN-only sector did not raise decoder event" severity failure;
        wait until int_n = '1' for 6 ms;
        assert int_n = '1' report "SYDEN-only event did not clear" severity failure;
        wait for 28 ms;
        assert int_n = '1' report "SYDEN-only mode inserted an absent sync" severity failure;

      when 10 =>
        -- IFCTRL masks the pin; it does not acknowledge the IFSTAT event.
        decoder_on; await_interrupt(first_edge);
        write_reg(1,0); read_reg(1,value);
        assert int_n = '1' and value(5) = '0'
          report "masking DECIEN acknowledged decoder status" severity failure;
        write_reg(1,16#20#);
        assert int_n = '0' report "unmasking pending DECI did not assert pin" severity failure;

      when 11 =>
        -- Preserve existing sector event priority over a simultaneous STAT3
        -- acknowledge. Drive the actual final word and read edge together.
        decoder_on;
        for i in 0 to 1174 loop
          cd_di <= std_logic_vector(to_unsigned(i,16)); cd_wr <= '1';
          tick(8); cd_wr <= '0'; tick(8);
        end loop;
        write_port('0',x"0F");
        tick; cs_n <= '0'; rs <= '1'; rd_n <= '0'; cd_wr <= '1';
        tick(8); rd_n <= '1'; cd_wr <= '0'; tick(8); cs_n <= '1';
        assert int_n = '0' report "STAT3 acknowledge erased simultaneous sector event" severity failure;

      when 12 =>
        -- A delayed sector burst straddles the nominal idle timer expiry.
        -- Do not notify software while HEAD/PT still describe the old sector.
        decoder_on; wait for 13.1 ms;
        for i in 0 to 1174 loop
          cd_di <= std_logic_vector(to_unsigned(i,16)); cd_wr <= '1';
          tick(8); cd_wr <= '0'; tick(8);
          assert int_n = '1' report "idle timer announced a partially delivered sector" severity failure;
        end loop;
        cd_wr <= '1'; tick(8); cd_wr <= '0'; tick(8);
        assert int_n = '0' report "delayed sector completion was lost" severity failure;

      when 13 =>
        -- A partial HPS packet must not suspend the internal sync forever.
        decoder_on;
        cd_wr <= '1'; tick(8); cd_wr <= '0'; tick(8);
        await_interrupt(first_edge);
        wait until int_n = '1' for 6 ms;
        assert int_n = '1' report "partial packet decoder event did not clear" severity failure;
        await_interrupt(edge_time);
        assert edge_time-first_edge > 13.332 ms and edge_time-first_edge < 13.334 ms
          report "partial packet stopped decoder recurrence" severity failure;

      when others => assert false report "unknown TEST_CASE" severity failure;
    end case;
    report "PASS CDC case " & integer'image(TEST_CASE) severity note;
    stop;
    wait;
  end process;
end architecture;
