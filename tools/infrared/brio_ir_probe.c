/* Experimental, bounded BRIO IR capture. No file writes or login access.
 * Build with build_probe.py. Uses pinned libuvc with KSMedia L8_IR support.
 * --check only queries USB access; --capture requires explicit invocation.
 */
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
static volatile sig_atomic_t interrupted = 0;
static pthread_mutex_t frame_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned frames = 0, rejected = 0;
static double brightest_mean = -1, darkest_mean = 255;
/* Brightest frame of this diagnostic run, not a live authentication sample. */
static uint8_t latest[PIXELS];

static void on_signal(int signal_number) { (void)signal_number; interrupted = 1; }

static int fail(const char *stage, int code) {
    /* Stage is always a fixed internal string, never device-supplied text. */
    printf("{\"ok\":false,\"stage\":\"%s\",\"code\":%d}\n", stage, code);
    return 1;
}

static int valid_frame(const uvc_frame_t *frame) {
    return frame && frame->data && frame->width == WIDTH && frame->height == HEIGHT
        && frame->frame_format == UVC_FRAME_FORMAT_KSMEDIA_L8_IR
        && frame->data_bytes == PIXELS
        && (frame->step == 0 || frame->step == WIDTH);
}

static void on_frame(uvc_frame_t *frame, void *user) {
    (void)user;
    pthread_mutex_lock(&frame_lock);
    if (valid_frame(frame)) {
        const uint8_t *pixels = frame->data;
        unsigned long total = 0;
        for (size_t i = 0; i < PIXELS; i++) total += pixels[i];
        double mean = (double)total / PIXELS;
        if (mean > brightest_mean) {
            brightest_mean = mean;
            memcpy(latest, frame->data, PIXELS);
        }
        if (mean < darkest_mean) darkest_mean = mean;
        frames++;
    } else {
        rejected++;
    }
    pthread_mutex_unlock(&frame_lock);
}

/* A snapshot travels over stdout to the caller's memory only. */
static void base64(const uint8_t *data, size_t count) {
    static const char chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < count; i += 3) {
        uint32_t value = (uint32_t)data[i] << 16;
        if (i + 1 < count) value |= (uint32_t)data[i + 1] << 8;
        if (i + 2 < count) value |= data[i + 2];
        putchar(chars[(value >> 18) & 63]);
        putchar(chars[(value >> 12) & 63]);
        putchar(i + 1 < count ? chars[(value >> 6) & 63] : '=');
        putchar(i + 2 < count ? chars[value & 63] : '=');
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

static int selftest(void) {
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
    on_frame(&frame, NULL);
    memset(pixels, 1, sizeof(pixels));
    on_frame(&frame, NULL);
    if (frames != 2 || brightest_mean != 180 || darkest_mean != 1 || latest[0] != 180) return 1;
    frame.data_bytes--;
    on_frame(&frame, NULL);
    if (frames != 2 || rejected != 1 || latest[0] != 180) return 1;
    puts("IR frame validation and illuminated-frame selection passed");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) return selftest();
    int snapshot = argc == 2 && strcmp(argv[1], "--snapshot") == 0;
    int capture = snapshot || (argc == 2 && strcmp(argv[1], "--capture") == 0);
    if (!capture && !(argc == 2 && strcmp(argv[1], "--check") == 0)) {
        fprintf(stderr, "Usage: brio-ir-probe --check | --capture | --snapshot | --selftest\n");
        return 2;
    }
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    libusb_context *usb = NULL;
    libusb_device *selected = NULL;
    int rc = libusb_init(&usb);
    if (rc) return fail("usb-init", rc);
    rc = check_device(usb, &selected);
    if (rc) {
        if (selected) libusb_unref_device(selected);
        libusb_exit(usb);
        return fail("ir-descriptor", rc);
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
        printf("{\"ok\":true,\"irDescriptor\":true,\"width\":340,\"height\":340,"
               "\"driverActive\":%d,\"claimCode\":%d}\n", active, rc);
        libusb_unref_device(selected); libusb_exit(usb);
        return 0;
    }
    libusb_unref_device(selected);
    libusb_exit(usb);
    /* No implicit privilege elevation or driver detachment from --check. */
    if (geteuid() != 0) return fail("administrator-required", LIBUSB_ERROR_ACCESS);

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
    stage = "start-ir";
    rc = uvc_start_streaming(handle, &control, on_frame, NULL, 0);
    if (rc) goto cleanup;
    /* Five seconds, independent of whether any frames arrive. */
    for (int tick = 0; tick < 50 && !interrupted; tick++) {
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 100000000 };
        nanosleep(&delay, NULL);
    }
    uvc_stop_streaming(handle);
    stage = interrupted ? "cancelled" : "no-valid-ir-frames";
    if (interrupted || frames == 0) rc = UVC_ERROR_TIMEOUT;

cleanup:
    /* libuvc releases interfaces and reattaches the original drivers. */
    if (handle) uvc_close(handle);
    if (device) uvc_unref_device(device);
    if (context) uvc_exit(context);
    if (rc) return fail(stage, rc);
    unsigned long total = 0;
    unsigned min = 255, max = 0;
    for (size_t i = 0; i < PIXELS; i++) {
        unsigned p = latest[i]; total += p;
        if (p < min) min = p;
        if (p > max) max = p;
    }
    printf("{\"ok\":true,\"frames\":%u,\"rejected\":%u,\"width\":340,\"height\":340,"
           "\"min\":%u,\"max\":%u,\"mean\":%.3f,\"darkestMean\":%.3f",
           frames, rejected, min, max, (double)total / PIXELS, darkest_mean);
    if (snapshot) {
        printf(",\"pixels\":\"");
        base64(latest, PIXELS);
        putchar('"');
    }
    puts("}");
    memset(latest, 0, sizeof(latest));
    return 0;
}
