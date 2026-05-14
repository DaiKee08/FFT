module fft_top #(
    parameter DW     = 32,
    parameter AW     = 9,
    parameter N      = 1024,
    parameter STAGES = 10
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output wire          done,

    input  wire          ext_wen,
    input  wire          ext_rd_en,
    input  wire [1:0]    ext_bank,
    input  wire [AW-1:0] ext_addr,
    input  wire [DW-1:0] ext_din,

    input  wire          tw_ext_wen,
    input  wire [AW-1:0] tw_ext_addr,
    input  wire [DW-1:0] tw_ext_din,

    input  wire [AW-1:0] ext_rd_addr_0,
    input  wire [AW-1:0] ext_rd_addr_1,
    input  wire [1:0]    ext_rd_pair,
    output wire [DW-1:0] ext_rd_dout_0,
    output wire [DW-1:0] ext_rd_dout_1
);

    localparam [3:0] BANK_NONE = 4'b1111;
    localparam [3:0] BANK_01   = 4'b1100;
    localparam [3:0] BANK_23   = 4'b0011;

    wire [3:0]    ctr_bank_sel;
    wire [3:0]    ctr_wen_sel;
    wire          ctr_rd_pair_sel;
    wire [AW-1:0] ctr_rd_addr_0, ctr_rd_addr_1;
    wire [AW-1:0] ctr_wr_addr_0, ctr_wr_addr_1;
    wire [DW-1:0] ctr_wr_din_0,  ctr_wr_din_1;
    wire          ctr_tw_cen;
    wire [AW-1:0] ctr_tw_addr;

    wire [DW-1:0] rd_dout_0, rd_dout_1;
    wire [DW-1:0] tw_dout;

    reg  [3:0]    mem_bank_sel;
    reg  [3:0]    mem_wen_sel;
    reg           mem_rd_pair_sel;
    reg  [AW-1:0] mem_rd_addr_0, mem_rd_addr_1;
    reg  [AW-1:0] mem_wr_addr_0, mem_wr_addr_1;
    reg  [DW-1:0] mem_wr_din_0,  mem_wr_din_1;

    function [3:0] active_low_onehot;
        input [1:0] idx;
        begin
            active_low_onehot = BANK_NONE;
            active_low_onehot[idx] = 1'b0;
        end
    endfunction

    always @(*) begin
        mem_bank_sel    = ctr_bank_sel;
        mem_wen_sel     = ctr_wen_sel;
        mem_rd_pair_sel = ctr_rd_pair_sel;
        mem_rd_addr_0   = ctr_rd_addr_0;
        mem_rd_addr_1   = ctr_rd_addr_1;
        mem_wr_addr_0   = ctr_wr_addr_0;
        mem_wr_addr_1   = ctr_wr_addr_1;
        mem_wr_din_0    = ctr_wr_din_0;
        mem_wr_din_1    = ctr_wr_din_1;

        if (ext_wen) begin
            mem_bank_sel    = active_low_onehot(ext_bank);
            mem_wen_sel     = active_low_onehot(ext_bank);
            mem_rd_pair_sel = 1'b0;
            mem_rd_addr_0   = {AW{1'b0}};
            mem_rd_addr_1   = {AW{1'b0}};
            mem_wr_addr_0   = ext_addr;
            mem_wr_addr_1   = ext_addr;
            mem_wr_din_0    = ext_din;
            mem_wr_din_1    = ext_din;
        end else if (ext_rd_en) begin
            mem_bank_sel    = ext_rd_pair[0] ? BANK_23 : BANK_01;
            mem_wen_sel     = BANK_NONE;
            mem_rd_pair_sel = ext_rd_pair[0];
            mem_rd_addr_0   = ext_rd_addr_0;
            mem_rd_addr_1   = ext_rd_addr_1;
            mem_wr_addr_0   = {AW{1'b0}};
            mem_wr_addr_1   = {AW{1'b0}};
            mem_wr_din_0    = {DW{1'b0}};
            mem_wr_din_1    = {DW{1'b0}};
        end
    end

    wire          tw_cen  = tw_ext_wen ? 1'b0       : ctr_tw_cen;
    wire          tw_wen  = tw_ext_wen ? 1'b0       : 1'b1;
    wire [AW-1:0] tw_addr = tw_ext_wen ? tw_ext_addr : ctr_tw_addr;
    wire [DW-1:0] tw_din  = tw_ext_wen ? tw_ext_din  : {DW{1'b0}};

    data_sram_system u_data_sram (
        .clk        (clk),
        .bank_sel   (mem_bank_sel),
        .wen_sel    (mem_wen_sel),
        .rd_pair_sel(mem_rd_pair_sel),
        .rd_addr_0  (mem_rd_addr_0),
        .rd_addr_1  (mem_rd_addr_1),
        .rd_dout_0  (rd_dout_0),
        .rd_dout_1  (rd_dout_1),
        .wr_addr_0  (mem_wr_addr_0),
        .wr_addr_1  (mem_wr_addr_1),
        .wr_din_0   (mem_wr_din_0),
        .wr_din_1   (mem_wr_din_1)
    );

    assign ext_rd_dout_0 = rd_dout_0;
    assign ext_rd_dout_1 = rd_dout_1;

    tw_sram_wrapper u_tw_sram (
        .clk (clk),
        .cen (tw_cen),
        .wen (tw_wen),
        .addr(tw_addr),
        .din (tw_din),
        .dout(tw_dout)
    );

    fft_ctr #(.DW(DW), .AW(AW), .N(N), .STAGES(STAGES)) u_fft_ctr (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .done       (done),
        .bank_sel   (ctr_bank_sel),
        .wen_sel    (ctr_wen_sel),
        .rd_pair_sel(ctr_rd_pair_sel),
        .rd_addr_0  (ctr_rd_addr_0),
        .rd_addr_1  (ctr_rd_addr_1),
        .wr_addr_0  (ctr_wr_addr_0),
        .wr_addr_1  (ctr_wr_addr_1),
        .wr_din_0   (ctr_wr_din_0),
        .wr_din_1   (ctr_wr_din_1),
        .rd_dout_0  (rd_dout_0),
        .rd_dout_1  (rd_dout_1),
        .tw_cen     (ctr_tw_cen),
        .tw_addr    (ctr_tw_addr),
        .tw_dout    (tw_dout)
    );

endmodule
