module Butterfly #(
    parameter WIDTH = 16,
    parameter RH    = 0
)(
    input  signed [WIDTH-1:0] x0_re,
    input  signed [WIDTH-1:0] x0_im,
    input  signed [WIDTH-1:0] x1_re,
    input  signed [WIDTH-1:0] x1_im,
    output signed [WIDTH-1:0] y0_re,
    output signed [WIDTH-1:0] y0_im,
    output signed [WIDTH-1:0] y1_re,
    output signed [WIDTH-1:0] y1_im
);

    wire signed [WIDTH:0] sum_re  = x0_re + x1_re;
    wire signed [WIDTH:0] sum_im  = x0_im + x1_im;
    wire signed [WIDTH:0] diff_re = x0_re - x1_re;
    wire signed [WIDTH:0] diff_im = x0_im - x1_im;

    assign y0_re = (sum_re  + RH) >>> 1;
    assign y0_im = (sum_im  + RH) >>> 1;
    assign y1_re = (diff_re + RH) >>> 1;
    assign y1_im = (diff_im + RH) >>> 1;

endmodule
