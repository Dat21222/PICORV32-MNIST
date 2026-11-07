`timescale 1ns/1ps
// tb_case1_single_image.v
// Test Case 1: End-to-End Single-Image SoC Inference & Logit Verification
// Uses final_wrapper_wrapper with single-image firmware (bram_cpu.coe).
module tb_case1_single_image;
    reg sim_clk;
    reg sim_resetn;
    reg ps_clk;
    reg ps_porb;
    reg ps_srstb;

    initial begin
        sim_clk = 1'b0;
        ps_clk  = 1'b0;
    end
    always #5  sim_clk = ~sim_clk; // PL clock: 100 MHz
    always #15 ps_clk  = ~ps_clk;  // PS reference: ~33.33 MHz

    wire ps_clk_pin, ps_porb_pin, ps_srstb_pin;
    assign ps_clk_pin   = ps_clk;
    assign ps_porb_pin  = ps_porb;
    assign ps_srstb_pin = ps_srstb;

    wire [14:0] DDR_addr;
    wire [2:0]  DDR_ba;
    wire DDR_cas_n, DDR_ck_n, DDR_ck_p;
    wire DDR_cke, DDR_cs_n;
    wire [3:0]  DDR_dm;
    wire [31:0] DDR_dq;
    wire [3:0]  DDR_dqs_n, DDR_dqs_p;
    wire DDR_odt, DDR_ras_n, DDR_reset_n, DDR_we_n;
    wire FIXED_IO_ddr_vrn, FIXED_IO_ddr_vrp;
    wire [53:0] FIXED_IO_mio;
    wire [3:0]  result;

    wire [31:0] read_data, write_data, mem_addr;
    wire [3:0]  mem_wstrb;
    wire        mem_valid, mem_ready;
    wire        trap_observe;

    final_wrapper_wrapper dut (
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(ps_clk_pin),
        .FIXED_IO_ps_porb(ps_porb_pin),
        .FIXED_IO_ps_srstb(ps_srstb_pin),
        .result(result)
    );

    assign read_data    = dut.final_wrapper_i.interconnect_0_mem_rdata;
    assign write_data   = dut.final_wrapper_i.picorv32_wrapper_0_mem_wdata;
    assign mem_addr     = dut.final_wrapper_i.picorv32_wrapper_0_mem_addr;
    assign mem_wstrb    = dut.final_wrapper_i.picorv32_wrapper_0_mem_wstrb;
    assign mem_valid    = dut.final_wrapper_i.picorv32_wrapper_0_mem_valid;
    assign mem_ready    = dut.final_wrapper_i.interconnect_0_mem_ready;
    assign trap_observe = dut.final_wrapper_i.picorv32_wrapper_0.trap;

    wire acc_clear   = dut.final_wrapper_i.mmio_mlp_0_acc_clear;
    wire acc_start   = dut.final_wrapper_i.mmio_mlp_0_acc_start;
    wire pixel_valid = dut.final_wrapper_i.mmio_mlp_0_pixel_valid;
    wire acc_done    = dut.final_wrapper_i.mlp_acc_0_done;

    integer px_stream_count;
    reg [31:0] mailbox_result;
    integer k;

    initial begin
        px_stream_count = 0;
        mailbox_result  = 32'hDEAD_BEEF;
        $timeformat(-9, 0, " ns", 12);
        $display("================================================================");
        $display("TEST CASE 1: End-to-End Single-Image SoC Verification");
        $display("================================================================");
        sim_resetn = 1'b0;
        ps_porb    = 1'b0;
        ps_srstb   = 1'b0;

        force dut.final_wrapper_i.processing_system7_0_FCLK_CLK0 = sim_clk;
        force dut.final_wrapper_i.processing_system7_0_FCLK_RESET0_N = 1'b0;

        #200;
        ps_porb  = 1'b1;
        ps_srstb = 1'b1;

        #800;
        sim_resetn = 1'b1;
        force dut.final_wrapper_i.processing_system7_0_FCLK_RESET0_N = 1'b1;
        $display("[INFO] Internal FCLK reset released HIGH at %0t", $time);
    end

    always @(posedge sim_clk) begin
        if (sim_resetn === 1'b1) begin
            if (acc_clear) begin
                $display("[TC1][MMIO] acc_clear asserted at %0t", $time);
                px_stream_count <= 0;
            end else if (pixel_valid) begin
                px_stream_count <= px_stream_count + 1;
            end

            if (acc_start) begin
                $display("[TC1][MMIO] acc_start asserted at %0t (pixels streamed = %0d)",
                         $time, px_stream_count);
            end

            if (acc_done) begin
                $display("----------------------------------------------------------------");
                $display("[TC1][MLP DONE] Inference finished at %0t -> result_class = %0d",
                         $time, result);
                for (k = 0; k < 10; k = k + 1) begin
                    $display("   logit[%0d] = %0d (0x%08x)",
                             k,
                             $signed(dut.final_wrapper_i.mlp_acc_0.inst.logits_mem[k]),
                             dut.final_wrapper_i.mlp_acc_0.inst.logits_mem[k]);
                end
                $display("----------------------------------------------------------------");
            end

            if (mem_valid && mem_ready && (mem_wstrb == 4'b1111)) begin
                if (mem_addr == 32'h0000_2000) begin
                    mailbox_result <= write_data;
                    $display("[TC1][MAILBOX] CPU wrote RESULT_MAILBOX (0x2000) = %0d at %0t",
                             write_data, $time);
                end else if (mem_addr == 32'h0000_2004) begin
                    $display("================================================================");
                    $display("[TC1][DONE MAILBOX] CPU wrote DONE_MAILBOX (0x2004) = 0x%08x at %0t",
                             write_data, $time);
                    $display("  Predicted Class in Mailbox 0x2000 = %0d", mailbox_result);
                    if (write_data == 32'h600d_0001 && px_stream_count == 784)
                        $display("  STATUS: PASS (CPU + MMIO + MLP single-image flow completed)");
                    else
                        $display("  STATUS: FAIL (done_code=0x%08x, px_count=%0d)", write_data, px_stream_count);
                    $display("================================================================");
                    #100;
                    $finish;
                end
            end
        end
    end

    always @(negedge sim_clk) begin
        if (sim_resetn === 1'b1 && trap_observe === 1'b1) begin
            $display("[TC1] FAIL: CPU trap at %0t, addr=%h read=%h write=%h",
                     $time, mem_addr, read_data, write_data);
            $finish;
        end
    end

    initial begin
        #3000000;
        $display("[TC1] TIMEOUT: 3 ms elapsed. trap=%b read=%h write=%h",
                 trap_observe, read_data, write_data);
        $finish;
    end
endmodule
