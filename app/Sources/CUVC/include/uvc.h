// Small library for reading and setting UVC webcam controls on macOS over IOKit.
#pragma once
#include <stdint.h>

#define UVC_SET_CUR 0x01
#define UVC_GET_CUR 0x81
#define UVC_GET_MIN 0x82
#define UVC_GET_MAX 0x83
#define UVC_GET_DEF 0x87

typedef struct uvc_cam uvc_cam;

// Opens the first UVC camera whose USB product name contains `name_hint` (any UVC camera if NULL).
uvc_cam *uvc_open(const char *name_hint);
void uvc_close(uvc_cam *cam);
const char *uvc_name(const uvc_cam *cam);

// Controls by name: ae-mode, ae-priority, exposure, backlight, brightness, contrast, gain,
// power-line, saturation, sharpness, wb-temp, wb-auto. Both return 0 on success.
int uvc_get(uvc_cam *cam, const char *control, uint8_t code, long *value);
int uvc_set(uvc_cam *cam, const char *control, long value);

int uvc_control_count(void);
const char *uvc_control_name(int i);
const char *uvc_control_help(int i);
