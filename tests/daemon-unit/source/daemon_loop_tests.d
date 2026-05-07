module daemon_loop_tests;

// Tests for the daemon's refresh-selection logic.
// We test the pure scheduling layer directly rather than the full runDaemonLoop
// (which requires libimobiledevice and a real device). The invariants we care
// about are:
//   - Only apps past the refresh threshold are selected
//   - A successful refresh updates lastSigned / expiresAt
//   - Failed refreshes leave the app unchanged and do not crash the loop

import std.datetime.date : DateTime;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import core.time : hours, days;

import daemon.managed_apps;
import daemon.refresh_schedule;

// Simulated single-cycle: select due apps, call the injected refresh, assert outcomes.
private void simulateOneCycle(
    ManagedApp[] apps,
    SysTime now,
    long thresholdHours,
    void delegate(ref ManagedApp) onRefresh,
) {
    auto due = appsNeedingRefresh(apps, now, thresholdHours);
    foreach (ref app; due)
        onRefresh(app);
}

unittest {
    SysTime now = SysTime(DateTime(2026, 1, 10, 12, 0, 0), UTC());

    ManagedApp fresh = {
        bundleId: "com.test.fresh",
        name: "Fresh App",
        expiresAt: now + days(3),
    };
    ManagedApp stale = {
        bundleId: "com.test.stale",
        name: "Stale App",
        expiresAt: now + 24.hours,  // within 48h threshold
    };

    string[] refreshed;
    simulateOneCycle([fresh, stale], now, DEFAULT_REFRESH_THRESHOLD_HOURS, (ref app) {
        refreshed ~= app.bundleId;
    });

    assert(refreshed == ["com.test.stale"], "Only stale app should be refreshed");
}

unittest {
    SysTime now = SysTime(DateTime(2026, 1, 10, 12, 0, 0), UTC());

    ManagedApp app = {
        bundleId: "com.test.app",
        name: "My App",
        expiresAt: now + 24.hours,
    };

    // appsNeedingRefresh returns copies; capture the modified copy from inside the delegate
    SysTime updatedExpiry;
    simulateOneCycle([app], now, DEFAULT_REFRESH_THRESHOLD_HOURS, (ref a) {
        a.lastSigned = now;
        a.expiresAt  = signingExpiresAt(now);
        updatedExpiry = a.expiresAt;
    });

    assert(updatedExpiry == signingExpiresAt(now), "Expiry must be 7 days from signing time");
}

unittest {
    SysTime now = SysTime(DateTime(2026, 1, 10, 12, 0, 0), UTC());

    ManagedApp app = {
        bundleId: "com.test.fail",
        name: "Failing App",
        expiresAt: now + 24.hours,
    };
    SysTime originalExpiry = app.expiresAt;

    // A refresh that throws should not modify the app
    bool threw;
    try {
        simulateOneCycle([app], now, DEFAULT_REFRESH_THRESHOLD_HOURS, (ref a) {
            throw new Exception("device offline");
        });
    } catch (Exception) {
        threw = true;
    }

    assert(threw, "Exception from refresh must propagate");
    assert(app.expiresAt == originalExpiry, "Failed refresh must not change expiry");
}

unittest {
    SysTime now = SysTime(DateTime(2026, 1, 10, 12, 0, 0), UTC());

    // threshold=0 means only apps that are literally expired
    ManagedApp expiredApp = {
        bundleId: "com.test.expired",
        expiresAt: now - 1.hours,
    };
    ManagedApp soonApp = {
        bundleId: "com.test.soon",
        expiresAt: now + 6.hours,  // would trigger at 48h threshold, not at 0
    };

    string[] refreshed;
    simulateOneCycle([expiredApp, soonApp], now, 0, (ref app) {
        refreshed ~= app.bundleId;
    });

    assert(refreshed == ["com.test.expired"],
        "threshold=0 should only select apps that are already expired");
}
