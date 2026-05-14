`timescale 1ns/1ps

module tb_fft;

    localparam int DW        = 32;
    localparam int AW        = 9;
    localparam int N         = 1024;
    localparam int STAGES    = 10;
    localparam int TW_N      = 512;
    localparam int CLK_HALF  = 5;
    localparam int READ_WAIT = 2;

    reg             clk;
    reg             rst_n;
    reg             start;
    wire            done;

    reg             ext_wen;
    reg             ext_rd_en;
    reg  [1:0]      ext_bank;
    reg  [AW-1:0]   ext_addr;
    reg  [DW-1:0]   ext_din;

    reg             tw_ext_wen;
    reg  [AW-1:0]   tw_ext_addr;
    reg  [DW-1:0]   tw_ext_din;

    reg  [AW-1:0]   ext_rd_addr_0;
    reg  [AW-1:0]   ext_rd_addr_1;
    reg  [1:0]      ext_rd_pair;
    wire [DW-1:0]   ext_rd_dout_0;
    wire [DW-1:0]   ext_rd_dout_1;

    reg  [15:0]     input_data  [0:N-1];
    reg  [31:0]     twiddle_data[0:TW_N-1];

    integer i;
    integer fp_out;
    reg [9:0]  point_idx;
    reg        bank_id;
    reg [15:0] val16;
    reg [31:0] val32;

    fft_top #(
        .DW(DW),
        .AW(AW),
        .N(N),
        .STAGES(STAGES)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .done         (done),
        .ext_wen      (ext_wen),
        .ext_rd_en    (ext_rd_en),
        .ext_bank     (ext_bank),
        .ext_addr     (ext_addr),
        .ext_din      (ext_din),
        .tw_ext_wen   (tw_ext_wen),
        .tw_ext_addr  (tw_ext_addr),
        .tw_ext_din   (tw_ext_din),
        .ext_rd_addr_0(ext_rd_addr_0),
        .ext_rd_addr_1(ext_rd_addr_1),
        .ext_rd_pair  (ext_rd_pair),
        .ext_rd_dout_0(ext_rd_dout_0),
        .ext_rd_dout_1(ext_rd_dout_1)
    );

    initial clk = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    function automatic bit parity10(input [9:0] idx);
        parity10 = ^idx;
    endfunction

    function automatic [9:0] bit_reverse(input [9:0] in);
        integer k;
        begin
            for (k = 0; k < 10; k = k + 1)
                bit_reverse[k] = in[9-k];
        end
    endfunction

    task automatic drive_idle;
        begin
            start         <= 1'b0;
            ext_wen       <= 1'b0;
            ext_rd_en     <= 1'b0;
            ext_bank      <= 2'd0;
            ext_addr      <= '0;
            ext_din       <= '0;
            tw_ext_wen    <= 1'b0;
            tw_ext_addr   <= '0;
            tw_ext_din    <= '0;
            ext_rd_addr_0 <= '0;
            ext_rd_addr_1 <= '0;
            ext_rd_pair   <= 2'd0;
        end
    endtask

    task automatic apply_reset;
        begin
            rst_n <= 1'b0;
            drive_idle();
            repeat (4) @(posedge clk);
            rst_n <= 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic write_data_sram(
        input [1:0]    bank,
        input [AW-1:0] addr,
        input [DW-1:0] data
    );
        begin
            @(posedge clk);
            ext_wen  <= 1'b1;
            ext_bank <= bank;
            ext_addr <= addr;
            ext_din  <= data;
            @(posedge clk);
            ext_wen  <= 1'b0;
        end
    endtask

    task automatic write_tw_sram(
        input [AW-1:0] addr,
        input [DW-1:0] data
    );
        begin
            @(posedge clk);
            tw_ext_wen  <= 1'b1;
            tw_ext_addr <= addr;
            tw_ext_din  <= data;
            @(posedge clk);
            tw_ext_wen  <= 1'b0;
        end
    endtask

    task automatic read_data_sram(
        input  [1:0]    bank,
        input  [AW-1:0] addr,
        output [DW-1:0] data
    );
        begin
            @(negedge clk);
            ext_rd_en   <= 1'b1;
            ext_rd_pair <= 2'd0;

            if (bank[0]) begin
                ext_rd_addr_1 <= addr;
            end else begin
                ext_rd_addr_0 <= addr;
            end

            repeat (READ_WAIT) @(posedge clk);
            #1 data = bank[0] ? ext_rd_dout_1 : ext_rd_dout_0;

            @(negedge clk);
            ext_rd_en     <= 1'b0;
            ext_rd_addr_0 <= '0;
            ext_rd_addr_1 <= '0;
            ext_rd_pair   <= 2'd0;
        end
    endtask

    task automatic load_twiddles;
        begin
            $display("[TB] Loading twiddles...");
            for (i = 0; i < TW_N; i = i + 1)
                write_tw_sram(i[AW-1:0], twiddle_data[i]);
        end
    endtask

    task automatic load_inputs;
        begin
            $display("[TB] Loading inputs...");
            for (i = 0; i < N; i = i + 1) begin
                point_idx = i[9:0];
                bank_id   = parity10(point_idx);
                val16     = input_data[i];
                write_data_sram({1'b0, bank_id}, point_idx[AW-1:0], {val16, 16'h0000});
            end
        end
    endtask

    task automatic run_fft;
        begin
            $display("[TB] Start FFT...");
            @(posedge clk) start <= 1'b1;
            @(posedge clk) start <= 1'b0;
            wait (done === 1'b1);
            @(posedge clk);
            $display("[TB] FFT done.");
        end
    endtask

    task automatic dump_outputs(input string file_name);
        begin
            $display("[TB] Writing %s...", file_name);
            fp_out = $fopen(file_name, "w");
            if (fp_out == 0) begin
                $fatal(1, "[TB] Cannot open %s", file_name);
            end

            for (i = 0; i < N; i = i + 1) begin
                point_idx = bit_reverse(i[9:0]);
                bank_id   = parity10(point_idx);
                read_data_sram({1'b0, bank_id}, point_idx[AW-1:0], val32);
                $fwrite(fp_out, "%04x%04x\n", val32[31:16], val32[15:0]);
            end

            $fclose(fp_out);
        end
    endtask

    initial begin
        $dumpfile("testbench.vcd");
        $dumpvars(0, testbench);
    end

    initial begin
        $readmemh("FFT_input/input_q1_15_v3.hex", input_data);
        $readmemh("FFT_input/twiddle_q15.hex", twiddle_data);

        apply_reset();
        load_twiddles();
        load_inputs();
        run_fft();
        dump_outputs("fft_output.txt");

        #100;
        $display("[TB] Simulation complete.");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "[TB] TIMEOUT");
    end

endmodule
