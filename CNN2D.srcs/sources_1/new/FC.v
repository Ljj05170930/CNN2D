`timescale 1ns / 1ps
module FC #(
    parameter DIN_WIDTH = 8,
    parameter NUM       = 9
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire [8:0]                    top_state,
    input  wire                          maxpool_valid_ff,
    input  wire [7:0]                    FC_din,
    input  wire                          avg_dout_cov1D_valid,
    input  wire [15:0]                   avg_pool_cov1D_dout,
    output reg                           layer5_ready,
    output reg                           layer6_ready,
    output reg [4:0]                     fc_cnt, 
    output wire [32*DIN_WIDTH-1:0]       fc_din
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

    reg [DIN_WIDTH-1:0] fc_rem0 [0:31];
    reg [DIN_WIDTH-1:0] fc_rem1 [0:31];
    integer j;

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            fc_cnt       <= 4'b0;
            layer5_ready <= 1'b0;
            layer6_ready <= 1'b0;
        end
        else begin
            case (top_state)
                LAYER5: begin
                    if (avg_dout_cov1D_valid) begin
                        if (fc_cnt == 5'd15) begin
                            fc_cnt       <= 5'b0;
                            layer5_ready <= 1'b1;
                        end
                        else begin
                            fc_cnt <= fc_cnt + 1'b1;
                        end
                    end
                end
                LAYER6: begin
                    if (maxpool_valid_ff) begin
                        if(fc_cnt == 5'd31)begin
                            layer6_ready <= 1'b1;
                            fc_cnt  <= 5'b0;
                        end
                        else fc_cnt <= fc_cnt + 1'b1;
                    end
                end
                default: begin
                    fc_cnt       <= 4'b0;
                    layer5_ready <= 1'b0;
                    layer6_ready <= 1'b0;
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (j = 0; j < 32; j = j + 1)begin
                fc_rem0[j] <= 8'b0;
                fc_rem1[j] <= 8'b0;
            end
        end
        else begin
            case (top_state)
                LAYER5:begin
                    if (avg_dout_cov1D_valid) begin
                        fc_rem0[fc_cnt << 1]   <= avg_pool_cov1D_dout[7:0];
                        fc_rem0[(fc_cnt << 1) + 1] <= avg_pool_cov1D_dout[15:8];
                    end
                end 
                LAYER6:begin
                    if (maxpool_valid_ff) begin
                        fc_rem1[fc_cnt]   <= FC_din;
                    end
                end 
                LAYER7:begin
                    for (j = 0; j < 32; j = j + 1)begin
                        fc_rem0[j] <= fc_rem0[j];
                        fc_rem1[j] <= fc_rem1[j];
                    end
                end
                default: begin
                    for (j = 0; j < 32; j = j + 1)begin
                        fc_rem0[j] <= 8'b0;
                        fc_rem1[j] <= 8'b0;
                    end
                end 
            endcase
        end
    end

wire [DIN_WIDTH-1:0] fc_rem_sel [0:31];
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : rem_mux
            assign fc_rem_sel[i] = (top_state == LAYER6) ? fc_rem0[i] : fc_rem1[i];
        end
    endgenerate
    assign fc_din[DIN_WIDTH*NUM-1:0]                 = {fc_rem_sel[8], fc_rem_sel[7], fc_rem_sel[6], fc_rem_sel[5], fc_rem_sel[4], fc_rem_sel[3], fc_rem_sel[2], fc_rem_sel[1], fc_rem_sel[0]};
    assign fc_din[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM]   = {fc_rem_sel[17],fc_rem_sel[16],fc_rem_sel[15],fc_rem_sel[14],fc_rem_sel[13],fc_rem_sel[12],fc_rem_sel[11],fc_rem_sel[10],fc_rem_sel[9]};
    assign fc_din[DIN_WIDTH*NUM*3-1:2*DIN_WIDTH*NUM] = {fc_rem_sel[26],fc_rem_sel[25],fc_rem_sel[24],fc_rem_sel[23],fc_rem_sel[22],fc_rem_sel[21],fc_rem_sel[20],fc_rem_sel[19],fc_rem_sel[18]};
    assign fc_din[32*DIN_WIDTH-1:3*DIN_WIDTH*NUM]    = {fc_rem_sel[31],fc_rem_sel[30],fc_rem_sel[29],fc_rem_sel[28],fc_rem_sel[27]};



endmodule