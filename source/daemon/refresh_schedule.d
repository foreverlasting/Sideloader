module daemon.refresh_schedule;

import std.datetime.date : DateTime;
import std.datetime.systime;
import std.datetime.timezone;
import core.time : Duration, hours, days;

import daemon.managed_apps;

enum long DEFAULT_REFRESH_THRESHOLD_HOURS = 48;
enum long CERTIFICATE_LIFETIME_DAYS = 7;

SysTime signingExpiresAt(SysTime signedAt) {
    return signedAt + days(CERTIFICATE_LIFETIME_DAYS);
}

bool needsRefresh(ManagedApp app, SysTime now, long thresholdHours = DEFAULT_REFRESH_THRESHOLD_HOURS) {
    return (app.expiresAt - now) <= thresholdHours.hours;
}

ManagedApp[] appsNeedingRefresh(
    ManagedApp[] apps,
    SysTime now,
    long thresholdHours = DEFAULT_REFRESH_THRESHOLD_HOURS,
) {
    import std.algorithm : filter;
    import std.array : array;
    return apps.filter!(a => needsRefresh(a, now, thresholdHours)).array;
}

Duration timeUntilNextRefreshCheck(ManagedApp[] apps, SysTime now) {
    import std.algorithm : minElement, map;
    import std.array : array;

    if (apps.length == 0)
        return 6.hours;

    auto gaps = apps.map!(a => a.expiresAt - now - DEFAULT_REFRESH_THRESHOLD_HOURS.hours);
    auto next = gaps.minElement;

    if (next <= Duration.zero)
        return Duration.zero;
    if (next < 1.hours)
        return 1.hours;
    return next;
}

unittest {
    import core.time : hours, minutes;

    SysTime base = SysTime(DateTime(2026, 1, 1, 12, 0, 0), UTC());

    // signingExpiresAt is exactly 7 days after signing
    auto exp = signingExpiresAt(base);
    assert(exp == base + days(7));

    // needsRefresh: app expiring in 72h is NOT within 48h threshold
    ManagedApp fresh = {
        bundleId: "com.test.fresh",
        expiresAt: base + 72.hours,
    };
    assert(!needsRefresh(fresh, base, DEFAULT_REFRESH_THRESHOLD_HOURS));

    // app expiring in 24h IS within 48h threshold
    ManagedApp stale = {
        bundleId: "com.test.stale",
        expiresAt: base + 24.hours,
    };
    assert(needsRefresh(stale, base, DEFAULT_REFRESH_THRESHOLD_HOURS));

    // app already expired is stale
    ManagedApp expired = {
        bundleId: "com.test.expired",
        expiresAt: base - 1.hours,
    };
    assert(needsRefresh(expired, base, DEFAULT_REFRESH_THRESHOLD_HOURS));

    // threshold=0 means only refresh if literally expired
    assert(!needsRefresh(fresh, base, 0));
    assert(needsRefresh(expired, base, 0));
}

unittest {
    SysTime now = SysTime(DateTime(2026, 1, 1, 12, 0, 0), UTC());

    // No apps → sleep 6 hours
    assert(timeUntilNextRefreshCheck([], now) == 6.hours);

    // App expiring in 50h: threshold=48h, next check in 2h
    ManagedApp app = {
        bundleId: "com.test.app",
        expiresAt: now + 50.hours,
    };
    auto wait = timeUntilNextRefreshCheck([app], now);
    assert(wait == 2.hours);

    // App already past threshold: no wait
    ManagedApp urgent = {
        bundleId: "com.test.urgent",
        expiresAt: now + 10.hours,
    };
    assert(timeUntilNextRefreshCheck([urgent], now) == Duration.zero);

    // Returns minimum across multiple apps
    assert(timeUntilNextRefreshCheck([app, urgent], now) == Duration.zero);
}

unittest {
    import core.time : minutes;

    SysTime now = SysTime(DateTime(2026, 1, 1, 12, 0, 0), UTC());

    // appsNeedingRefresh returns only stale apps
    ManagedApp a = { bundleId: "a", expiresAt: now + 72.hours };  // fresh
    ManagedApp b = { bundleId: "b", expiresAt: now + 24.hours };  // stale
    ManagedApp c = { bundleId: "c", expiresAt: now - 1.hours };   // expired

    auto results = appsNeedingRefresh([a, b, c], now, DEFAULT_REFRESH_THRESHOLD_HOURS);
    assert(results.length == 2);
    assert(results[0].bundleId == "b");
    assert(results[1].bundleId == "c");
}
