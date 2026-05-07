module daemon.managed_apps;

import std.conv : to;
import std.datetime.date : DateTime;
import std.datetime.systime;
import std.datetime.timezone;
import std.file;
import std.json;
import std.path;
import std.string;

struct ManagedApp {
    string bundleId;
    string originalBundleId;
    string name;
    string ipaPath;
    string deviceUdid;
    SysTime lastSigned;
    SysTime expiresAt;
}

string managedAppsPath(string configDir) {
    return buildPath(configDir, "managed_apps.json");
}

ManagedApp[] loadManagedApps(string configDir) {
    string path = managedAppsPath(configDir);
    if (!exists(path))
        return [];

    auto root = parseJSON(readText(path));
    if ("apps" !in root)
        return [];

    ManagedApp[] apps;
    foreach (entry; root["apps"].array) {
        ManagedApp app;
        app.bundleId = entry["bundleId"].str;
        app.originalBundleId = entry["originalBundleId"].str;
        app.name = entry["name"].str;
        app.ipaPath = entry["ipaPath"].str;
        app.deviceUdid = entry["deviceUdid"].str;
        app.lastSigned = SysTime.fromISOExtString(entry["lastSigned"].str);
        app.expiresAt = SysTime.fromISOExtString(entry["expiresAt"].str);
        apps ~= app;
    }
    return apps;
}

void saveManagedApps(string configDir, ManagedApp[] apps) {
    string path = managedAppsPath(configDir);
    mkdirRecurse(dirName(path));

    JSONValue root = ["apps": JSONValue(new JSONValue[0])];
    foreach (app; apps) {
        JSONValue entry = [
            "bundleId":         JSONValue(app.bundleId),
            "originalBundleId": JSONValue(app.originalBundleId),
            "name":             JSONValue(app.name),
            "ipaPath":          JSONValue(app.ipaPath),
            "deviceUdid":       JSONValue(app.deviceUdid),
            "lastSigned":       JSONValue(app.lastSigned.toISOExtString()),
            "expiresAt":        JSONValue(app.expiresAt.toISOExtString()),
        ];
        root["apps"].array ~= entry;
    }
    write(path, root.toPrettyString());
}

void addManagedApp(string configDir, ManagedApp app) {
    auto apps = loadManagedApps(configDir);
    foreach (ref existing; apps) {
        if (existing.bundleId == app.bundleId) {
            existing = app;
            saveManagedApps(configDir, apps);
            return;
        }
    }
    apps ~= app;
    saveManagedApps(configDir, apps);
}

bool removeManagedApp(string configDir, string bundleId) {
    auto apps = loadManagedApps(configDir);
    size_t before = apps.length;
    import std.algorithm : filter;
    import std.array : array;
    apps = apps.filter!(a => a.bundleId != bundleId).array;
    if (apps.length == before)
        return false;
    saveManagedApps(configDir, apps);
    return true;
}

string ipaStoragePath(string dataDir, string bundleId) {
    // Sanitize bundle ID for use as a filename
    string safe = bundleId.replace("/", "_").replace("..", "_");
    return buildPath(dataDir, "apps", safe ~ ".ipa");
}

unittest {
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    import core.time : hours;

    string dir = buildPath(tempDir(), "sideloader_test_managed_apps");
    scope (exit) {
        if (exists(dir)) rmdirRecurse(dir);
    }

    SysTime now = SysTime(DateTime(2026, 1, 1, 12, 0, 0), UTC());

    // Empty config directory returns empty list
    assert(loadManagedApps(dir) == []);

    // Add and load roundtrip
    ManagedApp app = {
        bundleId: "com.example.app.TEAM1",
        originalBundleId: "com.example.app",
        name: "My App",
        ipaPath: "/tmp/myapp.ipa",
        deviceUdid: "AABBCCDD-1234-5678-ABCD-EEFF00112233",
        lastSigned: now,
        expiresAt: now + 7.hours * 24,
    };
    addManagedApp(dir, app);

    auto loaded = loadManagedApps(dir);
    assert(loaded.length == 1);
    assert(loaded[0].bundleId == app.bundleId);
    assert(loaded[0].name == app.name);
    assert(loaded[0].lastSigned == app.lastSigned);
    assert(loaded[0].expiresAt == app.expiresAt);

    // Update existing app (same bundleId replaces)
    ManagedApp updated = app;
    updated.name = "Renamed App";
    addManagedApp(dir, updated);
    loaded = loadManagedApps(dir);
    assert(loaded.length == 1);
    assert(loaded[0].name == "Renamed App");

    // Remove
    assert(removeManagedApp(dir, app.bundleId));
    assert(loadManagedApps(dir).length == 0);

    // Remove non-existent returns false
    assert(!removeManagedApp(dir, "com.nonexistent"));
}

unittest {
    // IPA storage paths are sanitized
    assert(ipaStoragePath("/data", "com.example.app") == "/data/apps/com.example.app.ipa");
    // /  → _  then  .. → _  (surrounding underscores from / replacements are preserved)
    assert(ipaStoragePath("/data", "bad/../traversal") == "/data/apps/bad___traversal.ipa");
    assert(ipaStoragePath("/data", "has/slash") == "/data/apps/has_slash.ipa");
}
