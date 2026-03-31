`timescale 1ns / 1ps
// =============================================================================
// Module  : CTRL
// Function: Top-level sequencer for a multi-layer CNN accelerator.
//           Drives a 9-state one-hot FSM (IDLE + LAYER0~LAYER7) that coordinates:
//             · Weight / BN address generation (W_addr, BN_addr)
//             · Per-layer spatial config (img_width, img_height, pool_en, conv_mode)
//             · 8-bank SRAM read/write address and write-enable steering
//             · FC shift register control (shift_en, FC_valid)
//             · Downstream data-select valid pipeline (select_din_valid)
//           Layer-ready flags are generated internally by counting maxpool_flag
//           beats; transitions to the next layer are gated on those flags plus
//           external handshake signals (layer5_ready, layer6_ready, etc.).
// =============================================================================
module CTRL #(
    parameter MAX_WIDTH  = 6,    // Bit-width of img_width / img_height
    parameter SRAM_WIDTH = 10,   // Address width per SRAM bank
    parameter SRAM_NUM   = 8,    // Number of SRAM banks
    parameter DIN_WIDTH  = 8     // Input pixel bit-width
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // ---- Global control ----------------------------------------------------
    input  wire                          cnn_start,           // start pulse

    // ---- 2-D conv handshake ------------------------------------------------
    input  wire                          din_valid,           // raw pixel input valid
    input  wire                          conv_rs_end,         // row-sum conv done strobe
    input  wire                          conv_end,            // full conv done strobe

    // ---- FC / downstream ready signals -------------------------------------
    input  wire [4:0]                    fc_cnt,              // FC shift counter
    input  wire                          layer5_ready,        // LAYER5 processing done
    input  wire                          layer6_ready,        // LAYER6 processing done

    // ---- Pooling handshake -------------------------------------------------
    input  wire                          maxpool_valid_rise,  // rising edge of maxpool output valid
    input  wire                          maxpool_flag,        // maxpool output beat strobe

    // ---- 1-D conv RAM address feedback (from CONV1D_RAM_CTRL) -------------
    input  wire [6:0]                    conv1D_ram_addr0,    // RAM0 write pointer
    input  wire [6:0]                    conv1D_ram_addr1,    // RAM1 write pointer

    // ---- FSM state outputs -------------------------------------------------
    output      [8:0]                    top_state,           // one-hot current state
    output wire                          state_switch,        // asserted when next_state changes

    // ---- Spatial configuration per layer -----------------------------------
    output reg  [MAX_WIDTH-1:0]          img_width,
    output reg  [MAX_WIDTH-1:0]          img_height,

    // ---- Weight & BN address buses -----------------------------------------
    output reg  [6:0]                    W_addr,
    output reg  [7:0]                    BN_addr,

    // ---- FC shift register control -----------------------------------------
    output reg                           shift_en,
    output reg                           FC_valid,

    // ---- 8-bank SRAM control -----------------------------------------------
    output reg  [SRAM_NUM-1:0]           ram_we,              // per-bank write enable
    output wire [SRAM_WIDTH*SRAM_NUM-1:0] ram_addr,           // packed 8-bank address bus
    output reg  [1:0]                    sram_write_select,   // write-bank round-robin select

    // ---- Downstream data-select valid --------------------------------------
    output reg                           select_din_valid,    // gated valid to conv data_select
    output reg  [3:0]                    pool_en,             // per-channel pool enable
    output reg                           conv_mode            // 0 = 2-D conv, 1 = 1-D conv
);

// =============================================================================
// One-hot FSM state encoding
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;  // 1-D conv stage A (reads RAM0, writes RAM1)
localparam LAYER5 = 9'b001000000;  // 1-D conv stage B (reads RAM1)
localparam LAYER6 = 9'b010000000;  // FC stage
localparam LAYER7 = 9'b100000000;  // Final maxpool / output

// =============================================================================
// FSM registers
// =============================================================================
reg [8:0] current_state, next_state;
reg [8:0] current_state_ff;    // 1-cycle delayed current_state
reg [8:0] current_state_ff0;   // 2-cycle delayed current_state
reg [8:0] next_state_ff;       // 1-cycle delayed next_state

// Internal layer-ready flags generated by beat counters below
reg layer0_ready, layer1_ready, layer2_ready, layer3_ready;

// =============================================================================
// FSM sequential — current state register
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  current_state <= IDLE;
    else         current_state <= next_state;
end

// Delayed copies for transition detection
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        current_state_ff  <= 9'b0;
        current_state_ff0 <= 9'b0;
    end
    else begin
        current_state_ff  <= current_state;
        current_state_ff0 <= current_state_ff;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  next_state_ff <= 9'b0;
    else         next_state_ff <= next_state;
end

assign top_state   = current_state;
assign state_switch = (next_state_ff != next_state);   // combinational next-state changed

// =============================================================================
// FSM combinational — next-state logic
// LAYER3 has a split: if ram addr reaches 127 go to LAYER4, else back to IDLE
//   (handles the case where 1-D conv path is taken vs. not)
// LAYER4 / LAYER5 transition on conv1D_ram_addr thresholds (from CONV1D_RAM_CTRL)
// =============================================================================
always @(*) begin
    case (current_state)
        IDLE:   next_state = cnn_start    ? LAYER0 : IDLE;
        LAYER0: next_state = layer0_ready ? LAYER1 : LAYER0;
        LAYER1: next_state = layer1_ready ? LAYER2 : LAYER1;
        LAYER2: next_state = layer2_ready ? LAYER3 : LAYER2;
        LAYER3: begin
            if (layer3_ready && conv1D_ram_addr0 == 7'd127)
                next_state = LAYER4;
            else
                next_state = layer3_ready ? IDLE : LAYER3;
        end
        LAYER4: next_state = (conv1D_ram_addr1 == 7'd55)  ? LAYER5 : LAYER4;
        LAYER5: next_state = layer5_ready                  ? LAYER6 : LAYER5;
        LAYER6: next_state = layer6_ready                  ? LAYER7 : LAYER6;
        LAYER7: next_state = maxpool_valid_rise            ? IDLE   : LAYER7;
        default: next_state = IDLE;
    endcase
end

// =============================================================================
// Weight address (W_addr)
// Advances on maxpool_valid_rise in most layers.
// LAYER4 also advances on the first cycle of the state (state-entry edge).
// shift_en gates the advance in LAYER0~LAYER3 to avoid double-counting.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        W_addr <= 6'b0;
    end
    else begin
        case (current_state)
            IDLE: W_addr <= 6'b0;
            LAYER0, LAYER1, LAYER2, LAYER3: begin
                if (maxpool_valid_rise && !shift_en)
                    W_addr <= W_addr + 1'b1;
            end
            LAYER4: begin
                if (current_state != current_state_ff)   // state-entry bump
                    W_addr <= W_addr + 1'b1;
                else if (maxpool_valid_rise)
                    W_addr <= W_addr + 1'b1;
            end
            LAYER5, LAYER6, LAYER7: begin
                if (maxpool_valid_rise)
                    W_addr <= W_addr + 1'b1;
            end
            default: W_addr <= 6'b0;
        endcase
    end
end

// =============================================================================
// BN address (BN_addr)
// LAYER0: increments every cycle until shift_cnt reaches 4 (5-beat shift burst).
// LAYER4/5: increments on state-boundary and on each shift_en beat.
// All other active layers: increments on maxpool_valid_rise.
// =============================================================================
reg [2:0] shift_cnt;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        BN_addr <= 6'b0;
    end
    else begin
        case (current_state)
            IDLE: BN_addr <= 6'b0;
            LAYER0: begin
                if (shift_cnt != 3'b100)   // stop after 5 beats
                    BN_addr <= BN_addr + 1'b1;
            end
            LAYER4, LAYER5: begin
                if (current_state_ff != next_state_ff)   // state transition edge
                    BN_addr <= BN_addr + 1'b1;
                else if (shift_en)
                    BN_addr <= BN_addr + 1'b1;
            end
            LAYER1, LAYER2, LAYER3, LAYER6, LAYER7: begin
                if (maxpool_valid_rise)
                    BN_addr <= BN_addr + 1'b1;
            end
            default: BN_addr <= 6'b0;
        endcase
    end
end

// =============================================================================
// FC_valid
// Asserted at LAYER6 entry and on every maxpool_valid_rise_ff thereafter.
// Clears in all other states.
// =============================================================================
reg maxpool_valid_rise_ff;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  maxpool_valid_rise_ff <= 1'b0;
    else         maxpool_valid_rise_ff <= maxpool_valid_rise;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        FC_valid <= 1'b0;
    end
    else begin
        case (current_state)
            LAYER6: FC_valid <= (current_state_ff != LAYER6) || maxpool_valid_rise_ff;
            default: FC_valid <= 1'b0;
        endcase
    end
end

// =============================================================================
// shift_en / shift_cnt — FC weight shift register control
// LAYER0     : runs a fixed 5-beat burst (shift_cnt 0→4), then idles.
// LAYER4/5   : triggered by maxpool_valid_rise (when fc_cnt != 15); runs 2-beat burst.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        shift_en  <= 1'b0;
        shift_cnt <= 3'b0;
    end
    else begin
        case (current_state)
            LAYER0: begin
                if (shift_cnt == 3'b100) begin
                    shift_en  <= 1'b0;              // burst complete: hold
                end
                else begin
                    shift_en  <= 1'b1;
                    shift_cnt <= shift_cnt + 1'b1;
                end
            end
            LAYER4, LAYER5: begin
                if (maxpool_valid_rise && fc_cnt != 5'd15) begin
                    shift_en  <= 1'b1;              // arm a new 2-beat burst
                    shift_cnt <= 3'd1;
                end
                else if (shift_cnt == 3'b010) begin
                    shift_en  <= 1'b0;              // burst done
                end
                else if (shift_en) begin
                    shift_cnt <= shift_cnt + 1'b1;
                end
            end
            default: begin
                shift_en  <= 1'b0;
                shift_cnt <= 2'b0;
            end
        endcase
    end
end

// =============================================================================
// Per-layer spatial configuration
// img_width / img_height / pool_en / conv_mode are registered and held for the
// duration of each layer.  Values reflect the feature-map size at each stage.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        pool_en    <= 4'b0;
        img_height <= 6'b0;
        img_width  <= 6'b0;
        conv_mode  <= 1'b0;
    end
    else begin
        case (current_state)
            IDLE: begin
                pool_en <= 4'b0;  img_height <= 6'b0;   img_width <= 6'b0;  conv_mode <= 1'b0;
            end
            LAYER0: begin
                pool_en <= 4'b1111; img_height <= 6'd62; img_width <= 6'd50; conv_mode <= 1'b0;
            end
            LAYER1: begin
                pool_en <= 4'b0001; img_height <= 6'd31; img_width <= 6'd25; conv_mode <= 1'b0;
            end
            LAYER2: begin
                pool_en <= 4'b0001; img_height <= 6'd15; img_width <= 6'd12; conv_mode <= 1'b0;
            end
            LAYER3: begin
                pool_en <= 4'b0001; img_height <= 6'd7;  img_width <= 6'd6;  conv_mode <= 1'b0;
            end
            LAYER4: begin
                pool_en <= 4'b0011; img_height <= 6'd1;  img_width <= 6'd14; conv_mode <= 1'b1;
            end
            LAYER5: begin
                pool_en <= 4'b0000; img_height <= 6'b0;  img_width <= 6'b0;  conv_mode <= 1'b1;
            end
            LAYER6: begin
                pool_en <= 4'b0000; img_height <= 6'b0;  img_width <= 6'b0;  conv_mode <= 1'b0;
            end
            default: begin
                pool_en <= 4'b0;  img_height <= 6'b0;   img_width <= 6'b0;  conv_mode <= 1'b0;
            end
        endcase
    end
end

// =============================================================================
// SRAM write-side counters & layer-ready flags
// sram_write_num  : counts maxpool_flag beats within one sub-frame
// sram_write_id   : sub-frame (tile) index; increments when write_num wraps
// sram_write_select: round-robin bank selector (2-bit, used in LAYER1~3)
// layerN_ready    : set for one cycle when all writes for that layer complete
//
// Beat limits per layer:
//   LAYER0 : 775 beats total (sram_write_num wraps at 774)
//   LAYER1 : 180 beats/bank × 4 banks × 2 tiles = sram_write_num wraps at 179
//   LAYER2 : 42  beats/bank × 4 banks × 4 tiles = sram_write_num wraps at 41
//   LAYER3 : 9   beats/tile × 32 tiles           = sram_write_num wraps at 8
// =============================================================================
reg [9:0] sram_read_num;
reg [3:0] sram_read_select;
reg [1:0] sram_read_id;
reg [5:0] sram_write_id;
reg [9:0] sram_write_num;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_write_select <= 2'b0;
        sram_write_id     <= 6'b0;
        sram_write_num    <= 10'b0;
        layer0_ready      <= 1'b0;
        layer1_ready      <= 1'b0;
        layer2_ready      <= 1'b0;
        layer3_ready      <= 1'b0;
    end
    else if (maxpool_flag) begin
        case (current_state)
            LAYER0: begin
                if (sram_write_num == 10'd774) begin
                    sram_write_num <= 10'b0;
                    layer0_ready   <= 1'b1;                // all 775 beats written
                end
                else begin
                    sram_write_num    <= sram_write_num + 1'b1;
                    sram_write_select <= 2'b00;
                    sram_write_id     <= 6'b0;
                    layer0_ready      <= 1'b0;
                    layer1_ready      <= 1'b0;
                    layer2_ready      <= 1'b0;
                    layer3_ready      <= 1'b0;
                end
            end
            LAYER1: begin
                if (sram_write_num == 10'd179) begin
                    sram_write_num <= 10'b0;
                    if (sram_write_select == 2'b11) begin
                        sram_write_select <= 2'b00;
                        if (sram_write_id == 6'd1) begin
                            sram_write_id <= 6'b0;
                            layer1_ready  <= 1'b1;         // 4 banks × 2 tiles done
                        end
                        else sram_write_id <= sram_write_id + 1'b1;
                    end
                    else sram_write_select <= sram_write_select + 1'b1;
                end
                else begin
                    sram_write_num <= sram_write_num + 1'b1;
                    layer0_ready   <= 1'b0;
                    layer1_ready   <= 1'b0;
                    layer2_ready   <= 1'b0;
                    layer3_ready   <= 1'b0;
                end
            end
            LAYER2: begin
                if (sram_write_num == 10'd41) begin
                    sram_write_num <= 10'b0;
                    if (sram_write_select == 2'b11) begin
                        sram_write_select <= 2'b00;
                        if (sram_write_id == 6'd3) begin
                            sram_write_id <= 6'b0;
                            layer2_ready  <= 1'b1;         // 4 banks × 4 tiles done
                        end
                        else sram_write_id <= sram_write_id + 1'b1;
                    end
                    else sram_write_select <= sram_write_select + 1'b1;
                end
                else begin
                    sram_write_num <= sram_write_num + 1'b1;
                    layer0_ready   <= 1'b0;
                    layer1_ready   <= 1'b0;
                    layer2_ready   <= 1'b0;
                    layer3_ready   <= 1'b0;
                end
            end
            LAYER3: begin
                if (sram_write_num == 10'd8) begin
                    sram_write_num <= 10'b0;
                    if (sram_write_id == 6'd31) begin
                        sram_write_id <= 6'b0;
                        layer3_ready  <= 1'b1;             // 32 tiles × 9 beats done
                    end
                    else sram_write_id <= sram_write_id + 1'b1;
                end
                else sram_write_num <= sram_write_num + 1'b1;
            end
            default: begin
                sram_write_select <= 2'b00;
                sram_write_id     <= 6'b0;
                sram_write_num    <= 10'b0;
                layer0_ready      <= 1'b0;
                layer1_ready      <= 1'b0;
                layer2_ready      <= 1'b0;
                layer3_ready      <= 1'b0;
            end
        endcase
    end
    else begin
        // Freeze counters between maxpool beats; clear ready pulses
        sram_write_num    <= sram_write_num;
        sram_write_id     <= sram_write_id;
        sram_write_select <= sram_write_select;
        layer0_ready      <= 1'b0;
        layer1_ready      <= 1'b0;
        layer2_ready      <= 1'b0;
        layer3_ready      <= 1'b0;
    end
end

// =============================================================================
// select_din_valid pipeline (3-cycle delay)
// select_valid_ff0: raw pre-valid; set on layer entry or conv_end,
//                   cleared on conv_rs_end (row-sum boundary).
// select_valid_ff1/ff2: 2-stage delay shift register.
// select_din_valid: output; LAYER0 tracks din_valid directly,
//                   LAYER1~3 use the delayed signal.
// =============================================================================
reg select_valid_ff0, select_valid_ff1, select_valid_ff2;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        select_valid_ff0 <= 1'b0;
    end
    else begin
        case (current_state)
            LAYER1: begin
                if      (current_state_ff == LAYER0) select_valid_ff0 <= 1'b1;  // layer entry
                else if (conv_end)                   select_valid_ff0 <= 1'b1;  // next tile
                else if (conv_rs_end)                select_valid_ff0 <= 1'b0;  // row-sum boundary
            end
            LAYER2: begin
                if      (current_state_ff == LAYER1) select_valid_ff0 <= 1'b1;
                else if (conv_end)                   select_valid_ff0 <= 1'b1;
                else if (conv_rs_end)                select_valid_ff0 <= 1'b0;
            end
            LAYER3: begin
                if      (current_state_ff == LAYER2) select_valid_ff0 <= 1'b1;
                else if (conv_end)                   select_valid_ff0 <= 1'b1;
                else if (conv_rs_end)                select_valid_ff0 <= 1'b0;
            end
            default: select_valid_ff0 <= 1'b0;
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        select_valid_ff1 <= 1'b0;
        select_valid_ff2 <= 1'b0;
    end
    else begin
        select_valid_ff1 <= select_valid_ff0;
        select_valid_ff2 <= select_valid_ff1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        select_din_valid <= 1'b0;
    end
    else begin
        case (current_state)
            IDLE:              select_din_valid <= 1'b0;
            LAYER0:            select_din_valid <= din_valid;        // pass-through in first layer
            LAYER1, LAYER2, LAYER3: select_din_valid <= select_valid_ff2;  // 3-cycle delayed
            default:           select_din_valid <= 1'b0;
        endcase
    end
end

// =============================================================================
// SRAM read-side counters
// sram_read_num    : beat index within one bank read burst
// sram_read_select : bank round-robin read pointer
// sram_read_id     : tile (sub-frame) read index
//
// Beat limits mirror the write-side limits of the preceding layer:
//   LAYER1 reads LAYER0 data : 775 beats  (wraps at 774)
//   LAYER2 reads LAYER1 data : 180 beats/bank × 8 banks / 2 (wraps at 179)
//   LAYER3 reads LAYER2 data : 42  beats per tile            (wraps at 41)
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_read_num    <= 10'b0;
        sram_read_select <= 4'b0;
        sram_read_id     <= 2'b0;
    end
    else if (select_valid_ff0) begin
        case (current_state)
            LAYER1: begin
                if (sram_read_num == 10'd774)  sram_read_num <= 10'b0;
                else                           sram_read_num <= sram_read_num + 1'b1;
            end
            LAYER2: begin
                if (sram_read_num == 10'd179) begin
                    sram_read_num <= 10'b0;
                    if (sram_read_select == 4'd7) begin
                        sram_read_select <= 4'b0;
                        if (sram_read_id == 2'b01)  sram_read_id <= 2'b00;
                        else                        sram_read_id <= sram_read_id + 1'b1;
                    end
                    else sram_read_select <= sram_read_select + 1'b1;
                end
                else sram_read_num <= sram_read_num + 1'b1;
            end
            LAYER3: begin
                if (sram_read_num == 10'd41) begin
                    sram_read_num <= 10'b0;
                    if (sram_read_select == 4'd7) begin
                        sram_read_select <= 4'b0;
                        if (sram_read_id == 2'b11)  sram_read_id <= 2'b00;
                        else                        sram_read_id <= sram_read_id + 1'b1;
                    end
                    else sram_read_select <= sram_read_select + 1'b1;
                end
                else sram_read_num <= sram_read_num + 1'b1;
            end
            default: begin
                sram_read_num    <= 10'b0;
                sram_read_select <= 4'b0;
                sram_read_id     <= 2'b0;
            end
        endcase
    end
    else begin
        sram_read_num    <= 10'b0;
        sram_read_select <= sram_read_select;   // hold bank pointer across gaps
        sram_read_id     <= sram_read_id;
    end
end

// =============================================================================
// SRAM address generation (8 banks)
// Each bank gets a 10-bit address.  Write and read banks are interleaved:
//   LAYER0 : banks 0-3 = write, banks 4-7 = idle
//   LAYER1 : banks 0-3 = read (LAYER0 data), banks 4-7 = write (LAYER1 result)
//   LAYER2 : banks 0-3 = write (LAYER2 result), banks 4-7 = read (LAYER1 data)
//   LAYER3 : banks 0-3 = read (LAYER2 data), banks 4-7 = idle
// Write address = sram_write_num + sram_write_id × stride
// Read  address = sram_read_num  + sram_read_id  × stride
// =============================================================================
reg [9:0] sram_addr0, sram_addr1, sram_addr2, sram_addr3;
reg [9:0] sram_addr4, sram_addr5, sram_addr6, sram_addr7;

assign ram_addr = {sram_addr7, sram_addr6, sram_addr5, sram_addr4,
                   sram_addr3, sram_addr2, sram_addr1, sram_addr0};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sram_addr0 <= 10'b0;  sram_addr1 <= 10'b0;
        sram_addr2 <= 10'b0;  sram_addr3 <= 10'b0;
        sram_addr4 <= 10'b0;  sram_addr5 <= 10'b0;
        sram_addr6 <= 10'b0;  sram_addr7 <= 10'b0;
    end
    else begin
        case (current_state)
            LAYER0: begin
                // All 4 write banks share the same sequential write pointer
                sram_addr0 <= sram_write_num;
                sram_addr1 <= sram_write_num;
                sram_addr2 <= sram_write_num;
                sram_addr3 <= sram_write_num;
                sram_addr4 <= 10'b0;
                sram_addr5 <= 10'b0;
                sram_addr6 <= 10'b0;
                sram_addr7 <= 10'b0;
            end
            LAYER1: begin
                // Banks 0-3: read LAYER0 data (linear)
                sram_addr0 <= sram_read_num;
                sram_addr1 <= sram_read_num;
                sram_addr2 <= sram_read_num;
                sram_addr3 <= sram_read_num;
                // Banks 4-7: write LAYER1 result (stride = 180 per tile)
                sram_addr4 <= sram_write_num + sram_write_id * 10'd180;
                sram_addr5 <= sram_write_num + sram_write_id * 10'd180;
                sram_addr6 <= sram_write_num + sram_write_id * 10'd180;
                sram_addr7 <= sram_write_num + sram_write_id * 10'd180;
            end
            LAYER2: begin
                // Banks 0-3: write LAYER2 result (stride = 42 per tile)
                sram_addr0 <= sram_write_num + sram_write_id * 10'd42;
                sram_addr1 <= sram_write_num + sram_write_id * 10'd42;
                sram_addr2 <= sram_write_num + sram_write_id * 10'd42;
                sram_addr3 <= sram_write_num + sram_write_id * 10'd42;
                // Banks 4-7: read LAYER1 data (stride = 180 per tile)
                sram_addr4 <= sram_read_num  + sram_read_id  * 10'd180;
                sram_addr5 <= sram_read_num  + sram_read_id  * 10'd180;
                sram_addr6 <= sram_read_num  + sram_read_id  * 10'd180;
                sram_addr7 <= sram_read_num  + sram_read_id  * 10'd180;
            end
            LAYER3: begin
                // Banks 0-3: read LAYER2 data (stride = 42 per tile)
                sram_addr0 <= sram_read_num  + sram_read_id  * 10'd42;
                sram_addr1 <= sram_read_num  + sram_read_id  * 10'd42;
                sram_addr2 <= sram_read_num  + sram_read_id  * 10'd42;
                sram_addr3 <= sram_read_num  + sram_read_id  * 10'd42;
                sram_addr4 <= 10'b0;
                sram_addr5 <= 10'b0;
                sram_addr6 <= 10'b0;
                sram_addr7 <= 10'b0;
            end
            default: begin
                sram_addr0 <= 10'b0;  sram_addr1 <= 10'b0;
                sram_addr2 <= 10'b0;  sram_addr3 <= 10'b0;
                sram_addr4 <= 10'b0;  sram_addr5 <= 10'b0;
                sram_addr6 <= 10'b0;  sram_addr7 <= 10'b0;
            end
        endcase
    end
end

// =============================================================================
// SRAM write-enable (ram_we)
// sram_write_select steers maxpool_flag to the correct bank group.
// LAYER0     : banks 0-3 all enabled simultaneously (4-channel write).
// LAYER1/3   : one-hot shifted left by sram_write_select into banks 4-7.
// LAYER2     : one-hot shifted into banks 0-3.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ram_we <= 8'b0;
    end
    else begin
        case (current_state)
            IDLE:   ram_we <= 8'b0;
            LAYER0: ram_we <= {4'b0, {4{maxpool_flag}}};   // banks 0-3 simultaneous write
            LAYER1: begin
                case (sram_write_select)
                    2'b00: ram_we <= {3'b000, maxpool_flag, 4'b0000};  // bank 4
                    2'b01: ram_we <= {2'b00,  maxpool_flag, 5'b00000}; // bank 5
                    2'b10: ram_we <= {1'b0,   maxpool_flag, 6'b000000};// bank 6
                    2'b11: ram_we <= {        maxpool_flag, 7'b0000000};// bank 7
                    default: ram_we <= 8'b0;
                endcase
            end
            LAYER2: begin
                case (sram_write_select)
                    2'b00: ram_we <= {7'b000_0000, maxpool_flag      }; // bank 0
                    2'b01: ram_we <= {6'b00_0000,  maxpool_flag, 1'b0}; // bank 1
                    2'b10: ram_we <= {5'b0_0000,   maxpool_flag, 2'b00};// bank 2
                    2'b11: ram_we <= {4'b0000,      maxpool_flag, 3'b000};// bank 3
                    default: ram_we <= 8'b0;
                endcase
            end
            LAYER3: begin
                case (sram_write_select)
                    2'b00: ram_we <= {3'b000, maxpool_flag, 4'b0000};  // bank 4
                    2'b01: ram_we <= {2'b00,  maxpool_flag, 5'b00000}; // bank 5
                    2'b10: ram_we <= {1'b0,   maxpool_flag, 6'b000000};// bank 6
                    2'b11: ram_we <= {        maxpool_flag, 7'b0000000};// bank 7
                    default: ram_we <= 8'b0;
                endcase
            end
            default: ram_we <= 8'b0;
        endcase
    end
end

endmodule