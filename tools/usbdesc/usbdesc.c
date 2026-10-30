// Prints the raw configuration descriptors of Apogee USB devices.
// Read-only: uses the descriptors macOS already cached, sends nothing to the device.
// Build: clang -framework IOKit -framework CoreFoundation usbdesc.c -o usbdesc
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>

#define APOGEE_VID 0x0C60

static int intProp(io_service_t s, CFStringRef key) {
    int val = -1;
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    if (r) {
        if (CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberIntType, &val);
        CFRelease(r);
    }
    return val;
}

static void dump(io_service_t svc) {
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) { fprintf(stderr, "plugin failed 0x%x\n", kr); return; }
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { fprintf(stderr, "no device interface\n"); return; }

    UInt8 ncfg = 0;
    (*dev)->GetNumberOfConfigurations(dev, &ncfg);
    for (UInt8 c = 0; c < ncfg; c++) {
        IOUSBConfigurationDescriptorPtr cd;
        if ((*dev)->GetConfigurationDescriptorPtr(dev, c, &cd) != kIOReturnSuccess) continue;
        UInt16 len = USBToHostWord(cd->wTotalLength);
        printf("config %u length %u\n", c, len);
        const UInt8 *p = (const UInt8 *)cd;
        for (UInt16 off = 0; off < len && p[off]; off += p[off]) {
            printf("%04x:", off);
            for (UInt8 i = 0; i < p[off] && off + i < len; i++) printf(" %02x", p[off + i]);
            printf("\n");
        }
    }
    (*dev)->Release(dev);
}

int main(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS)
        return 1;
    io_service_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(it))) {
        if (intProp(svc, CFSTR("idVendor")) == APOGEE_VID) {
            printf("device %04x:%04x bcd %04x\n", APOGEE_VID,
                   intProp(svc, CFSTR("idProduct")), intProp(svc, CFSTR("bcdDevice")));
            dump(svc);
            found++;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found ? 0 : 2;
}
