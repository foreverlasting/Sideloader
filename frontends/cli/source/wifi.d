module wifi;

import std.stdio;

import argparse;
import slf4d;
import slf4d.default_provider;

import imobiledevice;

import cli_frontend;

@(Command("wifi").Description("WiFi sideloading helpers."))
struct WifiCommand
{
    int opCall()
    {
        import std.sumtype : match;
        return cmd.match!(
            (WifiSetup cmd) => cmd()
        );
    }

    @SubCommands
    import std.sumtype : SumType, match;
    SumType!(WifiSetup) cmd;
}

@(Command("setup").Description("Pair this computer with your iPhone for WiFi sideloading."))
struct WifiSetup
{
    @(NamedArgument("udid").Description("UDID of the device (if multiple USB devices are connected)."))
    string udid = null;

    int opCall()
    {
        auto log = getLogger();

        // Only consider USB-connected devices for the initial pairing step
        auto devices = iDevice.deviceList();

        import std.algorithm : filter;
        import std.array : array;
        auto usbDevices = devices.filter!(d => d.connType == iDeviceConnectionType.usbmuxd).array;

        string targetUdid = this.udid;
        if (!targetUdid) {
            if (usbDevices.length == 0) {
                log.error("No USB-connected device found. Connect your iPhone with a USB cable and try again.");
                return 1;
            }
            if (usbDevices.length > 1) {
                log.error("Multiple USB devices connected. Specify one with --udid.");
                return 1;
            }
            targetUdid = usbDevices[0].udid;
        }

        writefln!"Setting up WiFi pairing for device %s..."(targetUdid);

        // Ensure the device is paired (lockdownd handshake)
        scope device = new iDevice(targetUdid, iDevice.ConnectionPreference.usbOnly);
        scope lockdown = new LockdowndClient(device, "sideloader.wifi-setup");

        auto pairResult = lockdown.pair();
        with (lockdownd_error_t) switch (pairResult) {
            case LOCKDOWN_E_SUCCESS:
            case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
                break;  // already paired or pending trust dialog
            default:
                log.errorF!"Pairing failed (error %s). Unlock your device and trust this computer."(pairResult);
                return 1;
        }

        bool wifiEnabled = false;
        try {
            enableWifiConnections(device);
            wifiEnabled = true;
        } catch (Exception ex) {
            log.warnF!"Could not enable WiFi sync automatically: %s"(ex.msg);
        }

        writeln();
        if (wifiEnabled) {
            writeln("WiFi sync enabled. You can unplug the USB cable.");
        } else {
            writeln("Device is paired. Now enable WiFi sync on your iPhone:");
            writeln();
            writeln("  1. Open the Settings app on your iPhone.");
            writeln("  2. Go to:  General → VPN & Device Management");
            writeln("  3. Tap your computer's name under \"Development\".");
            writeln("  4. Enable \"Connect via Wi-Fi\".");
            writeln();
            writeln("Once enabled, you can unplug the USB cable.");
        }
        writeln("Run `sideloader device scan` to confirm WiFi connectivity.");
        writeln();
        writeln("Note: Both your iPhone and this machine must be on the same WiFi network.");
        writeln("      The avahi/nss-mdns services must be running on Arch Linux for");
        writeln("      device discovery to work. Run:");
        writeln("        sudo systemctl enable --now avahi-daemon");
        return 0;
    }
}

private void enableWifiConnections(iDevice device) {
    import plist;
    import std.bitmanip : nativeToBigEndian, bigEndianToNative;

    scope lockdown = new LockdowndClient(device, "sideloader.wifi-setup");
    auto service = lockdown.startService("com.apple.mobile.wireless_lockdown");

    idevice_connection_t conn;
    idevice_connect(device.handle, service.port, &conn).assertSuccess();
    scope(exit) idevice_disconnect(conn);

    auto req = new PlistDict();
    req["EnableWifiConnections"] = new PlistBoolean(true);
    string xml = req.toXml();

    ubyte[4] lenBuf = nativeToBigEndian(cast(uint) xml.length);
    uint sent;
    idevice_connection_send(conn, cast(const(char)*) lenBuf.ptr, 4, &sent).assertSuccess();
    idevice_connection_send(conn, xml.ptr, cast(uint) xml.length, &sent).assertSuccess();

    ubyte[4] respLenBuf;
    uint recvd;
    idevice_connection_receive(conn, cast(char*) respLenBuf.ptr, 4, &recvd);
    if (recvd == 4) {
        uint bodyLen = bigEndianToNative!uint(respLenBuf);
        if (bodyLen > 0 && bodyLen < 65536) {
            char[] body_ = new char[bodyLen];
            idevice_connection_receive(conn, body_.ptr, bodyLen, &recvd);
        }
    }
}
