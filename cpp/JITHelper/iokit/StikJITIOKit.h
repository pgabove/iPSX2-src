// StikJITIOKit.h — the IOKit names StikJIT's TXM check (ProcessInfo+TXM.swift) uses.
// SPDX-License-Identifier: GPL-3.0+
//
// Used instead of StikJIT's own iokit/StikJITIOKit.h (which only includes IOKitLib.h) so the
// helper also builds with SDKs whose IOKit headers are missing or lack these names.

#ifndef IPSX2_STIKJIT_IOKIT_H
#define IPSX2_STIKJIT_IOKIT_H

#if __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#else
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
typedef char io_string_t[512];
typedef UInt32 IOOptionBits;

extern const mach_port_t kIOMainPortDefault;
io_registry_entry_t IORegistryEntryFromPath(mach_port_t mainPort, const io_string_t path);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key,
                                          CFAllocatorRef allocator, IOOptionBits options);
kern_return_t IOObjectRelease(io_object_t object);
#endif

#ifndef kIORegistryEntryPropertyKeysKey
#define kIORegistryEntryPropertyKeysKey "IORegistryEntryPropertyKeys"
#endif

#endif
