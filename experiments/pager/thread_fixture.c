// Guest-only demand-paging stress fixture. Calls cold functions simultaneously.
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sched.h>

#define WORKERS 8
static _Atomic unsigned arrived;
static _Atomic unsigned failures;
#define COLD(N) __attribute__((noinline, aligned(16384))) static unsigned cold##N(unsigned x) { \
    volatile unsigned y = x; return y * 17 + N; }
COLD(0) COLD(1) COLD(2) COLD(3) COLD(4) COLD(5) COLD(6) COLD(7)
static unsigned (*const functions[])(unsigned) = {cold0,cold1,cold2,cold3,cold4,cold5,cold6,cold7};
static void *worker(void *arg) {
    unsigned id = (unsigned)(unsigned long)arg;
    atomic_fetch_add(&arrived, 1);
    while (atomic_load(&arrived) != WORKERS) sched_yield();
    for (unsigned n=0; n<1000; ++n)
        for (unsigned i=0; i<8; ++i)
            if (functions[i](id+n) != (id+n)*17+i) atomic_fetch_add(&failures, 1);
    return NULL;
}
int main(void) {
    struct sigaction current;
    if (sigaction(SIGUSR1, NULL, &current)) return 2;
    pthread_t threads[WORKERS];
    for (unsigned i=0; i<WORKERS; ++i)
        if (pthread_create(&threads[i], NULL, worker, (void *)(unsigned long)i)) return 3;
    for (unsigned i=0; i<WORKERS; ++i) pthread_join(threads[i], NULL);
    if (atomic_load(&failures)) return 4;
#ifdef TEST_WRITE_FAULT
    *(volatile unsigned char *)(void *)cold0 = 0;
#endif
    puts("concurrent cold-page calls passed");
    return 0;
}
