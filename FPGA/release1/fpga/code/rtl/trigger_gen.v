/** -*- verilog -*-
 *
 * @brief Red Pitaya trigger generation module.  It detects and counts trigger
 *        pulses in a digitized signal.  Input signal and thresholds are signed.
 *
 * @Author John Brzustowski
 *
 * (c) 2014 John Brzustowski https://radr-project.org
 *
 * This part of code is written in Verilog hardware description language (HDL).
 * Please visit http://en.wikipedia.org/wiki/Verilog
 * for more details on the language used herein.

   Generate a trigger a fixed delay after the signal crosses an excitation
   threshold after having crossed a relaxation threshold.  The threshold
   values are independent, and when unequal, "crossing" a threshold means
   being found at or beyond it in the direction away from the other threshold.
   If the thresholds are equal, a positive crossing is treated as excitation,
   a negative crossing as relaxation.
   If a non-zero latency is specified, then at least that number of clock ticks 
   must elapse between consecutive excitation events (and a relaxation event is
   still required between these).
   The count of ticks since the most recent excitation is maintained in register "age".
   The delay value does not affect the sequence of "age" values, but
   is merely the age at which an excitation causes output "trigger" to be asserted.
  
   Timing:  if the input at clock pulse N crosses the excitation threshold after
   a crossing of the relaxation threshold, then the trigger output is high
   at the start of the clock pulse N+1+delay.
  
   The trigger is only held high for one clock.
  
 */

//  mode M1:  thresh_relax < thresh_excite (usual situation)

`define TS_M1_WAITING_RELAX     3'd0  // waiting for signal to cross threshold in relaxation direction
`define TS_M1_WAITING_EXCITE    3'd1  // waiting for signal to cross threshold in excitation direction

// mode M2:  thresh_relax > thresh_excite (inverted signal)

`define TS_M2_WAITING_RELAX     3'd2  // waiting for signal to cross threshold in relaxation direction
`define TS_M2_WAITING_EXCITE    3'd3  // waiting for signal to cross threshold in excitation direction

// mode M3:  thresh_relax == thresh_excite (single threshold; crossing upward is excitation)

`define TS_M3_WAITING_RELAX     3'd4  // waiting for signal to cross threshold in relaxation direction
`define TS_M3_WAITING_EXCITE    3'd5  // waiting for signal to cross threshold in excitation direction

`define TS_DELAYING             3'd6  // threshold crossed; delaying before triggering

module trigger_gen 
  ( input clock,
    input reset,
    input enable,
    input [width-1:0] signal_in,
    input [width-1:0] thresh_relax,
    input [width-1:0] thresh_excite,
    input [delay_width-1:0] delay,
    input [age_width-1:0] latency,
    output reg 		    trigger,
    output reg [counter_width-1:0] counter
    );
   
   parameter width = 12;
   parameter delay_width = 32;
   parameter counter_width = 32;
   parameter age_width = 32;
   parameter do_smoothing = 1;
   
   reg [2:0] 			   state;
   reg [delay_width-1:0] 	   delay_counter;
   reg [width-1:0] 		   sig_smoothed; // possibly smoothed version of signal_in
   reg [age_width-1:0]             age;          // number of clock ticks since reset or assertion of trigger
   reg [age_width-1:0]             latency_counter;  // number of clock ticks remaining after excite before next excite is allowed
   
   // smooth the signal with an IIR filter:  smooth[i+1] <= (7 * smooth[i] + value[i+1]) / 8
   // FIXME: make the weighting a control parameter, instead of hardwiring 7/8, 1/8.
   // Note the sign extension, as we treat signal as signed.

   reg [width + 3 - 1: 0]          smoother;
   
   always @(posedge clock)
     if (reset | ~enable)
       begin
	  if ($signed(thresh_relax) < $signed(thresh_excite))
	    state <=  `TS_M1_WAITING_RELAX;
	  else if ($signed(thresh_relax) > $signed(thresh_excite))
	    state <=  `TS_M2_WAITING_RELAX;
	  else
	    state <=  `TS_M3_WAITING_RELAX;
	  trigger <=  1'b0;
	  counter <=  1'b0;
	  sig_smoothed <=  signal_in;
          smoother <= {signal_in, 3'b0};
	  age <=  1'b0;
          latency_counter <= 1'b0;
       end
     else
       begin	  
	  age <= age + 1'b1;

          smoother[width + 3 - 1: 0] = {sig_smoothed[width-1:0], 3'b0} - {{3{sig_smoothed[width - 1]}}, sig_smoothed[width-1:0]} + {{3{signal_in[width - 1]}}, signal_in[width - 1:0]};

	  sig_smoothed =  do_smoothing ? smoother[3 + width - 1 : 3] : signal_in;

	  if (|latency_counter) 
            begin
               // count down latency
               latency_counter <= latency_counter - 1'b1;
            end
	  
	  case (state)
	    `TS_M1_WAITING_RELAX:
	      begin
		 trigger <=  1'b0;
		 if ($signed(sig_smoothed) <= $signed(thresh_relax))
		   begin
		      state <=  `TS_M1_WAITING_EXCITE;
		   end
	      end
	    
	    `TS_M1_WAITING_EXCITE:
	      begin
                 if ((! (| latency_counter)) && $signed(sig_smoothed) >= $signed(thresh_excite))
		   begin
		      age <=  1'b0;
		      counter <=  counter + 1'b1;
                      latency_counter <= latency;
		      if (delay == 0)
			begin
			   state <=  `TS_M1_WAITING_RELAX;
			   trigger <=  1'b1;
			end
		      else
			begin
			   state <=  `TS_DELAYING;
			   delay_counter <=  delay;
			end
		   end
              end
	    
	    `TS_M2_WAITING_RELAX:
	      begin
		 trigger <=  1'b0;
		 if ($signed(sig_smoothed) >= $signed(thresh_relax))
		   begin
		      state <=  `TS_M2_WAITING_EXCITE;
		   end
	      end
	    
	    `TS_M2_WAITING_EXCITE:
	      begin
		 if ((! (|latency_counter)) && $signed(sig_smoothed) <= $signed(thresh_excite))
                        begin
		           age <=  1'b0;
		           counter <=  counter + 1'b1;
                           latency_counter <= latency;
		           if (delay == 0)
			     begin
			        state <=  `TS_M2_WAITING_RELAX;
			        trigger <=  1'b1;
			     end
		           else
			     begin
			        state <=  `TS_DELAYING;
			        delay_counter <=  delay;
			     end
		        end
              end
	    
	    `TS_M3_WAITING_RELAX:
	      begin
		 trigger <=  1'b0;
		 if ($signed(sig_smoothed) < $signed(thresh_relax))
		   begin
		      state <=  `TS_M3_WAITING_EXCITE;
		   end
	      end
	    
	    `TS_M3_WAITING_EXCITE:
	        begin
		   if ((! (|latency_counter)) && $signed(sig_smoothed) > $signed(thresh_excite))
		     begin
		        age <=  1'b0;
		        counter <=  counter + 1'b1;
                        latency_counter <= latency;
		        if (delay == 0)
			  begin
			     state <=  `TS_M3_WAITING_RELAX;
			     trigger <=  1'b1;
			  end
		        else
			  begin
			     state <=  `TS_DELAYING;
			     delay_counter <=  delay;
			  end
		     end
	        end
	    `TS_DELAYING:
              if (| delay_counter)
                begin
		   delay_counter <= delay_counter - 1'b1;
		end
              else
		begin
		   if ($signed(thresh_relax) < $signed(thresh_excite))
		     state <=  `TS_M1_WAITING_RELAX;
		   else if ($signed(thresh_relax) > $signed(thresh_excite))
		     state <=  `TS_M2_WAITING_RELAX;
		   else
		     state <=  `TS_M3_WAITING_RELAX;
		   trigger <=  1'b1;
		end
	  endcase // case (state)
       end
endmodule // red_pitaya_trigger_gen
