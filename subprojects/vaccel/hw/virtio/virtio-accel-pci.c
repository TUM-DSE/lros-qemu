#include "qemu/osdep.h"
#include "hw/pci/pci.h"
#include "hw/qdev-properties.h"
#include "hw/virtio/virtio.h"
#include "hw/virtio/virtio-bus.h"
#include "hw/virtio/virtio-pci.h"
#include "../../include/hw/virtio/virtio-accel.h"
#include "qapi/error.h"
#include "qemu/module.h"

typedef struct VirtIOAccelPCI VirtIOAccelPCI;

/*
 * virtio-accel-pci: This extends VirtioPCIProxy.
 */
#define TYPE_VIRTIO_ACCEL_PCI "virtio-accel-pci"
DECLARE_INSTANCE_CHECKER(VirtIOAccelPCI, VIRTIO_ACCEL_PCI,
                         TYPE_VIRTIO_ACCEL_PCI)

struct VirtIOAccelPCI {
    VirtIOPCIProxy parent_obj;
    VirtIOAccel vdev;
};

static const Property virtio_accel_pci_properties[] = {
    DEFINE_PROP_BIT("ioeventfd", VirtIOPCIProxy, flags,
                    VIRTIO_PCI_FLAG_USE_IOEVENTFD_BIT, true),
    DEFINE_PROP_UINT32("vectors", VirtIOPCIProxy, nvectors, 2),
};

static void virtio_accel_pci_realize(VirtIOPCIProxy *vpci_dev, Error **errp)
{
    VirtIOAccelPCI *vaccel = VIRTIO_ACCEL_PCI(vpci_dev);
    DeviceState *vdev = DEVICE(&vaccel->vdev);

    if (vaccel->vdev.conf.runtime == NULL) {
        error_setg(errp, "'runtime' parameter expects a valid object");
        return;
    }
    /*
     * Let the generic disable-legacy/disable-modern properties decide the
     * transport, instead of hardwiring one here.  Unikraft speaks legacy
     * virtio only and already passes "disable-legacy=off,disable-modern=on",
     * which gets it exactly what forcing used to; guests that want virtio-1
     * (miniOSv on aarch64, where there is no port I/O to reach a legacy
     * device's I/O BAR) pass "disable-legacy=on" and get the modern layout.
     *
     * Note this device is not registered with transitional/non-transitional
     * variants, so proxy->trans_devid stays 0 and the legacy device ID comes
     * from the class below.  Modern mode overwrites it in
     * virtio_pci_device_plugged() with 0x1040 + VIRTIO_ID_ACCEL.
     */
    if (!qdev_realize(vdev, BUS(&vpci_dev->bus), errp)) {
        return;
    }
}

static void virtio_accel_pci_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    VirtioPCIClass *k = VIRTIO_PCI_CLASS(klass);
    PCIDeviceClass *pcidev_k = PCI_DEVICE_CLASS(klass);

    k->realize = virtio_accel_pci_realize;
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
    device_class_set_props(dc, virtio_accel_pci_properties);
    pcidev_k->vendor_id = PCI_VENDOR_ID_REDHAT_QUMRANET;
    pcidev_k->device_id = 0x1015;
    pcidev_k->revision = VIRTIO_PCI_ABI_VERSION;
    pcidev_k->class_id = PCI_CLASS_OTHERS;
}

static void virtio_accel_initfn(Object *obj)
{
    VirtIOAccelPCI *dev = VIRTIO_ACCEL_PCI(obj);

    virtio_instance_init_common(obj, &dev->vdev, sizeof(dev->vdev),
                                TYPE_VIRTIO_ACCEL);
}

static const VirtioPCIDeviceTypeInfo virtio_accel_pci_info = {
    .generic_name  = TYPE_VIRTIO_ACCEL_PCI,
    .instance_size = sizeof(VirtIOAccelPCI),
    .instance_init = virtio_accel_initfn,
    .class_init    = virtio_accel_pci_class_init,
};

static void virtio_accel_pci_register_types(void)
{
    virtio_pci_types_register(&virtio_accel_pci_info);
}
type_init(virtio_accel_pci_register_types)
