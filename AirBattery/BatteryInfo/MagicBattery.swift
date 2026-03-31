//
//  MagicBattery.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//
import SwiftUI
import Foundation
import IOBluetooth

class SPBluetoothDataModel {
    static var shared: SPBluetoothDataModel = SPBluetoothDataModel()
    private let lock = NSLock()
    private var storedData: String = "{}"
    private var lastUpdate: Date = Date(timeIntervalSince1970: 0)

    var data: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedData
        }
        set {
            lock.lock()
            storedData = newValue
            lock.unlock()
        }
    }
    
    func refeshData(completion: (String) -> Void, error: (() -> Void)? = nil) {
        let uptime = Date().timeIntervalSince(appStartTime)
        let now = Date()

        lock.lock()
        let cachedData = storedData
        let shouldUseCache = uptime > 60 && now.timeIntervalSince(lastUpdate) < 60
        lock.unlock()

        // After 60s of uptime, throttle to once per 60s
        if shouldUseCache {
            completion(cachedData)
            return
        }
        
        if let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"], lowPriority: true) {
            lock.lock()
            storedData = result
            lastUpdate = now
            lock.unlock()
            completion(result)
        } else {
            error?()
        }
    }
}

class MagicBattery {
    static var shared: MagicBattery = MagicBattery()
    
    var scanTimer: Timer?
    @AppStorage("readBTDevice") var readBTDevice = true
    //@AppStorage("readBTHID") var readBTHID = true
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("deviceName") var deviceName = "Mac"
    
    func startScan() {
        let interval = TimeInterval(59.0 * Double(updateInterval))
        scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scanDevices), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning Magic devices...")
        scanDevices()
    }
    
    @objc func scanDevices() {
        DispatchQueue.global(qos: .utility).async {
            SPBluetoothDataModel.shared.refeshData { result in
                if self.readBTDevice {
                    let bluetoothJson = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: []) as? [String: Any]
                    self.getIOBTBattery()
                    self.getOtherBTBattery(json: bluetoothJson)
                    self.getMagicBattery(json: bluetoothJson)
                    self.getOldMagicKeyboard(json: bluetoothJson)
                    self.getOldMagicTrackpad(json: bluetoothJson)
                    self.getOldMagicMouse(json: bluetoothJson)
                }
            }
        }
    }
    
    func findParentKey(forValue value: Any, in json: [String: Any]) -> String? {
        for (key, subJson) in json {
            if let subJsonDictionary = subJson as? [String: Any] {
                if subJsonDictionary.values.contains(where: { $0 as? String == value as? String }) {
                    return key
                } else if let parentKey = findParentKey(forValue: value, in: subJsonDictionary) {
                    return parentKey
                }
            } else if let subJsonArray = subJson as? [[String: Any]] {
                for subJsonDictionary in subJsonArray {
                    if subJsonDictionary.values.contains(where: { $0 as? String == value as? String }) {
                        return key
                    } else if let parentKey = findParentKey(forValue: value, in: subJsonDictionary) {
                        return parentKey
                    }
                }
            }
        }
        return nil
    }
    
    func getDeviceName(_ mac: String, _ def: String, json: [String: Any]? = nil) -> String {
        let bluetoothJson = json ?? (try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any])
        if let bluetoothJson = bluetoothJson {
            if let parent = findParentKey(forValue: mac, in: bluetoothJson) {
                return parent
            }
        }
        return def
    }
    
    func getDeviceType(_ mac: String, _ def: String, json: [String: Any]? = nil) -> String {
        let bluetoothJson = json ?? (try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any])
        if let bluetoothJson = bluetoothJson,
           let SPBluetoothDataTypeRaw = bluetoothJson["SPBluetoothDataType"] as? [Any],
           let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let id = info["device_address"] as? String,
                           let type = info["device_minorType"] as? String{
                            if id == mac { return type }
                        }
                    }
                }
            }
        }
        return def
    }
    
    func getDeviceTypeWithPID(_ pid: String, _ def: String, json: [String: Any]? = nil) -> String {
        let bluetoothJson = json ?? (try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any])
        if let bluetoothJson = bluetoothJson,
           let SPBluetoothDataTypeRaw = bluetoothJson["SPBluetoothDataType"] as? [Any],
           let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let id = info["device_productID"] as? String,
                           let type = info["device_minorType"] as? String{
                            if id == pid { return type }
                        }
                    }
                }
            }
        }
        return def
    }
    
    func readMagicBattery(object: io_object_t, json: [String: Any]? = nil) {
        var mac = ""
        var type = "hid"
        var status = 0
        var percent = 0
        var productName = ""
        let lastUpdate = Date().timeIntervalSince1970
        if let productProperty = IORegistryEntryCreateCFProperty(object, "DeviceAddress" as CFString, kCFAllocatorDefault, 0) {
            mac = productProperty.takeRetainedValue() as! String
            mac = mac.replacingOccurrences(of:"-", with:":").uppercased()
        }
        if let percentProperty = IORegistryEntryCreateCFProperty(object, "BatteryStatusFlags" as CFString, kCFAllocatorDefault, 0) {
            status = percentProperty.takeRetainedValue() as! Int
            if status == 4 { status = 0 }
        }
        if let percentProperty = IORegistryEntryCreateCFProperty(object, "BatteryPercent" as CFString, kCFAllocatorDefault, 0) {
            percent = percentProperty.takeRetainedValue() as! Int
        }
        if let productProperty = IORegistryEntryCreateCFProperty(object, "Product" as CFString, kCFAllocatorDefault, 0) {
            productName = productProperty.takeRetainedValue() as! String
            if productName.contains("Trackpad") { type = "Trackpad" }
            if productName.contains("Keyboard") { type = "Keyboard" }
            if productName.contains("Mouse") { type = "MMouse" }
            if type == "hid" {
                type = getDeviceType(mac, type, json: json)
                if type.contains("Trackpad") { type = "Trackpad" }
                if type.contains("Keyboard") { type = "Keyboard" }
                if type.contains("Mouse") { type = "MMouse" }
            } else {
                productName = getDeviceName(mac, productName, json: json)
            }
        }
        if !productName.contains("Internal"){
            AirBatteryModel.updateDevice(Device(deviceID: mac, deviceType: type, deviceName: productName, batteryLevel: percent, isCharging: status, parentName: deviceName, lastUpdate: lastUpdate))
        }
    }

    func getMagicBattery(json: [String: Any]? = nil) {
        var serialPortIterator = io_iterator_t()
        var object : io_object_t
        let masterPort: mach_port_t
        if #available(macOS 12.0, *) {
            masterPort = kIOMainPortDefault // New name in macOS 12 and higher
        } else {
            masterPort = kIOMasterPortDefault // Old name in macOS 11 and lower
        }
        let matchingDict : CFDictionary = IOServiceMatching("AppleDeviceManagementHIDEventService")
        let kernResult = IOServiceGetMatchingServices(masterPort, matchingDict, &serialPortIterator)
        
        if KERN_SUCCESS == kernResult {
            repeat {
                object = IOIteratorNext(serialPortIterator)
                if object != 0 { readMagicBattery(object: object, json: json) }
            } while object != 0
            IOObjectRelease(object)
        }
        IOObjectRelease(serialPortIterator)
    }
    
    func getOldMagicKeyboard(json: [String: Any]? = nil) {
        var serialPortIterator = io_iterator_t()
        var object : io_object_t
        let masterPort: mach_port_t
        if #available(macOS 12.0, *) { masterPort = kIOMainPortDefault } else { masterPort = kIOMasterPortDefault }
        let matchingDict : CFDictionary = IOServiceMatching("AppleBluetoothHIDKeyboard")
        let kernResult = IOServiceGetMatchingServices(masterPort, matchingDict, &serialPortIterator)
        if KERN_SUCCESS == kernResult {
            repeat {
                object = IOIteratorNext(serialPortIterator)
                if object != 0 { readMagicBattery(object: object, json: json) }
            } while object != 0
            IOObjectRelease(object)
        }
        IOObjectRelease(serialPortIterator)
    }
    
    func getOldMagicTrackpad(json: [String: Any]? = nil) {
        var serialPortIterator = io_iterator_t()
        var object : io_object_t
        let masterPort: mach_port_t
        if #available(macOS 12.0, *) { masterPort = kIOMainPortDefault } else { masterPort = kIOMasterPortDefault }
        let matchingDict : CFDictionary = IOServiceMatching("BNBTrackpadDevice")
        let kernResult = IOServiceGetMatchingServices(masterPort, matchingDict, &serialPortIterator)
        if KERN_SUCCESS == kernResult {
            repeat {
                object = IOIteratorNext(serialPortIterator)
                if object != 0 { readMagicBattery(object: object, json: json) }
            } while object != 0
            IOObjectRelease(object)
        }
        IOObjectRelease(serialPortIterator)
    }
    
    func getOldMagicMouse(json: [String: Any]? = nil) {
        var serialPortIterator = io_iterator_t()
        var object : io_object_t
        let masterPort: mach_port_t
        if #available(macOS 12.0, *) { masterPort = kIOMainPortDefault } else { masterPort = kIOMasterPortDefault }
        let matchingDict : CFDictionary = IOServiceMatching("BNBMouseDevice")
        let kernResult = IOServiceGetMatchingServices(masterPort, matchingDict, &serialPortIterator)
        if KERN_SUCCESS == kernResult {
            repeat {
                object = IOIteratorNext(serialPortIterator)
                if object != 0 { readMagicBattery(object: object, json: json) }
            } while object != 0
            IOObjectRelease(object)
        }
        IOObjectRelease(serialPortIterator)
    }
    
    func getAirpods(json: [String: Any]? = nil) {
        let now = Date().timeIntervalSince1970
        let bluetoothJson = json ?? (try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any])
        if let bluetoothJson = bluetoothJson,
        let SPBluetoothDataTypeRaw = bluetoothJson["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        var productID = "200e"
                        var mainDevice: Device?
                        var subDevices: [Device] = []
                        if let level = info["device_batteryLevelCase"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "%", with: "")) {
                                if var apCase = AirBatteryModel.getByName(n + " (Case)".local) {
                                    apCase.batteryLevel = level
                                    apCase.lastUpdate = now
                                    mainDevice = apCase
                                } else {
                                    mainDevice = Device(deviceID: id, deviceType: "ap_case", deviceName: n + " (Case)".local, deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, lastUpdate: now)
                                }
                            }
                        }
                        if let level = info["device_batteryLevelLeft"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: "%", with: "")) {
                                if var apLeft = AirBatteryModel.getByName(n + " 🄻") {
                                    apLeft.batteryLevel = level
                                    apLeft.lastUpdate = now
                                    subDevices.append(apLeft)
                                } else {
                                    subDevices.append(Device(deviceID: id, deviceType: "ap_pod_left", deviceName: n + " 🄻", deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            }
                            mainDevice?.deviceModel = getHeadphoneModel(productID)
                        }
                        if let level = info["device_batteryLevelRight"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: "%", with: "")) {
                                if var apRight = AirBatteryModel.getByName(n + " 🅁") {
                                    apRight.batteryLevel = level
                                    apRight.lastUpdate = now
                                    subDevices.append(apRight)
                                } else {
                                    subDevices.append(Device(deviceID: id, deviceType: "ap_pod_right", deviceName: n + " 🅁", deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            }
                            mainDevice?.deviceModel = getHeadphoneModel(productID)
                        }
                        if let apCase = mainDevice { AirBatteryModel.updateDevice(apCase) }
                        if subDevices.count != 0 {
                            if subDevices.count == 2 {
                                if abs(Int(subDevices[0].batteryLevel) - Int(subDevices[1].batteryLevel)) < 3 {
                                    AirBatteryModel.hideDevice(n + " 🄻")
                                    AirBatteryModel.hideDevice(n + " 🅁")
                                    AirBatteryModel.updateDevice(Device(deviceID: n + "_All", deviceType: "ap_pod_all", deviceName: n + " 🄻🅁", deviceModel: getHeadphoneModel(productID), batteryLevel: Int(min(subDevices[0].batteryLevel, subDevices[1].batteryLevel)), isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            } else {
                                AirBatteryModel.hideDevice(n + " 🄻🅁")
                                for pod in subDevices { AirBatteryModel.updateDevice(pod) }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func getOtherBTBattery(json: [String: Any]? = nil) {
        let bluetoothJson = json ?? (try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any])
        if let bluetoothJson = bluetoothJson,
        let SPBluetoothDataTypeRaw = bluetoothJson["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let level = info["device_batteryLevelMain"] as? String,
                           let id = info["device_address"] as? String,
                           let type = info["device_minorType"] as? String,
                           (info["device_vendorID"] as? String) != "0x004C" {
                            guard let batLevel = Int(level.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "%", with: "")) else { return }
                            AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: n, batteryLevel: batLevel, isCharging: 0, lastUpdate: Date().timeIntervalSince1970))
                        }
                    }
                }
            }
        }
    }
    
    func getIOBTBattery() {
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in devices {
                let name = device.name
                let address = device.addressString
                let connected = device.isConnected()
                //let usb = device.getValue(forKey: "isPluggedOverUSB") as! Bool ?? false
                
                if connected && !device.isAppleDevice {
                    if let battery = device.getValue(forKey: "batteryPercentSingle") as? Int, let name = name, let address = address, battery != 0 {
                        // We don't have the global JSON here, but getDeviceType will handle it
                        let type = getDeviceType(address.replacingOccurrences(of: "-", with: ":").uppercased(),"", json: nil)
                        AirBatteryModel.updateDevice(Device(deviceID: address, deviceType: type, deviceName: name, batteryLevel: battery, isCharging: 0, lastUpdate: Date().timeIntervalSince1970))
                    }
                    //let left = device.getValue(forKey: "batteryPercentLeft") as? Int
                    //let right = device.getValue(forKey: "batteryPercentRight") as? Int
                    //let _case = device.getValue(forKey: "batteryPercentCase") as? Int
                }
            }
        }
    }
}

extension IOBluetoothDevice {
    func getValue(forKey: String) -> Any? {
        if self.responds(to: Selector((forKey))) {
            return self.value(forKey: forKey)
        }
        return nil
    }
    
    var isAppleDevice: Bool {
        return self.getValue(forKey: "isAppleDevice") as? Bool ?? false
    }
}
