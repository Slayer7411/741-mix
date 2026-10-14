// Zählt Speicheranforderungen eines Threads über den malloc-Logger von libmalloc (wie Instruments).
// Nur für Prüfungen, nie im Betrieb eingeschaltet.
#include "MixDSPAllocProbe.h"
#include <atomic>
#include <pthread.h>

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
extern "C" malloc_logger_t *malloc_logger;

namespace {
constexpr uint32_t kLogAllocate = 2;   // MALLOC_LOG_TYPE_ALLOCATE
pthread_t watched;
std::atomic<bool> active{false};
std::atomic<int64_t> count{0};
malloc_logger_t *previous = nullptr;

void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t r, uint32_t skip) {
    if (active.load(std::memory_order_relaxed) && (type & kLogAllocate) && pthread_equal(pthread_self(), watched))
        count.fetch_add(1, std::memory_order_relaxed);
    if (previous) previous(type, a1, a2, a3, r, skip);
}
}

void mdsp_alloc_probe_begin(void) {
    watched = pthread_self();
    count.store(0);
    if (malloc_logger != logger) { previous = malloc_logger; malloc_logger = logger; }
    active.store(true);
}

int64_t mdsp_alloc_probe_end(void) {
    active.store(false);
    if (malloc_logger == logger) malloc_logger = previous;
    previous = nullptr;
    return count.load();
}
