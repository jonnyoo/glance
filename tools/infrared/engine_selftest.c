/* No camera access: validates state isolation and cancellation before USB opens. */
#define BRIO_IR_EMBEDDED
#include "brio_ir_probe.c"
#include <assert.h>

int main(void) {
    brio_ir_job *first = brio_ir_create();
    assert(first && selftest(first) == 0);
    assert(!snapshot_ready(first)); // two complete frames are not a burst
    uint8_t pixels[PIXELS];
    memset(pixels, 1, sizeof(pixels));
    uvc_frame_t frame = {0};
    frame.data = pixels; frame.data_bytes = PIXELS;
    frame.width = WIDTH; frame.height = HEIGHT; frame.step = WIDTH;
    frame.frame_format = UVC_FRAME_FORMAT_KSMEDIA_L8_IR;
    for (int i = 0; i < 10; i++) on_frame(&frame, first);
    assert(first->frames == 12 && !snapshot_ready(first)); // mostly dark
    memset(pixels, 180, sizeof(pixels));
    frame.data_bytes--;
    for (int i = 0; i < 3; i++) on_frame(&frame, first);
    assert(!snapshot_ready(first)); // malformed bright frames do not count
    frame.data_bytes = PIXELS;
    on_frame(&frame, first);
    assert(!snapshot_ready(first)); // only two illuminated frames
    on_frame(&frame, first);
    assert(snapshot_ready(first) && first->latest[0] == 180);
    brio_ir_destroy(first);
    brio_ir_job *next = brio_ir_create();
    assert(next && next->frames == 0 && next->rejected == 0);
    assert(next->brightest_mean == -1 && next->latest[0] == 0);
    assert(next->illuminated_frames == 0 && !snapshot_ready(next));
    brio_ir_cancel(next);
    size_t count = 0;
    char *response = brio_ir_snapshot(next, &count);
    assert(response && count < 200 && strstr(response, "\"stage\":\"cancelled\""));
    assert(!strstr(response, "pixels"));
    brio_ir_free_response(response, count);
    brio_ir_destroy(next);
    puts("IR engine bounded-burst readiness, malformed/dark-frame handling, state isolation and pre-start cancellation passed");
    return 0;
}
