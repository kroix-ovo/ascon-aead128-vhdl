`timescale 1ns / 1ps
// SW[9]=1 selects self-test; SW[3]=1 displays failure case, otherwise
// SW[1:0] selects one byte of the latched 32-bit self-test cycle count.
// LED[8]=done, LED[9]=pass, LED[10]=fail, LED[12]=MMCM locked.
module ascon_weight_board_top #(parameter integer CLOCK_DIVIDE = 10)(
 input CLK100MHZ, input [9:0] SW, input BTNC, input BTNU,
 output [12:0] LED
);
 wire raw_clk, clk, feedback, fb_buffer, locked;
 MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(10.0),
 .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(CLOCK_DIVIDE)) mmcm_u (
 .CLKIN1(CLK100MHZ),.CLKFBIN(fb_buffer),.CLKFBOUT(feedback),
 .CLKOUT0(raw_clk),.LOCKED(locked),.RST(1'b0),.PWRDWN(1'b0));
 BUFG feedback_u(.I(feedback),.O(fb_buffer));
 BUFG clock_u(.I(raw_clk),.O(clk));
 (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync = 2'b11;
 always @(posedge clk or negedge locked) begin
   if (!locked) reset_sync <= 2'b11;
   else reset_sync <= {reset_sync[0],BTNU};
 end
 (* ASYNC_REG="TRUE" *) reg [9:0] sw_meta=0, sw_sync=0;
 always @(posedge clk) begin sw_meta<=SW; sw_sync<=sw_meta; end
 wire [12:0] demo_led;
 wire [9:0] demo_switches;
 wire demo_start;
 (* mark_debug="true" *) wire auto_done,auto_pass,auto_fail;
 (* mark_debug="true" *) wire [2:0] auto_case;
 (* mark_debug="true" *) wire [31:0] auto_cycles;
 (* mark_debug="true" *) wire done,pass,fail;
 (* mark_debug="true" *) wire [7:0] test_case;
 (* mark_debug="true" *) wire [31:0] cycles;
 ascon_weight_selftest selftest_u(.clk_i(clk),.rst_i(reset_sync[1]),
   .done_o(done),.pass_o(pass),.fail_o(fail),.case_o(test_case),.cycles_o(cycles));
 ascon_demo_autotest auto_demo_u(.clk_i(clk),.rst_i(reset_sync[1]),
   .selftest_done_i(done),.selftest_pass_i(pass),.switches_i(sw_sync),.start_i(BTNC),
   .demo_led_i(demo_led),.switches_o(demo_switches),.start_o(demo_start),
   .done_o(auto_done),.pass_o(auto_pass),.fail_o(auto_fail),.case_o(auto_case),.cycles_o(auto_cycles));
 ascon_demo_top #(.G_ROUNDS_PER_CYCLE(3),.G_BUFFERING_ENABLE(1)) demo_u(
   .CLK100MHZ(clk),.SW(demo_switches),.BTNC(demo_start),.BTNU(reset_sync[1]),.LED(demo_led));
 wire [7:0] display_byte = sw_sync[3] ? ((auto_fail && !fail) ? {5'b10000,auto_case} : test_case) : cycles >> (8*sw_sync[1:0]);
 assign LED = sw_sync[9] ? {locked,1'b0,(fail|auto_fail),(pass&auto_pass),(done&auto_done),display_byte} : demo_led;
endmodule
