module bram_controller (
	input wire clk, resetn,
	
	//CPU handshake
	input wire req_valid, 			// cpu request true instruction form
	output wire req_ready,			// Controller reports completion to the requester.
	
	//CPU send information of transaction though interconnect
	input wire [31:0] req_addr,		// cpu address
	input wire [31:0] req_wdata,	// cpu write data
	input wire [3:0]  req_wstrb,	// cpu send write enable bit 
	output wire [31:0] req_rdata,	// response read data from bram
	
	//bram receive information of transaction
	output wire bram_en, 			// allow access to bram
	output wire [13:0] bram_addr, 	// bram address
	output wire [31:0] bram_din,	// bram write in data
	input wire [31:0] bram_dout,	// bram read out data
	output wire [3:0] bram_wen		// bram write enable bit 
);

	parameter IDLE = 1'b0;
	parameter RESP = 1'b1;
	
	reg state;
	assign bram_addr = req_addr[15:2];
	assign bram_en = resetn && req_valid && (state == IDLE);
	assign bram_wen = bram_en ? req_wstrb : 4'b0000;
	assign req_ready = resetn && (state == RESP); 
	assign req_rdata = bram_dout;
	assign bram_din = req_wdata;

	always @(posedge clk) begin
		if (!resetn) state <= IDLE;
		else begin
			case (state)
			IDLE: if (req_valid) state <= RESP;
			RESP: if (req_valid) state <= IDLE;
			default: state <= IDLE;
			endcase
			end
	end
endmodule