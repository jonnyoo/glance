/* Experimental, bounded BRIO IR capture. No file writes or login access.
 * Build with build_probe.py. Uses pinned libuvc with KSMedia L8_IR support.
 * --check only queries USB access; --capture requires explicit invocation.
 */
#include "brio_ir_engine.h"
#include <stdatomic.h>
#include <libusb.h>
#include <libuvc/libuvc.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { WIDTH = 340, HEIGHT = 340, PIXELS = WIDTH * HEIGHT };
static const uint8_t ir_guid[16] = {
    0x32,0,0,0,2,0,0x10,0,0x80,0,0,0xaa,0,0x38,0x9b,0x71
};
struct brio_ir_job {
    atomic_bool cancelled;
    pthread_mutex_t frame_lock;
    unsigned frames, rejected;
    double brightest_mean, darkest_mean;
    uint8_t latest[PIXELS];
    FILE *output;
};
/* CLI signal handlers never access a job owned by another thread. */
static volatile sig_atomic_t interrupted = 0;
#ifndef BRIO_IR_EMBEDDED
static void on_signal(int number) { (void)number; interrupted = 1; }
#endif
static void erase(void *memory, size_t size) {
    volatile unsigned char *bytes = memory;
    while (size--) *bytes++ = 0;
}

brio_ir_job *brio_ir_create(void) {
    brio_ir_job *job = calloc(1, sizeof(*job));
    if (!job) return NULL;
    atomic_init(&job->cancelled, 0);
    pthread_mutex_init(&job->frame_lock, NULL);
    job->brightest_mean = -1;
    job->darkest_mean = 255;
    return job;
}
void brio_ir_cancel(brio_ir_job *job) { atomic_store(&job->cancelled, 1); }
void brio_ir_destroy(brio_ir_job *job) {
    if (!job) return;
    pthread_mutex_destroy(&job->frame_lock);
    erase(job, sizeof(*job));
    free(job);
}
static int is_cancelled(brio_ir_job *job) {
    return interrupted || atomic_load(&job->cancelled);
}
static int fail(brio_ir_job *job, const char *stage, int code) {
    fprintf(job->output, "{\"ok\":false,\"stage\":\"%s\",\"code\":%d}\n", stage, code);
    return 1;
}

static int valid_frame(const uvc_frame_t *frame) {
    return frame && frame->data && frame->width == WIDTH && frame->height == HEIGHT
        && frame->frame_format == UVC_FRAME_FORMAT_KSMEDIA_L8_IR
        && frame->data_bytes == PIXELS
        && (frame->step == 0 || frame->step == WIDTH);
}

static void on_frame(uvc_frame_t *frame, void *user) {
    brio_ir_job *job = user;
    pthread_mutex_lock(&job->frame_lock);
    if (valid_frame(frame)) {
        const uint8_t *pixels = frame->data;
        unsigned long total = 0;
        for (size_t i = 0; i < PIXELS; i++) total += pixels[i];
        double mean = (double)total / PIXELS;
        if (mean > job->brightest_mean) {
            job->brightest_mean = mean;
            memcpy(job->latest, frame->data, PIXELS);
        }
        if (mean < job->darkest_mean) job->darkest_mean = mean;
        job->frames++;
    } else {
        job->rejected++;
    }
    pthread_mutex_unlock(&job->frame_lock);
}

/* A snapshot travels over stdout to the caller's memory only. */
static void base64(FILE *output, const uint8_t *data, size_t count) {
    static const char chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < count; i += 3) {
        uint32_t value = (uint32_t)data[i] << 16;
        if (i + 1 < count) value |= (uint32_t)data[i + 1] << 8;
        if (i + 2 < count) value |= data[i + 2];
        fputc(chars[(value >> 18) & 63], output);
        fputc(chars[(value >> 12) & 63], output);
        fputc(i + 1 < count ? chars[(value >> 6) & 63] : '=', output);
        fputc(i + 2 < count ? chars[value & 63] : '=', output);
    }
}

static int check_device(libusb_context *usb, libusb_device **selected) {
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(usb, &devices);
    if (count < 0) return (int)count;
    int found = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(devices[i], &d) != 0) continue;
        if (d.idVendor == 0x046d && d.idProduct == 0x085e) {
            found++;
            if (!*selected) *selected = libusb_ref_device(devices[i]);
        }
    }
    libusb_free_device_list(devices, 1);
    /* Never choose an arbitrary camera when more than one matches. */
    if (found != 1) return found ? LIBUSB_ERROR_BUSY : LIBUSB_ERROR_NO_DEVICE;
    struct libusb_config_descriptor *config = NULL;
    int rc = libusb_get_active_config_descriptor(*selected, &config);
    if (rc) return rc;
    int supported = 0;
    for (int i = 0; i < config->bNumInterfaces; i++) {
        for (int j = 0; j < config->interface[i].num_altsetting; j++) {
            const struct libusb_interface_descriptor *a = &config->interface[i].altsetting[j];
            if (a->bInterfaceNumber != 2 || a->bAlternateSetting != 0 ||
                a->bInterfaceClass != 14 || a->bInterfaceSubClass != 2) continue;
            int matching_format = 0;
            for (int off = 0; off + 3 <= a->extra_length;) {
                const uint8_t *d = a->extra + off;
                if (d[0] < 3 || off + d[0] > a->extra_length) break;
                if (d[1] == 0x24 && d[2] == 0x10) {
                    matching_format = d[0] >= 28 && d[3] == 4 && d[21] == 8
                        && memcmp(d + 5, ir_guid, 16) == 0;
                }
                if (matching_format && d[1] == 0x24 && d[2] == 0x11 && d[0] >= 30 &&
                    d[3] == 1 && (d[5] | d[6] << 8) == WIDTH &&
                    (d[7] | d[8] << 8) == HEIGHT) supported = 1;
                off += d[0];
            }
        }
    }
    libusb_free_config_descriptor(config);
    return supported ? 0 : LIBUSB_ERROR_NOT_SUPPORTED;
}

static int selftest(brio_ir_job *job) {
    uint8_t pixels[PIXELS] = {0};
    uvc_frame_t frame = {0};
    frame.data = pixels; frame.data_bytes = PIXELS;
    frame.width = WIDTH; frame.height = HEIGHT; frame.step = WIDTH;
    frame.frame_format = UVC_FRAME_FORMAT_KSMEDIA_L8_IR;
    if (!valid_frame(&frame)) return 1;
    frame.frame_format = UVC_FRAME_FORMAT_GRAY8;
    if (valid_frame(&frame)) return 1; /* grayscale is not evidence of IR */
    frame.frame_format = UVC_FRAME_FORMAT_KSMEDIA_L8_IR;
    frame.data_bytes--;
    if (valid_frame(&frame)) return 1;
    frame.data_bytes = PIXELS; frame.step++;
    if (valid_frame(&frame)) return 1;
    frame.step = WIDTH; frame.width++;
    if (valid_frame(&frame)) return 1;
    frame.width = WIDTH;
    memset(pixels, 180, sizeof(pixels));
    on_frame(&frame, job);
    memset(pixels, 1, sizeof(pixels));
    on_frame(&frame, job);
    if (job->frames != 2 || job->brightest_mean != 180 || job->darkest_mean != 1 || job->latest[0] != 180) return 1;
    frame.data_bytes--;
    on_frame(&frame, job);
    if (job->frames != 2 || job->rejected != 1 || job->latest[0] != 180) return 1;
    puts("IR frame validation and illuminated-frame selection passed");
    return 0;
}

static int run_probe(brio_ir_job *job, int argc, const char **argv) {
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) return selftest(job);
    int snapshot = argc == 2 && strcmp(argv[1], "--snapshot") == 0;
    int capture = snapshot || (argc == 2 && strcmp(argv[1], "--capture") == 0);
    if (!capture && !(argc == 2 && strcmp(argv[1], "--check") == 0)) {
        fprintf(stderr, "Usage: brio-ir-probe --check | --capture | --snapshot | --selftest\n");
        return 2;
    }
    if (is_cancelled(job)) return fail(job, "cancelled", UVC_ERROR_TIMEOUT);
    libusb_context *usb = NULL;
    libusb_device *selected = NULL;
    int rc = libusb_init(&usb);
    if (rc) return fail(job, "usb-init", rc);
    rc = check_device(usb, &selected);
    if (rc) {
        if (selected) libusb_unref_device(selected);
        libusb_exit(usb);
        return fail(job, "ir-descriptor", rc);
    }
    if (!capture) {
        libusb_device_handle *handle = NULL;
        rc = libusb_open(selected, &handle);
        int active = -1;
        if (!rc) {
            active = libusb_kernel_driver_active(handle, 2);
            rc = libusb_claim_interface(handle, 2);
            if (!rc) libusb_release_interface(handle, 2);
            libusb_close(handle);
        }
        fprintf(job->output, "{\"ok\":true,\"irDescriptor\":true,\"width\":340,\"height\":340,"
               "\"driverActive\":%d,\"claimCode\":%d}\n", active, rc);
        libusb_unref_device(selected); libusb_exit(usb);
        return 0;
    }
    libusb_unref_device(selected);
    libusb_exit(usb);
    /* No implicit privilege elevation or driver detachment from --check. */
    if (geteuid() != 0) return fail(job, "administrator-required", LIBUSB_ERROR_ACCESS);

    uvc_context_t *context = NULL;
    uvc_device_t *device = NULL;
    uvc_device_handle_t *handle = NULL;
    uvc_stream_ctrl_t control = {0};
    const char *stage = "uvc-init";
    rc = uvc_init(&context, NULL);
    if (rc) goto cleanup;
    stage = "find-brio";
    rc = uvc_find_device(context, &device, 0x046d, 0x085e, NULL);
    if (rc) goto cleanup;
    if (is_cancelled(job)) { stage = "cancelled"; rc = UVC_ERROR_TIMEOUT; goto cleanup; }
    stage = "take-camera";
    rc = uvc_open(device, &handle);
    if (rc) goto cleanup;
    stage = "negotiate-ir";
    rc = uvc_get_stream_ctrl_format_size(handle, &control,
        UVC_FRAME_FORMAT_KSMEDIA_L8_IR, WIDTH, HEIGHT, 30);
    if (rc) goto cleanup;
    if (control.bInterfaceNumber != 2 || control.bFormatIndex != 4 ||
        control.bFrameIndex != 1 || control.dwMaxVideoFrameSize < PIXELS ||
        control.dwMaxVideoFrameSize > PIXELS * 2 ||
        control.dwFrameInterval != 333333) {
        stage = "unexpected-ir-format"; rc = UVC_ERROR_INVALID_MODE; goto cleanup;
    }
    if (is_cancelled(job)) { stage = "cancelled"; rc = UVC_ERROR_TIMEOUT; goto cleanup; }
    stage = "start-ir";
    rc = uvc_start_streaming(handle, &control, on_frame, job, 0);
    if (rc) goto cleanup;
    /* Five seconds, independent of whether any frames arrive. */
    for (int tick = 0; tick < 50 && !is_cancelled(job); tick++) {
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 100000000 };
        nanosleep(&delay, NULL);
    }
    uvc_stop_streaming(handle);
    stage = is_cancelled(job) ? "cancelled" : "no-valid-ir-frames";
    if (is_cancelled(job) || job->frames == 0) rc = UVC_ERROR_TIMEOUT;

cleanup:
    /* libuvc releases interfaces and reattaches the original drivers. */
    if (handle) uvc_close(handle);
    if (device) uvc_unref_device(device);
    if (context) uvc_exit(context);
    if (rc) return fail(job, stage, rc);
    unsigned long total = 0;
    unsigned min = 255, max = 0;
    for (size_t i = 0; i < PIXELS; i++) {
        unsigned p = job->latest[i]; total += p;
        if (p < min) min = p;
        if (p > max) max = p;
    }
    fprintf(job->output, "{\"ok\":true,\"frames\":%u,\"rejected\":%u,\"width\":340,\"height\":340,"
           "\"min\":%u,\"max\":%u,\"mean\":%.3f,\"darkestMean\":%.3f",
           job->frames, job->rejected, min, max, (double)total / PIXELS, job->darkest_mean);
    if (snapshot) {
        fprintf(job->output, ",\"pixels\":\"");
        base64(job->output, job->latest, PIXELS);
        fputc('"', job->output);
    }
    fputs("}\n", job->output);
    memset(job->latest, 0, sizeof(job->latest));
    return 0;
}

/* A job is single-use. The caller must join capture before destroying it.
 * Cancellation may run concurrently; no paths or executables cross this API. */
char *brio_ir_snapshot(brio_ir_job *job, size_t *length) {
    char *data = NULL;
    *length = 0;
    job->output = open_memstream(&data, length);
    if (!job->output) return NULL;
    const char *arguments[] = { "brio-ir-probe", "--snapshot" };
    run_probe(job, 2, arguments);
    fclose(job->output);
    job->output = NULL;
    return data;
}
void brio_ir_free_response(char *data, size_t length) {
    if (data) { erase(data, length); free(data); }
}
#ifndef BRIO_IR_EMBEDDED
int main(int argc, const char **argv) {
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    brio_ir_job *job = brio_ir_create();
    if (!job) return 1;
    job->output = stdout;
    int result = run_probe(job, argc, argv);
    brio_ir_destroy(job);
    return result;
}
#endif
