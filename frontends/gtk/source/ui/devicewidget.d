module ui.devicewidget;

import core.thread;

import std.format;

import adw.ActionRow;
import adw.ExpanderRow;
import adw.PreferencesGroup;

import gtk.Dialog;
import gtk.FileChooserNative;
import gtk.FileFilter;
import gtk.Label;
import gtk.MessageDialog;
import gtk.Window;

import slf4d;

import imobiledevice;

import server.developersession;

import sideload;

import ui.authentication.authenticationassistant;
import ui.sideloadprogresswindow;
import ui.sideloadergtkapplication;
import ui.toolselectionwindow;
import ui.utils;
import ui.wifisetupwindow;

class DeviceWidget: PreferencesGroup {
    iDevice device;
    LockdowndClient lockdowndClient;
    Window toolSelectionWindow;
    Window wifiWindow;
    private iDeviceConnectionType connType;

    this(iDeviceInfo deviceInfo) {
        string udid = deviceInfo.udid;
        string deviceId = format!"%s (%s)"(udid, deviceInfo.connType == iDeviceConnectionType.network ? "Network" : "USB");

        device = new iDevice(udid);
        connType = deviceInfo.connType;

        ExpanderRow phoneExpander = new ExpanderRow();
        new Thread({
            try {
                lockdowndClient = new LockdowndClient(device, "sideloader");
                runInUIThread(() { if (phoneExpander) phoneExpander.setTitle(lockdowndClient.deviceName()); });
            } catch (iMobileDeviceException!lockdownd_error_t ex) {
                getLogger().errorF!"Cannot get device name for %s: %s"(deviceId, ex);
                if (ex.underlyingError == lockdownd_error_t.LOCKDOWN_E_PASSWORD_PROTECTED) {
                    runInUIThread(() { if (phoneExpander) phoneExpander.setTitle("(unlock your device)"); });
                }
            }
        }).start();
        phoneExpander.setSubtitle(deviceId);
        phoneExpander.setIconName("phone"); {
            ActionRow installApplicationRow = new ActionRow();
            installApplicationRow.setTitle("Install application...");
            installApplicationRow.setSubtitle("Sign and install an .ipa file to your device");
            installApplicationRow.setIconName("system-software-install-symbolic");
            installApplicationRow.setActivatable(true);
            installApplicationRow.addOnActivated((_) => selectApplication(false));
            phoneExpander.addRow(installApplicationRow);

            ActionRow managedInstallRow = new ActionRow();
            managedInstallRow.setTitle("Install & manage...");
            managedInstallRow.setSubtitle("Sideload and track for automatic re-signing");
            managedInstallRow.setIconName("emblem-synchronizing-symbolic");
            managedInstallRow.setActivatable(true);
            managedInstallRow.addOnActivated((_) => selectApplication(true));
            phoneExpander.addRow(managedInstallRow);

            if (deviceInfo.connType == iDeviceConnectionType.usbmuxd) {
                ActionRow wifiSetupRow = new ActionRow();
                wifiSetupRow.setIconName("network-wireless-symbolic");

                new Thread({
                    auto status = checkWifiPairingStatus(device);
                    runInUIThread({
                        final switch (status) {
                            case WifiPairingStatus.pairedWithWifi:
                                wifiSetupRow.setTitle("WiFi paired");
                                wifiSetupRow.setSubtitle("This device is set up for wireless sideloading");
                                wifiSetupRow.setActivatable(false);
                                break;
                            case WifiPairingStatus.pairedNoWifi:
                                wifiSetupRow.setTitle("Enable WiFi...");
                                wifiSetupRow.setSubtitle("Device is paired — enable wireless connectivity");
                                wifiSetupRow.setActivatable(true);
                                wifiSetupRow.addOnActivated((_) {
                                    auto rootWindow = cast(Window) this.getRoot();
                                    wifiWindow = new WifiSetupWindow(device, rootWindow, runningApplication.configurationPath);
                                    wifiWindow.show();
                                });
                                break;
                            case WifiPairingStatus.notPaired:
                                wifiSetupRow.setTitle("Set up WiFi...");
                                wifiSetupRow.setSubtitle("One-time setup — sideload wirelessly without a cable");
                                wifiSetupRow.setActivatable(true);
                                wifiSetupRow.addOnActivated((_) {
                                    auto rootWindow = cast(Window) this.getRoot();
                                    wifiWindow = new WifiSetupWindow(device, rootWindow, runningApplication.configurationPath);
                                    wifiWindow.show();
                                });
                                break;
                        }
                    });
                }).start();

                phoneExpander.addRow(wifiSetupRow);
            }

            ActionRow additionalToolsRow = new ActionRow();
            additionalToolsRow.setTitle("Additional tools");
            additionalToolsRow.setIconName("applications-utilities-symbolic");
            additionalToolsRow.setActivatable(true);
            additionalToolsRow.addOnActivated((_) => showTools(device));
            phoneExpander.addRow(additionalToolsRow);

        }

        add(phoneExpander);
    }

    private void offerWifiSetup() {
        auto rootWindow = cast(Window) this.getRoot();
        auto dialog = new MessageDialog(
            rootWindow,
            DialogFlags.DESTROY_WITH_PARENT | DialogFlags.MODAL | DialogFlags.USE_HEADER_BAR,
            MessageType.QUESTION,
            ButtonsType.YES_NO,
            "Enable WiFi sideloading? Set up pairing now so future installs don't need a USB cable."
        );
        dialog.addOnResponse((response, _) {
            dialog.close();
            if (response == ResponseType.YES) {
                wifiWindow = new WifiSetupWindow(device, cast(Window) this.getRoot(), runningApplication.configurationPath);
                wifiWindow.show();
            }
        });
        dialog.show();
    }

    void showTools(iDevice device) {
        auto rootWindow = cast(Window) this.getRoot();
        toolSelectionWindow = new ToolSelectionWindow(rootWindow, device);
        toolSelectionWindow.show();
    }

    void selectApplication(bool managed = false) {
        auto rootWindow = cast(Window) this.getRoot();
        auto fileChooser = new FileChooserNative(
            "Select iOS application",
            rootWindow,
            FileChooserAction.OPEN,
            "_Select",
            "_Cancel"
        );
        fileChooser.setTransientFor(rootWindow);
        fileChooser.setModal(true);
        auto ipaFilter = new FileFilter();
        ipaFilter.addPattern("*.ipa");
        ipaFilter.setName("iOS application package");
        fileChooser.addFilter(ipaFilter);
        fileChooser.addOnResponse((response, _) {
            if (response == ResponseType.ACCEPT) {
                string path = fileChooser.getFile().getPath();
                getLogger().infoF!`Application "%s" selected for installation.`(path);
                try {
                    Application app = new Application(path);
                    AuthenticationAssistant.authenticate(runningApplication, (developer) {
                        void delegate() wifiOffer = null;
                        if (connType == iDeviceConnectionType.usbmuxd) {
                            wifiOffer = () { offerWifiSetup(); };
                        }
                        SideloadProgressWindow.sideload(runningApplication, developer, app, device, managed, path, wifiOffer);
                    });
                } catch (Exception ex) {
                    getLogger().errorF!"Invalid application: %s"(ex);
                    auto errorDialog = new MessageDialog(cast(Window) this.getRoot(), DialogFlags.DESTROY_WITH_PARENT | DialogFlags.MODAL | DialogFlags.USE_HEADER_BAR, MessageType.ERROR, ButtonsType.CLOSE, format!"Sideloading failed: %s"(ex.msg));
                    errorDialog.addOnResponse((_, __) {
                        errorDialog.close();
                    });
                    errorDialog.show();
                }
            }
        });

        fileChooser.show();
    }

    void closeWindows() {
        if (toolSelectionWindow) {
            toolSelectionWindow.close();
        }
        if (wifiWindow) {
            wifiWindow.close();
        }
    }
}
