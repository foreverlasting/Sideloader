module ui.mainwindow;

import gdk.Cursor;

import gio.Menu;

import gtk.Box;
import gtk.Button;
import gtk.ComboBox;
import gtk.Entry;
import gtk.Label;
import gtk.MenuButton;

import adw.Clamp;
import adw.HeaderBar;
import adw.StatusPage;
import adw.Window;

import constants;
import imobiledevice;

import daemon.paired_devices;

import ui.devicewidget;
import ui.utils;

class MainWindow: Window {
    DeviceWidget[iDeviceInfo] deviceWidgets;
    private Box devicesBox;
    private Label pairedOfflineLabel;

    Label connectDeviceLabel;
    private Label connectDeviceHint;

    Cursor defaultCursor;
    Cursor waitCursor;

    string configPath;

    this(string configPath = null) {
        this.configPath = configPath;
        // setTitle(applicationName);
        setTitle("");
        setDefaultSize(600, 400);

        defaultCursor = this.getCursor();
        waitCursor = new Cursor("wait", defaultCursor);

        Box mainWindowBox = new Box(Orientation.VERTICAL, 4); {
            HeaderBar headerBar = new HeaderBar();
            headerBar.addCssClass("flat"); {
                auto hamburgerButton = new MenuButton(); {
                    hamburgerButton.setProperty("direction", ArrowType.NONE);

                    Menu menu = new Menu();

                    Menu accountActions = new Menu(); {
                        // accountActions.append("Log-in", "app.log-in");
                        accountActions.append("Manage App IDs", "app.manage-app-ids");
                        accountActions.append("Manage certificates", "app.manage-certificates");
                    }
                    menu.appendSection(null, accountActions);

                    Menu managedSection = new Menu(); {
                        managedSection.append("Managed Apps", "app.managed-apps");
                    }
                    menu.appendSection(null, managedSection);

                    Menu appActions = new Menu(); {
                        appActions.append("Settings", "app.settings");
                        appActions.append("Donate", "app.donate");
                        appActions.append("About " ~ applicationName, "app.about");
                    }
                    menu.appendSection(null, appActions);

                    hamburgerButton.setMenuModel(menu);
                }
                headerBar.packEnd(hamburgerButton);

                auto refreshDevicesButton = new Button("Refresh device list"); {
                    refreshDevicesButton.setIconName("view-refresh-symbolic");
                    refreshDevicesButton.addOnClicked((_) {
                        setBusy(true);
                        uiTry!({
                            scope(exit) setBusy(false);
                            foreach (k, dw; deviceWidgets) {
                                removeDeviceWidget(k);
                            }

                            foreach (dev; iDevice.deviceList()) {
                                addDeviceWidget(dev);
                            }
                        });
                    });
                }
                headerBar.packStart(refreshDevicesButton);
            }
            mainWindowBox.append(headerBar);

            StatusPage content = new StatusPage();
            content.setTitle(applicationName); {
                Clamp clamp = new Clamp(); {
                    devicesBox = new Box(Orientation.VERTICAL, 0); {
                        connectDeviceLabel = new Label("Connect your iPhone via USB");
                        devicesBox.append(connectDeviceLabel);

                        connectDeviceHint = new Label("WiFi pairing is optional — you can set it up once your device is connected.");
                        connectDeviceHint.addCssClass("dim-label");
                        connectDeviceHint.setWrap(true);
                        connectDeviceHint.setMarginTop(4);
                        devicesBox.append(connectDeviceHint);

                        pairedOfflineLabel = new Label("");
                        pairedOfflineLabel.addCssClass("dim-label");
                        pairedOfflineLabel.setWrap(true);
                        pairedOfflineLabel.setMarginTop(12);
                        pairedOfflineLabel.hide();
                        devicesBox.append(pairedOfflineLabel);
                    }
                    clamp.setChild(devicesBox);
                }
                content.setChild(clamp);
            }
            mainWindowBox.append(content);
        }
        setChild(mainWindowBox);
    }

    void setBusy(bool val) {
        this.setSensitive(!val);
        this.setCursor(val ? waitCursor : defaultCursor);
    }

    void addDeviceWidget(iDeviceInfo deviceInfo) {
        if (deviceInfo !in deviceWidgets) {
            connectDeviceLabel.hide();
            connectDeviceHint.hide();
            auto deviceWidget = new DeviceWidget(deviceInfo);
            deviceWidgets[deviceInfo] = deviceWidget;
            devicesBox.append(deviceWidgets[deviceInfo]);
            updatePairedOfflineLabel();
        }
    }

    void removeDeviceWidget(iDeviceInfo deviceId) {
        if (deviceId in deviceWidgets) {
            auto deviceWidget = deviceWidgets[deviceId];
            deviceWidget.unparent();
            deviceWidget.closeWindows();
            deviceWidgets.remove(deviceId);
            if (deviceWidgets.length == 0) {
                connectDeviceLabel.show();
                connectDeviceHint.show();
            }
            updatePairedOfflineLabel();
        }
    }

    private void updatePairedOfflineLabel() {
        if (configPath is null) {
            pairedOfflineLabel.hide();
            return;
        }

        auto paired = loadPairedDevices(configPath);
        if (paired.length == 0) {
            pairedOfflineLabel.hide();
            return;
        }

        import std.algorithm : canFind, filter, map;
        import std.array : array;
        import std.format : format;
        import std.string : join;

        auto connectedUdids = deviceWidgets.keys.map!(k => k.udid).array;
        auto offline = paired.filter!(p => !connectedUdids.canFind(p.udid)).array;

        if (offline.length == 0) {
            pairedOfflineLabel.hide();
        } else {
            string names = offline.map!(d => d.deviceName).array.join(", ");
            pairedOfflineLabel.setLabel(format!"WiFi-paired (offline): %s"(names));
            pairedOfflineLabel.show();
        }
    }
}
