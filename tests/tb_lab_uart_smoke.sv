`timescale 1ns/1ps
module tb_lab_uart_smoke;
parameter integer DIV = 13;
parameter integer SOURCE_CLOCK_HZ = DIV*9600;
parameter integer START_CYCLES = 37;
parameter integer GAP_CYCLES = 41;
parameter integer FRAMES = 4;
parameter integer SAMPLE_PERCENT = 50;
localparam real CLOCK_NS = 10.0;
localparam real BIT_NS = DIV * CLOCK_NS;
reg clk = 0;
reg reset = 1;
wire tx;
integer packets = 0;
real reset_released, last_start, previous_stop;

always #(CLOCK_NS/2.0) clk = ~clk;
lab_uart_smoke_tx #(.CLOCK_HZ(SOURCE_CLOCK_HZ), .BAUD(9600),
    .STARTUP_CYCLES(START_CYCLES), .GAP_CYCLES(GAP_CYCLES), .FRAME_COUNT(FRAMES)) dut
    (.clk(clk), .reset(reset), .tx(tx));

task automatic receive_byte(output reg [7:0] value);
    integer bit_number;
    begin
        @(negedge tx);
        last_start = $realtime;
        #(BIT_NS*SAMPLE_PERCENT/100.0);
        if (tx !== 0) $fatal(1, "Start bit missing");
        for (bit_number=0; bit_number<8; bit_number=bit_number+1) begin
            #(BIT_NS);
            if (tx !== 0 && tx !== 1) $fatal(1, "Unknown data bit");
            value[bit_number] = tx;
        end
        #(BIT_NS);
        if (tx !== 1) $fatal(1, "Stop bit missing");
        // Finish just before the stop cell ends, so a back-to-back start is seen.
        #(BIT_NS*(99-SAMPLE_PERCENT)/100.0);
        if (tx !== 1) $fatal(1, "Stop bit ended early");
    end
endtask

task automatic receive_burst;
    integer frame_number, byte_number;
    reg [127:0] golden;
    reg [7:0] actual, expected;
    begin
        for (frame_number=0; frame_number<FRAMES; frame_number=frame_number+1) begin
            golden = 128'h555555554d434455415254310100a40a;
            golden[23:16] = frame_number;
            golden[15:8] = frame_number ^ 8'ha4;
            for (byte_number=0; byte_number<16; byte_number=byte_number+1) begin
                receive_byte(actual);
                if (byte_number == 0) begin
                    if (frame_number == 0) begin
                        if (last_start - reset_released < ((START_CYCLES>0 ? START_CYCLES : 1)+1)*CLOCK_NS ||
                            last_start - reset_released > ((START_CYCLES>0 ? START_CYCLES : 1)+2)*CLOCK_NS)
                            $fatal(1, "Startup interval or synchronized reset release differs");
                    end else if (last_start - previous_stop < (GAP_CYCLES>0 ? GAP_CYCLES : 1)*CLOCK_NS-0.1 ||
                                 last_start - previous_stop > (GAP_CYCLES>0 ? GAP_CYCLES : 1)*CLOCK_NS+0.1)
                        $fatal(1, "Inter-frame idle interval differs");
                end
                expected = golden >> ((15-byte_number)*8);
                if (actual !== expected)
                    $fatal(1, "Frame %0d byte %0d expected %02x got %02x", frame_number, byte_number, expected, actual);
            end
            previous_stop = last_start + 10*BIT_NS;
            packets = packets + 1;
        end
        // A finite burst must remain at idle mark indefinitely after completion.
        repeat ((GAP_CYCLES + 160*DIV)*2) begin
            @(posedge clk);
            #1;
            if (tx !== 1) $fatal(1, "Output restarted after final frame");
        end
    end
endtask

initial begin
    if (DIV < 1 || START_CYCLES < 0 || GAP_CYCLES < 0 || FRAMES < 1 || FRAMES > 256 ||
        SAMPLE_PERCENT < 40 || SAMPLE_PERCENT > 60) $fatal(1, "Invalid test case");
    repeat(4) @(negedge clk);
    reset = 0;
    reset_released = $realtime;
    receive_burst();

    // Assert reset partway through a character; discard that partial character.
    // The next release must restart the bounded sequence from frame zero.
    @(negedge clk); reset = 1;
    repeat(4) @(negedge clk);
    reset = 0;
    reset_released = $realtime;
    @(negedge tx);
    #(BIT_NS*3.1);
    reset = 1;
    repeat(4) @(negedge clk);
    if (tx !== 1) $fatal(1, "Reset did not return to idle mark");
    reset = 0;
    reset_released = $realtime;
    receive_burst();
    $display("UART_SMOKE_PASS frames=%0d DIV=%0d sample=%0d", packets, DIV, SAMPLE_PERCENT);
    $finish;
end

initial begin
    #((START_CYCLES*4 + (FRAMES+5)*(160*DIV+GAP_CYCLES)*4 + 1000)*CLOCK_NS);
    $fatal(1, "UART smoke simulation watchdog expired");
end
endmodule
