/**
 * forked from:
 *
 * @brief Red Pitaya Oscilloscope worker module.
 *
 * @Author Jure Menart <juremenart@gmail.com>
 *         Ales Bardorfer <ales.bardorfer@redpitaya.com>
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in C programming language.
 * Please visit http://en.wikipedia.org/wiki/C_(programming_language)
 * for more details on the language used herein.
 * This module is multi-threaded and is using synchronization with mutexes
 * from POSIX thread library. For these topics please visit:
 * http://en.wikipedia.org/wiki/POSIX_Threads
 */

#include <stdio.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <stdlib.h>

#include "main_digdar.h"
#include "worker.h"
#include "fpga_digdar.h"

/**
 * GENERAL DESCRIPTION:
 *
 * The worker module is linking point between main digdar module and FPGA
 * module. 
 *
 * It is running continuously in separate thread and controls FPGA OSC module. If
 * the oscilloscope is running in auto or manual mode it collects results, 
 * process them and put them to main module, where they are available for the 
 * client. In the opposite direction main module is setting new parameters which 
 * are used by worker by each new iteration of the worker thread loop. If 
 * parameters change during measurement, this is aborted and worker updates new 
 * parameters and starts new measurement.
 * Third party of the data is control of the worker thread loop - main or worker
 * module can change the state of the loop. Possible states are defined in
 * rp_osc_worker_state_e enumeration.
 *
 * Signal and parameters structures between worker and main module are protected
 * with mutexes - which means only one can access them at the same time. With 
 * this the consistency of output (signal) or input (parameters) data is assured.
 * 
 * Besides interfacing main and FPGA module big task of worker module is also 
 * processing the result, this includes:
 *  - preparing time vector, based on current settings
 *  - decimating the signal length from FPGA buffer length (OSC_FPGA_SIG_LEN) to
 *    output signal length (SIGNAL_LENGTH defined in main_osc.h). 
 *  - converting signal from ADC samples to voltage in [V].
 */

/** POSIX thread handler */
pthread_t rp_osc_thread_handler;
/** Worker thread function declaration */
void *rp_osc_worker_thread(void *args);

/** pthread mutex used to protect parameters and related variables */
pthread_mutex_t       rp_osc_ctrl_mutex = PTHREAD_MUTEX_INITIALIZER;
/** Worker thread state holder */
rp_osc_worker_state_t rp_osc_ctrl;
/** Worker module copy of parameters (copied from main parameters) */
rp_osc_params_t       rp_osc_params[PARAMS_NUM];
/** Signalizer if new parameters were copied */
int                   rp_osc_params_dirty;
/** Signalizer if worker thread loop needs to update FPGA registers */
int                   rp_osc_params_fpga_update;

/** pthread mutex used to protect signal structure and related variables */
pthread_mutex_t       rp_osc_sig_mutex = PTHREAD_MUTEX_INITIALIZER;
/** Output signals holder */
float               **rp_osc_signals;
/** Output signals signalizer - it indicates to main whether new signals are 
 *  available or not */
int                   rp_osc_signals_dirty = 0;
/** Output signal index indicator - used in long acquisitions, it indicates 
 *  to main module if the returning signal is full or partial
 */
int                   rp_osc_sig_last_idx = 0;

/** Pointers to the FPGA input signal buffers for Channel A and B */
int                  *rp_fpga_cha_signal, *rp_fpga_chb_signal;

/** Pointers to the FPGA input signal buffers for Slow Channel A and B */
int                  *rp_fpga_xcha_signal, *rp_fpga_xchb_signal;

/** @brief Initializes worker module
 *
 * This function starts new worker thread, initializes internal structures 
 * (signals, state, ...) and initializes FPGA module.
 *
 * @retval -1 Failure
 * @retval 0 Success
*/
int rp_osc_worker_init(void)
{
    rp_osc_ctrl               = rp_osc_idle_state;
    rp_osc_params_dirty       = 0;
    rp_osc_params_fpga_update = 0;

    /* FPGA module initialization */
    if(osc_fpga_init() < 0) {
        return -1;
    }

    /* Initializing the pointers for the FPGA input signal buffers */
    osc_fpga_get_sig_ptr(&rp_fpga_cha_signal, &rp_fpga_chb_signal, &rp_fpga_xcha_signal, &rp_fpga_xchb_signal);

    return 0;
}

/** @brief Cleans up worker module.
 *
 * This function stops the working thread (sending quit state to it) and waits
 * until it is shutdown. After that it cleans up FPGA module and internal 
 * structures.
 * After this function is called any access to worker module are forbidden.
 *
 * @retval 0 Always returns 0
*/
int rp_osc_worker_exit(void)
{
    osc_fpga_exit();
    return 0;
}


/** @brief Returns a pulse of data
 * 
 * @param [out] pm Pointer to pulse_metadata structure. If null, no metdata are written.
 *
 * @param [in] ns Number of samples to grab for a pulse; 0...16384
 *
 * @param [out] data Pointer to location to store samples; must be allocated to hold at least ns samples.
 * If null, no samples are written.
 *
 * @param [out] pm Pointer to pulse_metadata structure
 *
 * @param [in] timeout maximum wait time, in microseconds.  If zero, wait forever.
 *
 * @retval 0 okay.
 *         -1 reached timeout without a pulse
*/

int rp_osc_get_pulse(pulse_metadata * pm, uint16_t ns, uint16_t *data, uint32_t timeout)
{
  static int initial_arm = 0;

  if (ns > 16384)
    ns = 16384;

  /* set number of samples to collect after triggering */
  osc_fpga_set_trigger_delay(ns);

  /* Start the writing machine */
  if (! initial_arm) {
    osc_fpga_arm_trigger();
    /* Start the trigger: 10 is the digdar trigger source on TRIG line; FIXME: find the .H file where this is defined */
    osc_fpga_set_trigger(10);
    initial_arm = 1;
  }
        
        
  /* Sleep for a while, waiting for sample; imposes maximum PRF of
     10 kHz */

  uint32_t waited = 0;
  for(;;) {
    const uint32_t single_wait = 10;  // wait 10 us at a time
    if(osc_fpga_triggered())
      break;
    usleep(single_wait);
    waited += single_wait;
    if (timeout > 0 && waited >= timeout)
      return -1;
  }

  if (pm) {
    pm->trig_clock = g_digdar_fpga_reg_mem->trig_clock_low + (((uint64_t) g_digdar_fpga_reg_mem->trig_clock_high) << 32);
    pm->num_trig = g_digdar_fpga_reg_mem->trig_count;
    pm->num_acp = g_digdar_fpga_reg_mem->acp_count;
    pm->acp_clock = g_digdar_fpga_reg_mem->acp_clock_low + (((uint64_t) g_digdar_fpga_reg_mem->acp_clock_high) << 32);
    pm->num_arp = g_digdar_fpga_reg_mem->arp_count;
    pm->arp_clock = g_digdar_fpga_reg_mem->arp_clock_low + (((uint64_t) g_digdar_fpga_reg_mem->arp_clock_high) << 32);
  }

  int32_t tr_ptr;
  osc_fpga_get_wr_ptr(0, &tr_ptr);

  // arm to allow acquisition of next pulse while we copy data from the BRAM buffer
  // for this one.

  osc_fpga_arm_trigger();
  /* Start the trigger: 10 is the digdar trigger source on TRIG line; FIXME: find the .H file where this is defined */
  osc_fpga_set_trigger(10);

  if (data) {
    int32_t *src_data = & rp_fpga_cha_signal[tr_ptr];
    int32_t *max_data = & rp_fpga_cha_signal[16384];
    for (uint16_t i = 0; i < ns; ++i) {
      data[i] = *src_data++;
      if (src_data == max_data)
        src_data = & rp_fpga_cha_signal[0];
    }
  }
  return 0;
}

