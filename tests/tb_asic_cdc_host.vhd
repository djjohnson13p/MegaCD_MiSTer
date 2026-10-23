library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Production ASIC and CDC connected as in MCD.vhd. Only CPU bus masters and
-- synthetic buffer RAM are models. No copyrighted disc or firmware is used.
-- Oracle: krikzz/mega-ed-pub 8b72838, mcd-verificator/src/test_cdc_new.c,
-- testCDC_dma3: flags 0x01-0x21 and write-to-skip tests 0x60-0x63.
entity tb_asic_cdc_host is
  generic (TEST_CASE : natural := 0;
           TRANSFER_BYTES : positive := 8;
           SOURCE_ADDR : natural := 0);
end entity;

architecture test of tb_asic_cdc_host is
  constant CLOCK_PERIOD : time := 18.624 ns;
  constant WORDS : positive := TRANSFER_BYTES/2;
  signal clk : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal enable : std_logic := '1';
  signal sa : std_logic_vector(23 downto 1) := (others => '0');
  signal sdi, sdo : std_logic_vector(15 downto 0) := (others => '0');
  signal sas_n, srnw, suds_n, slds_n : std_logic := '1';
  signal sdtack_n, sce_f, sce_r, eres_n : std_logic;
  signal ma : std_logic_vector(17 downto 1) := (others => '0');
  signal mdi, mdo : std_logic_vector(15 downto 0) := (others => '0');
  signal mas_n, mrnw, muds_n, mlds_n, mfdc_n : std_logic := '1';
  signal mdtack_n : std_logic;
  signal cdc_n, coe_n, clwe_n, cdc_int_n : std_logic;
  signal cdc_hdi, cdc_do, ram_di : std_logic_vector(7 downto 0);
  signal cdc_hrd_n, cdc_dten_n, cdc_wait_n : std_logic;
  signal ram_a : std_logic_vector(15 downto 0);
begin
  clk <= not clk after CLOCK_PERIOD/2;
  -- One registered RAM read, with unique byte pairs for advancement checks.
  process(clk) begin
    if rising_edge(clk) then
      ram_di <= std_logic_vector(unsigned(ram_a(7 downto 0)) xor x"A5");
    end if;
  end process;

  asic: entity work.ASIC port map (
    CLK => clk, RST_N => rst_n, ENABLE => enable,
    S68K_A => sa, S68K_DI => sdi, S68K_DO => sdo,
    S68K_AS_N => sas_n, S68K_RNW => srnw, S68K_UDS_N => suds_n,
    S68K_LDS_N => slds_n, S68K_DTACK_N => sdtack_n,
    S68K_IPL_N => open, S68K_VPA_N => open, S68K_FC => "01",
    S68K_HALT_N => open, S68K_RESET_N => open,
    S68K_CE_F => sce_f, S68K_CE_R => sce_r,
    EXT_VA => ma, EXT_VDI => mdi, EXT_VDO => mdo,
    EXT_AS_N => mas_n, EXT_RNW => mrnw, EXT_UDS_N => muds_n,
    EXT_LDS_N => mlds_n, EXT_DTACK_N => mdtack_n,
    EXT_ASEL_N => '1', EXT_VCLK_CE => '0', EXT_RAS2_N => '1',
    EXT_ROM_N => '1', EXT_FDC_N => mfdc_n,
    PRG_A => open, PRG_DI => x"0000", PRG_DO => open,
    PRG_WRL_N => open, PRG_WRH_N => open, PRG_OE_N => open,
    PRG_RFS => open, PRG_RDY => '1',
    PCM_A => open, PCM_DI => open, PCM_WE_N => open, PCM_N => open,
    ROM_DI => x"0000", ROM_CE_N => open, ROM_RDY => '1',
    PRAM_N => open, BRAM_N => open, BROM_N => open,
    CDC_N => cdc_n, COE_N => coe_n, CLWE_N => clwe_n, CUWE_N => open,
    CDC_INT_N => cdc_int_n, ERES_N => eres_n,
    CDC_HDI => cdc_hdi, CDC_HRD_N => cdc_hrd_n,
    CDC_DTEN_N => cdc_dten_n, CDC_WAIT_N => cdc_wait_n,
    CD_DI => x"0000", CD_SC_WR => '0', CDD_STAT => (others => '0'),
    CDD_COMM => open, CDD_SEND => open, CDD_REC => '0', CDD_DM => '0',
    WORDRAM0_A => open, WORDRAM0_DI => x"0000", WORDRAM0_DO => open,
    WORDRAM0_WR => open, WORDRAM1_A => open, WORDRAM1_DI => x"0000",
    WORDRAM1_DO => open, WORDRAM1_WR => open,
    FD_DAT => open, FD_WR => open, LED_RED => open, LED_GREEN => open
  );
  cdc: entity work.CDC port map (
    CLK => clk, RESET_N => eres_n, ENABLE => enable,
    CLKEN_P => sce_r, CLKEN_N => sce_f,
    DI => sdi(7 downto 0), DO => cdc_do, CS_N => cdc_n,
    RS => sa(1), RD_N => coe_n, WR_N => clwe_n, INT_N => cdc_int_n,
    HDO => cdc_hdi, HRD_N => cdc_hrd_n, DTEN_N => cdc_dten_n,
    WAIT_N => cdc_wait_n, CD_DI => x"0000", CD_WR => '0',
    RAM_A_WR => open, RAM_A_RD => ram_a, RAM_DI => ram_di,
    RAM_DO => open, RAM_WE => open
  );

  process
    variable value, mode : std_logic_vector(15 downto 0);
    variable destination : natural;
    variable use_sub : boolean;
    procedure tick(constant n : positive := 1) is
    begin
      for i in 1 to n loop wait until falling_edge(clk); end loop;
    end procedure;
    procedure sub_access(constant address : natural;
                         constant is_write : boolean;
                         constant data : natural;
                         variable result : out std_logic_vector(15 downto 0);
                         constant hold_cycles : positive := 16) is
    begin
      sa <= std_logic_vector(to_unsigned(address/2,23));
      sdi <= std_logic_vector(to_unsigned(data,16));
      if is_write then srnw <= '0'; else srnw <= '1'; end if;
      sas_n <= '0'; suds_n <= '0'; slds_n <= '0';
      tick(hold_cycles);
      assert sdtack_n = '0' report "sub CPU bus was not acknowledged" severity failure;
      if cdc_n = '0' then result := x"00" & cdc_do; else result := sdo; end if;
      sas_n <= '1'; suds_n <= '1'; slds_n <= '1'; srnw <= '1'; tick(64);
    end procedure;
    procedure main_access(constant address : natural;
                          constant is_write : boolean;
                          constant data : natural;
                          variable result : out std_logic_vector(15 downto 0);
                          constant hold_cycles : positive := 16) is
    begin
      ma <= std_logic_vector(to_unsigned((address mod 16#40000#)/2,17));
      mdi <= std_logic_vector(to_unsigned(data,16));
      if is_write then mrnw <= '0'; else mrnw <= '1'; end if;
      mas_n <= '0'; muds_n <= '0'; mlds_n <= '0'; mfdc_n <= '0';
      tick(hold_cycles);
      assert mdtack_n = '0' report "main CPU bus was not acknowledged" severity failure;
      result := mdo;
      mas_n <= '1'; muds_n <= '1'; mlds_n <= '1'; mfdc_n <= '1';
      mrnw <= '1'; tick(64);
    end procedure;
    procedure write_cdc(constant address, data : natural) is
      variable unused : std_logic_vector(15 downto 0);
    begin
      -- x004 low byte selects the CDC internal register without changing DD.
      sa <= std_logic_vector(to_unsigned(16#FF8004#/2,23)); sdi <= x"00" & std_logic_vector(to_unsigned(address,8));
      sas_n <= '0'; suds_n <= '1'; slds_n <= '0'; srnw <= '0';
      tick(16); sas_n <= '1'; slds_n <= '1'; srnw <= '1'; tick(16);
      sub_access(16#FF8006#,true,data,unused);
    end procedure;
    procedure host_access(constant from_sub, is_write : boolean;
                          variable result : out std_logic_vector(15 downto 0);
                          constant hold_cycles : positive := 16) is
    begin
      if from_sub then sub_access(16#FF8008#,is_write,16#DEAD#,result,hold_cycles);
      else main_access(16#A12008#,is_write,16#DEAD#,result,hold_cycles); end if;
    end procedure;
    procedure get_mode(variable result : out std_logic_vector(15 downto 0)) is
    begin
      main_access(16#A12004#,false,0,result);
    end procedure;
    function word_at(constant offset : natural) return std_logic_vector is
    begin
      return std_logic_vector(to_unsigned((SOURCE_ADDR+offset) mod 256,8) xor x"A5") &
             std_logic_vector(to_unsigned((SOURCE_ADDR+offset+1) mod 256,8) xor x"A5");
    end function;
  begin
    assert TRANSFER_BYTES >= 8 and TRANSFER_BYTES <= 4096 and (TRANSFER_BYTES mod 2) = 0
      report "test requires an even transfer length of 8..4096 bytes" severity failure;
    tick(8); rst_n <= '1'; tick(64);
    use_sub := (TEST_CASE mod 2) = 1;
    if use_sub then destination := 3; else destination := 2; end if;
    sub_access(16#FF8004#,true,destination*256,value);
    write_cdc(1,16#42#); -- DOUTEN and DTEIEN
    write_cdc(2,(TRANSFER_BYTES-1) mod 256); write_cdc(3,(TRANSFER_BYTES-1)/256);
    write_cdc(4,SOURCE_ADDR mod 256); write_cdc(5,SOURCE_ADDR/256);
    if TEST_CASE = 10 or TEST_CASE = 11 then
      get_mode(mode);
      assert mode(15 downto 14) = "00"
        report "EDT reasserted before a transfer after mode setup" severity failure;
      report "PASS ASIC/CDC host case " & natural'image(TEST_CASE) severity note;
      stop; wait;
    end if;
    write_cdc(6,0); tick(128);
    get_mode(mode);
    assert mode(14) = '1' and mode(10 downto 8) = std_logic_vector(to_unsigned(destination,3))
      report "transfer did not fill the host buffer" severity failure;

    case TEST_CASE is
      when 0 | 1 =>
        for i in 0 to WORDS-1 loop
          host_access(use_sub,false,value);
          assert value = word_at(i*2) report "normal host read data differs" severity failure;
        end loop;
        get_mode(mode);
        assert mode(15 downto 14) = "10" report "finished host read flags differ" severity failure;
      when 2 | 3 =>
        for i in 0 to WORDS/2-1 loop host_access(use_sub,true,value); end loop;
        for i in WORDS/2 to WORDS-1 loop
          host_access(use_sub,false,value);
          assert value = word_at(i*2) report "host writes did not skip the expected word prefix" severity failure;
        end loop;
        get_mode(mode);
        assert mode(15 downto 14) = "10" report "write-skip transfer did not finish" severity failure;
      when 4 | 5 =>
        for i in 0 to WORDS-2 loop
          get_mode(mode);
          assert mode(15 downto 14) = "01" report "EDT asserted before final buffered word" severity failure;
          host_access(use_sub,false,value);
        end loop;
        get_mode(mode);
        assert mode(15 downto 14) = "11" report "EDT missing while final host word is buffered" severity failure;
        host_access(use_sub,false,value);
        assert value = word_at((WORDS-1)*2) report "EDT truncated the final host word" severity failure;
        get_mode(mode);
        assert mode(15 downto 14) = "10" report "DSR did not clear after final read" severity failure;
      when 6 | 7 =>
        for i in 0 to 3 loop
          host_access(not use_sub,true,value); host_access(not use_sub,false,value);
        end loop;
        host_access(use_sub,false,value);
        assert value = word_at(0) report "wrong CPU advanced the host word" severity failure;
      when 8 | 9 =>
        host_access(use_sub,true,value,512);
        host_access(use_sub,false,value);
        assert value = word_at(2) report "held write did not skip exactly one word" severity failure;
      when 12 | 13 | 16 | 17 | 18 | 19 =>
        for i in 0 to WORDS-1 loop host_access(use_sub,false,value); end loop;
        get_mode(mode);
        assert mode(15 downto 14) = "10" report "transfer completion prerequisite failed" severity failure;
        if TEST_CASE = 12 or TEST_CASE = 13 then
          sub_access(16#FF8004#,true,destination*256,value);
          get_mode(mode);
          assert mode(15 downto 14) = "00"
            report "mode write did not leave EDT cleared" severity failure;
        elsif TEST_CASE = 16 or TEST_CASE = 17 then
          sub_access(16#FF800A#,true,16#1234#,value);
          get_mode(mode);
          assert mode(15 downto 14) = "10"
            report "DMA address write changed completed EDT" severity failure;
        else
          write_cdc(7,0); -- DTACK is distinct from gate-array EDT.
          get_mode(mode);
          assert mode(15 downto 14) = "10" report "DTACK changed EDT" severity failure;
          write_cdc(15,0); get_mode(mode);
          assert mode(15 downto 14) = "10" report "CDC reset changed EDT" severity failure;
        end if;
      when 14 | 15 =>
        -- testCDC_flags 0x11-0x12: terminate CDC and deselect destination.
        write_cdc(1,0);
        sub_access(16#FF8004#,true,0,value); get_mode(mode);
        assert mode(15 downto 14) = "00" report "mode deselect left abort status set" severity failure;
      when others => assert false report "unknown TEST_CASE" severity failure;
    end case;
    report "PASS ASIC/CDC host case " & natural'image(TEST_CASE) severity note;
    stop;
    wait;
  end process;
  process begin
    wait for 10 ms;
    assert false report "ASIC/CDC host test timed out" severity failure;
  end process;
end architecture;
