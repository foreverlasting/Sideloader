module install;

import slf4d;
import slf4d.default_provider;

import argparse;
import progress;

import imobiledevice;

import sideload;
import sideload.application;

import cli_frontend;

@(Command("install").Description("Install an application on the device (renames the app, register the identifier, sign and install automatically)."))
struct InstallCommand
{
    mixin LoginCommand;

    @(PositionalArgument(0, "app path").Description("The path of the IPA file to sideload."))
    string appPath;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi").Description("Prefer WiFi connection when device is available on both USB and WiFi."))
    bool preferWifi;

    @(NamedArgument("usb").Description("Connect via USB only, ignoring WiFi-connected devices."))
    bool usbOnly;

    @(NamedArgument("singlethread").Description("Run the signature process on a single thread. Sacrifices speed for more consistency."))
    bool singlethreaded;

    int opCall()
    {
        Application app = openApp(appPath);

        auto log = getLogger();

        string configurationPath = systemConfigurationPath();

        scope provisioningData = initializeADI(configurationPath);
        scope adi = provisioningData.adi;
        scope akDevice = provisioningData.device;

        auto appleAccount = login(akDevice, adi);

        if (!appleAccount) {
            return 1;
        }

        auto connPref = usbOnly          ? iDevice.ConnectionPreference.usbOnly
                      : preferWifi       ? iDevice.ConnectionPreference.preferWifi
                                         : iDevice.ConnectionPreference.auto_;

        auto devices = iDevice.deviceList();
        string udid = this.udid;
        if (!udid) {
            // When --usb is set, ignore WiFi-only devices during auto-detection
            import std.algorithm : filter;
            import std.array : array;
            auto candidates = usbOnly
                ? devices.filter!(d => d.connType == iDeviceConnectionType.usbmuxd).array
                : devices;
            if (candidates.length == 1) {
                udid = candidates[0].udid;
            } else {
                if (!candidates.length) {
                    log.error(usbOnly ? "No USB-connected device found." : "No device connected.");
                    return 1;
                }
                log.error("Multiple devices are connected. Please select one with --udid.");
                return 1;
            }
        }

        log.infoF!"Initiating connection to the device (UDID: %s)"(udid);
        auto device = new iDevice(udid, connPref);
        Bar progressBar = new Bar();
        string message;
        progressBar.message = () => message;
        sideloadFull(configurationPath, device, appleAccount, app, (progress, action) {
            message = action;
            progressBar.index = cast(int) (progress * 100);
            progressBar.update();
        }, !singlethreaded);
        progressBar.finish();

        return 0;
    }
}
