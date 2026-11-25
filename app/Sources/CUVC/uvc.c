#include "uvc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

enum { UNIT_CT, UNIT_PU };

typedef struct {
    const char *name;
    int unit;
    uint8_t selector;
    uint16_t size;
    int is_signed;
    const char *help;
} control_t;

static const control_t controls[] = {
    {"ae-mode", UNIT_CT, 0x02, 1, 0, "auto exposure: 1 = manual, 8 = auto"},
    {"ae-priority", UNIT_CT, 0x03, 1, 0, "1 = may lower frame rate to brighten"},
    {"exposure", UNIT_CT, 0x04, 4, 0, "exposure time in 0.1 ms units (manual mode)"},
    {"backlight", UNIT_PU, 0x01, 2, 0, "backlight compensation"},
    {"brightness", UNIT_PU, 0x02, 2, 1, ""},
    {"contrast", UNIT_PU, 0x03, 2, 0, ""},
    {"gain", UNIT_PU, 0x04, 2, 0, ""},
    {"power-line", UNIT_PU, 0x05, 1, 0, "anti-flicker: 0 = off, 1 = 50 Hz, 2 = 60 Hz"},
    {"saturation", UNIT_PU, 0x07, 2, 0, ""},
    {"sharpness", UNIT_PU, 0x08, 2, 0, ""},
    {"wb-temp", UNIT_PU, 0x0A, 2, 0, "white balance in kelvin (when wb-auto = 0)"},
    {"wb-auto", UNIT_PU, 0x0B, 1, 0, "1 = automatic white balance"},
};
#define NCONTROLS ((int)(sizeof(controls) / sizeof(controls[0])))

struct uvc_cam {
    IOUSBDeviceInterface **dev;
    int vc_if, ct_id, pu_id;
    char name[128];
};

// Finds the VideoControl interface, camera terminal and processing unit in the config descriptor.
static int find_units(IOUSBDeviceInterface **dev, struct uvc_cam *cam) {
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg) != kIOReturnSuccess || !cfg) return 0;
    const uint8_t *p = (const uint8_t *)cfg;
    uint16_t total = USBToHostWord(cfg->wTotalLength);
    int in_vc = 0;
    cam->vc_if = cam->ct_id = cam->pu_id = -1;
    for (uint16_t i = 0; i + 2 <= total;) {
        uint8_t len = p[i], type = p[i + 1];
        if (len < 2 || i + len > total) break;
        if (type == 0x04 && len >= 9) {  // interface descriptor
            in_vc = (p[i + 5] == 0x0E && p[i + 6] == 0x01 && p[i + 3] == 0);
            if (in_vc && cam->vc_if < 0) cam->vc_if = p[i + 2];
        } else if (type == 0x24 && in_vc && len >= 4) {  // class-specific VideoControl descriptor
            uint8_t sub = p[i + 2];
            if (sub == 0x02 && len >= 6 && cam->ct_id < 0) {
                if ((p[i + 4] | (p[i + 5] << 8)) == 0x0201) cam->ct_id = p[i + 3];  // camera terminal
            } else if (sub == 0x05 && cam->pu_id < 0) {
                cam->pu_id = p[i + 3];  // processing unit
            }
        }
        i += len;
    }
    return cam->vc_if >= 0 && (cam->ct_id >= 0 || cam->pu_id >= 0);
}

uvc_cam *uvc_open(const char *name_hint) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS)
        return NULL;
    struct uvc_cam *found = NULL;
    io_service_t svc;
    while (!found && (svc = IOIteratorNext(it))) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin,
                                              &score) == kIOReturnSuccess && plugin) {
            IOUSBDeviceInterface **dev = NULL;
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
            IODestroyPlugInInterface(plugin);
            struct uvc_cam cam = {0};
            if (dev && find_units(dev, &cam)) {
                CFStringRef s = IORegistryEntryCreateCFProperty(svc, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
                if (!s || !CFStringGetCString(s, cam.name, sizeof(cam.name), kCFStringEncodingUTF8))
                    strcpy(cam.name, "USB camera");
                if (s) CFRelease(s);
                if (!name_hint || strstr(cam.name, name_hint)) {
                    found = malloc(sizeof(*found));
                    *found = cam;
                    found->dev = dev;
                    dev = NULL;
                }
            }
            if (dev) (*dev)->Release(dev);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

void uvc_close(uvc_cam *cam) {
    if (!cam) return;
    (*cam->dev)->Release(cam->dev);
    free(cam);
}

const char *uvc_name(const uvc_cam *cam) { return cam->name; }

static const control_t *lookup(const char *name) {
    for (int i = 0; i < NCONTROLS; i++)
        if (!strcmp(controls[i].name, name)) return &controls[i];
    return NULL;
}

static IOReturn request(uvc_cam *cam, const control_t *c, uint8_t code, long *value) {
    int unit = c->unit == UNIT_CT ? cam->ct_id : cam->pu_id;
    if (unit < 0) return kIOReturnUnsupported;
    uint8_t buf[4] = {0};
    IOUSBDevRequest req;
    req.bmRequestType = code == UVC_SET_CUR ? 0x21 : 0xA1;
    req.bRequest = code;
    req.wValue = (uint16_t)(c->selector << 8);
    req.wIndex = (uint16_t)((unit << 8) | cam->vc_if);
    req.wLength = c->size;
    req.pData = buf;
    req.wLenDone = 0;
    if (code == UVC_SET_CUR)
        for (int i = 0; i < c->size; i++) buf[i] = (uint8_t)((unsigned long)*value >> (8 * i));
    IOReturn kr = (*cam->dev)->DeviceRequest(cam->dev, &req);
    if (kr != kIOReturnSuccess || code == UVC_SET_CUR) return kr;
    unsigned long v = 0;
    for (int i = 0; i < c->size; i++) v |= (unsigned long)buf[i] << (8 * i);
    if (c->is_signed && c->size == 2) *value = (int16_t)v;
    else if (c->is_signed && c->size == 1) *value = (int8_t)v;
    else *value = (long)v;
    return kr;
}

int uvc_get(uvc_cam *cam, const char *control, uint8_t code, long *value) {
    const control_t *c = lookup(control);
    if (!cam || !c || code == UVC_SET_CUR) return -1;
    return request(cam, c, code, value) == kIOReturnSuccess ? 0 : -1;
}

int uvc_set(uvc_cam *cam, const char *control, long value) {
    const control_t *c = lookup(control);
    if (!cam || !c) return -1;
    return request(cam, c, UVC_SET_CUR, &value) == kIOReturnSuccess ? 0 : -1;
}

int uvc_control_count(void) { return NCONTROLS; }
const char *uvc_control_name(int i) { return i >= 0 && i < NCONTROLS ? controls[i].name : NULL; }
const char *uvc_control_help(int i) { return i >= 0 && i < NCONTROLS ? controls[i].help : NULL; }
