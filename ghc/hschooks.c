/*
These routines customise the error messages
for various bits of the RTS.  They are linked
in instead of the defaults.
*/

/*
 * These should be linked against headers from the compiler which is compiling us.
 * For instance, if we are compiling this file to produce the stage1 compiler,
 * we should use Rts.h from stage0.
 */
#if GHC_STAGE > 1
#  include <rts/PosixSource.h>
#else // PosixSource.h not yet exposed, hacky inline for now.
#  include <ghcplatform.h>
#  if defined(solaris2_HOST_OS)
#  define _POSIX_C_SOURCE 200112L
#  define _XOPEN_SOURCE   600
#  else
#  define _POSIX_C_SOURCE 200809L
#  define _XOPEN_SOURCE   700
#  endif
#endif
#include <Rts.h>

#include <HsFFI.h>

#include <string.h>
#include <stdbool.h>

#if defined(HAVE_UNISTD_H)
#include <unistd.h>
#endif

void
initGCStatistics(void)
{
  /* Workaround for #8754: if the GC stats aren't enabled because the
   compiler couldn't use -Bsymbolic to link the default hooks, then
   initialize them sensibly. See Note [-Bsymbolic and hooks] in
   Main.hs. */
  if (RtsFlags.GcFlags.giveStats == NO_GC_STATS) {
    RtsFlags.GcFlags.giveStats = COLLECT_GC_STATS;
  }
}

void
defaultsHook (void)
{
    // This helps particularly with large compiles, but didn't work
    // very well with earlier GHCs because it caused large amounts of
    // fragmentation.  See rts/sm/BlockAlloc.c:allocLargeChunk().
    RtsFlags.GcFlags.heapSizeSuggestionAuto = true;

    RtsFlags.GcFlags.maxStkSize         = 512*1024*1024 / sizeof(W_);

    initGCStatistics();

    // See #3408: the default idle GC time of 0.3s is too short on
    // Windows where we receive console events once per second or so.
    RtsFlags.GcFlags.idleGCDelayTime = SecondsToTime(5);
}

void
StackOverflowHook (StgWord stack_size)    /* in bytes */
{
    fprintf(stderr,
            "GHC stack-space overflow: current limit is %zu bytes.\n"
            "Use the `-K<size>' option to increase it.\n",
            (size_t) stack_size);
}

int main (int argc, char *argv[])
{
    RtsConfig conf = defaultRtsConfig;
    conf.defaultsHook = defaultsHook;
    conf.rts_opts_enabled = RtsOptsAll;
    conf.stackOverflowHook = StackOverflowHook;
    extern StgClosure ZCMain_main_closure;

    hs_main(argc, argv, &ZCMain_main_closure, conf);
}
