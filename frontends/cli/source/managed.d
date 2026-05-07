module managed;

import std.algorithm;
import std.array;
import std.datetime.systime;
import std.datetime.timezone;
import core.time : hours, days;
import std.file;
import std.format;
import std.path;
import std.stdio;
import std.sumtype;

import argparse;
import progress;
import slf4d;
import slf4d.default_provider;

import imobiledevice;
import sideload;
import sideload.application;

import daemon.managed_apps;
import daemon.refresh_schedule;

import cli_frontend;

@(Command("managed").Description("Manage apps for automatic WiFi re-signing."))
struct ManagedCommand
{
    int opCall()
    {
        return cmd.match!(
            (ManagedAdd cmd)     => cmd(),
            (ManagedRemove cmd)  => cmd(),
            (ManagedList cmd)    => cmd(),
            (ManagedRefresh cmd) => cmd(),
        );
    }

    @SubCommands
    SumType!(ManagedAdd, ManagedRemove, ManagedList, ManagedRefresh) cmd;
}

@(Command("add").Description("Sideload an IPA and add it to the auto-refresh list."))
struct ManagedAdd
{
    mixin LoginCommand;

    @(PositionalArgument(0, "ipa path").Description("Path to the IPA file."))
    string appPath;

    @(NamedArgument("udid").Description("UDID of the target device."))
    string udid = null;

    @(NamedArgument("singlethread").Description("Run signing on a single thread."))
    bool singlethreaded;

    int opCall()
    {
        auto log = getLogger();
        string configPath = systemConfigurationPath();
        string dataPath   = systemDataPath();

        Application app = openApp(appPath);

        scope provisioningData = initializeADI(configPath);
        scope adi = provisioningData.adi;
        scope akDevice = provisioningData.device;

        auto appleAccount = login(akDevice, adi);
        if (!appleAccount)
            return 1;

        string targetUdid = udid;
        if (!targetUdid) {
            auto devices = iDevice.deviceList();
            if (devices.length == 0) {
                log.error("No device connected.");
                return 1;
            }
            if (devices.length > 1) {
                log.error("Multiple devices connected. Specify one with --udid.");
                return 1;
            }
            targetUdid = devices[0].udid;
        }

        log.infoF!"Installing %s on device %s..."(app.bundleName(), targetUdid);
        auto device = new iDevice(targetUdid, iDevice.ConnectionPreference.auto_);

        SysTime signedAt;
        Bar progressBar = new Bar();
        string message;
        progressBar.message = () => message;
        sideloadFull(configPath, device, appleAccount, app, (prog, action) {
            message = action;
            progressBar.index = cast(int)(prog * 100);
            progressBar.update();
        }, !singlethreaded);
        progressBar.finish();

        signedAt = Clock.currTime(UTC());

        // Archive IPA alongside a stable copy for daemon use
        string storedIpa = ipaStoragePath(dataPath, app.bundleIdentifier());
        mkdirRecurse(dirName(storedIpa));
        if (std.file.exists(storedIpa))
            std.file.remove(storedIpa);
        std.file.copy(appPath, storedIpa);

        ManagedApp entry = {
            bundleId:         app.bundleIdentifier(),
            originalBundleId: app.bundleIdentifier(),
            name:             app.bundleName(),
            ipaPath:          storedIpa,
            deviceUdid:       targetUdid,
            lastSigned:       signedAt,
            expiresAt:        signingExpiresAt(signedAt),
        };
        addManagedApp(configPath, entry);

        writefln!"\n%s added to auto-refresh list. Expires: %s"(entry.name, entry.expiresAt.toSimpleString());
        return 0;
    }
}

@(Command("remove").Description("Remove an app from the auto-refresh list."))
struct ManagedRemove
{
    @(PositionalArgument(0, "bundle-id").Description("Bundle ID of the app to remove."))
    string bundleId;

    @(NamedArgument("keep-ipa").Description("Do not delete the cached IPA from storage."))
    bool keepIpa;

    int opCall()
    {
        auto log = getLogger();
        string configPath = systemConfigurationPath();
        string dataPath   = systemDataPath();

        // Find the entry before removing so we can delete its cached IPA
        auto apps = loadManagedApps(configPath);
        auto match = apps.filter!(a => a.bundleId == bundleId).array;

        if (!removeManagedApp(configPath, bundleId)) {
            log.errorF!"No managed app found with bundle ID: %s"(bundleId);
            return 1;
        }

        if (!keepIpa && match.length > 0) {
            string ipa = match[0].ipaPath;
            if (std.file.exists(ipa)) {
                std.file.remove(ipa);
                log.infoF!"Removed cached IPA: %s"(ipa);
            }
        }

        writefln!"Removed %s from auto-refresh list."(bundleId);
        return 0;
    }
}

@(Command("list").Description("Show managed apps and their signing expiry status."))
struct ManagedList
{
    int opCall()
    {
        string configPath = systemConfigurationPath();
        auto apps = loadManagedApps(configPath);

        if (apps.length == 0) {
            writeln("No managed apps. Use `sideloader managed add <ipa>` to add one.");
            return 0;
        }

        SysTime now = Clock.currTime(UTC());
        writefln!"%-30s  %-15s  %s"("Name", "Status", "Expires");
        writeln  ("-".replicate(70));
        foreach (app; apps) {
            auto remaining = app.expiresAt - now;
            string status;
            if (remaining.total!"seconds" <= 0)
                status = "EXPIRED";
            else if (remaining <= 48.hours)
                status = format!"< %dh"(remaining.total!"hours" + 1);
            else
                status = format!"%dd %dh"(remaining.total!"days", remaining.total!"hours" % 24);
            writefln!"%-30s  %-15s  %s"(app.name, status, app.expiresAt.toSimpleString());
        }
        return 0;
    }
}

@(Command("refresh").Description("Manually re-sign and reinstall managed app(s)."))
struct ManagedRefresh
{
    mixin LoginCommand;

    @(PositionalArgument(0, "bundle-id").Description("Bundle ID to refresh (omit to refresh all due apps)."))
    string bundleId = null;

    @(NamedArgument("all").Description("Refresh all managed apps regardless of expiry."))
    bool all;

    @(NamedArgument("singlethread").Description("Run signing on a single thread."))
    bool singlethreaded;

    int opCall()
    {
        auto log = getLogger();
        string configPath = systemConfigurationPath();

        scope provisioningData = initializeADI(configPath);
        scope adi = provisioningData.adi;
        scope akDevice = provisioningData.device;

        auto appleAccount = login(akDevice, adi);
        if (!appleAccount)
            return 1;

        auto apps = loadManagedApps(configPath);
        SysTime now = Clock.currTime(UTC());

        ManagedApp[] targets;
        if (bundleId) {
            targets = apps.filter!(a => a.bundleId == bundleId).array;
            if (targets.length == 0) {
                log.errorF!"No managed app with bundle ID: %s"(bundleId);
                return 1;
            }
        } else if (all) {
            targets = apps;
        } else {
            targets = appsNeedingRefresh(apps, now);
            if (targets.length == 0) {
                writeln("All apps are up to date. Use --all to force a refresh.");
                return 0;
            }
        }

        int failures;
        foreach (ref app; targets) {
            writefln!"\nRefreshing %s..."(app.name);
            try {
                auto appObj = openApp(app.ipaPath);
                auto device = new iDevice(app.deviceUdid, iDevice.ConnectionPreference.preferWifi);
                Bar progressBar = new Bar();
                string msg;
                progressBar.message = () => msg;
                sideloadFull(configPath, device, appleAccount, appObj, (prog, action) {
                    msg = action;
                    progressBar.index = cast(int)(prog * 100);
                    progressBar.update();
                }, !singlethreaded);
                progressBar.finish();

                SysTime signedAt = Clock.currTime(UTC());
                app.lastSigned = signedAt;
                app.expiresAt  = signingExpiresAt(signedAt);
                addManagedApp(configPath, app);
                writefln!"  OK — expires %s"(app.expiresAt.toSimpleString());
            } catch (Exception e) {
                log.errorF!"  Failed to refresh %s: %s"(app.name, e.msg);
                ++failures;
            }
        }

        return failures > 0 ? 1 : 0;
    }
}
