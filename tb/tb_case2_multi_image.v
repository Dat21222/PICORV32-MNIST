`timescale 1ns/1ps
// tb_case2_multi_image.v
// Test Case 2: Back-to-Back 3-Image SoC Classification & Reset Verification
// Uses final_wrapper_wrapper with 3-image firmware (bram_cpu_multi3.coe):
//   Image 0 (0x1000): img_106.jpg (Label 3) -> Result Mailbox 0x2000
//   Image 1 (0x1400): img_107.jpg (Label 0) -> Result Mailbox 0x2004
//   Image 2 (0x1800): img_114.jpg (Label 7) -> Result Mailbox 0x2008
//   Completion Flag:  0x600D0003            -> Done Mailbox   0x200C
module tb_case2_multi_image;
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

    integer img_idx;
    integer px_stream_count;
    reg [31:0] mailbox_results [0:2];
    reg [3:0]  expected_labels [0:2];
    integer k;

    initial begin
        img_idx = 0;
        px_stream_count = 0;
        mailbox_results[0] = 32'hDEAD_BEEF;
        mailbox_results[1] = 32'hDEAD_BEEF;
        mailbox_results[2] = 32'hDEAD_BEEF;
        expected_labels[0] = 4'd3; // img_106.jpg
        expected_labels[1] = 4'd0; // img_107.jpg
        expected_labels[2] = 4'd7; // img_114.jpg

        $timeformat(-9, 0, " ns", 12);
        $display("================================================================");
        $display("TEST CASE 2: Back-to-Back 3-Image Classification & Reset Check");
        $display("  Image #0 (0x1000): img_106.jpg (Label = 3)");
        $display("  Image #1 (0x1400): img_107.jpg (Label = 0)");
        $display("  Image #2 (0x1800): img_114.jpg (Label = 7)");
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
                $display("[TC2][MMIO] Image #%0d: acc_clear asserted at %0t (prev px_count=%0d)",
                         img_idx, $time, px_stream_count);
                px_stream_count <= 0;
            end else if (pixel_valid) begin
                px_stream_count <= px_stream_count + 1;
            end

            if (acc_start) begin
                $display("[TC2][MMIO] Image #%0d: acc_start asserted at %0t after %0d pixels loaded",
                         img_idx, $time, px_stream_count);
            end

            if (acc_done) begin
                $display("----------------------------------------------------------------");
                $display("[TC2][MLP DONE] Image #%0d completed at %0t -> result_class = %0d (label = %0d)",
                         img_idx, $time, result, expected_labels[img_idx]);
                for (k = 0; k < 10; k = k + 1) begin
                    $display("   logit[%0d] = %0d (0x%08x)",
                             k,
                             $signed(dut.final_wrapper_i.mlp_acc_0.inst.logits_mem[k]),
                             dut.final_wrapper_i.mlp_acc_0.inst.logits_mem[k]);
                end
                $display("----------------------------------------------------------------");
                img_idx <= img_idx + 1;
            end

            if (mem_valid && mem_ready && (mem_wstrb == 4'b1111)) begin
                if (mem_addr == 32'h0000_2000 && write_data != 32'd0) begin
                    mailbox_results[0] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #0 result = %0d at 0x2000 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_2004 && write_data != 32'd0) begin
                    mailbox_results[1] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #1 result = %0d at 0x2004 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_2008 && write_data != 32'd0) begin
                    mailbox_results[2] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #2 result = %0d at 0x2008 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_2000 && write_data == 32'd0 && img_idx > 0) begin
                    mailbox_results[0] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #0 result = %0d at 0x2000 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_2004 && write_data == 32'd0 && img_idx > 1) begin
                    mailbox_results[1] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #1 result = %0d at 0x2004 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_2008 && write_data == 32'd0 && img_idx > 2) begin
                    mailbox_results[2] <= write_data;
                    $display("[TC2][MAILBOX] CPU stored Image #2 result = %0d at 0x2008 (%0t)", write_data, $time);
                end else if (mem_addr == 32'h0000_200C) begin
                    $display("================================================================");
                    $display("[TC2][DONE MAILBOX] CPU wrote 0x%08x to 0x200C at %0t", write_data, $time);
                    $display("  Image #0 (img_106.jpg): Predicted = %0d | True Label = %0d", mailbox_results[0], expected_labels[0]);
                    $display("  Image #1 (img_107.jpg): Predicted = %0d | True Label = %0d", mailbox_results[1], expected_labels[1]);
                    $display("  Image #2 (img_114.jpg): Predicted = %0d | True Label = %0d", mailbox_results[2], expected_labels[2]);
                    if (write_data == 32'h600d_0003)
                        $display("  FLOW STATUS: PASS (All 3 images classified back-to-back without hang/trap)");
                    else
                        $display("  FLOW STATUS: FAIL (Unexpected DONE_MAILBOX 0x%08x)", write_data);
                    $display("================================================================");
                    #100;
                    $finish;
                end
            end
        end
    end

    always @(negedge sim_clk) begin
        if (sim_resetn === 1'b1 && trap_observe === 1'b1) begin
            $display("[TC2] FAIL: CPU trap at %0t, addr=%h read=%h write=%h",
                     $time, mem_addr, read_data, write_data);
            $finish;
        end
    end

    initial begin
        #10000000;
        $display("[TC2] TIMEOUT: 10 ms elapsed. img_idx=%0d trap=%b read=%h write=%h",
                 img_idx, trap_observe, read_data, write_data);
        $finish;
    end
endmodule
