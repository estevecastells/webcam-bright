import CoreMediaIO

// Is the camera streaming to anyone? AVFoundation's isInUseByAnotherApplication never changes for
// this camera; CoreMediaIO's DeviceIsRunningSomewhere does (and also counts our own session).

func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func cmioDevice(uniqueID: String) -> CMIOObjectID? {
    var address = cmioAddress(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return nil }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return nil }
    for id in ids {
        var uidAddress = cmioAddress(kCMIODevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if CMIOObjectGetPropertyData(id, &uidAddress, 0, nil, uidSize, &uidSize, &uid) == 0,
           let value = uid?.takeRetainedValue() as String?, value == uniqueID { return id }
    }
    return nil
}

func cmioIsRunningSomewhere(_ id: CMIOObjectID) -> Bool {
    var address = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return CMIOObjectGetPropertyData(id, &address, 0, nil, size, &size, &running) == 0 && running != 0
}
