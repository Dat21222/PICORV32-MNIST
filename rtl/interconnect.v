module interconnect #(
	parameter [31:0] BRAM_BASE = 32'h00000000,
	parameter [31:0] BRAM_SIZE = 32'h00010000,
	parameter [31:0] MLP_BASE = 32'h10000000,
	parameter [31:0] MLP_SIZE = 32'h00001000
	)(
	input wire clk, resetn,
	// related cpu interface
	input wire mem_valid,
	output reg mem_ready,
	
	output reg [31:0] mem_rdata,
	input wire [31:0] mem_wdata,
	input wire [3:0] mem_wstrb,
	input wire [31:0] mem_addr,
	
	//related bram controller interface
	output wire bram_req_valid,
	input wire bram_req_ready,
	
	output wire [31:0] bram_req_addr,	
	output wire [31:0] bram_req_wdata,	
	output wire [3:0]  bram_req_wstrb,	
	input wire [31:0] bram_req_rdata,		
	
	// related mlp controller interface
	output wire mlp_req_valid,
	input wire mlp_req_ready,
	
	output wire [31:0] mlp_req_addr,	
	output wire [31:0] mlp_req_wdata,	
	output wire [3:0]  mlp_req_wstrb,	
	input wire [31:0] mlp_req_rdata	
);
	parameter [1:0] IDLE = 2'b00;
	parameter [1:0] RESP_BRAM = 2'b01;
	parameter [1:0] RESP_MLP = 2'b10;
	
	reg [2:0] state;
	
	wire bram_sel = (mem_addr >= BRAM_BASE) && ((mem_addr - BRAM_BASE) < BRAM_SIZE );
	wire mlp_sel = (mem_addr >= MLP_BASE) && ((mem_addr - MLP_BASE) < MLP_SIZE );
	
	// bram controll
	assign bram_req_valid = resetn && (state == RESP_BRAM) && mem_valid;
	assign bram_req_addr = (state == RESP_BRAM) ? mem_addr : 32'b0;
	assign bram_req_wdata = (state == RESP_BRAM) ? mem_wdata: 32'b0;
	assign bram_req_wstrb = (state == RESP_BRAM) ? mem_wstrb: 32'b0;
	//assign mem_rdata = ((state == RESP_BRAM) && bram_req_ready) ? bram_req_rdata;
	
	//assign mem_ready = resetn && bram_req_ready && mem_valid && (state == RESP_BRAM);	
	
	// mlp controll
	assign mlp_req_valid = resetn && (state == RESP_MLP) && mem_valid;
	assign mlp_req_addr = (state == RESP_MLP) ? mem_addr: 32'b0;
	assign mlp_req_wdata = (state == RESP_MLP) ? mem_wdata: 32'b0;
	assign mlp_req_wstrb = (state == RESP_MLP) ? mem_wstrb: 32'b0;
	
		
	always @(posedge clk) begin
		if (!resetn) state <= IDLE;
		else begin
			case (state)
			IDLE: if (bram_sel && mem_valid) state <= RESP_BRAM;
					else if (mlp_sel && mem_valid) state <= RESP_MLP; 
			RESP_BRAM: if (bram_req_ready && mem_valid) state <= IDLE;
			RESP_MLP: if (mlp_req_ready && mem_valid) state <= IDLE;
			default: state <= IDLE;
			endcase
		end
	end
	
	always @(*) begin
    mem_ready = 1'b0;
    mem_rdata = 32'b0;

    if (resetn && mem_valid) begin
        case (state)
				RESP_BRAM: begin
					mem_ready = bram_req_ready;
					mem_rdata = bram_req_rdata;
				end

				RESP_MLP: begin
					mem_ready = mlp_req_ready;
					mem_rdata = mlp_req_rdata;
				end

				default: begin
					mem_ready = 1'b0;
					mem_rdata = 32'b0;
				end
		endcase
	end
	end
	
endmodule