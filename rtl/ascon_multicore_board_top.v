`timescale 1ns / 1ps
// Nexys A7-100T, volatile self-test only. 900 MHz VCO / divider.
module ascon_multicore_board_top #(
  parameter integer CORES=2, parameter integer CLOCK_DIVIDE=9
)(input CLK100MHZ, input BTNU, output [3:0] LED);
  wire raw_clk, clk, feedback, fb_buffer, locked;
  MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(9.0),
    .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(CLOCK_DIVIDE)) mmcm_u (
    .CLKIN1(CLK100MHZ),.CLKFBIN(fb_buffer),.CLKFBOUT(feedback),
    .CLKOUT0(raw_clk),.LOCKED(locked),.RST(1'b0),.PWRDWN(1'b0));
  BUFG feedback_u(.I(feedback),.O(fb_buffer));
  BUFG clock_u(.I(raw_clk),.O(clk));
  (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync=2'b11;
  always @(posedge clk or negedge locked) begin
    if (!locked) reset_sync<=2'b11;
    else reset_sync<={reset_sync[0],BTNU};
  end
  (* mark_debug="true" *) wire test_done,test_pass,test_fail;
  (* mark_debug="true" *) wire [3:0] test_case;
  (* mark_debug="true" *) wire [7:0] failure_code;
  (* mark_debug="true" *) wire [9:0] passed_mask;
  (* mark_debug="true" *) wire [319:0] case_cycles;
  ascon_multicore_selftest #(.G_CORES(CORES)) test_u (
    .clk_i(clk),.rst_i(reset_sync[1]),.done_o(test_done),.pass_o(test_pass),
    .fail_o(test_fail),.case_o(test_case),.failure_o(failure_code),
    .passed_o(passed_mask),.cycles_o(case_cycles));
  assign LED={locked,test_fail,test_pass,test_done};
endmodule
