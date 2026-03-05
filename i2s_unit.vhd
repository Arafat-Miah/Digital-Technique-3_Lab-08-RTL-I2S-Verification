-------------------------------------------------------------------------------
-- i2s_unit.vhd: VHDL RTL model for the i2s_unit
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2s_unit is
  port (
    clk       : in  std_logic;
    rst_n     : in  std_logic;
    play_in   : in  std_logic;
    tick_in   : in  std_logic;
    audio0_in : in  std_logic_vector(23 downto 0);
    audio1_in : in  std_logic_vector(23 downto 0);
    req_out   : out std_logic;
    ws_out    : out std_logic;
    sck_out   : out std_logic;
    sdo_out   : out std_logic
  );
end i2s_unit;

architecture RTL of i2s_unit is

  -- Timing constants based on a 384-clock-cycle frame (18.432 MHz clk / 48 kHz audio)
  constant CTR_MAX_C     : unsigned(8 downto 0) := to_unsigned(383, 9);
  constant LOAD_C        : unsigned(8 downto 0) := to_unsigned(3, 9);   -- Trigger point to load shift register and request next sample
  constant END_C         : unsigned(8 downto 0) := to_unsigned(7, 9);   -- Point where the frame is considered completely finished
  constant WS_HI_START_C : unsigned(8 downto 0) := to_unsigned(188, 9); -- Word Select rises 1 SCK period before right channel data
  constant WS_HI_END_C   : unsigned(8 downto 0) := to_unsigned(380, 9); -- Word Select falls 1 SCK period before left channel data

  -- These names are expected by the provided SVA bindings
  signal play_mode_r : std_logic;
  signal ctr_r       : unsigned(8 downto 0);
  signal in_reg_r    : std_logic_vector(47 downto 0);
  signal shreg_r     : std_logic_vector(47 downto 0);

  signal play_mode_n : std_logic;
  signal ctr_n       : unsigned(8 downto 0);
  signal in_reg_n    : std_logic_vector(47 downto 0);
  signal shreg_n     : std_logic_vector(47 downto 0);

begin

  -----------------------------------------------------------------------------
  -- Next-state combinational logic
  -- This process calculates the next state (_n) for all registers.
  -- It handles the I2S state machine, counting, and data movement.
  -----------------------------------------------------------------------------
  next_p : process(play_mode_r, ctr_r, in_reg_r, shreg_r,
                   play_in, tick_in, audio0_in, audio1_in)
  begin
    -- 1. Default assignments to prevent unintended latches during synthesis
    play_mode_n <= play_mode_r;
    ctr_n       <= ctr_r;
    in_reg_n    <= in_reg_r;
    shreg_n     <= shreg_r;

    if play_mode_r = '0' then
      -- ==========================================
      -- STANDBY MODE LOGIC
      -- ==========================================
      -- Wait for play_in to go high to start operation
      play_mode_n <= play_in;
      ctr_n       <= (others => '0');
      shreg_n     <= (others => '0');

      -- If play is requested, check if a sample is ready to be loaded immediately
      if play_in = '1' then
        if tick_in = '1' then
          in_reg_n <= audio0_in & audio1_in; -- Concatenate left and right channels
        else
          in_reg_n <= (others => '0');
        end if;
      else
        in_reg_n <= (others => '0');
      end if;

    else
      -- ==========================================
      -- PLAY MODE LOGIC
      -- ==========================================
      
      -- A. Input Register Handling: Capture incoming stereo samples when requested
      if (tick_in = '1') and (play_in = '1') then
        in_reg_n <= audio0_in & audio1_in;
      end if;

      -- B. Shift Register Handling: Load new frame or shift current frame
      if ctr_r = LOAD_C then
        -- Load the newly fetched audio frame into the shift register
        if play_in = '1' then
          shreg_n <= in_reg_r;
        end if;
      elsif ctr_r(2 downto 0) = "011" then
        -- Shift data left by 1 bit. This happens when the last 3 bits are 3, 11, 19...
        -- which perfectly aligns the data shift with the falling edge of the serial clock.
        shreg_n <= shreg_r(46 downto 0) & '0';
      end if;

      -- C. Stop / Wrap-around Logic
      if (ctr_r = END_C) and (play_in = '0') then
        -- Graceful stop: Do not cut off audio abruptly. 
        -- Wait until the current frame finishes, then safely return to standby.
        play_mode_n <= '0';
        ctr_n       <= (others => '0');
        in_reg_n    <= (others => '0');
        shreg_n     <= (others => '0');
      else
        -- Continue playing
        play_mode_n <= '1';

        -- Wrap the counter back to 0 at the end of the 384-clock frame
        if ctr_r = CTR_MAX_C then
          ctr_n <= (others => '0');
        else
          ctr_n <= ctr_r + 1;
        end if;
      end if;
    end if;
  end process next_p;

  -----------------------------------------------------------------------------
  -- Register process (Sequential Logic)
  -- This process physically updates the D-flip-flops on the rising clock edge.
  -----------------------------------------------------------------------------
  regs_p : process(clk, rst_n)
  begin
    if rst_n = '0' then
      -- Asynchronous active-low reset: Clear all memory elements
      play_mode_r <= '0';
      ctr_r       <= (others => '0');
      in_reg_r    <= (others => '0');
      shreg_r     <= (others => '0');

    elsif rising_edge(clk) then
      -- Update current state (_r) with calculated next state (_n)
      play_mode_r <= play_mode_n;
      ctr_r       <= ctr_n;
      in_reg_r    <= in_reg_n;
      shreg_r     <= shreg_n;
    end if;
  end process regs_p;

  -----------------------------------------------------------------------------
  -- Output logic (Combinational)
  -- Directly drives the external ports based on the current internal state.
  -----------------------------------------------------------------------------
  
  -- Request a new sample at the exact cycle we load the shift register (Creates a 1-frame pipeline)
  req_out <= '1' when (play_mode_r = '1') and (play_in = '1') and (ctr_r = LOAD_C)
             else '0';

  -- Serial Clock (SCK): Divides the system clock by 8. High for 4 cycles, Low for 4 cycles.
  sck_out <= '1' when (play_mode_r = '1') and (ctr_r(2) = '0')
             else '0';

  -- Word Select (WS): High for right channel, Low for left channel.
  -- Boundaries incorporate the mandatory I2S 1-bit delay prior to data transmission.
  ws_out <= '1' when (play_mode_r = '1') and
                     (ctr_r >= WS_HI_START_C) and
                     (ctr_r <  WS_HI_END_C)
            else '0';

  -- Serial Data Out (SDO): Always transmits the Most Significant Bit (MSB) of the shift register.
  sdo_out <= shreg_r(47) when (play_mode_r = '1')
             else '0';

end RTL;
