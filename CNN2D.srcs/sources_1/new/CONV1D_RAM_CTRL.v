module CONV1D_RAM_CTRL#(
    parameter DIN_WIDTH = 8,
    parameter DOUT_WIDTH = 8
)
(
    input wire                  clk,
    input wire                  rst_n,
    input wire                  cnn_start,
    input wire [8:0]            top_state,
    input wire                  control,

    input wire                  avg_dout_valid,
    input wire                  maxpool_flag,
    input wire [DIN_WIDTH-1:0]  avg_pool_dout,
    input wire [DIN_WIDTH*2-1:0] maxpool_dout_2channel,

    output reg [6:0]            conv1D_ram_addr0,
    output reg [6:0]            conv1D_ram_addr1,
    output reg                    conv1D_din_valid,
    output reg [DOUT_WIDTH*4-1:0] ram_out
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

localparam state0 = 4'b0000;
localparam state1 = 4'b0011;  
localparam state2 = 4'b0111;
localparam state3 = 4'b1111;

reg [3:0] cur_state,next_state,cur_state_ff;
reg  [DIN_WIDTH-1:0] ram_din_mem[0:3];

reg  [DIN_WIDTH-1:0] ram_buffer0[0:6];
reg  [DIN_WIDTH-1:0] ram_buffer1[0:6];

wire [4*DIN_WIDTH-1:0] conv1D_ram0_din;
reg [4*DIN_WIDTH-1:0] conv1D_ram1_din;

reg  [2:0]             ram_cnt;
reg  [1:0]             conv1D_ram_wr;
reg  we_ok;
reg  [3:0] we_cnt;
wire [DOUT_WIDTH*4-1:0] ram0_out;
wire [DOUT_WIDTH*4-1:0] ram1_out;

reg [2:0] conv1D_channel;
reg [3:0] conv1D_num;
reg  conv1D_id;

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        we_cnt <= 4'b0;
        we_ok  <= 1'b0;
    end
    else if(cur_state == state2 && maxpool_flag) begin
        if (we_cnt == 4'd6) begin
            we_ok <= 1'b1;
            we_cnt <= we_cnt + 1'b1;
        end
        else if (we_cnt == 4'd13) begin
            we_ok <= 1'b0;
            we_cnt <= 4'b0;
        end
        else begin
            we_cnt <= we_cnt + 1'b1;
        end
    end
end


always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        ram_cnt <= 3'b0;
    end
    else begin
        case (cur_state)
            state1:begin
                if(avg_dout_valid) begin
                    if (ram_cnt == 3'b011) begin
                        ram_cnt <= 3'b0;
                    end
                    else ram_cnt <= ram_cnt + 1'b1;
                end
            end 
            state2:begin
                if (maxpool_flag) begin
                    if (ram_cnt == 3'd6) begin
                        ram_cnt <= 3'b0;
                    end
                    else ram_cnt <= ram_cnt + 1'b1;
                end
            end
            default:ram_cnt <= 3'b0; 
        endcase
    end

end
integer i;
integer j;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 4; i = i + 1) begin
            ram_din_mem[i] <= 8'b0;
        end
        for (j = 0; j < 7; j = j + 1) begin
            ram_buffer0[j] <= 8'b0;
            ram_buffer1[j] <= 8'b0;
        end
    end
    else begin
        case (cur_state)
            state1:begin
                if(avg_dout_valid) begin
                    ram_din_mem[ram_cnt] <= avg_pool_dout;
                end
            end 
            state2:begin
                if (maxpool_flag && !we_ok) begin
                    ram_buffer0[ram_cnt] <= maxpool_dout_2channel[DIN_WIDTH-1:0];
                    ram_buffer1[ram_cnt] <= maxpool_dout_2channel[DIN_WIDTH*2-1:DIN_WIDTH];
                end
            end
            default:begin
                for (i = 0; i < 4; i = i + 1) begin
                    ram_din_mem[i] <= 8'b0;
                end
                for (j = 0; j < 7; j = j + 1) begin
                    ram_buffer0[j] <= 8'b0;
                    ram_buffer1[j] <= 8'b0;
                end
            end
        endcase
    end
end

generate
    genvar k;
    for (k = 0; k < 4; k = k + 1) begin
        assign conv1D_ram0_din[DIN_WIDTH*k+:DIN_WIDTH] = ram_din_mem[k];
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        conv1D_ram1_din <= 32'b0;
    end
    else if(we_ok) begin
        conv1D_ram1_din <= {maxpool_dout_2channel,ram_buffer1[ram_cnt],ram_buffer0[ram_cnt]};
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        cur_state <= state0;        
    end
    else begin
        cur_state <= next_state;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        cur_state_ff <= state0;
    end
    else begin
        cur_state_ff <= cur_state;
    end
end

always @(*) begin
    case (cur_state)
        state0:begin
            next_state = top_state == LAYER3 ? state1 : state0;
        end 
        state1:begin
            next_state = (conv1D_ram_addr0 == 7'd127 && conv1D_ram_wr[0]) ? state2 : state1;
        end
        state2:begin
            next_state = (conv1D_ram_addr1 == 7'd56) ? state3 : state2;
        end
        state3:begin
            next_state = top_state == LAYER6 ? state0 : state3;
        end
        default: next_state = state0;
    endcase
end

reg conv1D_din_valid0;
reg conv1D_din_valid1;
reg conv1D_din_valid2;
reg read_all0, read_all1;
reg control_ff;
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        control_ff <= 1'b0;
    end
    else begin
        control_ff <= control;
    end
end
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        conv1D_din_valid0 <= 1'b0;
    end
    else begin
        case (cur_state)
            state0,state1:begin
                conv1D_din_valid0 <= 1'b0;
            end 
            state2:begin
                if (conv1D_ram_addr0 == 7'd127 && read_all0) begin
                    conv1D_din_valid0 <= 1'b0;
                end
                else if ((control_ff || control) && !read_all0) begin
                    conv1D_din_valid0 <= ~conv1D_din_valid0;
                end
                else if (cur_state_ff == state1) begin
                    conv1D_din_valid0 <= 1'b1;
                end
            end
            state3:begin
                if (cur_state_ff == state2) begin
                    conv1D_din_valid0 <= 1'b1;
                end
                else if (conv1D_ram_addr0 == 7'd55 && read_all1) begin
                    conv1D_din_valid0 <= 1'b0;
                end
                else if ((control_ff || control) && !read_all1) begin
                    conv1D_din_valid0 <= ~conv1D_din_valid0;
                end
            end
            default: conv1D_din_valid0 <= 1'b0;
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        conv1D_din_valid  <= 1'b0;
        conv1D_din_valid1 <= 1'b0;
        conv1D_din_valid2 <= 1'b0;
    end
    else if (control) begin
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

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        ram_out <= 32'b0;
    end
    else begin
        case (cur_state)
            state2:begin
                ram_out <= ram0_out;
            end 
            state3:begin
                ram_out <= ram1_out;
            end 
            default: ram_out <= 32'b0;
        endcase
    end
end


always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_num     <= 5'b0;
        conv1D_id      <= 1'b0;
        conv1D_channel <= 3'b0;
        read_all0      <= 1'b0;
        read_all1      <= 1'b0;
    end
    else if(conv1D_din_valid0) begin
        case (top_state)
            LAYER4: begin
                if (conv1D_num == 5'd15) begin
                    conv1D_num <= 5'b0;
                    if (conv1D_id == 1'b1) begin
                        conv1D_id <= 1'b0;
                        if (conv1D_channel == 3'b111) begin
                            conv1D_channel <= 3'b0;
                            read_all0 <= 1'b1;
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
                            read_all0 <= 1'b1;
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
        conv1D_id  <= conv1D_id;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_ram_addr0 <= 6'b0;
        conv1D_ram_addr1 <= 6'b0;
    end
    else begin
        case (cur_state)
            state0:begin
                conv1D_ram_addr0 <= 6'b0;
                conv1D_ram_addr1 <= 6'b0;
            end 
            state1:begin
                if (conv1D_ram_wr[0]) begin
                    conv1D_ram_addr0 <= conv1D_ram_addr0 + 1'b1;
                    conv1D_ram_addr1 <= 6'b0;
                end
            end
            state2:begin
                if (conv1D_ram_wr[1]) begin
                    conv1D_ram_addr1 <= conv1D_ram_addr1 + 1'b1;
                end
                conv1D_ram_addr0 <= conv1D_channel + (conv1D_num << 3);
            end
            state3:begin
                conv1D_ram_addr1 <= (conv1D_channel*7) + conv1D_num;
            end
            default: conv1D_ram_addr0 <= 6'b0;
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        conv1D_ram_wr <= 2'b0;
    end
    else begin
        case (cur_state)
            state0,state3:begin
                conv1D_ram_wr <= 2'b0;
            end
            state1:begin
                if(ram_cnt == 3'b011 && avg_dout_valid) begin
                    conv1D_ram_wr <= 2'b01;
                end
                else begin
                    conv1D_ram_wr <= 2'b00;
                end
            end 
            state2:begin
                if (we_ok) begin
                    conv1D_ram_wr[0] <= 1'b0;
                    conv1D_ram_wr[1] <= maxpool_flag;
                end
                else begin
                    conv1D_ram_wr <= 2'b0;
                end
            end
            default:conv1D_ram_wr <= 2'b0;
        endcase
    end
end

CONV1D_RAM u_CONV1D_RAM0(
    .clka  (clk             ),
    .ena   (cnn_start       ),
    .wea   (conv1D_ram_wr[0]),
    .addra (conv1D_ram_addr0) ,
    .dina  (conv1D_ram0_din  ),
    .douta (ram0_out        )
);

CONV1D_RAM u_CONV1D_RAM1(
    .clka  (clk             ),
    .ena   (cnn_start       ),
    .wea   (conv1D_ram_wr[1]),
    .addra (conv1D_ram_addr1),
    .dina  (conv1D_ram1_din   ),
    .douta (ram1_out        )
);



endmodule