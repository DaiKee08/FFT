module multiply #(
    parameter WIDTH = 16
)(
    input  signed [WIDTH-1:0] a_re,
    input  signed [WIDTH-1:0] a_im,
    input  signed [WIDTH-1:0] b_re,
    input  signed [WIDTH-1:0] b_im,
    output signed [WIDTH-1:0] m_re,
    output signed [WIDTH-1:0] m_im
);

    localparam SHIFT = WIDTH - 1;

    wire signed [2*WIDTH-1:0] ar_br = a_re * b_re;
    wire signed [2*WIDTH-1:0] ar_bi = a_re * b_im;
    wire signed [2*WIDTH-1:0] ai_br = a_im * b_re;
    wire signed [2*WIDTH-1:0] ai_bi = a_im * b_im;

    wire signed [WIDTH-1:0] ar_br_q = ar_br >>> SHIFT;
    wire signed [WIDTH-1:0] ar_bi_q = ar_bi >>> SHIFT;
    wire signed [WIDTH-1:0] ai_br_q = ai_br >>> SHIFT;
    wire signed [WIDTH-1:0] ai_bi_q = ai_bi >>> SHIFT;

    assign m_re = ar_br_q - ai_bi_q;
    assign m_im = ar_bi_q + ai_br_q;

endmodule
