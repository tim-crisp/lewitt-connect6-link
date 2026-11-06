# Verified USB subset

Device: vendor `0x29c2`, product `0x0005`, firmware 2.2.7, API major 1.
No exclusive device open is necessary for these requests.

| Request field | Read | Write |
|---|---|---|
| bmRequestType | `0xa1` | `0x21` |
| bRequest | `0x03` | `0x03` |
| wValue | `0x0100 \| messageID` | `0x0100 \| messageID` |
| wIndex | `0x3300` | `0x3300` |
| wLength | 128 | 128 |

Message 0 is the general settings block. Message 2 is the mixer block.
Message 10 is the version block (read
only here). In the version block, byte 0 is the API major version; bytes 49–51
are the firmware major/minor/patch components.

General settings offsets:

| Offset | Type | Field |
|---|---|---|
| 0 | little-endian int16, dB × 256 | Speakers volume |
| 2 | little-endian int16, dB × 256 | Headphone 1 volume |
| 4 | little-endian int16, dB × 256 | Headphone 2 volume |
| 10 | uint8, 0/1 | Speakers mute |
| 11 | uint8, 0/1 | Headphone 1 mute |
| 12 | uint8, 0/1 | Headphone 2 mute |
| 38 | uint8 | Native volume key mapping: 0=None, 1=Speakers, 2=Headphone 1, 4=Headphone 2 |

The output writer accepts only volumes from −60 to 0 dB and mute flags 0 or 1.
The separate volume-key writer changes only byte 38. It preserves freshly read
levels/mutes, rejects a competing mapping edit, and accepts only 0, 1, 2 or 4.
Normal output level/mute edits preserve this mapping.

Mixer offsets exposed by the Mobile in writer:

| Offset | Type | Field |
|---|---|---|
| 6 | little-endian int16, dB × 256 | Mobile in → Mix A level |
| 20 | little-endian int16, dB × 256 | Mobile in → Mix B level |
| 46 | uint8, 0/1 | Mobile in → Mix A mute |
| 53 | uint8, 0/1 | Mobile in → Mix B mute |

The Mobile writer accepts only levels from −60 to +10 dB and mute flags 0 or 1.
Levels and mute flags have independent write masks, so changing a level never
implicitly enables a muted send. Every other byte is copied from an immediately
preceding read. This preserves other input sends, output source selection and
Mac input 1/2 remapping (mixer byte 67). There are no firmware, sample rate,
configuration, or reset operations in the bridge.
