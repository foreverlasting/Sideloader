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

import ui.utils;

class WifiSetupWindow: Dialog {
    private Button pairButton;
    private Label stepsLabel;

    this(iDevice device, Window parent) {
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
                auto result = lockdown.pair();
                with (lockdownd_error_t) switch (result) {
                    case LOCKDOWN_E_SUCCESS:
                    case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
                        runInUIThread({
                            pairButton.setLabel("Paired");
                            stepsLabel.setMarkup(
                                "<b>Device paired! Enable WiFi sync on your iPhone:</b>\n\n" ~
                                "1. Open <b>Settings</b>\n" ~
                                "2. Go to <b>General → VPN &amp; Device Management</b>\n" ~
                                "3. Tap your computer under <b>Development</b>\n" ~
                                "4. Enable <b>Connect via Wi-Fi</b>\n\n" ~
                                "Once done, you can unplug the USB cable.\n" ~
                                "<i>Both devices must be on the same WiFi network.</i>"
                            );
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
}
