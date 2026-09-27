/* No camera access: validates state isolation and cancellation before USB opens. */
#define BRIO_IR_EMBEDDED
#include "brio_ir_probe.c"
#include <assert.h>

int main(void) {
    brio_ir_job *first = brio_ir_create();
    assert(first && selftest(first) == 0);
    brio_ir_destroy(first);
    brio_ir_job *next = brio_ir_create();
    assert(next && next->frames == 0 && next->rejected == 0);
    assert(next->brightest_mean == -1 && next->latest[0] == 0);
    brio_ir_cancel(next);
    size_t count = 0;
    char *response = brio_ir_snapshot(next, &count);
    assert(response && count < 200 && strstr(response, "\"stage\":\"cancelled\""));
    assert(!strstr(response, "pixels"));
    brio_ir_free_response(response, count);
    brio_ir_destroy(next);
    puts("IR engine state isolation and pre-start cancellation passed");
    return 0;
}
