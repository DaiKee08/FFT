module fft_ctr #(
    parameter DW    = 32,       // data width (16-bit re + 16-bit im)
    parameter AW    = 9,        // SRAM address width (512 words)
    parameter N     = 1024,     // FFT length
    parameter STAGES= 10        // log2(N)
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,      // pulse to begin FFT

    output reg  [3:0]        bank_sel,   // chip-enable per bank (active-low)
    output reg  [3:0]        wen_sel,    // write-enable per bank (active-low)
    output reg               rd_pair_sel,// 0: read from {0,1}; 1: read from {2,3} (registered)
    output reg  [AW-1:0]     rd_addr_0,
    output reg  [AW-1:0]     rd_addr_1,
    output reg  [AW-1:0]     wr_addr_0,
    output reg  [AW-1:0]     wr_addr_1,
    output reg  [DW-1:0]     wr_din_0,
    output reg  [DW-1:0]     wr_din_1,
    input  wire [DW-1:0]     rd_dout_0,  // read data from bank-pair port 0
    input  wire [DW-1:0]     rd_dout_1,  // read data from bank-pair port 1

    output reg               tw_cen,     // active-low chip enable
    output reg  [AW-1:0]     tw_addr,
    input  wire [DW-1:0]     tw_dout,    // {tw_re[15:0], tw_im[15:0]}

    output reg               done        // pulse when FFT complete
);

localparam S_IDLE   = 3'd0,
           S_RUN    = 3'd1,
           S_WAIT   = 3'd2,  // flush pipeline between stages
           S_FLUSH  = 3'd3,  // flush pipeline after last stage
           S_DONE   = 3'd4;

reg  [2:0]  state, nxt_state;
reg  [3:0]  stage_cnt;       // current FFT stage (0..9)
reg  [8:0]  bf_cnt;          // butterfly counter within stage (0..511)
reg         ping;            // 0: read from {0,1}, write to {2,3}; 1: swap
reg  [1:0]  wait_cnt;        // counts flush cycles between stages

reg         p1_valid;
reg  [3:0]  p1_stage;
reg  [8:0]  p1_bf;
reg         p1_swap;         // need to swap rd_dout_0/1 for butterfly order
reg         p1_ping;

reg         p2_valid;
reg  [3:0]  p2_stage;
reg  [8:0]  p2_bf;
reg         p2_ping;
reg  signed [15:0] p2_y0_re, p2_y0_im;
reg  signed [15:0] p2_y1_re, p2_y1_im;
reg  [AW-1:0] p2_wr_addr_0, p2_wr_addr_1;
reg            p2_wr_swap;   // which dest bank gets y0 vs y1

wire signed [15:0] x0_re, x0_im, x1_re, x1_im;

reg  signed [15:0] p2_tw_re, p2_tw_im;

wire signed [15:0] bf_y0_re, bf_y0_im, bf_y1_re, bf_y1_im;

wire signed [15:0] mul_re, mul_im;

function [0:0] parity10;
    input [9:0] idx;
    parity10 = ^idx;   // reduction XOR
endfunction

reg [9:0] a_idx_comb, b_idx_comb;
reg [8:0] tw_idx_comb;
reg       a_bank_comb, b_bank_comb;    // XOR-parity bank assignment
reg       swap_comb;                    // 1 if a is in bank 1 (need swap)

always @(*) begin : addr_gen
    reg [3:0] sbit;     // bit position = 9 - stage_cnt
    reg [9:0] lo, hi;
    sbit = 4'd9 - stage_cnt;

    lo = bf_cnt & ((1 << sbit) - 1);               // bits below sbit
    hi = ({1'b0, bf_cnt} >> sbit) << (sbit + 1);   // bits above sbit, shifted up (10-bit to avoid overflow)
    a_idx_comb = hi[9:0] | lo[9:0];                // bit sbit = 0
    b_idx_comb = a_idx_comb | (10'd1 << sbit);     // bit sbit = 1

    a_bank_comb = parity10(a_idx_comb);
    b_bank_comb = parity10(b_idx_comb);  // always = ~a_bank_comb

    swap_comb = a_bank_comb;   // 0 → a in bank0(normal), 1 → a in bank1(swap)

    tw_idx_comb = (bf_cnt & ((9'd1 << sbit) - 9'd1)) << stage_cnt;
end

reg [9:0]  p1_a_idx, p1_b_idx;
reg        p1_a_bank, p1_b_bank;

always @(*) begin : wr_addr_gen
    reg [3:0] sbit;
    reg [9:0] lo, hi;
    sbit = 4'd9 - p1_stage;

    lo = p1_bf & ((1 << sbit) - 1);
    hi = ({1'b0, p1_bf} >> sbit) << (sbit + 1);
    p1_a_idx = hi[9:0] | lo[9:0];
    p1_b_idx = p1_a_idx | (10'd1 << sbit);

    p1_a_bank = parity10(p1_a_idx);
    p1_b_bank = parity10(p1_b_idx);
end

assign x0_re = p1_swap ? rd_dout_1[31:16] : rd_dout_0[31:16];
assign x0_im = p1_swap ? rd_dout_1[15:0]  : rd_dout_0[15:0];
assign x1_re = p1_swap ? rd_dout_0[31:16] : rd_dout_1[31:16];
assign x1_im = p1_swap ? rd_dout_0[15:0]  : rd_dout_1[15:0];

Butterfly #(.WIDTH(16), .RH(0)) u_bf (
    .x0_re(x0_re), .x0_im(x0_im),
    .x1_re(x1_re), .x1_im(x1_im),
    .y0_re(bf_y0_re), .y0_im(bf_y0_im),
    .y1_re(bf_y1_re), .y1_im(bf_y1_im)
);

Multiply #(.WIDTH(16)) u_mul (
    .a_re(p2_y1_re), .a_im(p2_y1_im),
    .b_re(p2_tw_re),  .b_im(p2_tw_im),
    .m_re(mul_re),    .m_im(mul_im)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= S_IDLE;
    else
        state <= nxt_state;
end

always @(*) begin
    nxt_state = state;
    case (state)
        S_IDLE:  if (start)      nxt_state = S_RUN;
        S_RUN:   if (bf_cnt == 9'd511) begin
                     if (stage_cnt == STAGES-1)
                         nxt_state = S_FLUSH;
                     else
                         nxt_state = S_WAIT;
                 end
        S_WAIT:  if (wait_cnt == 2'd2)
                                 nxt_state = S_RUN;
        S_FLUSH: if (!p1_valid && !p2_valid)
                                 nxt_state = S_DONE;
        S_DONE:                  nxt_state = S_IDLE;
        default:                 nxt_state = S_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stage_cnt <= 4'd0;
        bf_cnt    <= 9'd0;
        ping      <= 1'b0;
        wait_cnt  <= 2'd0;
    end else if (state == S_IDLE && start) begin
        stage_cnt <= 4'd0;
        bf_cnt    <= 9'd0;
        ping      <= 1'b0;
        wait_cnt  <= 2'd0;
    end else if (state == S_RUN) begin
        if (bf_cnt == 9'd511) begin
            bf_cnt   <= 9'd0;
            wait_cnt <= 2'd0;
        end else begin
            bf_cnt <= bf_cnt + 9'd1;
        end
    end else if (state == S_WAIT) begin
        wait_cnt <= wait_cnt + 2'd1;
        if (wait_cnt == 2'd2) begin
            stage_cnt <= stage_cnt + 4'd1;
            ping      <= ~ping;
        end
    end
end

wire rd_issue = (state == S_RUN);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p1_valid    <= 1'b0;
        p1_stage    <= 4'd0;
        p1_bf       <= 9'd0;
        p1_swap     <= 1'b0;
        p1_ping     <= 1'b0;
        rd_pair_sel <= 1'b0;
    end else begin
        p1_valid <= rd_issue;
        if (rd_issue) begin
            p1_stage    <= stage_cnt;
            p1_bf       <= bf_cnt;
            p1_swap     <= swap_comb;
            p1_ping     <= ping;
            rd_pair_sel <= ping;  // select read pair for next cycle's data
        end else begin
            rd_pair_sel <= 1'b0;
        end
    end
end

always @(*) begin
    if (rd_issue) begin
        if (!swap_comb) begin
            rd_addr_0 = a_idx_comb[8:0];
            rd_addr_1 = b_idx_comb[8:0];
        end else begin
            rd_addr_0 = b_idx_comb[8:0];
            rd_addr_1 = a_idx_comb[8:0];
        end
        tw_addr = tw_idx_comb;
        tw_cen  = 1'b0;  // active low — enable
    end else begin
        rd_addr_0 = {AW{1'b0}};
        rd_addr_1 = {AW{1'b0}};
        tw_addr   = {AW{1'b0}};
        tw_cen    = 1'b1;  // disabled
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p2_tw_re <= 16'd0;
        p2_tw_im <= 16'd0;
    end else if (p1_valid) begin
        p2_tw_re <= tw_dout[31:16];
        p2_tw_im <= tw_dout[15:0];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p2_valid    <= 1'b0;
        p2_stage    <= 4'd0;
        p2_bf       <= 9'd0;
        p2_ping     <= 1'b0;
        p2_y0_re    <= 16'd0;
        p2_y0_im    <= 16'd0;
        p2_y1_re    <= 16'd0;
        p2_y1_im    <= 16'd0;
        p2_wr_addr_0<= {AW{1'b0}};
        p2_wr_addr_1<= {AW{1'b0}};
        p2_wr_swap  <= 1'b0;
    end else begin
        p2_valid <= p1_valid;
        if (p1_valid) begin
            p2_stage <= p1_stage;
            p2_bf    <= p1_bf;
            p2_ping  <= p1_ping;

            p2_y0_re <= bf_y0_re;
            p2_y0_im <= bf_y0_im;

            p2_y1_re <= bf_y1_re;
            p2_y1_im <= bf_y1_im;

            if (!p1_a_bank) begin
                p2_wr_addr_0 <= p1_a_idx[8:0];
                p2_wr_addr_1 <= p1_b_idx[8:0];
                p2_wr_swap   <= 1'b0;
            end else begin
                p2_wr_addr_0 <= p1_b_idx[8:0];
                p2_wr_addr_1 <= p1_a_idx[8:0];
                p2_wr_swap   <= 1'b1;
            end
        end
    end
end

wire signed [15:0] final_y1_re = mul_re;
wire signed [15:0] final_y1_im = mul_im;

always @(*) begin
    bank_sel    = 4'b1111;
    wen_sel     = 4'b1111;
    wr_addr_0   = {AW{1'b0}};
    wr_addr_1   = {AW{1'b0}};
    wr_din_0    = {DW{1'b0}};
    wr_din_1    = {DW{1'b0}};

    if (rd_issue) begin
        if (!ping) begin
            bank_sel[0] = 1'b0;  // enable bank 0
            bank_sel[1] = 1'b0;  // enable bank 1
        end else begin
            bank_sel[2] = 1'b0;
            bank_sel[3] = 1'b0;
        end
    end

    if (p2_valid) begin
        if (!p2_ping) begin
            bank_sel[2] = 1'b0;
            bank_sel[3] = 1'b0;
            wen_sel[2]  = 1'b0;  // enable write
            wen_sel[3]  = 1'b0;
        end else begin
            bank_sel[0] = 1'b0;
            bank_sel[1] = 1'b0;
            wen_sel[0]  = 1'b0;
            wen_sel[1]  = 1'b0;
        end

        if (!p2_wr_swap) begin
            wr_addr_0 = p2_wr_addr_0;
            wr_addr_1 = p2_wr_addr_1;
            wr_din_0  = {p2_y0_re, p2_y0_im};
            wr_din_1  = {final_y1_re, final_y1_im};
        end else begin
            wr_addr_0 = p2_wr_addr_0;
            wr_addr_1 = p2_wr_addr_1;
            wr_din_0  = {final_y1_re, final_y1_im};
            wr_din_1  = {p2_y0_re, p2_y0_im};
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        done <= 1'b0;
    else
        done <= (state == S_DONE);
end

endmodule
