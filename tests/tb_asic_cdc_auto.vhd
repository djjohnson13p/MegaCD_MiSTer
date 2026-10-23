library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Production ASIC and CDC connected as in MCD.vhd. Only CPU bus masters and
-- synthetic buffer RAM are models. No copyrighted disc or firmware is used.
-- Oracle: krikzz/mega-ed-pub 8b72838, mcd-verificator/src/test_cdc_new.c,
-- Adjacent automatic-DMA compatibility: real destination write ports,
-- ordered data, completion flags, and address increments. PCM is optional
-- because the production PCM_HALT_WAIT counter lacks simulation initialization.
entity tb_asic_cdc_auto is
  generic (DESTINATION : natural := 5;
           TRANSFER_BYTES : positive := 32;
           SOURCE_ADDR : natural := 16#3FFC#;
           DEST_BYTEADDR : natural := 16#40#;
           PRG_DELAY : positive := 3;
           TIMEOUT_US : positive := 3000);
end entity;

architecture test of tb_asic_cdc_auto is
  constant CLOCK_PERIOD : time := 18.624 ns;
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
  function ram_byte(constant address : natural) return std_logic_vector is
  begin
    -- Physical RAM has 14 address bits. Include the high six in the pattern so
    -- an incorrect smaller wrap boundary cannot masquerade as correct data.
    return std_logic_vector(to_unsigned(address mod 256,8) xor
                            to_unsigned((address/256) mod 64,8) xor x"A5");
  end function;
  signal prg_a : std_logic_vector(17 downto 0);
  signal prg_do : std_logic_vector(15 downto 0);
  signal prg_wrl_n, prg_wrh_n : std_logic;
  signal prg_ready : std_logic := '1';
  signal wr0_a, wr1_a, wr0_do, wr1_do : std_logic_vector(15 downto 0);
  signal wr0_wr, wr1_wr : std_logic;
  signal pcm_a : std_logic_vector(12 downto 0);
  signal pcm_di : std_logic_vector(7 downto 0);
  signal pcm_we_n, pcm_n : std_logic;
  signal bytes_written : natural := 0;
  function source_byte(address : natural) return std_logic_vector is
    variable a : natural := address mod 16384;
  begin
    return std_logic_vector(to_unsigned(a mod 256,8) xor
                            to_unsigned(a/256,8) xor x"A5");
  end function;
  function source_word(offset : natural) return std_logic_vector is
  begin
    return source_byte(SOURCE_ADDR+offset) & source_byte(SOURCE_ADDR+offset+1);
  end function;
begin
  clk <= not clk after CLOCK_PERIOD/2;
  -- One registered RAM read, with unique byte pairs for advancement checks.
  process(clk) begin
    if rising_edge(clk) then
      ram_di <= ram_byte(to_integer(unsigned(ram_a)));
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
    PRG_A => prg_a, PRG_DI => x"0000", PRG_DO => prg_do,
    PRG_WRL_N => prg_wrl_n, PRG_WRH_N => prg_wrh_n, PRG_OE_N => open,
    PRG_RFS => open, PRG_RDY => prg_ready,
    PCM_A => pcm_a, PCM_DI => pcm_di, PCM_WE_N => pcm_we_n, PCM_N => pcm_n,
    ROM_DI => x"0000", ROM_CE_N => open, ROM_RDY => '1',
    PRAM_N => open, BRAM_N => open, BROM_N => open,
    CDC_N => cdc_n, COE_N => coe_n, CLWE_N => clwe_n, CUWE_N => open,
    CDC_INT_N => cdc_int_n, ERES_N => eres_n,
    CDC_HDI => cdc_hdi, CDC_HRD_N => cdc_hrd_n,
    CDC_DTEN_N => cdc_dten_n, CDC_WAIT_N => cdc_wait_n,
    CD_DI => x"0000", CD_SC_WR => '0', CDD_STAT => (others => '0'),
    CDD_COMM => open, CDD_SEND => open, CDD_REC => '0', CDD_DM => '0',
    WORDRAM0_A => wr0_a, WORDRAM0_DI => x"0000", WORDRAM0_DO => wr0_do,
    WORDRAM0_WR => wr0_wr, WORDRAM1_A => wr1_a, WORDRAM1_DI => x"0000",
    WORDRAM1_DO => wr1_do, WORDRAM1_WR => wr1_wr,
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

  -- Capture destination transactions independently from CDC completion. PRG
  -- ready must go low then high; write strobes may span many clocks.
  process(clk)
    variable prg_active, pcm_active : boolean := false;
    variable prg_release : boolean := false;
    variable busy_left : natural := 0;
    variable count, word_address : natural := 0;
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        prg_ready <= '1'; prg_active := false; pcm_active := false;
        prg_release := false; busy_left := 0; count := 0;
        bytes_written <= 0;
      else
        if prg_wrl_n = '0' or prg_wrh_n = '0' then
          if not prg_active then
            assert DESTINATION = 5 report "unexpected PRG destination write" severity failure;
            assert prg_wrl_n = '0' and prg_wrh_n = '0'
              report "PRG DMA lost a byte lane" severity failure;
            assert count < TRANSFER_BYTES report "extra PRG DMA word" severity failure;
            assert to_integer(unsigned(prg_a)) = DEST_BYTEADDR/2+count/2
              report "PRG DMA address differs" severity failure;
            assert prg_do = source_word(count) report "PRG DMA data differs" severity failure;
            count := count+2; prg_ready <= '0'; busy_left := PRG_DELAY;
            prg_active := true; prg_release := false;
          elsif busy_left > 0 then
            busy_left := busy_left-1;
          elsif not prg_release then
            prg_ready <= '1'; prg_release := true;
          end if;
        else
          prg_active := false;
        end if;
        if wr0_wr = '1' or wr1_wr = '1' then
          assert DESTINATION = 7 report "unexpected word-RAM destination write" severity failure;
          assert not (wr0_wr = '1' and wr1_wr = '1')
            report "both word-RAM banks wrote one DMA word" severity failure;
          assert count < TRANSFER_BYTES report "extra word-RAM DMA word" severity failure;
          if wr0_wr = '1' then
            word_address := to_integer(unsigned(wr0_a))*2;
            assert wr0_do = source_word(count) report "word-RAM bank0 data differs" severity failure;
          else
            word_address := to_integer(unsigned(wr1_a))*2+1;
            assert wr1_do = source_word(count) report "word-RAM bank1 data differs" severity failure;
          end if;
          assert word_address = DEST_BYTEADDR/2+count/2
            report "word-RAM DMA address differs" severity failure;
          count := count+2;
        end if;
        if pcm_n = '0' and pcm_we_n = '0' then
          if not pcm_active then
            assert DESTINATION = 4 report "unexpected PCM destination write" severity failure;
            assert count < TRANSFER_BYTES report "extra PCM DMA byte" severity failure;
            assert to_integer(unsigned(pcm_a)) = 16#1000#+DEST_BYTEADDR/2+count
              report "PCM DMA address differs" severity failure;
            assert pcm_di = source_byte(SOURCE_ADDR+count) report "PCM DMA data differs" severity failure;
            count := count+1; pcm_active := true;
          end if;
        else
          pcm_active := false;
        end if;
        bytes_written <= count;
      end if;
    end if;
  end process;

  process
    variable value, mode : std_logic_vector(15 downto 0);
    variable deadline : time;
    variable final_word_address : natural;
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
    procedure get_mode(variable result : out std_logic_vector(15 downto 0)) is
    begin main_access(16#A12004#,false,0,result); end procedure;
  begin
    assert DESTINATION = 4 or DESTINATION = 5 or DESTINATION = 7
      report "automatic destination must be PCM, PRG, or word RAM" severity failure;
    assert TRANSFER_BYTES >= 8 and TRANSFER_BYTES <= 4096 and TRANSFER_BYTES mod 8 = 0
      report "automatic DMA length must be a multiple of eight in 8..4096" severity failure;
    assert DEST_BYTEADDR mod 8 = 0 report "DMA base must align to eight bytes" severity failure;
    tick(8); rst_n <= '1'; tick(64);
    main_access(16#A12000#,true,1,value); -- SRES=1, SBRQ=0: release sub CPU/PRG DMA.
    if DESTINATION = 7 then
      main_access(16#A12002#,true,2,value); -- 2M word RAM assigned to sub side.
    end if;
    sub_access(16#FF8004#,true,DESTINATION*256,value);
    write_cdc(1,16#42#);
    write_cdc(2,(TRANSFER_BYTES-1) mod 256); write_cdc(3,(TRANSFER_BYTES-1)/256);
    write_cdc(4,SOURCE_ADDR mod 256); write_cdc(5,SOURCE_ADDR/256);
    sub_access(16#FF800A#,true,DEST_BYTEADDR/8,value);
    write_cdc(6,0);
    deadline := now + TIMEOUT_US*1 us;
    while bytes_written < TRANSFER_BYTES and now < deadline loop
      -- These real sub-CPU cycles also exercise the PCM bus-halt handshake.
      sub_access(16#FF800C#,false,0,value);
      get_mode(mode);
      if bytes_written < TRANSFER_BYTES then
        assert mode(15) = '0' report "automatic DMA EDT asserted before destination writes completed" severity failure;
      end if;
    end loop;
    assert bytes_written = TRANSFER_BYTES report "automatic DMA destination timed out before all writes" severity failure;
    tick(128); get_mode(mode);
    assert mode(15 downto 14) = "10" report "automatic DMA completion EDT/DSR differs" severity failure;
    assert mode(10 downto 8) = std_logic_vector(to_unsigned(DESTINATION,3))
      report "automatic DMA destination changed" severity failure;
    assert cdc_dten_n = '1' and cdc_int_n = '0'
      report "automatic DMA did not complete the CDC transfer" severity failure;
    sub_access(16#FF800A#,false,0,value);
    if DESTINATION = 4 then final_word_address := DEST_BYTEADDR/2+TRANSFER_BYTES;
    else final_word_address := DEST_BYTEADDR/2+TRANSFER_BYTES/2; end if;
    assert to_integer(unsigned(value)) = final_word_address/4
      report "automatic DMA destination address increment differs" severity failure;
    tick(128); get_mode(mode);
    assert mode(15 downto 14) = "10" report "automatic DMA completion flags did not persist" severity failure;
    report "PASS ASIC/CDC automatic destination " & natural'image(DESTINATION) severity note;
    stop; wait;
  end process;
  process begin
    wait for 5 ms;
    assert false report "automatic DMA bench watchdog expired" severity failure;
  end process;
end architecture;
