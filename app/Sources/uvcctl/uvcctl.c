// uvcctl: inspect or change webcam controls by hand.
//
//   uvcctl list                          every control: current, min, max, default
//   uvcctl set brightness 150 gain 20    set one or more controls
//   uvcctl reset                         every control back to the camera's default
//
// UVC_CAMERA=<part of name> picks a camera when more than one is plugged in.
// While WebcamBright runs it will move exposure and gain again during calls.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uvc.h"

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "list";
    uvc_cam *cam = uvc_open(getenv("UVC_CAMERA"));
    if (!cam) {
        fprintf(stderr, "No UVC camera found.\n");
        return 1;
    }
    int rc = 0;
    if (!strcmp(cmd, "list")) {
        printf("%s\n\n%-12s %8s %8s %8s %8s\n", uvc_name(cam), "control", "current", "min", "max", "default");
        for (int i = 0; i < uvc_control_count(); i++) {
            const char *name = uvc_control_name(i);
            long cur, v;
            if (uvc_get(cam, name, UVC_GET_CUR, &cur)) continue;  // not supported by this camera
            char mn[24] = "-", mx[24] = "-", df[24] = "-";
            if (!uvc_get(cam, name, UVC_GET_MIN, &v)) snprintf(mn, sizeof mn, "%ld", v);
            if (!uvc_get(cam, name, UVC_GET_MAX, &v)) snprintf(mx, sizeof mx, "%ld", v);
            if (!uvc_get(cam, name, UVC_GET_DEF, &v)) snprintf(df, sizeof df, "%ld", v);
            printf("%-12s %8ld %8s %8s %8s  %s\n", name, cur, mn, mx, df, uvc_control_help(i));
        }
    } else if (!strcmp(cmd, "set") && argc >= 4 && argc % 2 == 0) {
        for (int i = 2; i + 1 < argc; i += 2) {
            long v = strtol(argv[i + 1], NULL, 0), now;
            if (uvc_set(cam, argv[i], v)) {
                fprintf(stderr, "%s: unknown control or value refused\n", argv[i]);
                rc = 1;
            } else if (!uvc_get(cam, argv[i], UVC_GET_CUR, &now)) {
                printf("%s = %ld\n", argv[i], now);
            }
        }
    } else if (!strcmp(cmd, "reset")) {
        for (int i = 0; i < uvc_control_count(); i++) {
            long def;
            const char *name = uvc_control_name(i);
            if (!uvc_get(cam, name, UVC_GET_DEF, &def) && !uvc_set(cam, name, def)) printf("%s = %ld\n", name, def);
        }
    } else {
        fprintf(stderr, "usage: uvcctl [list | set <control> <value> ... | reset]\n");
        rc = 2;
    }
    uvc_close(cam);
    return rc;
}
