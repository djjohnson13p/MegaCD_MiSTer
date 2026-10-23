// SPDX-License-Identifier: GPL-2.0-or-later
// Optional transport smoke test. No receive, flow-control or core-state inputs.
module lab_uart_smoke_tx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD = 9_600,
    parameter integer STARTUP_CYCLES = 500_000_000,
    parameter integer GAP_CYCLES = 12_500_000,
    parameter integer FRAME_COUNT = 4
)(
    input  wire clk,
    input  wire reset,
    output reg  tx = 1'b1
);

localparam integer BIT_CYCLES = (CLOCK_HZ + BAUD / 2) / BAUD;
localparam integer TICK_WIDTH = (BIT_CYCLES > 1) ? $clog2(BIT_CYCLES) : 1;
localparam [1:0] STARTUP = 0, SEND = 1, GAP = 2, DONE = 3;

// RESET is generated outside this fixed-clock domain. Assert immediately;
// release only after two clock edges. Power-up also starts in reset.
reg [1:0] reset_pipe = 2'b11;
always @(posedge clk or posedge reset) begin
    if (reset) reset_pipe <= 2'b11;
    else reset_pipe <= {reset_pipe[0], 1'b0};
end

reg [1:0] state = STARTUP;
reg [31:0] wait_count = 0;
reg [TICK_WIDTH-1:0] tick_count = 0;
reg [9:0] shift = 10'h3ff;
reg [3:0] bit_index = 0;
reg [3:0] byte_index = 0;
reg [7:0] packet_sequence = 0;

// 16 bytes: 55 55 55 55 "MCDUART1" version sequence check LF.
// The check is a framing discriminator, not a transport error-correcting code.
function automatic [7:0] payload(input [3:0] pos, input [7:0] seq);
    case (pos)
        0, 1, 2, 3: payload = 8'h55;
        4: payload = "M";
        5: payload = "C";
        6: payload = "D";
        7: payload = "U";
        8: payload = "A";
        9: payload = "R";
        10: payload = "T";
        11: payload = "1";
        12: payload = 8'h01;
        13: payload = seq;
        14: payload = seq ^ 8'ha4;
        15: payload = 8'h0a;
    endcase
endfunction

always @(posedge clk) begin
    if (reset_pipe[1]) begin
        tx <= 1'b1;
        state <= STARTUP;
        wait_count <= 0;
        tick_count <= 0;
        shift <= 10'h3ff;
        bit_index <= 0;
        byte_index <= 0;
        packet_sequence <= 0;
    end else begin
        case (state)
            STARTUP, GAP: begin
                tx <= 1'b1;
                if ((state == STARTUP && (STARTUP_CYCLES == 0 || wait_count == STARTUP_CYCLES - 1)) ||
                    (state == GAP && (GAP_CYCLES == 0 || wait_count == GAP_CYCLES - 1))) begin
                    wait_count <= 0;
                    shift <= {1'b1, payload(0, packet_sequence), 1'b0};
                    tx <= 1'b0;
                    tick_count <= BIT_CYCLES - 1;
                    bit_index <= 0;
                    byte_index <= 0;
                    state <= SEND;
                end else wait_count <= wait_count + 1'b1;
            end
            SEND: begin
                if (tick_count != 0) tick_count <= tick_count - 1'b1;
                else begin
                    tick_count <= BIT_CYCLES - 1;
                    if (bit_index == 9) begin
                        // The stop bit has already occupied one full bit time.
                        tx <= 1'b1;
                        if (byte_index == 15) begin
                            if (packet_sequence == FRAME_COUNT - 1) state <= DONE;
                            else begin
                                packet_sequence <= packet_sequence + 1'b1;
                                wait_count <= 0;
                                state <= GAP;
                            end
                        end else begin
                            byte_index <= byte_index + 1'b1;
                            shift <= {1'b1, payload(byte_index + 1'b1, packet_sequence), 1'b0};
                            tx <= 1'b0;
                            bit_index <= 0;
                        end
                    end else begin
                        shift <= {1'b1, shift[9:1]};
                        tx <= shift[1];
                        bit_index <= bit_index + 1'b1;
                    end
                end
            end
            default: tx <= 1'b1;
        endcase
    end
end

endmodule
