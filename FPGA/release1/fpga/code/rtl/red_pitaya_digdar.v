/**
 *
 * @brief Red Pitaya DIGDAR module. Detects pulses on Trigger, ACP and ARP channels.
 *
 * @Author John Brzustowski
 *
 * (c) John Brzustowski https://radr-project.org
 *
 */

/**
 * Memory Map is generated from ogdar
 */

`include "generated_mmap.v"  // import register map generated by ogdar

module red_pitaya_digdar
  (
   input             adc_clk_i, //!< clock
   input             adc_rstn_i, //!< ADC reset - active low

   input [ 14-1: 0]  adc_a_i, //!< fast ADC channel A
   input [ 14-1: 0]  adc_b_i, //!< fast ADC channel B
   input [ 12-1: 0]  xadc_a_i, //!< most recent value from slow ADC channel A
   input [ 12-1: 0]  xadc_b_i, //!< most recent value from slow ADC channel B
   input             xadc_a_strobe_i, //!< strobe for most recent value from slow ADC channel A
   input             xadc_b_strobe_i, //!< strobe for most recent value from slow ADC channel B

   output            negate_o, //!< true if ADC CHA data should be negated

   // system bus
   input             sys_clk_i , //!< bus clock
   input             sys_rstn_i , //!< bus reset - active low
   input [ 32-1: 0]  sys_addr_i , //!< bus address
   input [ 32-1: 0]  sys_wdata_i , //!< bus write data
   input [ 4-1: 0]   sys_sel_i , //!< bus write byte select
   input             sys_wen_i , //!< bus write enable
   input             sys_ren_i , //!< bus read enable
   output [ 32-1: 0] sys_rdata_o , //!< bus read data
   output            sys_err_o , //!< bus error indicator
   output            sys_ack_o     //!< bus acknowledge signal

   );

`include "generated_regdefs.v"  // import register definitions generated by ogdar

   wire              acp_trig     ;
   wire              arp_trig     ;
   wire              trig_trig    ;
   wire [ 32-1: 0]   acp_age      ;
   wire              reset        ;

   reg               adc_arm_do   ; // asserted for one clock to arm FPGA for capture
   reg               adc_rst_do   ;

   //---------------------------------------------------------------------------------
   //  Input Y (ADC A can be set to counting mode instead of ADC values)

   wire [ 16-1: 0]   adc_a_y;

   assign adc_a_y = counting_mode ? adc_counter[16-1:0] : $signed(adc_a_i);

   assign reset = adc_rst_do | (adc_rstn_i == 1'b0) ;

   reg [  32-1: 0]   samp_countdown            ;

   assign negate = ~options[0]; // sense of negation is reversed from what user intends, since we already have to do one negation to compensate for inverting pre-amp

   assign avg_en = options[1]; // 1 means average (where possible) instead of simply decimating

   assign counting_mode = options[2]; // 1 means we use a counter instead of the real adc values

   assign use_sum = avg_en & options[3] & (dec_rate <= 4); // when decimation is 4 or less, we can return the sum rather than the average, of samples (16 bits)

`define STATUS_ARMED_BIT      0 // bit number in status that indicates fpga is armed (waiting for a trigger to begin capture)
`define STATUS_CAPTURING_BIT  1 // bit number in status that indicates fpga is capturing
`define STATUS_FIRED_BIT      2 // bit number in status that indicates fpga fired (completed capture after a trigger)

`define armed     status[`STATUS_ARMED_BIT]
`define capturing status[`STATUS_CAPTURING_BIT]
`define fired     status[`STATUS_FIRED_BIT]

   trigger_gen #( .width(12),
                  .counter_width(32),
                  .do_smoothing(1)
                  ) trigger_gen_acp  // not really a trigger; we're just counting these pulses
     (
      .clock(adc_clk_i),
      .reset(reset),
      .enable(1'b1),
      .strobe(xadc_a_strobe_i),
      .signal_in(xadc_a_i), // signed
      .thresh_excite(acp_thresh_excite[12-1:0]), // signed
      .thresh_relax(acp_thresh_relax[12-1:0]), //signed
      .delay(0),
      .latency(acp_latency),
      .trigger(acp_trig),
      .counter(acp_count),
      .age(acp_age)
      );

   trigger_gen #( .width(12),
                  .counter_width(32),
                  .do_smoothing(1)
                  ) trigger_gen_arp  // not really a trigger; we're just counting these pulses
     (
      .clock(adc_clk_i),
      .reset(reset),
      .enable(1'b1),
      .strobe(xadc_b_strobe_i),
      .signal_in(xadc_b_i), // signed
      .thresh_excite(arp_thresh_excite[12-1:0]), // signed
      .thresh_relax(arp_thresh_relax[12-1:0]), // signed
      .delay(0),
      .latency(arp_latency),
      .trigger(arp_trig),
      .counter(arp_count)
      );

   trigger_gen #( .width(14),
                  .counter_width(32),
                  .do_smoothing(1)
                  ) trigger_gen_trig // this counts trigger pulses and uses them
     (
      .clock(adc_clk_i),
      .reset(reset),
      .enable(1'b1),
      .strobe(1'b1),
      .signal_in(adc_b_i), // signed
      .thresh_excite(trig_thresh_excite[14-1:0]), // signed
      .thresh_relax(trig_thresh_relax[14-1:0]), // signed
      .delay(trig_delay),
      .latency(trig_latency),
      .trigger(trig_trig),
      .counter(trig_count)
      );



   //---------------------------------------------------------------------------------
   //
   //  reset
   always @(posedge adc_clk_i) begin
      if (reset) begin
         clocks             <= 64'h0;

         acp_clock          <= 64'h0;
         acp_prev_clock     <= 64'h0;

         arp_clock          <= 64'h0;
         arp_prev_clock     <= 64'h0;

         trig_clock         <= 64'h0;
         trig_prev_clock    <= 64'h0;

         acp_per_arp        <= 32'h0;

         acp_at_arp         <= 32'h0;
         trig_at_arp        <= 32'h0;

         // set thresholds at extremes to prevent triggering
         // before client values have been set

         trig_thresh_excite <= 32'h1fff;  // signed 14 bits
         trig_thresh_relax  <= 32'h2000;  // signed 14 bits

         acp_thresh_excite  <= 32'h07ff;  // signed 12 bits
         acp_thresh_relax   <= 32'h0800;  // signed 12 bits

         arp_thresh_excite  <= 32'h07ff;  // signed 12 bits
         arp_thresh_relax   <= 32'h0800;  // signed 12 bits

         dec_rate           <= 32'h1 ;

         trig_source        <= 32'h0 ;
         adc_trig           <= 1'b0  ;
         adc_a_sum          <= 32'h0 ;
         adc_b_sum          <= 32'h0 ;
         adc_dec_cnt        <= 'h0   ;
         adc_wp             <= 'h0   ;
         samp_countdown     <= 32'h0 ;
         acp_raw            <= 'h0   ;
         arp_raw            <= 'h0   ;
         status             <= 'h0   ;

      end
      else begin
      end // if (reset)
      adc_arm_do <= command[0];
      adc_rst_do <= command[1];
   end

   //---------------------------------------------------------------------------------
   //  Decimate input data

   reg [ 16-1: 0]    adc_a_dat     ;
   reg [ 14-1: 0]    adc_b_dat     ;
   reg [ 32-1: 0]    adc_a_sum     ;
   reg [ 32-1: 0]    adc_b_sum     ;
   reg [ 32-1: 0]    adc_dec_cnt   ;
   wire              dec_done      ;

   assign dec_done = adc_dec_cnt >= dec_rate;

   always @(posedge adc_clk_i) begin
      if (! reset) begin
         acp_raw <= {20'h0, xadc_a_i};
         arp_raw <= {20'h0, xadc_b_i};

         if (adc_arm_do) begin // arm
            `armed      <= 1'b1;
            `capturing  <= 1'b0;
            `fired      <= 1'b0;
         end
         else if (`capturing) begin
            adc_counter <= adc_counter + 16'b1;
            // incorporate new samples into running totals
            adc_dec_cnt <= adc_dec_cnt + 32'h1 ;
            adc_a_sum   <= adc_a_sum + adc_a_y ;
            adc_b_sum   <= $signed(adc_b_sum) + $signed(adc_b_i) ;

            // always store the appropriate sum / average / decimated sample in adc_[ab]_dat
            // so it is available to store in the buffer on the next clock, if appropriate
            if (use_sum) begin
               // for decimation rates <= 4, the sum fits in 16 bits, so we can return
               // that instead of the average, retaining some bits.
               // This path only used when avg_en is true.
               adc_a_dat <= adc_a_sum[15+0 :  0];
               adc_b_dat <= adc_b_sum[15+0 :  0];
            end
            else begin
               // not summing.  If avg_en is true and the decimation rate is one of the "special" powers of two,
               // return the average, truncated toward zero.
               // Otherwise, we're either not averaging or can't easily compute average because the decimation
               // rate is not a power of two, just return the bare sample.
               // The values adc_a_dat and adc_b_dat are only used at the end of the decimation interval
               // when it is time to save values in the appropriate buffers.
               case (dec_rate & {17{avg_en}})
                 17'h1     : begin adc_a_dat <= adc_a_sum[15+0 :  0];      adc_b_dat <= adc_b_sum[15+0 :  0];  end
                 17'h2     : begin adc_a_dat <= adc_a_sum[15+1 :  1];      adc_b_dat <= adc_b_sum[15+1 :  1];  end
                 17'h4     : begin adc_a_dat <= adc_a_sum[15+2 :  2];      adc_b_dat <= adc_b_sum[15+2 :  2];  end
                 17'h8     : begin adc_a_dat <= adc_a_sum[15+3 :  3];      adc_b_dat <= adc_b_sum[15+3 :  3];  end
                 17'h40    : begin adc_a_dat <= adc_a_sum[15+6 :  6];      adc_b_dat <= adc_b_sum[15+6 :  6];  end
                 17'h400   : begin adc_a_dat <= adc_a_sum[15+10: 10];      adc_b_dat <= adc_b_sum[15+10: 10];  end
                 17'h2000  : begin adc_a_dat <= adc_a_sum[15+13: 13];      adc_b_dat <= adc_b_sum[15+13: 13];  end
                 17'h10000 : begin adc_a_dat <= adc_a_sum[15+16: 16];      adc_b_dat <= adc_b_sum[15+16: 16];  end
                 default   : begin adc_a_dat <= adc_a_y;                   adc_b_dat <= adc_b_i;               end
               endcase
            end
         end // if (`capturing)
      end
   end

   //---------------------------------------------------------------------------------
   //  ADC buffer RAM

   localparam RSZ = 14 ;  // RAM size 2^RSZ

   reg [  32-1: 0] adc_a_buf [0:(1<<(RSZ-1))-1] ; // 28 bits so we can do 32 bit reads
   reg [  16-1: 0] adc_a_prev ; // temporary register for saving previous 16-bit sample from ADC a because we combine two into a 32-bit write

   reg [  14-1: 0] adc_b_buf [0:(1<<RSZ)-1]  ;
   reg [  32-1: 0] adc_a_rd                  ;
   reg [  14-1: 0] adc_b_rd                  ;
   reg [  12-1: 0] xadc_a_buf [0:(1<<RSZ)-1] ;
   reg [  12-1: 0] xadc_b_buf [0:(1<<RSZ)-1] ;
   reg [  12-1: 0] xadc_a_rd                 ;
   reg [  12-1: 0] xadc_b_rd                 ;
   reg [ RSZ-1: 0] adc_wp                    ;
   reg [ RSZ-1: 0] adc_raddr                 ;
   reg [ RSZ-1: 0] adc_a_raddr               ;

   reg [ RSZ-1: 0] adc_b_raddr               ;
   reg [ RSZ-1: 0] xadc_a_raddr              ;
   reg [ RSZ-1: 0] xadc_b_raddr              ;
   reg [   4-1: 0] adc_rval                  ;
   wire            adc_rd_dv                 ;
   reg             adc_trig                  ;

   // Write to BRAM buffers
   always @(posedge adc_clk_i) begin
      if (! reset) begin
         if (! `capturing) begin
            if (adc_trig)
              begin
                 `capturing  <= 1'b1 ;
                 `armed  <= 1'b0;
                 adc_wp <= 'h0;
                 samp_countdown <= num_samp;
                 adc_counter <= 'h0;
                 adc_dec_cnt <= 17'h0;
                 adc_a_sum   <= 'h0;
                 adc_b_sum   <= 'h0;
              end
         end else // ! `capturing
           begin
              if (samp_countdown == 32'h0) // capture complete
                begin
                   `capturing <= 1'b0 ;
                   `fired <= 1'b1;
                end
              else if (dec_done) // decimation done
                begin
                   // Note: the adc_a buffer is 32 bits wide, so we only write into it on every 2nd sample
                   // The later sample goes into the upper 16 bits, the earlier one into the lower 16 bits.
                   // We divide adc_wp by two to use it as an index into the 32-bit array.
                   if (adc_wp[0])
                     adc_a_buf[adc_wp[RSZ-1:1]] <= {adc_a_dat, adc_a_prev};
                   else
                     adc_a_prev <= adc_a_dat;
                   adc_b_buf[adc_wp] <= adc_b_dat ;
                   xadc_a_buf[adc_wp] <= xadc_a_i ;
                   xadc_b_buf[adc_wp] <= xadc_b_i ;
                   samp_countdown <= samp_countdown - 32'b1 ; // -1
                   adc_wp <= adc_wp + 1'b1 ;
                   adc_dec_cnt <= 0;
                end // if (dec_done)
           end
      end // if (! reset)
   end

   // Return value from buffer and return to processing system.
   // I don't understand the logic whereby we only reply on the 4th clock
   // after the read request comes in.
   always @(posedge adc_clk_i) begin
      if ( reset)
        adc_rval <= 4'h0 ;
      else
        adc_rval <= {adc_rval[2:0], (ren || wen)};
   end
   assign adc_rd_dv = adc_rval[3];

   always @(posedge adc_clk_i) begin
      adc_raddr      <= addr[RSZ+1:2] ; // address synchronous to clock
      adc_a_raddr    <= adc_raddr     ; // double register
      adc_b_raddr    <= adc_raddr     ; // otherwise memory corruption at reading
      xadc_a_raddr   <= adc_a_raddr     ; // double register
      xadc_b_raddr   <= adc_b_raddr     ; // otherwise memory corruption at reading
      adc_a_rd       <= adc_a_buf[adc_a_raddr[RSZ-1:1]] ;
      adc_b_rd       <= adc_b_buf[adc_b_raddr] ;
      xadc_a_rd      <= xadc_a_buf[xadc_a_raddr] ;
      xadc_b_rd      <= xadc_b_buf[xadc_b_raddr] ;
   end

   //---------------------------------------------------------------------------------
   //
   //  Trigger source selector

   always @(posedge adc_clk_i) begin
      if (! reset) begin
         case (trig_source)
           32'd1: adc_trig <=      1'b1 & `armed ; // trigger immediately upon arming
           32'd2: adc_trig <= trig_trig & `armed ; // trigger on radar trigger pulse
           32'd3: adc_trig <= acp_trig  & `armed ; // trigger on acp pulse
           32'd4: adc_trig <= arp_trig  & `armed ; // trigger on arp pulse
           default : adc_trig <= 1'b0      ;
         endcase
      end
   end

   //---------------------------------------------------------------------------------
   //
   //  system bus connection
   //
   // bridge between ADC and system, for reading/writing registers and buffers

   //bus bridging components
   wire [ 32-1: 0]   addr         ;
   wire [ 32-1: 0]   wdata        ;
   wire              wen          ;
   wire              ren          ;
   reg [ 32-1: 0]    rdata        ;
   reg               err          ;
   reg               ack          ;

   always @(posedge adc_clk_i) begin
      if (! reset) begin
         if (wen) begin
            casez (addr[19:0])
`include "generated_setters.v"  // import setter logic generated by ogdar
            endcase // casez (addr[19:0])
         end // if (wen)
`include "generated_pulsers.v" // import pulser (one-shot) logic generated by ogdar

      end // ! reset
   end // always @ (posedge adc_clk_i)

   //---------------------------------------------------------------------------------
   //
   // metadata: keep track of pulse counts at different trigger events, and save metadata
   // for a radar trigger pulse

   always @(posedge adc_clk_i) begin
      if (! reset ) begin

         clocks <= clocks + 64'b1;

         if (acp_trig) begin
            acp_clock           <= clocks;
            acp_prev_clock      <= acp_clock;
         end
         if (arp_trig) begin
            arp_clock              <= clocks;
            arp_prev_clock         <= arp_clock;
            acp_per_arp            <= acp_count - acp_at_arp;
            acp_at_arp             <= acp_count;
            trig_at_arp            <= trig_count;
            clock_since_acp_at_arp <= acp_age;
         end
         if (trig_trig) begin
            trig_clock           <= clocks;
            trig_prev_clock      <= trig_clock;

            if (! `capturing) begin
               // we've been triggered but are not already capturing a
               // previous pulse so save copies of metadata registers
               // for this pulse.  (If trig_trig is true but we are
               // already capturing, the capture interval is too long
               // for the trigger rate!)
               saved_acp_count              <=  acp_count              ;
               saved_acp_clock              <=  acp_clock              ;
               saved_acp_prev_clock         <=  acp_prev_clock         ;
               saved_arp_count              <=  arp_count              ;
               saved_arp_clock              <=  arp_clock              ;
               saved_arp_prev_clock         <=  arp_prev_clock         ;
               saved_acp_per_arp            <=  acp_per_arp            ;
               saved_acp_at_arp             <=  acp_at_arp             ;
               saved_clock_since_acp_at_arp <=  clock_since_acp_at_arp ;
               saved_trig_at_arp            <=  trig_at_arp            ;
               saved_trig_count             <=  trig_count             ;
               saved_trig_clock             <=  clocks                 ; // NB: not trig_clock, since that's not valid until the next tick.
               saved_trig_prev_clock        <=  trig_clock             ;
            end
         end // if(trig_trig)
      end // if (! reset)
   end

   always @(*) begin
      err <= 1'b0 ;

      casez (addr[19:0])
`include "generated_getters.v"  // import getter logic generated by ogdar
        // reads from buffers
        20'h1???? : begin ack <= adc_rd_dv;     rdata <= adc_a_rd                           ; end // 32 bit register
        20'h2???? : begin ack <= adc_rd_dv;     rdata <= {16'h0, 2'h0, adc_b_rd}            ; end

        20'h3???? : begin ack <= adc_rd_dv;     rdata <= {16'h0, 4'h0, xadc_a_rd}           ; end
        20'h4???? : begin ack <= adc_rd_dv;     rdata <= {16'h0, 4'h0, xadc_b_rd}           ; end
        default   : begin ack <= 1'b1;          rdata <= 32'h0                              ; end
      endcase
   end

   bus_clk_bridge i_bridge
     (
      .sys_clk_i     (  sys_clk_i      ),
      .sys_rstn_i    (  sys_rstn_i     ),
      .sys_addr_i    (  sys_addr_i     ),
      .sys_wdata_i   (  sys_wdata_i    ),
      .sys_sel_i     (  sys_sel_i      ),
      .sys_wen_i     (  sys_wen_i      ),
      .sys_ren_i     (  sys_ren_i      ),
      .sys_rdata_o   (  sys_rdata_o    ),
      .sys_err_o     (  sys_err_o      ),
      .sys_ack_o     (  sys_ack_o      ),

      .clk_i         (  adc_clk_i      ),
      .rstn_i        (  adc_rstn_i     ),
      .addr_o        (  addr           ),
      .wdata_o       (  wdata          ),
      .wen_o         (  wen            ),
      .ren_o         (  ren            ),
      .rdata_i       (  rdata          ),
      .err_i         (  err            ),
      .ack_i         (  ack            )
      );

endmodule // red_pitaya_digdar
