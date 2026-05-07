module ui.wifisetupwindow;

import core.thread;

import std.format;

import adw.HeaderBar;
import adw.StatusPage;

import gtk.Box;
import gtk.Button;
import gtk.Dialog;
import gtk.Label;
import gtk.Window;

import slf4d;

import imobiledevice;

import daemon.paired_devices;

import ui.utils;

class WifiSetupWindow: Dialog {
    private Button pairButton;
    private Label stepsLabel;
    private string configPath;

    this(iDevice device, Window parent, string configPath = null) {
        this.configPath = configPath;
        this.setTitle("Set Up WiFi");
        this.setTransientFor(parent);
        this.setDefaultSize(420, 0);
        this.setModal(true);

        auto headerBar = new HeaderBar();
        headerBar.addCssClass("flat");
        this.setTitlebar(headerBar);

        StatusPage page = new StatusPage(); {
            page.setIconName("network-wireless-symbolic");
            page.setTitle("WiFi Sideloading");
            page.setDescription("Pair this computer with your iPhone to enable wireless sideloading.");
            page.setVexpand(true);

            Box box = new Box(Orientation.VERTICAL, 12); {
                box.setMarginStart(24);
                box.setMarginEnd(24);
                box.setMarginBottom(24);

                pairButton = new Button("Pair Device");
                pairButton.addCssClass("suggested-action");
                pairButton.setHalign(Align.CENTER);
                pairButton.addOnClicked((_) => startPairing(device));
                box.append(pairButton);

                stepsLabel = new Label("");
                stepsLabel.setWrap(true);
                stepsLabel.setXalign(0.0f);
                stepsLabel.setUseMarkup(true);
                stepsLabel.hide();
                box.append(stepsLabel);
            }
            page.setChild(box);
        }
        this.setChild(page);
    }

    private void startPairing(iDevice device) {
        pairButton.setSensitive(false);
        stepsLabel.hide();

        new Thread({
            try {
                scope lockdown = new LockdowndClient(device, "sideloader.wifi-setup");

                auto validateResult = lockdown.validatePair();
                bool alreadyPaired = (validateResult == lockdownd_error_t.LOCKDOWN_E_SUCCESS);

                lockdownd_error_t result;
                if (alreadyPaired) {
                    result = lockdownd_error_t.LOCKDOWN_E_SUCCESS;
                } else {
                    result = lockdown.pair();
                }

                with (lockdownd_error_t) switch (result) {
                    case LOCKDOWN_E_SUCCESS:
                    case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
                        bool wifiEnabled = false;
                        try {
                            enableWifiConnections(device);
                            wifiEnabled = true;
                        } catch (Exception) {}

                        if (wifiEnabled && configPath !is null) {
                            import std.datetime.systime : Clock;
                            import std.datetime.timezone : UTC;
                            string devName;
                            try { devName = lockdown.deviceName(); } catch (Exception) { devName = device.udid; }
                            PairedDevice paired = {
                                udid: device.udid,
                                deviceName: devName,
                                pairedAt: Clock.currTime(UTC()),
                            };
                            savePairedDevice(configPath, paired);
                        }

                        runInUIThread({
                            pairButton.setLabel("Paired");
                            if (wifiEnabled) {
                                stepsLabel.setMarkup(
                                    "<b>WiFi sync enabled!</b>\n\n" ~
                                    "You can unplug the USB cable.\n" ~
                                    "<i>Both devices must be on the same WiFi network.</i>"
                                );
                            } else {
                                stepsLabel.setMarkup(
                                    "<b>Device paired, but automatic WiFi enablement failed.</b>\n\n" ~
                                    "Try disconnecting and reconnecting the USB cable, then pair again.\n\n" ~
                                    "If the issue persists, ensure <b>Developer Mode</b> is enabled on your " ~
                                    "iPhone (Settings → Privacy &amp; Security → Developer Mode).\n\n" ~
                                    "<i>Both devices must be on the same WiFi network.</i>"
                                );
                            }
                            stepsLabel.show();
                        });
                        break;
                    default:
                        string errText = format!"Pairing failed (%s). Unlock your device and trust this computer, then retry."(result);
                        runInUIThread({
                            stepsLabel.setMarkup(`<span color="red">` ~ errText ~ `</span>`);
                            stepsLabel.show();
                            pairButton.setSensitive(true);
                        });
                        break;
                }
            } catch (Exception ex) {
                string errText = ex.msg;
                runInUIThread({
                    stepsLabel.setMarkup(`<span color="red">Error: ` ~ errText ~ `</span>`);
                    stepsLabel.show();
                    pairButton.setSensitive(true);
                });
            }
        }).start();
    }

    private static void enableWifiConnections(iDevice device) {
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
}
