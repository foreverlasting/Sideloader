module daemon_cmd;

import std.process;
import std.stdio;
import std.string;
import std.file;
import std.path;

import argparse;
import slf4d;
import slf4d.default_provider;

import imobiledevice;
import sideload;
import sideload.application;

import daemon.daemon;
import daemon.managed_apps;
import daemon.refresh_schedule;

import cli_frontend;

@(Command("daemon").Description("Manage the Sideloader auto-refresh background service."))
struct DaemonCommand
{
    int opCall()
    {
        import std.sumtype : SumType;
        return cmd.match!(
            (DaemonRun cmd)       => cmd(),
            (DaemonInstall cmd)   => cmd(),
            (DaemonUninstall cmd) => cmd(),
            (DaemonStatus cmd)    => cmd(),
        );
    }

    import std.sumtype : SumType;
    @SubCommands
    SumType!(DaemonRun, DaemonInstall, DaemonUninstall, DaemonStatus) cmd;
}

@(Command("run").Description("Start the daemon (runs in foreground; used by systemd)."))
struct DaemonRun
{
    mixin LoginCommand;

    @(NamedArgument("threshold-hours").Description("Hours before expiry to trigger re-signing (default: 48)."))
    long thresholdHours = DEFAULT_REFRESH_THRESHOLD_HOURS;

    int opCall()
    {
        string configPath = systemConfigurationPath();

        scope provisioningData = initializeADI(configPath);
        scope adi = provisioningData.adi;
        scope akDevice = provisioningData.device;

        auto appleAccount = login(akDevice, adi);
        if (!appleAccount)
            return 1;

        import std.conv : to;

        // Allow env overrides for test acceleration:
        //   SIDELOADER_REFRESH_THRESHOLD_HOURS=0  → refresh any managed app immediately
        //   SIDELOADER_DAEMON_POLL_SECONDS=10      → check every 10s instead of 6h
        long effectiveThreshold = thresholdHours;
        string thresholdOverride = environment.get("SIDELOADER_REFRESH_THRESHOLD_HOURS");
        if (thresholdOverride)
            effectiveThreshold = thresholdOverride.to!long;

        DaemonConfig cfg = {
            configDir:             configPath,
            refreshThresholdHours: effectiveThreshold,
        };

        string pollOverride = environment.get("SIDELOADER_DAEMON_POLL_SECONDS");
        if (pollOverride) {
            import core.time : seconds;
            cfg.pollInterval = pollOverride.to!long.seconds;
        }

        runDaemonLoop(cfg, (ref app) {
            auto appObj = openApp(app.ipaPath);
            auto device = new iDevice(app.deviceUdid, iDevice.ConnectionPreference.preferWifi);
            sideloadFull(configPath, device, appleAccount, appObj, (prog, action) {}, true);

            import std.datetime.systime : Clock;
            import std.datetime.timezone : UTC;
            app.lastSigned = Clock.currTime(UTC());
            app.expiresAt  = signingExpiresAt(app.lastSigned);
        });

        return 0;
    }
}

@(Command("install").Description("Install and enable the systemd user service."))
struct DaemonInstall
{
    int opCall()
    {
        version (linux) {
            string binaryPath = thisExePath();
            string serviceContent = serviceTemplate(binaryPath);

            string serviceDir  = expandTilde("~/.config/systemd/user");
            string servicePath = buildPath(serviceDir, "sideloader-daemon.service");
            mkdirRecurse(serviceDir);
            write(servicePath, serviceContent);

            writefln!"Wrote service file to: %s"(servicePath);

            auto reload  = spawnProcess(["systemctl", "--user", "daemon-reload"]);
            auto enable  = spawnProcess(["systemctl", "--user", "enable", "--now", "sideloader-daemon"]);
            wait(reload);
            wait(enable);

            writeln("Sideloader daemon enabled and started.");
            writeln("Check status with: sideloader daemon status");
            return 0;
        } else {
            writeln("systemd service management is only supported on Linux.");
            return 1;
        }
    }
}

@(Command("uninstall").Description("Stop and remove the systemd user service."))
struct DaemonUninstall
{
    int opCall()
    {
        version (linux) {
            auto disable = spawnProcess(["systemctl", "--user", "disable", "--now", "sideloader-daemon"]);
            wait(disable);

            string servicePath = expandTilde("~/.config/systemd/user/sideloader-daemon.service");
            if (exists(servicePath)) {
                remove(servicePath);
                writefln!"Removed %s"(servicePath);
            }

            auto reload = spawnProcess(["systemctl", "--user", "daemon-reload"]);
            wait(reload);

            writeln("Sideloader daemon uninstalled.");
            return 0;
        } else {
            writeln("systemd service management is only supported on Linux.");
            return 1;
        }
    }
}

@(Command("status").Description("Show whether the background service is running."))
struct DaemonStatus
{
    int opCall()
    {
        version (linux) {
            auto pid = spawnProcess(["systemctl", "--user", "status", "sideloader-daemon"]);
            return wait(pid);
        } else {
            writeln("systemd service management is only supported on Linux.");
            return 1;
        }
    }
}

private string serviceTemplate(string binaryPath) {
    return `[Unit]
Description=Sideloader Auto-Refresh Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=` ~ binaryPath ~ ` daemon run -i
Restart=on-failure
RestartSec=60
Environment=HOME=%h

[Install]
WantedBy=default.target
`;
}
