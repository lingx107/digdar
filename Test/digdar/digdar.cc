/**
 * 
 * forked from:
 *
 * $Id: acquire.c 1246 2014-02-22 19:05:19Z ales.bardorfer $
 *
 * @brief Red Pitaya simple signal acquisition utility.
 *
 * @Author Ales Bardorfer <ales.bardorfer@redpitaya.com>
 *         Jure Menart <juremenart@gmail.com>
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in C programming language.
 * Please visit http://en.wikipedia.org/wiki/C_(programming_language)
 * for more details on the language used herein.
 */

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <getopt.h>
#include <string.h>
#include <sys/param.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>

#include "digdar.h"
#include "main_digdar.h"
#include "fpga_digdar.h"
#include "version.h"
#include "worker.h"
#include "capture_db.h"
#include "pulse_metadata.h"

/**
 * GENERAL DESCRIPTION:
 *
 * The code below acquires up to 16k samples on both Red Pitaya input
 * channels labeled ADC1 & ADC2.
 * 
 * It utilizes the routines of the Oscilloscope module for:
 *   - Triggered ADC signal acqusition to the FPGA buffers.
 *   - Parameter defined averaging & decimation.
 *   - Data transfer to SW buffers.
 *
 * Although the Oscilloscope routines export many functionalities, this 
 * simple signal acquisition utility only exploits a few of them:
 *   - Synchronization between triggering & data readout.
 *   - Only AUTO triggering is used by default.
 *   - Only decimation is parsed to t_params[8].
 *
 * Please feel free to exploit any other scope functionalities via 
 * parameters defined in t_params.
 *
 */

/** Program name */
const char *g_argv0 = NULL;

/** Minimal number of command line arguments */
#define MINARGS 0

/** Oscilloscope module parameters as defined in main module
 * @see rp_main_params
 */
float t_params[PARAMS_NUM] = { 0, 1e6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

/** Print usage information */
void usage() {

  const char *format =
    "\n"
    "Usage: %s [OPTION]\n"
    "\n"
    "  --dbfile -b FILENAME  Database filename; capture to this sqlite database instead of writing to stdout or TCP\n"
    "  --decim  -d DECIM   Decimation rate: one of 1, 2, 3, 4, 8, 64, 1024, 8192, or 65536\n"
    "  --sum   If specified, return the sum (in 16-bits) of samples in the decimation period.\n"
    "          e.g. instead of returning (x[0]+x[1])/2 at decimation rate 2, return x[0]+x[1]\n"
    "          Only valid if the decimation rate is <= 4 so that the sum fits in 16 bits\n"
    "  --samples   -n SAMPLES   Samples per pulse. (Up to 16384; default is 3000)\n"
    "  --pulses -p PULSES Number of pulses to allocate buffer for (default, 1000)\n"
    "  --remove -r START:END  Remove sector.  START and END are portions of the circle in [0, 1]\n"
    "                         where 0 is the start of the ARP pulse, and 1 is the start of the next ARP\n"
    "                         pulse.  Pulses within the sector from START to END are remoted and not output.\n"
    "                         If START > END, the removed sector consists of [END, 1] U [0, START].\n"
    "                         Multiple --remove options may be given.\n"
    "  --chunk_size -c Number of pulses to transfer in each chunk\n"
    "  --tcp HOST:PORT instead of writing to stdout, open a TCP socket connection to PORT on HOST and\n"
    "                  write there.\n"
    "  --version       -v    Print version info.\n"
    "  --help          -h    Print this message.\n"
    "\n";

  fprintf( stderr, format, g_argv0);
}

double now() {
  static struct timespec ts;
  clock_gettime(CLOCK_REALTIME, & ts);
  return ts.tv_sec + ts.tv_nsec / 1.0e9;
};


sector removals[MAX_REMOVALS];
uint16_t num_removals = 0;

uint16_t n_samples = 3000;  // samples to grab per radar pulse
uint32_t decim = 1; // decimation: 1, 2, 8, etc.
uint16_t num_pulses = 1000; // pulses to maintain in ring buffer (filled by worker thread)
uint16_t chunk_size = 10; // pulses to transmit per chunk (main thread)
uint16_t num_chunks = 0; // maximum number of pulses per chunk
uint16_t *pulses_in_chunk = 0; // number of pulses actually in each chunk
uint32_t psize = 0; // actual size of each pulse's storage (metadata + data) - will be set below
uint16_t use_sum = 0; // if non-zero, return sum of samples rather than truncated average
int outfd = -1; // file descriptor for output; fileno(stdout) by default;
capture_db * cap = 0; // pointer to capture database structure, if capturing to sqlite

// boilerplate ougoing socket connection fields, from Linux man-pages

struct addrinfo hints;
struct addrinfo *result, *rp;
int sfd, s;
struct sockaddr_storage peer_addr;
socklen_t peer_addr_len;
ssize_t nread;

pulse_metadata *pulse_buffer = 0;

char * host = 0;
char * port = 0;
char * dbfile = 0;

/** Acquire pulses main */
int main(int argc, char *argv[])
{
  g_argv0 = argv[0];

  if ( argc < MINARGS ) {
    usage();
    exit ( EXIT_FAILURE );
  }

  /* Command line options */
  static struct option long_options[] = {
    /* These options set a flag. */
    {"dbfile", required_argument, 0, 'b'},
    {"decim", required_argument,       0, 'd'},
    {"samples",      required_argument,       0, 'n'},
    {"sum",      no_argument,       0, 's'},
    {"pulses",       required_argument,       0, 'p'},
    {"chunk_size",    required_argument,          0, 'c'},
    {"remove",    required_argument,          0, 'r'},
    {"tcp",    required_argument,          0, 't'},
    {"version",      no_argument,       0, 'v'},
    {"help",         no_argument,       0, 'h'},
    {0, 0, 0, 0}
  };
  const char *optstring = "b:c:d:hn:p:r:st:v";

  /* getopt_long stores the option index here. */
  int option_index = 0;

  int ch = -1;
  while ( (ch = getopt_long( argc, argv, optstring, long_options, &option_index )) != -1 ) {
    switch ( ch ) {
    case 'b':
      dbfile = optarg;
      break;

    case 'c':
      chunk_size = atoi(optarg);
      break;

    case 'd':
      decim = atoi(optarg);
      break;

    case 'h':
      usage();
      exit( EXIT_SUCCESS );
      break;

    case 'n':
      n_samples = atoi(optarg);
      break;

    case 'p':
      num_pulses = atoi(optarg);
      break;

    case 'r':
      {
        if (num_removals == MAX_REMOVALS) {
          fprintf(stderr, "Too many removals specified; max is %d\n", MAX_REMOVALS);
          exit( EXIT_FAILURE );
        }
        char *split = strchr(optarg, ':');
        if (! split) {
          usage();
          exit (EXIT_FAILURE );
        }
        *split = '\0';
        removals[num_removals].begin = atof(optarg);
        removals[num_removals].end = atof(split + 1);
        ++num_removals;
      };
      break;

    case 's':
      use_sum = 1;
      break;

    case 't':
      {
        host = optarg;
        port = strchr(optarg, ':');
        if (! port) {
          usage();
          exit ( EXIT_FAILURE );
        }
            
        break;
      case 'v':
        fprintf(stdout, "%s version %s-%s\n", g_argv0, VERSION_STR, REVISION_STR);
        exit( EXIT_SUCCESS );
        break;

      default:
        usage();
        exit( EXIT_FAILURE );
      }
    }
  }

  if (host) {
    if (dbfile) {
      fprintf(stderr, "You can only specify capturing to a database (--dbfile / -b) *or* to the network (--tcp / -t), but not to both.");
      return -2;
    }

    memset(&hints, 0, sizeof(struct addrinfo));
    hints.ai_family = AF_INET;    /* Allow IPv4 only */
    hints.ai_socktype = SOCK_STREAM; /* Stream socket */
    hints.ai_flags = 0;
    hints.ai_protocol = 0;          /* Any protocol */

    *port++ = '\0';
    s = getaddrinfo(host, port, &hints, &result);
    if (s != 0) {
      fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(s));
      exit(EXIT_FAILURE);
    }

    /* getaddrinfo() returns a list of address structures.
       Try each address until we successfully connect(2).
       If socket(2) (or connect(2)) fails, we (close the socket
       and) try the next address. */

    for (rp = result; rp != NULL; rp = rp->ai_next) {
      outfd = socket(rp->ai_family, rp->ai_socktype,
                     rp->ai_protocol);
      if (outfd == -1)
        continue;

      if (connect(outfd, rp->ai_addr, rp->ai_addrlen) != -1)
        break;                  /* Success */

      close(outfd);
    }

    if (rp == NULL) {               /* No address succeeded */
      fprintf(stderr, "Could not connect\n");
      exit(EXIT_FAILURE);
    }
  }

  if (dbfile) {
    cap = new capture_db(dbfile, "capture_pulse_timestamp", "/capture_pulse_timestamp");

    // assume short-pulse mode for Bridgemaster E

    cap->set_radar_mode( 25e3, // pulse power, watts
                         50, // pulse length, nanoseconds
                         1800, // pulse repetition frequency, Hz
                         28  // antenna rotation rate, RPM
                         );

    // record digitizing mode
    cap->set_digitize_mode( 125e6 / decim, // digitizing rate, Hz
                            16,   // only uses lowest 14 bits when truncated average
                            ((decim <= 4) ? decim : 1 ) * (1<<14 - 1), // scale: max sample value possible
                            n_samples  // samples per pulse
                            );

    cap->set_retain_mode ("full"); // keep all samples from all pulses

    cap->set_pulses_per_transaction (chunk_size); // commit to keeping data for at least chunk_size pulses

    double ts = now();
    cap->record_geo(ts, 
                    45.371907, -64.402584, 30, // lat, lon, alt of Fundy Force radar site
                    0); // heading offset, in degrees

  }    


  switch(decim) {
  case 1: 
  case 2:
  case 3:
  case 4:
  case 8:
  case 64:
  case 1024:
  case 8192:
  case 65536: 
    break;
  default:
    fprintf(stderr, "incorrect value (%d) for decimation; must be 1, 2, 3, 4, 8, 64, 1024, 8192, or 65536\n", decim);
    return -1;
  }

  t_params[DECIM_FACTOR_PARAM] = decim;
      
  if (n_samples > 16384 || n_samples < 0) {
    fprintf(stderr, "incorrect value (%d) for samples per pulse; must be 0..16384\n", n_samples);
    return -1;
  }

  if (use_sum && decim > 4) {
    fprintf(stderr, "cannot specify --sum when decimation rate is > 4\n");
    return -1;
  }

  if (outfd == -1) {
    outfd = fileno(stdout);
  }

  /* Standard radar triggering mode */
  t_params[TRIG_MODE_PARAM] = 1;
  t_params[TRIG_SRC_PARAM] = 10;

  /* Initialization of Oscilloscope application */
  if(rp_app_init() < 0) {
    fprintf(stderr, "rp_app_init() failed!\n");
    return -1;
  }

  /* Setting of parameters in Oscilloscope main module */

  // FIXME: load digdar params from JSON file, parse, and set

  if(rp_set_params((float *)&t_params, PARAMS_NUM) < 0) {
    fprintf(stderr, "rp_set_params() failed!\n");
    return -1;
  }
    
  psize = sizeof(pulse_metadata) + sizeof(uint16_t) * (n_samples - 1);

  pulse_buffer = (pulse_metadata *) calloc(num_pulses, psize);
  if (!pulse_buffer) {
    fprintf(stderr, "couldn't allocate pulse buffer\n");
    return -1;
  }

  num_chunks = num_pulses / chunk_size;
  
  pulses_in_chunk = (uint16_t *) calloc(num_chunks, sizeof(uint16_t));

  // fill in magic number in pulse headers

  for (int i = 0; i < num_pulses; ++i) {
    pulse_metadata *pbm = (pulse_metadata *) (((char *) pulse_buffer) + i * psize);
    pbm->magic_number = PULSE_METADATA_MAGIC;
  }

  //    rp_osc_worker_init();

  // go ahead and start capturing

  rp_osc_worker_change_state(rp_osc_start_state);

  uint16_t cur_pulse; // index of first chunk pulse in ring buffer
  uint16_t num_pulses; // number of pulses availabe in chunk

  /* Continuous thread loop (exited only with 'quit' state) */
  while(1) {
    if (! rp_osc_get_chunk_for_reader(& cur_pulse, & num_pulses)) {
      usleep(20);
      sched_yield();
      continue;
    }
    if (cap) {
      int i;
      for (i = 0; i < num_pulses; ++i) {
        pulse_metadata *meta = (pulse_metadata *) (((char *) pulse_buffer) + cur_pulse++ * psize);
        double ts = meta->arp_clock_sec + 1.0e-9*(meta->arp_clock_nsec + 8 * meta->trig_clock);
        uint16_t *samples = (uint16_t *) (((char *) meta) + sizeof(pulse_metadata) - sizeof(uint16_t));

        cap->record_pulse (ts,
                           meta->num_trig,
                           meta->trig_clock,
                           meta->acp_clock,
                           meta->num_arp,
                           0, // constant 0 elevation angle for FORCE radar
                           0, // constant polarization for FORCE radar
                           samples);
      }
    } else {
      int n = num_pulses * psize;
      int offset = 0;
      int m;
      do {
        m = write(outfd, ((char *) pulse_buffer) + cur_pulse * psize + offset, n);
        if (m < 0)
          break;
        n -= m;
        offset += m;
      } while (n > 0);
      if (m < 0)
        break;
    }
  }
  return 0;
}
