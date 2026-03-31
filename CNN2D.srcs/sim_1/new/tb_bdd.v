/*
 * @Author: Zuo Zhang
 * @Date: 2026-03-28 18:27:30
 * @email: zhangzuo24@m.fudan.edu.cn
 * @github: https://github.com/zuoupup
 * @LastEditors: Zuo Zhang
 * @LastEditTime: 2026-03-28 18:55:06
 * @Description: This is a part of the Radar-AI Accelerator Design
 */
`timescale 1ns / 1ps

module tb_bdd();

    localparam DATA_WIDTH   = 8;
    localparam CLK_PERIOD   = 10;
    localparam FRAME_NUM    = 16;
    localparam DELTA_THRESHOLD = 7;
    localparam TOTAL_NUM    = 49600;

    reg                     clk;
    reg                     rst_n;
    reg                     din_valid;
    reg  [DATA_WIDTH-1:0]   raw_data;
    wire                    trigger_pluse;
    integer                 i;
    integer                 ret;
    integer                 fp;
    reg [DATA_WIDTH-1:0] mem_data [0:TOTAL_NUM-1];
    integer temp_val;


    bdd #(
        .DATA_WIDTH (DATA_WIDTH),
        .DELTA_THRESHOLD (DELTA_THRESHOLD),
        .FRAME_NUM (FRAME_NUM)
    ) inst_bdd (
        .clk(clk),
        .rst_n(rst_n),
        .raw_data(raw_data),
        .din_valid(din_valid),
        .trigger_pluse(trigger_pluse)
    );

    // Clock define
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        fp = $fopen("../../../../data/layer_0_input.txt", "r");
        if (fp == 0) begin
            $display("ERROR: cannot open file layer_0_input.txt");
            $finish;
        end

        for (i = 0; i < TOTAL_NUM; i = i + 1) begin
            ret = $fscanf(fp, "%d\n", temp_val);
            if (ret != 1) begin
                $display("ERROR: file data not enough or format error at index %0d", i);
                $finish;
            end

            if (temp_val < 0 || temp_val > 255) begin
                $display("WARNING: data out of 8-bit range at index %0d, val=%0d", i, temp_val);
            end

            mem_data[i] = temp_val[DATA_WIDTH-1:0];
        end

        $fclose(fp);
        $display("INFO: loaded %0d samples from txt.", TOTAL_NUM);
    end


    // --------------------------------------------------
    // stimulus
    // --------------------------------------------------
    initial begin
        rst_n          = 1'b0;
        din_valid       = 1'b0;
        raw_data = {DATA_WIDTH{1'b0}};

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 连续送 16*62*50 个点
        @(posedge clk);
        din_valid <= 1'b1;

        for (i = 0; i < TOTAL_NUM; i = i + 1) begin
            raw_data <= mem_data[i];
            @(posedge clk);
        end

        // 输入结束
        din_valid       <= 1'b0;
        raw_data <= 0;

        repeat (50) @(posedge clk);
        $finish;
    end

endmodule