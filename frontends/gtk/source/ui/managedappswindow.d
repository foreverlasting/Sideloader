module ui.managedappswindow;

import core.thread;
import core.time : hours;

import std.datetime.systime;
import std.datetime.timezone;
import std.format;

import adw.ActionRow;
import adw.Clamp;
import adw.HeaderBar;
import adw.PreferencesGroup;
import adw.StatusPage;

import gtk.Box;
import gtk.Button;
import gtk.Dialog;
import gtk.Label;
import gtk.MessageDialog;
import gtk.ScrolledWindow;
import gtk.Switch;
import gtk.Widget;
import gtk.Window;

import slf4d;

import imobiledevice;

import sideload;

import server.developersession;

import daemon.managed_apps;
import daemon.refresh_schedule;

import ui.authentication.authenticationassistant;
import ui.sideloadprogresswindow;
import ui.sideloadergtkapplication;
import ui.utils;

class ManagedAppsWindow: Dialog {
    private SideloaderGtkApplication app;
    private Box contentBox;
    private Button refreshAllButton;

    this(SideloaderGtkApplication app, Window parent) {
        this.app = app;
        this.setTitle("Managed Apps");
        this.setTransientFor(parent);
        this.setDefaultSize(520, 440);
        this.setModal(false);

        auto headerBar = new HeaderBar(); {
            headerBar.addCssClass("flat");
            refreshAllButton = new Button("Refresh All");
            refreshAllButton.setIconName("view-refresh-symbolic");
            refreshAllButton.addOnClicked((_) => refreshAll());
            headerBar.packEnd(refreshAllButton);
        }
        this.setTitlebar(headerBar);

        auto scroll = new ScrolledWindow(); {
            scroll.setVexpand(true);
            auto clamp = new Clamp(); {
                contentBox = new Box(Orientation.VERTICAL, 12); {
                    contentBox.setMarginStart(12);
                    contentBox.setMarginEnd(12);
                    contentBox.setMarginTop(12);
                    contentBox.setMarginBottom(12);
                }
                clamp.setChild(contentBox);
            }
            scroll.setChild(clamp);
        }
        this.setChild(scroll);

        loadApps();
    }

    private void loadApps() {
        for (Widget child; (child = contentBox.getFirstChild()) !is null; )
            contentBox.remove(child);

        auto apps = loadManagedApps(app.configurationPath);
        SysTime now = Clock.currTime(UTC());

        if (apps.length == 0) {
            auto emptyPage = new StatusPage();
            emptyPage.setIconName("application-x-executable-symbolic");
            emptyPage.setTitle("No Managed Apps");
            emptyPage.setDescription(
                "Install an app with <b>Install &amp; manage…</b> to track it for auto-refresh."
            );
            emptyPage.setVexpand(true);
            contentBox.append(emptyPage);
            refreshAllButton.setSensitive(false);
            return;
        }

        refreshAllButton.setSensitive(true);

        auto appsGroup = new PreferencesGroup();
        appsGroup.setTitle("Auto-Refresh Apps");
        foreach (managedApp; apps) {
            appsGroup.add(buildAppRow(managedApp, now));
        }
        contentBox.append(appsGroup);

        version (linux) {
            auto daemonGroup = new PreferencesGroup();
            daemonGroup.setTitle("Background Service");

            auto daemonRow = new ActionRow();
            daemonRow.setTitle("Auto-Refresh Daemon");
            daemonRow.setSubtitle("Automatically re-sign apps in the background via systemd");

            auto toggle = new Switch();
            toggle.setValign(Align.CENTER);
            toggle.setActive(isDaemonEnabled());
            toggle.addOnStateSet((active, _) {
                setDaemonEnabled(active);
                return false;
            });
            daemonRow.addSuffix(toggle);
            daemonRow.setActivatableWidget(toggle);

            daemonGroup.add(daemonRow);
            contentBox.append(daemonGroup);
        }
    }

    private ActionRow buildAppRow(ManagedApp managedApp, SysTime now) {
        auto row = new ActionRow();
        row.setTitle(managedApp.name);

        Duration remaining = managedApp.expiresAt - now;
        string subtitle;
        if (remaining.total!"seconds" <= 0) {
            subtitle = "EXPIRED";
        } else if (remaining <= 48.hours) {
            subtitle = format!"Expires in %dh"(remaining.total!"hours" + 1);
        } else {
            subtitle = format!"Expires in %dd %dh"(remaining.total!"days", remaining.total!"hours" % 24);
        }
        row.setSubtitle(subtitle);

        auto refreshBtn = new Button("Refresh");
        refreshBtn.addCssClass("flat");
        refreshBtn.setValign(Align.CENTER);
        refreshBtn.addOnClicked((_) => refreshApp(managedApp, refreshBtn));
        row.addSuffix(refreshBtn);

        return row;
    }

    private void refreshApp(ManagedApp managedApp, Button btn) {
        btn.setSensitive(false);
        AuthenticationAssistant.authenticate(app, (developer) {
            try {
                auto iosApp = new Application(managedApp.ipaPath);
                auto device = new iDevice(managedApp.deviceUdid, iDevice.ConnectionPreference.preferWifi);
                SideloadProgressWindow.sideload(
                    app, developer, iosApp, device,
                    true, managedApp.ipaPath,
                    () => runInUIThread({ loadApps(); }),
                );
            } catch (Exception ex) {
                string errMsg = ex.msg;
                runInUIThread({
                    btn.setSensitive(true);
                    auto errDialog = new MessageDialog(
                        cast(Window) this,
                        DialogFlags.DESTROY_WITH_PARENT | DialogFlags.MODAL | DialogFlags.USE_HEADER_BAR,
                        MessageType.ERROR, ButtonsType.CLOSE,
                        format!"Cannot refresh %s: %s"(managedApp.name, errMsg),
                    );
                    errDialog.addOnResponse((_, __) => errDialog.close());
                    errDialog.show();
                });
            }
        });
    }

    private void refreshAll() {
        refreshAllButton.setSensitive(false);
        AuthenticationAssistant.authenticate(app, (developer) {
            auto apps = loadManagedApps(app.configurationPath);
            if (apps.length == 0) {
                runInUIThread({ refreshAllButton.setSensitive(true); });
                return;
            }
            new Thread({
                foreach (managedApp; apps) {
                    try {
                        auto iosApp = new Application(managedApp.ipaPath);
                        auto device = new iDevice(managedApp.deviceUdid, iDevice.ConnectionPreference.preferWifi);
                        sideloadFull(app.configurationPath, device, developer, iosApp, (p, m) {});
                        SysTime signedAt = Clock.currTime(UTC());
                        ManagedApp updated = managedApp;
                        updated.lastSigned = signedAt;
                        updated.expiresAt = signingExpiresAt(signedAt);
                        addManagedApp(app.configurationPath, updated);
                    } catch (Exception ex) {
                        getLogger().errorF!"Failed to refresh %s: %s"(managedApp.name, ex.msg);
                    }
                }
                runInUIThread({ loadApps(); });
            }).start();
        });
    }

    version (linux) {
        private bool isDaemonEnabled() {
            import std.process : execute;
            try {
                auto result = execute(["systemctl", "--user", "is-enabled", "sideloader-daemon"]);
                return result.status == 0;
            } catch (Exception) {
                return false;
            }
        }

        private void setDaemonEnabled(bool enable) {
            import std.process : spawnProcess, wait;
            try {
                string[] cmd = enable
                    ? ["systemctl", "--user", "enable", "--now", "sideloader-daemon"]
                    : ["systemctl", "--user", "disable", "--now", "sideloader-daemon"];
                auto pid = spawnProcess(cmd);
                wait(pid);
            } catch (Exception ex) {
                getLogger().errorF!"Failed to toggle daemon: %s"(ex.msg);
            }
        }
    }
}
