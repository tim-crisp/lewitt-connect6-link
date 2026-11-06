#include "USBBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

struct C6Device { IOUSBDeviceInterface500 **usb; };

static IOReturn transfer(C6Device *device, uint8_t message, uint8_t *bytes,
                         uint16_t length, int write) {
    IOUSBDevRequestTO request = {0};
    request.bmRequestType = write ? 0x21 : 0xa1;
    request.bRequest = 3;
    request.wValue = 0x0100 | message; // CONNECT 6 API v1
    request.wIndex = 0x3300;         // extension unit 0x33, audio control interface 0
    request.wLength = length;
    request.pData = bytes;
    request.noDataTimeout = 300;
    request.completionTimeout = 300;
    IOReturn result = (*device->usb)->DeviceRequestTO(device->usb, &request);
    if (result) return result;
    return request.wLenDone == length ? kIOReturnSuccess : kIOReturnUnderrun;
}

C6Device *c6_open(int32_t *error) {
    *error = kIOReturnNoDevice;
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) { *error = kIOReturnNoMemory; return NULL; }
    int vendor = 0x29c2, product = 5;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_iterator_t iterator = 0;
    *error = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (*error) return NULL;
    io_service_t service = IOIteratorNext(iterator);
    io_service_t second = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (second) { // Never choose an arbitrary interface when two units are connected.
        IOObjectRelease(second); IOObjectRelease(service);
        *error = kIOReturnExclusiveAccess; return NULL;
    }
    if (!service) { *error = kIOReturnNoDevice; return NULL; }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    *error = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (*error || !plugin) return NULL;
    IOUSBDeviceInterface500 **usb = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500), (void **)&usb);
    (*plugin)->Release(plugin);
    if (hr || !usb) { *error = kIOReturnUnsupported; return NULL; }
    C6Device *device = calloc(1, sizeof(*device));
    if (!device) { (*usb)->Release(usb); *error = kIOReturnNoMemory; return NULL; }
    device->usb = usb;
    // No USBDeviceOpen, seize, reset, configuration or audio-interface changes.
    uint8_t version[128] = {0};
    *error = transfer(device, 10, version, sizeof(version), 0);
    // The layout has been verified against firmware 2.2.7. Fail closed on others.
    if (!*error && !(version[0] == 1 && version[49] == 2 && version[50] == 2 && version[51] == 7))
        *error = kIOReturnUnsupported;
    if (*error) { c6_close(device); return NULL; }
    return device;
}

void c6_close(C6Device *device) {
    if (device) { (*device->usb)->Release(device->usb); free(device); }
}

int32_t c6_read(C6Device *device, uint8_t settings[128]) {
    return transfer(device, 0, settings, 128, 0);
}

int32_t c6_set_native_volume_mapping(C6Device *device, const uint8_t expected[128], uint8_t mapping) {
    if (mapping != 0 && mapping != 1 && mapping != 2 && mapping != 4)
        return kIOReturnBadArgument;
    uint8_t fresh[128];
    IOReturn result = c6_read(device, fresh);
    if (result) return result;
    if (fresh[38] != expected[38]) return kIOReturnBusy;
    if (fresh[38] == mapping) return 0;
    fresh[38] = mapping;
    // Preserve fresh levels/mutes even when the rocker moved during the edit.
    return transfer(device, 0, fresh, sizeof(fresh), 1);
}

int32_t c6_read_mixer(C6Device *device, uint8_t mixer[128]) {
    return transfer(device, 2, mixer, 128, 0);
}

int32_t c6_apply_mobile(C6Device *device, const uint8_t expected[128],
                       const int16_t levels[2], uint8_t levelMask,
                       const uint8_t mutes[2], uint8_t muteMask) {
    const int levelOffsets[2] = {6, 20};
    const int muteOffsets[2] = {46, 53};
    if ((levelMask | muteMask) & ~3) return kIOReturnBadArgument;
    // Validate the entire requested edit before sending anything.
    for (int i = 0; i < 2; i++) {
        if ((levelMask & (1 << i)) && (levels[i] < -60 * 256 || levels[i] > 10 * 256))
            return kIOReturnBadArgument;
        if ((muteMask & (1 << i)) && mutes[i] > 1) return kIOReturnBadArgument;
    }
    uint8_t fresh[128];
    IOReturn result = c6_read_mixer(device, fresh);
    if (result) return result;
    for (int i = 0; i < 2; i++) {
        if (memcmp(fresh + levelOffsets[i], expected + levelOffsets[i], 2) ||
            fresh[muteOffsets[i]] != expected[muteOffsets[i]]) return kIOReturnBusy;
    }
    for (int i = 0; i < 2; i++) {
        if (levelMask & (1 << i)) {
            uint16_t raw = (uint16_t)levels[i];
            fresh[levelOffsets[i]] = raw & 0xff;
            fresh[levelOffsets[i] + 1] = raw >> 8;
        }
        if (muteMask & (1 << i)) fresh[muteOffsets[i]] = mutes[i];
    }
    // All output routes, other input sends and input 1/2 remapping are preserved
    // from the fresh read. This message does not contain microphone gains/48V.
    return transfer(device, 2, fresh, sizeof(fresh), 1);
}

int32_t c6_apply(C6Device *device, const uint8_t expected[128],
                 const int16_t volumes[3], uint8_t volumeMask,
                 const uint8_t mutes[3], uint8_t muteMask) {
    uint8_t fresh[128];
    IOReturn result = c6_read(device, fresh);
    if (result) return result;
    // Watch every physical output so a competing change is reconsidered next poll.
    if (memcmp(fresh, expected, 6) || memcmp(fresh + 10, expected + 10, 3))
        return kIOReturnBusy;
    for (int i = 0; i < 3; i++) {
        if (volumeMask & (1 << i)) {
            if (volumes[i] < -60 * 256 || volumes[i] > 0) return kIOReturnBadArgument;
            uint16_t raw = (uint16_t)volumes[i];
            fresh[i * 2] = raw & 0xff;
            fresh[i * 2 + 1] = raw >> 8;
        }
        if (muteMask & (1 << i)) {
            if (mutes[i] > 1) return kIOReturnBadArgument;
            fresh[10 + i] = mutes[i];
        }
    }
    // Firmware accepts the entire settings message. Everything else comes from
    // the fresh read above, including inputs, phantom power and native-key mapping.
    return transfer(device, 0, fresh, sizeof(fresh), 1);
}
