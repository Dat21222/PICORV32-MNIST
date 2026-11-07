# ==============================================================================
# Makefile: PicoRV32 RISC-V SoC with Pipelined Hardware MLP Neural Network
# Target Board: Xilinx Zynq-7000 (xc7z020)
# ==============================================================================

SHELL      := bash
VIVADO_BIN := C:/Xilinx/Vivado/2022.2/bin
XVLOG      := $(VIVADO_BIN)/xvlog.bat
XELAB      := $(VIVADO_BIN)/xelab.bat
XSIM       := $(VIVADO_BIN)/xsim.bat
PYTHON     := python3

PROJ_DIR   := $(shell pwd)
RTL_DIR    := $(PROJ_DIR)/rtl
TB_DIR     := $(PROJ_DIR)/tb
FW_DIR     := $(PROJ_DIR)/firmware

.PHONY: all help fw_single fw_multi3 sim_case3

help:
	@echo "------------------------------------------------------------------"
	@echo " PicoRV32 + Hardware MLP Neural Network Accelerator SoC"
	@echo "------------------------------------------------------------------"
	@echo " Targets:"
	@echo "   fw_single  : Build single-image RISC-V firmware (start.S + main.c)"
	@echo "   fw_multi3  : Build 3-image continuous inference firmware"
	@echo "   sim_case3  : Standalone MMIO protocol & accelerator simulation"
	@echo "------------------------------------------------------------------"

fw_single:
	cd $(FW_DIR) && bash build.sh

fw_multi3:
	cd $(FW_DIR) && bash build_multi3.sh

sim_case3:
	@echo "Running Test Case 3: MMIO Protocol & Accelerator Standalone..."
	$(XVLOG) --incr --relax -work xil_defaultlib "$(RTL_DIR)/mmio_mlp.v" "$(RTL_DIR)/mlp_acc.v" "$(TB_DIR)/tb_case3_mmio_protocol.v"
	$(XELAB) --incr --debug typical --relax --mt 2 -L xil_defaultlib -L unisims_ver --snapshot tb_case3_behav xil_defaultlib.tb_case3_mmio_protocol xil_defaultlib.glbl
	$(XSIM) tb_case3_behav -R
