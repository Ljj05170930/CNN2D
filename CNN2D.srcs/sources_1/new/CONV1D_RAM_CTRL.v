`timescale 1ns / 1ps
// =============================================================================
// Module  : CONV1D_RAM_CTRL
// Function: RAM controller for 1-D convolution input staging.
//           Manages two single-port RAMs (RAM0 / RAM1) that buffer feature maps
//           between the pooling stages and the 1-D conv layer.
//           RAM0 stores avg-pooled data (LAYER3 → LAYER4 readback).
//           RAM1 stores max-pooled data (LAYER4 → LAYER5 readback).
//           An internal 4-state FSM sequences write and read phases; a 3-cycle
//           valid pipeline aligns ram_out with downstream data_select timing.
// =============================================================================
module CONV1D_RAM_CTRL #(
    parameter DIN_WIDTH  = 8,   // Input data bit-width
    parameter DOUT_WIDTH = 8    // Output data bit-width
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- Global control ----------------------------------------------------
    input  wire                       cnn_start,           // RAM clock enable
    input  wire [8:0]                 top_state,           // one-hot top FSM state
    input  wire                       control,             // end-of-burst flush from data_select

    // ---- Upstream pooling results ------------------------------------------
    input  wire                       avg_dout_valid,               // avg-pool output valid
    input  wire                       maxpool_flag,                 // max-pool output valid
    input  wire [DIN_WIDTH-1:0]       avg_pool_dout,                // avg-pool single-channel out
    input  wire [DIN_WIDTH*2-1:0]     maxpool_dout_2channel,        // max-pool 2-channel packed out

    // ---- RAM address & data outputs ----------------------------------------
    output reg  [6:0]                 conv1D_ram_addr0,    // address for RAM0 (r/w)
    output reg  [6:0]                 conv1D_ram_addr1,    // address for RAM1 (w)
    output reg                        conv1D_din_valid,    // data valid to downstream (3-cycle delayed)
    output reg  [DOUT_WIDTH*4-1:0]    ram_out              // selected RAM read data (4 pixels packed)
);

// =============================================================================
// One-hot top-level FSM state encoding (mirror of top_state)
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

// =============================================================================
// Internal 4-state FSM encoding
// state0: idle / wait for LAYER3
// state1: write avg-pool data into RAM0
// state2: read RAM0 (LAYER4) while writing max-pool data into RAM1
// state3: read RAM1 (LAYER5); hold until LAYER6 resets to state0
// =============================================================================
localparam state0 = 4'b0000;
localparam state1 = 4'b0011;
localparam state2 = 4'b0111;
localparam state3 = 4'b1111;

reg [3:0] cur_state, next_state, cur_state_ff;   // FSM registers (ff = 1-cycle delayed)

// =============================================================================
// Internal registers & wires
// =============================================================================
reg  [DIN_WIDTH-1:0]     ram_din_mem [0:3];    // 4-entry shift accumulator for avg-pool data
reg  [DIN_WIDTH-1:0]     ram_buffer0 [0:6];    // pre-buffer: max-pool ch0 (7 entries)
reg  [DIN_WIDTH-1:0]     ram_buffer1 [0:6];    // pre-buffer: max-pool ch1 (7 entries)

wire [4*DIN_WIDTH-1:0]   conv1D_ram0_din;      // packed write data for RAM0
reg  [4*DIN_WIDTH-1:0]   conv1D_ram1_din;      // packed write data for RAM1

reg  [2:0]  ram_cnt;          // beat counter for state1 (mod-4) / state2 (mod-7)
reg  [1:0]  conv1D_ram_wr;    // write-enable: [1]=RAM1, [0]=RAM0

reg         we_ok;            // RAM1 write enable qualifier (asserted after 7 pre-buffer beats)
reg  [3:0]  we_cnt;           // counter to generate we_ok window in state2

wire [DOUT_WIDTH*4-1:0]  ram0_out;   // RAM0 read data
wire [DOUT_WIDTH*4-1:0]  ram1_out;   // RAM1 read data

reg  [2:0]  conv1D_channel;   // channel index [0..7] for read address calculation
reg  [3:0]  conv1D_num;       // beat index within one channel burst
reg         conv1D_id;        // sub-burst toggle (2 passes per channel)
reg         read_all0;        // flag: all of RAM0 has been read (LAYER4 complete)
reg         read_all1;        // flag: all of RAM1 has been read (LAYER5 complete)

// =============================================================================
// we_ok window generator
// In state2, the first 7 max-pool beats are buffered (ram_buffer0/1).
// After beat 6 (we_cnt==6), we_ok goes high so that subsequent beats are
// paired with the buffered data and written directly into RAM1.
// we_ok clears at we_cnt==13 (second group of 7 beats done).
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        we_cnt <= 4'b0;
        we_ok  <= 1'b0;
    end
    else if (cur_state == state2 && maxpool_flag) begin
        if (we_cnt == 4'd6) begin
            we_ok  <= 1'b1;
            we_cnt <= we_cnt + 1'b1;
        end
        else if (we_cnt == 4'd13) begin
            we_ok  <= 1'b0;
            we_cnt <= 4'b0;
        end
        else begin
            we_cnt <= we_cnt + 1'b1;
        end
    end
end

// =============================================================================
// ram_cnt: beat counter
// state1 — wraps at 3 (4 avg-pool pixels fill one RAM0 word)
// state2 — wraps at 6 (7 max-pool beats per buffer row)
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ram_cnt <= 3'b0;
    end
    else begin
        case (cur_state)
            state1: begin
                if (avg_dout_valid) begin
                    if (ram_cnt == 3'b011)  ram_cnt <= 3'b0;
                    else                    ram_cnt <= ram_cnt + 1'b1;
                end
            end
            state2: begin
                if (maxpool_flag) begin
                    if (ram_cnt == 3'd6)    ram_cnt <= 3'b0;
                    else                    ram_cnt <= ram_cnt + 1'b1;
                end
            end
            default: ram_cnt <= 3'b0;
        endcase
    end
end

// =============================================================================
// Input data accumulation
// state1: collect avg_pool_dout into ram_din_mem[0..3] (one word per 4 beats)
// state2: buffer max-pool ch0/ch1 into ram_buffer0/1 during pre-fill phase
// =============================================================================
integer i, j;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 4; i = i + 1) ram_din_mem[i] <= 8'b0;
        for (j = 0; j < 7; j = j + 1) begin
            ram_buffer0[j] <= 8'b0;
            ram_buffer1[j] <= 8'b0;
        end
    end
    else begin
        case (cur_state)
            state1: begin
                if (avg_dout_valid)
                    ram_din_mem[ram_cnt] <= avg_pool_dout;  // accumulate 4 pixels per RAM word
            end
            state2: begin
                if (maxpool_flag && !we_ok) begin
                    // Pre-fill phase: buffer first 7 beats of each channel pair
                    ram_buffer0[ram_cnt] <= maxpool_dout_2channel[DIN_WIDTH-1:0];
                    ram_buffer1[ram_cnt] <= maxpool_dout_2channel[DIN_WIDTH*2-1:DIN_WIDTH];
                end
            end
            default: begin
                for (i = 0; i < 4; i = i + 1) ram_din_mem[i] <= 8'b0;
                for (j = 0; j < 7; j = j + 1) begin
                    ram_buffer0[j] <= 8'b0;
                    ram_buffer1[j] <= 8'b0;
                end
            end
        endcase
    end
end

// Pack ram_din_mem[0..3] into a 32-bit RAM0 write word
generate
    genvar k;
    for (k = 0; k < 4; k = k + 1) begin : gen_ram0_din
        assign conv1D_ram0_din[DIN_WIDTH*k +: DIN_WIDTH] = ram_din_mem[k];
    end
endgenerate

// RAM1 write data: pair current max-pool beat with buffered row at ram_cnt
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_ram1_din <= 32'b0;
    end
    else if (we_ok) begin
        conv1D_ram1_din <= {maxpool_dout_2channel, ram_buffer1[ram_cnt], ram_buffer0[ram_cnt]};
    end
end

// =============================================================================
// Internal FSM — sequential
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  cur_state <= state0;
    else         cur_state <= next_state;
end

// One-cycle delayed copy used to detect state transitions
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  cur_state_ff <= state0;
    else         cur_state_ff <= cur_state;
end

// =============================================================================
// Internal FSM — combinational next-state logic
// =============================================================================
always @(*) begin
    case (cur_state)
        state0: next_state = (top_state == LAYER3)                           ? state1 : state0;
        state1: next_state = (conv1D_ram_addr0 == 7'd127 && conv1D_ram_wr[0]) ? state2 : state1;
        state2: next_state = (conv1D_ram_addr1 == 7'd56)                     ? state3 : state2;
        state3: next_state = (top_state == LAYER6)                           ? state0 : state3;
        default: next_state = state0;
    endcase
end

// =============================================================================
// conv1D_din_valid0 — pre-delay valid signal
// Toggles off/on around each control burst boundary; locks low when all RAM
// entries have been read (read_all0 / read_all1).
// =============================================================================
reg conv1D_din_valid0;
reg conv1D_din_valid1, conv1D_din_valid2;
reg control_ff;

// One-cycle delayed control for edge detection
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  control_ff <= 1'b0;
    else         control_ff <= control;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_din_valid0 <= 1'b0;
    end
    else begin
        case (cur_state)
            state0, state1: begin
                conv1D_din_valid0 <= 1'b0;
            end
            state2: begin
                if (conv1D_ram_addr0 == 7'd127 && read_all0)
                    conv1D_din_valid0 <= 1'b0;                          // all RAM0 read: stop
                else if ((control_ff || control) && !read_all0)
                    conv1D_din_valid0 <= ~conv1D_din_valid0;            // toggle at burst boundary
                else if (cur_state_ff == state1)
                    conv1D_din_valid0 <= 1'b1;                          // kickstart on state1→state2
            end
            state3: begin
                if (cur_state_ff == state2)
                    conv1D_din_valid0 <= 1'b1;                          // kickstart on state2→state3
                else if (conv1D_ram_addr0 == 7'd55 && read_all1)
                    conv1D_din_valid0 <= 1'b0;                          // all RAM1 read: stop
                else if ((control_ff || control) && !read_all1)
                    conv1D_din_valid0 <= ~conv1D_din_valid0;            // toggle at burst boundary
            end
            default: conv1D_din_valid0 <= 1'b0;
        endcase
    end
end

// =============================================================================
// Valid 3-cycle pipeline
// conv1D_din_valid0 → ff1 → ff2 → conv1D_din_valid (output)
// Entire pipeline is flushed synchronously on control pulse.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_din_valid  <= 1'b0;
        conv1D_din_valid1 <= 1'b0;
        conv1D_din_valid2 <= 1'b0;
    end
    else if (control) begin
        // Flush pipeline on end-of-burst
        conv1D_din_valid  <= 1'b0;
        conv1D_din_valid1 <= 1'b0;
        conv1D_din_valid2 <= 1'b0;
    end
    else begin
        conv1D_din_valid1 <= conv1D_din_valid0;
        conv1D_din_valid2 <= conv1D_din_valid1;
        conv1D_din_valid  <= conv1D_din_valid2;
    end
end

// =============================================================================
// ram_out mux: select RAM0 output in state2, RAM1 output in state3
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ram_out <= 32'b0;
    end
    else begin
        case (cur_state)
            state2:  ram_out <= ram0_out;
            state3:  ram_out <= ram1_out;
            default: ram_out <= 32'b0;
        endcase
    end
end

// =============================================================================
// Read address & traversal counters
// conv1D_num  : beat index within one burst (0..15 for LAYER4, 0..6 for LAYER5)
// conv1D_id   : sub-burst toggle (2 passes per channel)
// conv1D_channel: channel index [0..7]; increments after both passes complete
// read_all0/1 : set when all 8 channels × 2 passes have been read
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_num     <= 5'b0;
        conv1D_id      <= 1'b0;
        conv1D_channel <= 3'b0;
        read_all0      <= 1'b0;
        read_all1      <= 1'b0;
    end
    else if (conv1D_din_valid0) begin
        case (top_state)
            LAYER4: begin
                if (conv1D_num == 5'd15) begin
                    conv1D_num <= 5'b0;
                    if (conv1D_id == 1'b1) begin
                        conv1D_id <= 1'b0;
                        if (conv1D_channel == 3'b111) begin
                            conv1D_channel <= 3'b0;
                            read_all0      <= 1'b1;    // all channels read from RAM0
                        end
                        else conv1D_channel <= conv1D_channel + 1'b1;
                    end
                    else conv1D_id <= conv1D_id + 1'b1;
                end
                else conv1D_num <= conv1D_num + 1'b1;
            end
            LAYER5: begin
                if (conv1D_num == 5'd6) begin
                    conv1D_num <= 5'b0;
                    if (conv1D_id == 1'b1) begin
                        conv1D_id <= 1'b0;
                        if (conv1D_channel == 3'b111) begin
                            conv1D_channel <= 3'b0;
                            read_all0      <= 1'b1;    // all channels read from RAM1
                        end
                        else conv1D_channel <= conv1D_channel + 1'b1;
                    end
                    else conv1D_id <= conv1D_id + 1'b1;
                end
                else conv1D_num <= conv1D_num + 1'b1;
            end
            default: begin
                conv1D_num <= 5'b0;
                conv1D_id  <= 1'b0;
            end
        endcase
    end
    else begin
        conv1D_num <= 5'b0;
        conv1D_id  <= conv1D_id;   // hold id across burst gaps
    end
end

// =============================================================================
// Address generation
// state1 : RAM0 write address increments on each valid write (conv1D_ram_wr[0])
// state2 : RAM0 read  address = channel + (num << 3)  (interleaved layout)
//          RAM1 write address increments on each valid write (conv1D_ram_wr[1])
// state3 : RAM1 read  address = channel*7 + num
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_ram_addr0 <= 6'b0;
        conv1D_ram_addr1 <= 6'b0;
    end
    else begin
        case (cur_state)
            state0: begin
                conv1D_ram_addr0 <= 6'b0;
                conv1D_ram_addr1 <= 6'b0;
            end
            state1: begin
                if (conv1D_ram_wr[0]) begin
                    conv1D_ram_addr0 <= conv1D_ram_addr0 + 1'b1;
                    conv1D_ram_addr1 <= 6'b0;
                end
            end
            state2: begin
                if (conv1D_ram_wr[1])
                    conv1D_ram_addr1 <= conv1D_ram_addr1 + 1'b1;     // RAM1 write pointer
                conv1D_ram_addr0 <= conv1D_channel + (conv1D_num << 3); // RAM0 read: interleaved
            end
            state3: begin
                conv1D_ram_addr1 <= (conv1D_channel * 7) + conv1D_num;  // RAM1 read: row-major
            end
            default: conv1D_ram_addr0 <= 6'b0;
        endcase
    end
end

// =============================================================================
// Write-enable generation
// state1 : assert RAM0 WE when 4 avg-pool pixels have been collected (ram_cnt==3)
// state2 : assert RAM1 WE each maxpool_flag beat once we_ok is active
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_ram_wr <= 2'b0;
    end
    else begin
        case (cur_state)
            state0, state3: begin
                conv1D_ram_wr <= 2'b0;
            end
            state1: begin
                conv1D_ram_wr <= (ram_cnt == 3'b011 && avg_dout_valid) ? 2'b01 : 2'b00;
            end
            state2: begin
                if (we_ok) begin
                    conv1D_ram_wr[0] <= 1'b0;
                    conv1D_ram_wr[1] <= maxpool_flag;   // write RAM1 on every valid max-pool beat
                end
                else begin
                    conv1D_ram_wr <= 2'b0;
                end
            end
            default: conv1D_ram_wr <= 2'b0;
        endcase
    end
end

// =============================================================================
// RAM instances
// =============================================================================
CONV1D_RAM u_CONV1D_RAM0 (
    .clka  (clk              ),
    .ena   (cnn_start        ),
    .wea   (conv1D_ram_wr[0] ),
    .addra (conv1D_ram_addr0 ),
    .dina  (conv1D_ram0_din  ),
    .douta (ram0_out         )
);

CONV1D_RAM u_CONV1D_RAM1 (
    .clka  (clk              ),
    .ena   (cnn_start        ),
    .wea   (conv1D_ram_wr[1] ),
    .addra (conv1D_ram_addr1 ),
    .dina  (conv1D_ram1_din  ),
    .douta (ram1_out         )
);

endmodule