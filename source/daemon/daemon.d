module daemon.daemon;

import std.datetime.systime;
import std.datetime.timezone;
import core.time : Duration, hours, seconds;
import core.thread : Thread;

import slf4d;

import daemon.managed_apps;
import daemon.refresh_schedule;

alias RefreshDelegate = void delegate(ref ManagedApp app);

struct DaemonConfig {
    string configDir;
    long   refreshThresholdHours = DEFAULT_REFRESH_THRESHOLD_HOURS;
    Duration pollInterval = 6.hours;
}

void runDaemonLoop(DaemonConfig cfg, RefreshDelegate doRefresh, bool delegate() shouldStop = null) {
    auto log = getLogger();
    log.info("Sideloader daemon started.");

    while (shouldStop is null || !shouldStop()) {
        log.info("Checking for apps due for re-signing...");
        SysTime now = Clock.currTime(UTC());

        try {
            auto apps = loadManagedApps(cfg.configDir);

            // Warn about entries whose cached IPA has gone missing
            import std.file : exists;
            foreach (app; apps) {
                if (!exists(app.ipaPath))
                    log.warnF!"Cached IPA missing for %s (%s) — skipping refresh."(app.name, app.ipaPath);
            }

            import std.algorithm : filter;
            import std.array : array;
            auto validApps = apps.filter!(a => exists(a.ipaPath)).array;
            auto due = appsNeedingRefresh(validApps, now, cfg.refreshThresholdHours);

            if (due.length == 0) {
                log.info("All apps are up to date.");
            } else {
                log.infoF!"Refreshing %d app(s)..."(due.length);
                foreach (ref app; due) {
                    log.infoF!"  Refreshing: %s"(app.name);
                    try {
                        doRefresh(app);
                        // doRefresh is responsible for updating app.lastSigned / app.expiresAt
                        // Find and update this entry in the full apps list
                        foreach (ref stored; apps) {
                            if (stored.bundleId == app.bundleId) {
                                stored = app;
                                break;
                            }
                        }
                        log.infoF!"  OK — %s expires %s"(app.name, app.expiresAt.toSimpleString());
                    } catch (Exception e) {
                        log.errorF!"  Failed to refresh %s: %s"(app.name, e.msg);
                        notifyDesktop("Sideloader: failed to refresh " ~ app.name ~ " — " ~ e.msg);
                    }
                }
                saveManagedApps(cfg.configDir, apps);
            }

            Duration wait = timeUntilNextRefreshCheck(apps, Clock.currTime(UTC()));
            // Clamp: always wait at least 1 minute, at most pollInterval
            if (wait < 1.minutes) wait = 1.minutes;
            if (wait > cfg.pollInterval) wait = cfg.pollInterval;
            log.infoF!"Next check in %d minutes."(wait.total!"minutes");
            Thread.sleep(wait);
        } catch (Exception e) {
            log.errorF!"Daemon error: %s — retrying in 5 minutes."(e.msg);
            Thread.sleep(5.minutes);
        }
    }

    log.info("Sideloader daemon stopped.");
}

private void notifyDesktop(string message) {
    import std.process : spawnProcess, wait;
    try {
        auto pid = spawnProcess(["notify-send", "-a", "Sideloader", message]);
        wait(pid);
    } catch (Exception) {
        // notify-send is optional; swallow if not installed
    }
}

private alias minutes = (long n) => core.time.dur!"minutes"(n);
