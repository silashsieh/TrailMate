import Foundation
import Testing
@testable import TrailMate

@MainActor
struct DeviceDiscoveryServiceTests {
    @Test func parsesUSBAndWiFiRows() {
        let usb = DeviceDiscoveryService.parse(line: #"{"udid":"USB-A","name":"iPhone A","connectionType":"USB"}"#)
        #expect(usb?.udid == "USB-A")
        #expect(usb?.name == "iPhone A")
        #expect(usb?.connectionType == .usb)
        #expect(usb?.host == nil)
        #expect(usb?.port == nil)

        let wifi = DeviceDiscoveryService.parse(line: #"{"udid":"WIFI-B","name":"iPhone B","connectionType":"WiFi","host":"192.0.2.20","port":62078}"#)
        #expect(wifi?.udid == "WIFI-B")
        #expect(wifi?.connectionType == .wifi)
        #expect(wifi?.host == "192.0.2.20")
        #expect(wifi?.port == 62078)
    }

    @Test func rejectsMalformedAndMissingRequiredFieldsWithoutRunningLister() {
        for line in [
            "not JSON", "{", "[]",
            #"{"udid":"A","name":"iPhone"}"#,
            #"{"name":"iPhone","connectionType":"USB"}"#,
            #"{"udid":"A","connectionType":"USB"}"#,
            #"{"udid":"A","name":"iPhone","connectionType":"Bluetooth"}"#,
            #"{"udid":42,"name":"iPhone","connectionType":"USB"}"#
        ] {
            #expect(DeviceDiscoveryService.parse(line: line) == nil, "row: \(line)")
        }
    }

    @Test func malformedOptionalFieldsDoNotDiscardAValidDevice() {
        let device = DeviceDiscoveryService.parse(line: #"{"udid":"A","name":"iPhone","connectionType":"WiFi","host":4,"port":"bad"}"#)
        #expect(device?.udid == "A")
        #expect(device?.host == nil)
        #expect(device?.port == nil)
    }
}
