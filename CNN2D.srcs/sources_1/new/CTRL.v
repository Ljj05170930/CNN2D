`timescale 1ns / 1ps
module CTRL#(
    parameter MAX_WIDTH  = 6,
    parameter SRAM_WIDTH = 10,
    parameter SRAM_NUM   = 8,
    parameter DIN_WIDTH  = 8
)
(
    input wire                      clk,
    input wire                      rst_n,
    input wire                      cnn_start,
    input wire                      din_valid,     
    input wire                      conv_rs_end, 
    input wire                      conv_end,                                     
    input wire                      maxpool_valid_rise,
    input wire                      maxpool_flag,
    input wire [5:0]                cov1D_ram_addr, 

    output [8:0]                    top_state,
    output wire                     state_switch,
    output reg  [MAX_WIDTH-1:0]     img_width, 
    output reg  [MAX_WIDTH-1:0]     img_height,

    output reg  [5:0]              W_addr,
    output reg  [7:0]              B_addr,
    output reg  [7:0]              S_addr,
    output reg                     shift_en,

    output reg  [SRAM_NUM-1:0]                     ram_we,
    output wire [SRAM_WIDTH*SRAM_NUM-1:0]          ram_addr,
    output reg  [1:0]              sram_write_select,

    output reg                     select_din_valid,   
    output reg  [3:0]              pool_en,
    output reg                     conv_mode       
);

localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

reg [8:0] current_state, next_state,current_state_ff,next_state_ff;
reg layer0_ready, layer1_ready,layer2_ready, layer3_ready;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        current_state <= IDLE;
    end 
    else begin
        current_state <= next_state;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        current_state_ff <= 9'b0;
    end
    else begin
        current_state_ff <= current_state;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        next_state_ff <= 9'b0;
    end
    else begin
        next_state_ff <= next_state;
    end
end

assign top_state = current_state;
assign state_switch = next_state_ff != next_state;

always @(*) begin
    case (current_state)
        IDLE:   next_state = cnn_start ? LAYER0 : IDLE;
        LAYER0: next_state = layer0_ready ? LAYER1 : LAYER0;
        LAYER1: next_state = layer1_ready ? LAYER2 : LAYER1;
        LAYER2: next_state = layer2_ready ? LAYER3 : LAYER2;
        LAYER3: begin
            if(layer3_ready && cov1D_ram_addr == 6'd63) 
                next_state = LAYER4;
            else next_state = layer3_ready ? IDLE : LAYER3;
        end
        LAYER4:;
        default: next_state = IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        W_addr <= 6'b0;
    end
    else begin
        case (current_state)
            IDLE:begin
                W_addr <= 6'b0;
            end 
            LAYER0,LAYER1,LAYER2,LAYER3:begin
                if(maxpool_valid_rise && !shift_en) begin
                    W_addr <= W_addr + 1'b1;
                end 
            end
            default: W_addr <= 6'b0;
        endcase
    end
end

reg [2:0] shift_cnt;
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        S_addr <= 6'b0;
        B_addr <= 6'b0;
    end
    else begin
        case (current_state)
            IDLE:begin
                S_addr <= 6'b0;
                B_addr <= 6'b0;
            end 
            LAYER0:begin
                if(shift_cnt == 3'b100)begin
                    S_addr <= S_addr;
                    B_addr <= B_addr;
                end
                else begin
                    S_addr <= S_addr + 1'b1;
                    B_addr <= B_addr + 1'b1;
                end
            end
            LAYER1,LAYER2,LAYER3:begin
                if(maxpool_valid_rise) begin
                    S_addr <= S_addr + 1'b1;
                    B_addr <= B_addr + 1'b1;
                end
            end
            default:begin
                S_addr <= 6'b0;
                B_addr <= 6'b0;
            end 
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        shift_en  <= 1'b0;
        shift_cnt <= 3'b0;
    end
    else begin
        case (current_state)
            LAYER0:begin
                if (shift_cnt == 3'b100) begin
                    shift_cnt <= shift_cnt;
                    shift_en  <= 1'b0;
                end
                else begin
                    shift_en  <= 1'b1;
                    shift_cnt <= shift_cnt + 1'b1;
                end
            end 
            default:begin
                shift_en <= 1'b0;
                shift_cnt <= 2'b0;
            end
        endcase
    end
end


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
                pool_en    <= 4'b0;
                img_height <= 6'b0;
                img_width  <= 6'b0;
                conv_mode  <= 1'b0;
            end
            LAYER0: begin
                pool_en    <= 4'b1111;
                img_height <= 6'd62;
                img_width  <= 6'd50;
                conv_mode  <= 1'b0;
            end
            LAYER1: begin
                pool_en    <= 4'b0001;
                img_height <= 6'd31;
                img_width  <= 6'd25;
                conv_mode  <= 1'b0;
            end
            LAYER2: begin
                pool_en    <= 4'b0001;
                img_height <= 6'd15;
                img_width  <= 6'd12;
                conv_mode  <= 1'b0;
            end
            LAYER3: begin
                pool_en    <= 4'b0001;
                img_height <= 6'd7;
                img_width  <= 6'd6;
                conv_mode  <= 1'b0;
            end
            LAYER4: begin
                pool_en    <= 4'b0011;
                img_height <= 6'd1;
                img_width  <= 6'd16;
                conv_mode  <= 1'b1;
            end
            LAYER5: begin
                pool_en    <= 4'b0000;
                img_height <= 6'b0;
                img_width  <= 6'b0;
                conv_mode  <= 1'b0;
            end
            default: begin
                pool_en    <= 4'b0;
                img_height <= 6'b0;
                img_width  <= 6'b0;
                conv_mode  <= 1'b0;
            end
        endcase
    end
end

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
                    layer0_ready   <= 1'b1;
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
                            layer1_ready  <= 1'b1;
                        end
                        else begin
                            sram_write_id <= sram_write_id + 1'b1;
                        end
                    end
                    else begin
                        sram_write_select <= sram_write_select + 1'b1;
                    end
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
                            layer2_ready  <= 1'b1;
                        end
                        else begin
                            sram_write_id <= sram_write_id + 1'b1;
                        end
                    end
                    else begin
                        sram_write_select <= sram_write_select + 1'b1;
                    end
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
                        layer3_ready  <= 1'b1;
                    end
                    else sram_write_id <= sram_write_id + 1'b1;
                end
                else begin
                    sram_write_num <= sram_write_num + 1'b1;
                end
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
        sram_write_num    <= sram_write_num;
        sram_write_id     <= sram_write_id;
        sram_write_select <= sram_write_select;
        layer0_ready      <= 1'b0;
        layer1_ready      <= 1'b0;
        layer2_ready      <= 1'b0;
        layer3_ready      <= 1'b0;
    end
end

reg select_valid_ff0;
reg select_valid_ff1;
reg select_valid_ff2;
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        select_valid_ff0 <= 1'b0;
    end
    else begin
        case (current_state)
            LAYER1:begin
                if (current_state_ff == LAYER0) begin
                    select_valid_ff0 <= 1'b1;
                end
                else if(conv_end)begin
                    select_valid_ff0 <= 1'b1;
                end
                else if (conv_rs_end) begin
                    select_valid_ff0 <= 1'b0;
                end
            end 
            LAYER2:begin
                if (current_state_ff == LAYER1) begin
                    select_valid_ff0 <= 1'b1;
                end
                else if(conv_end)begin
                    select_valid_ff0 <= 1'b1;
                end
                else if (conv_rs_end) begin
                    select_valid_ff0 <= 1'b0;
                end
            end 
            LAYER3:begin
                if (current_state_ff == LAYER2) begin
                    select_valid_ff0 <= 1'b1;
                end
                else if(conv_end)begin
                    select_valid_ff0 <= 1'b1;
                end
                else if (conv_rs_end) begin
                    select_valid_ff0 <= 1'b0;
                end
            end 
            default: begin
                select_valid_ff0 <= 1'b0;
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        select_valid_ff1 <= 1'b0;
        select_valid_ff2 <= 1'b0;
    end
    else begin
        select_valid_ff1 <= select_valid_ff0;
        select_valid_ff2 <= select_valid_ff1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        select_din_valid <= 1'b0;
    end
    else begin
        case (current_state)
            IDLE:begin
                select_din_valid <= 1'b0;
            end 
            LAYER0:begin
                select_din_valid <= din_valid;
            end
            LAYER1,LAYER2,LAYER3:begin
                select_din_valid <= select_valid_ff2;
            end
            default:begin
                select_din_valid <= 1'b0;
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_read_num    <= 10'b0;
        sram_read_select <= 4'b0;
        sram_read_id     <= 2'b0;
    end 
    else if(select_valid_ff0) begin
        case (current_state)
            LAYER1: begin
                if (sram_read_num == 10'd774) begin
                    sram_read_num <= 10'b0;
                end 
                else if(select_valid_ff0) begin
                    sram_read_num <= sram_read_num + 1'b1;
                end
            end
            LAYER2: begin
                if (sram_read_num == 10'd179) begin
                    sram_read_num <= 10'b0;
                    if (sram_read_select == 4'd7) begin
                        sram_read_select <= 4'b0;
                        if (sram_read_id == 2'b01) begin
                            sram_read_id <= 2'b00;
                        end
                        else sram_read_id <= sram_read_id + 1'b1; 
                    end
                    else begin
                        sram_read_select <= sram_read_select + 1'b1; 
                    end
                end 
                else sram_read_num <= sram_read_num + 1'b1;
            end
            LAYER3: begin
                if (sram_read_num == 10'd41) begin
                    sram_read_num <= 10'b0;
                    if (sram_read_select == 4'd7) begin
                        sram_read_select <= 4'b0;
                        if (sram_read_id == 2'b11) begin
                            sram_read_id <= 2'b00;
                        end
                        else sram_read_id <= sram_read_id + 1'b1; 
                    end
                    else begin
                        sram_read_select <= sram_read_select + 1'b1; 
                    end
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
        sram_read_select <= sram_read_select;
        sram_read_id     <= sram_read_id;
    end
end

reg  [9:0] sram_addr0;
reg  [9:0] sram_addr1;
reg  [9:0] sram_addr2;
reg  [9:0] sram_addr3;
reg  [9:0] sram_addr4;
reg  [9:0] sram_addr5;
reg  [9:0] sram_addr6;
reg  [9:0] sram_addr7;

assign ram_addr = {sram_addr7, sram_addr6, sram_addr5, sram_addr4,
                   sram_addr3, sram_addr2, sram_addr1, sram_addr0};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sram_addr0 <= 10'b0;
        sram_addr1 <= 10'b0;
        sram_addr2 <= 10'b0;
        sram_addr3 <= 10'b0;
        sram_addr4 <= 10'b0;
        sram_addr5 <= 10'b0;
        sram_addr6 <= 10'b0;
        sram_addr7 <= 10'b0;
    end else begin
        case (current_state)
            LAYER0: begin
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
                sram_addr0 <= sram_read_num; 
                sram_addr1 <= sram_read_num;     
                sram_addr2 <= sram_read_num;     
                sram_addr3 <= sram_read_num;     
                sram_addr4 <= sram_write_num + sram_write_id * 10'd180;
                sram_addr5 <= sram_write_num + sram_write_id * 10'd180;
                sram_addr6 <= sram_write_num + sram_write_id * 10'd180;   
                sram_addr7 <= sram_write_num + sram_write_id * 10'd180;   
            end
            LAYER2: begin
                sram_addr0 <= sram_write_num + sram_write_id * 10'd42;
                sram_addr1 <= sram_write_num + sram_write_id * 10'd42; 
                sram_addr2 <= sram_write_num + sram_write_id * 10'd42;     
                sram_addr3 <= sram_write_num + sram_write_id * 10'd42;   
                sram_addr4 <= sram_read_num + sram_read_id * 10'd180;
                sram_addr5 <= sram_read_num + sram_read_id * 10'd180;
                sram_addr6 <= sram_read_num + sram_read_id * 10'd180;   
                sram_addr7 <= sram_read_num + sram_read_id * 10'd180;  
            end
            LAYER3: begin
                sram_addr0 <= sram_read_num + sram_read_id * 10'd42;  
                sram_addr1 <= sram_read_num + sram_read_id * 10'd42;    
                sram_addr2 <= sram_read_num + sram_read_id * 10'd42;  
                sram_addr3 <= sram_read_num + sram_read_id * 10'd42;  
                sram_addr4 <= 10'b0;
                sram_addr5 <= 10'b0;
                sram_addr6 <= 10'b0;
                sram_addr7 <= 10'b0;
            end
            default: begin
                sram_addr0 <= 10'b0;
                sram_addr1 <= 10'b0;
                sram_addr2 <= 10'b0;
                sram_addr3 <= 10'b0;
                sram_addr4 <= 10'b0;
                sram_addr5 <= 10'b0;
                sram_addr6 <= 10'b0;
                sram_addr7 <= 10'b0;
            end
        endcase
    end
end
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ram_we <= 8'b0;
    end 
    else begin
        case (current_state)
            IDLE: begin 
                ram_we <= 8'b0;
            end
            LAYER0: begin
                ram_we <= {4'b0, {4{maxpool_flag}}};
            end
            LAYER1: begin
                case (sram_write_select)
                    2'b00: ram_we <= {3'b000, maxpool_flag, 4'b0000}; 
                    2'b01: ram_we <= {2'b00, maxpool_flag, 5'b0000}; 
                    2'b10: ram_we <= {1'b0, maxpool_flag, 6'b0000}; 
                    2'b11: ram_we <= {maxpool_flag, 7'b0000}; 
                    default: ram_we <= 8'b0;
                endcase
            end
            LAYER2: begin
                case (sram_write_select)
                    2'b00: ram_we <= {7'b000, maxpool_flag}; 
                    2'b01: ram_we <= {6'b00, maxpool_flag, 1'b0}; 
                    2'b10: ram_we <= {5'b0, maxpool_flag, 2'b00}; 
                    2'b11: ram_we <= {4'b0, maxpool_flag, 3'b0000}; 
                    default: ram_we <= 8'b0;
                endcase
            end
            LAYER3: begin
                case (sram_write_select)
                    2'b00: ram_we <= {3'b000, maxpool_flag, 4'b0000}; 
                    2'b01: ram_we <= {2'b00, maxpool_flag, 5'b0000}; 
                    2'b10: ram_we <= {1'b0, maxpool_flag, 6'b0000}; 
                    2'b11: ram_we <= {maxpool_flag, 7'b0000}; 
                    default: ram_we <= 8'b0;
                endcase
            end
            default: begin
                ram_we <= 8'b0;
            end
        endcase
    end
end



endmodule
