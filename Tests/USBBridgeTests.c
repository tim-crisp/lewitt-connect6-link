// Exercise the real C read/merge/write implementation through an in-memory USB
// vtable. No hardware or audio is accessed by this test.
#include "../Sources/USBBridge.c"
#include <assert.h>
#include <stdio.h>

static uint8_t general[128], mixer[128], written[128];
static int writes;
static uint8_t writtenMessage;

static IOReturn fake_request(void *self, IOUSBDevRequestTO *request) {
    (void)self;
    assert(request->bRequest == 3 && request->wIndex == 0x3300 && request->wLength == 128);
    uint8_t message = request->wValue & 0xff;
    assert(message == 0 || message == 2);
    if (request->bmRequestType == 0xa1) {
        memcpy(request->pData, message == 0 ? general : mixer, 128);
    } else {
        assert(request->bmRequestType == 0x21);
        memcpy(written, request->pData, 128);
        writtenMessage = message;
        writes++;
    }
    request->wLenDone = 128;
    return 0;
}

int main(void) {
    IOUSBDeviceInterface500 table = {0};
    table.DeviceRequestTO = fake_request;
    IOUSBDeviceInterface500 *interface = &table;
    C6Device device = {&interface};
    uint8_t expected[128];
    int16_t levels[2] = {-1536, 256};
    uint8_t mutes[2] = {0, 1};
    for (int i = 0; i < 128; i++) mixer[i] = (uint8_t)(i + 17);
    mixer[6] = 0; mixer[7] = 1; mixer[20] = 0; mixer[21] = 1;
    mixer[46] = 0; mixer[53] = 1;
    memcpy(expected, mixer, 128);
    mixer[67] = 5; // A simultaneous, unrelated Mac input-remapping edit.
    mixer[31] = 9; // A simultaneous, unrelated output-routing edit.
    assert(c6_apply_mobile(&device, expected, levels, 1, mutes, 0) == 0);
    assert(writes == 1 && writtenMessage == 2);
    for (int i = 0; i < 128; i++) {
        if (i == 6) assert(written[i] == 0x00);
        else if (i == 7) assert(written[i] == 0xfa);
        else assert(written[i] == mixer[i]);
    }
    assert(c6_apply_mobile(&device, expected, levels, 0, (uint8_t[]){1, 1}, 1) == 0);
    assert(writes == 2 && written[46] == 1);
    for (int i = 0; i < 128; i++) if (i != 46) assert(written[i] == mixer[i]);
    mixer[53] = 0; // A competing Mobile mute change prevents stale edits.
    assert(c6_apply_mobile(&device, expected, levels, 1, mutes, 0) == kIOReturnBusy);
    assert(writes == 2);
    assert(c6_apply_mobile(&device, expected, (int16_t[]){3000, 0}, 1, mutes, 0) == kIOReturnBadArgument);
    assert(c6_apply_mobile(&device, expected, levels, 4, mutes, 0) == kIOReturnBadArgument);
    assert(writes == 2);
    memset(general, 0, 128);
    memcpy(expected, general, 128);
    general[36] = 1; // Fresh phantom-power setting must survive an output mute.
    general[32] = 1; // Fresh Mobile master mute must survive too.
    assert(c6_apply(&device, expected, (int16_t[]){0, 0, 0}, 0, (uint8_t[]){0, 1, 0}, 2) == 0);
    assert(writes == 3 && writtenMessage == 0);
    for (int i = 0; i < 128; i++) {
        if (i == 11) assert(written[i] == 1);
        else assert(written[i] == general[i]);
    }
    memcpy(expected, general, 128);
    general[2] = 0x80; general[3] = 0xcb; // A concurrent volume movement.
    general[10] = 1; // A concurrent mute change.
    for (int mapping = 1; mapping <= 4; mapping *= 2) {
        assert(c6_set_native_volume_mapping(&device, expected, mapping) == 0);
        assert(writtenMessage == 0 && written[38] == mapping);
        for (int i = 0; i < 128; i++) if (i != 38) assert(written[i] == general[i]);
    }
    assert(writes == 6);
    assert(c6_set_native_volume_mapping(&device, expected, 3) == kIOReturnBadArgument);
    assert(c6_set_native_volume_mapping(&device, expected, 7) == kIOReturnBadArgument);
    assert(writes == 6);
    general[38] = 2; // Another controller reassigned native volume first.
    assert(c6_set_native_volume_mapping(&device, expected, 4) == kIOReturnBusy);
    assert(writes == 6);
    memcpy(expected, general, 128);
    assert(c6_set_native_volume_mapping(&device, expected, 2) == 0);
    assert(writes == 6); // No-op assignments do not write.
    assert(c6_set_native_volume_mapping(&device, expected, 0) == 0);
    assert(writes == 7 && written[38] == 0);
    puts("PASS: USB edits change only their allowed fields, including volume-key mapping; stale/invalid edits never write");
}
