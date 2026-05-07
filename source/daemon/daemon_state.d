module daemon.daemon_state;

import std.conv : to;
import std.datetime.date : DateTime;
import std.datetime.systime;
import std.datetime.timezone;
import std.file;
import std.json;
import std.path;

struct DaemonState {
    SysTime lastCheckAt;
    SysTime lastRefreshAt;
    string lastResult;
    SysTime nextCheckAt;
}

string daemonStatePath(string configDir) {
    return buildPath(configDir, "daemon_state.json");
}

DaemonState loadDaemonState(string configDir) {
    string path = daemonStatePath(configDir);
    if (!exists(path))
        return DaemonState.init;

    auto root = parseJSON(readText(path));
    DaemonState state;

    if ("lastCheckAt" in root && root["lastCheckAt"].str.length > 0)
        state.lastCheckAt = SysTime.fromISOExtString(root["lastCheckAt"].str);
    if ("lastRefreshAt" in root && root["lastRefreshAt"].str.length > 0)
        state.lastRefreshAt = SysTime.fromISOExtString(root["lastRefreshAt"].str);
    if ("lastResult" in root)
        state.lastResult = root["lastResult"].str;
    if ("nextCheckAt" in root && root["nextCheckAt"].str.length > 0)
        state.nextCheckAt = SysTime.fromISOExtString(root["nextCheckAt"].str);

    return state;
}

void saveDaemonState(string configDir, DaemonState state) {
    string path = daemonStatePath(configDir);
    mkdirRecurse(dirName(path));

    JSONValue root = [
        "lastCheckAt":   JSONValue(state.lastCheckAt == SysTime.init ? "" : state.lastCheckAt.toISOExtString()),
        "lastRefreshAt": JSONValue(state.lastRefreshAt == SysTime.init ? "" : state.lastRefreshAt.toISOExtString()),
        "lastResult":    JSONValue(state.lastResult),
        "nextCheckAt":   JSONValue(state.nextCheckAt == SysTime.init ? "" : state.nextCheckAt.toISOExtString()),
    ];
    write(path, root.toPrettyString());
}

unittest {
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;

    string dir = buildPath(tempDir(), "sideloader_test_daemon_state");
    scope (exit) {
        if (exists(dir)) rmdirRecurse(dir);
    }

    // Empty dir returns init state
    auto empty = loadDaemonState(dir);
    assert(empty.lastResult == "");
    assert(empty.lastCheckAt == SysTime.init);

    // Save and load roundtrip
    SysTime now = SysTime(DateTime(2026, 5, 1, 10, 30, 0), UTC());
    DaemonState state = {
        lastCheckAt:   now,
        lastRefreshAt: now,
        lastResult:    "ok",
        nextCheckAt:   SysTime(DateTime(2026, 5, 1, 16, 30, 0), UTC()),
    };
    saveDaemonState(dir, state);

    auto loaded = loadDaemonState(dir);
    assert(loaded.lastCheckAt == state.lastCheckAt);
    assert(loaded.lastRefreshAt == state.lastRefreshAt);
    assert(loaded.lastResult == "ok");
    assert(loaded.nextCheckAt == state.nextCheckAt);

    // Overwrite with error state
    state.lastResult = "Failed to refresh com.example.app: network timeout";
    saveDaemonState(dir, state);
    loaded = loadDaemonState(dir);
    assert(loaded.lastResult == "Failed to refresh com.example.app: network timeout");
}
