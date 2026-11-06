#ifndef CONNECT6_USB_H
#define CONNECT6_USB_H
#include <stdint.h>
typedef struct C6Device C6Device;
C6Device *c6_open(int32_t *error);
void c6_close(C6Device *device);
int32_t c6_read(C6Device *device, uint8_t settings[128]);
// Native volume mapping: 0=None, 1=Speakers, 2=Headphone 1, 4=Headphone 2.
int32_t c6_set_native_volume_mapping(C6Device *device, const uint8_t expected[128], uint8_t mapping);
// Read/merge/write: only the selected physical output volumes/mutes can be changed.
// Reject stale volume/mute values instead of overwriting another adjustment.
int32_t c6_apply(C6Device *device, const uint8_t expected[128],
                 const int16_t volumes[3], uint8_t volumeMask,
                 const uint8_t mutes[3], uint8_t muteMask);
int32_t c6_read_mixer(C6Device *device, uint8_t mixer[128]);
// Only Mobile in's Mix A/B send levels and send mutes may be changed.
int32_t c6_apply_mobile(C6Device *device, const uint8_t expected[128],
                       const int16_t levels[2], uint8_t levelMask,
                       const uint8_t mutes[2], uint8_t muteMask);
#endif
