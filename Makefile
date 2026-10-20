PYTHON ?= python3
GHDL ?= ghdl
IVERILOG ?= iverilog
VERILATOR ?= verilator
BUILD_DIR ?= build

VHDL_SOURCES := rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd
DEMO_SOURCES := $(VHDL_SOURCES) rtl/ascon_demo_top.vhd
VHDL_TESTBENCH := verification/vhdl/tb_ascon_aead128.vhd

.PHONY: vectors model-test permutation-test ghdl-test vhdl-textio-test full-kat \
	full-icarus-kat full-verilator-kat full-generated-kat summarize-results \
	synth-verilog iverilog-lint verilator-lint clean

vectors:
	$(PYTHON) verification/fetch_vectors.py

model-test: vectors
	PYTHONPATH=verification/model $(PYTHON) -m pytest -q verification/model

permutation-test:
	$(PYTHON) verification/run_permutation.py

.PHONY: weight-file-test
weight-file-test: vectors
	$(PYTHON) verification/run_weight_file.py --ghdl $(GHDL)

ghdl-test: vectors
	SIM=ghdl $(PYTHON) verification/run.py --sim ghdl

vhdl-textio-test: vectors
	mkdir -p $(BUILD_DIR)/ghdl-textio
	cd $(BUILD_DIR)/ghdl-textio && $(GHDL) -a --std=08 ../../$(word 1,$(DEMO_SOURCES)) ../../$(word 2,$(DEMO_SOURCES)) ../../$(word 3,$(DEMO_SOURCES)) ../../$(word 4,$(DEMO_SOURCES)) ../../$(VHDL_TESTBENCH)
	cd $(BUILD_DIR)/ghdl-textio && $(GHDL) --elab-run --std=08 tb_ascon_aead128 -gG_VECTOR_FILE=$(abspath verification/vectors/xsim_vectors.txt) --assert-level=error

full-kat:
	FULL_KAT=1 $(MAKE) ghdl-test

synth-verilog:
	mkdir -p $(BUILD_DIR)/generated
	$(GHDL) synth --std=08 --out=verilog $(VHDL_SOURCES) -e ascon_aead128_core > $(BUILD_DIR)/generated/ascon_aead128_core.v

iverilog-lint: synth-verilog
	$(IVERILOG) -g2012 -s ascon_aead128_core -o $(BUILD_DIR)/generated/iverilog.out $(BUILD_DIR)/generated/ascon_aead128_core.v

verilator-lint: synth-verilog
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module ascon_aead128_core $(BUILD_DIR)/generated/ascon_aead128_core.v

.PHONY: iverilog-test verilator-test

iverilog-test: vectors synth-verilog
	SIM=icarus $(PYTHON) verification/run.py --sim icarus --netlist $(BUILD_DIR)/generated/ascon_aead128_core.v

verilator-test: vectors synth-verilog
	SIM=verilator $(PYTHON) verification/run.py --sim verilator --netlist $(BUILD_DIR)/generated/ascon_aead128_core.v

full-icarus-kat: vectors synth-verilog
	FULL_KAT=1 SIM=icarus $(PYTHON) verification/run.py --sim icarus --netlist $(BUILD_DIR)/generated/ascon_aead128_core.v

full-verilator-kat: vectors synth-verilog
	FULL_KAT=1 SIM=verilator $(PYTHON) verification/run.py --sim verilator --netlist $(BUILD_DIR)/generated/ascon_aead128_core.v

full-generated-kat: full-icarus-kat full-verilator-kat

summarize-results:
	$(PYTHON) verification/summarize_results.py

clean:
	rm -rf $(BUILD_DIR) .pytest_cache verification/**/__pycache__ tb_ascon_aead128 e~tb_ascon_aead128.o

.PHONY: board-selftest
board-selftest:
	mkdir -p $(BUILD_DIR)/board-selftest
	cd $(BUILD_DIR)/board-selftest && $(GHDL) -a --std=08 ../../rtl/ascon_pkg.vhd ../../rtl/ascon_permutation.vhd ../../rtl/ascon_aead128_core.vhd ../../rtl/ascon_selftest_vectors.vhd ../../rtl/ascon_weight_selftest.vhd ../../verification/vhdl/tb_weight_selftest.vhd
	cd $(BUILD_DIR)/board-selftest && $(GHDL) --elab-run --std=08 tb_weight_selftest --assert-level=error

.PHONY: board-demo-test
board-demo-test:
	mkdir -p $(BUILD_DIR)/board-demo
	cd $(BUILD_DIR)/board-demo && $(GHDL) -a --std=08 ../../rtl/ascon_pkg.vhd ../../rtl/ascon_permutation.vhd ../../rtl/ascon_aead128_core.vhd ../../rtl/ascon_demo_top.vhd ../../rtl/ascon_demo_autotest.vhd ../../verification/vhdl/tb_weight_demo.vhd
	cd $(BUILD_DIR)/board-demo && $(GHDL) --elab-run --std=08 tb_weight_demo --assert-level=error
	cd $(BUILD_DIR)/board-demo && $(GHDL) --elab-run --std=08 tb_weight_demo -gG_ROUNDS_PER_CYCLE=1 -gG_BUFFERING_ENABLE=false --assert-level=error
