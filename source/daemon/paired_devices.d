module daemon.paired_devices;

import std.datetime.date : DateTime;
import std.datetime.systime;
import std.datetime.timezone;
import std.file;
import std.json;
import std.path;

struct PairedDevice {
    string udid;
    string deviceName;
    SysTime pairedAt;
}

string pairedDevicesPath(string configDir) {
    return buildPath(configDir, "paired_devices.json");
}

PairedDevice[] loadPairedDevices(string configDir) {
    string path = pairedDevicesPath(configDir);
    if (!exists(path))
        return [];

    auto root = parseJSON(readText(path));
    if ("devices" !in root)
        return [];

    PairedDevice[] devices;
    foreach (entry; root["devices"].array) {
        PairedDevice dev;
        dev.udid = entry["udid"].str;
        dev.deviceName = entry["deviceName"].str;
        dev.pairedAt = SysTime.fromISOExtString(entry["pairedAt"].str);
        devices ~= dev;
    }
    return devices;
}

void savePairedDevices(string configDir, PairedDevice[] devices) {
    string path = pairedDevicesPath(configDir);
    mkdirRecurse(dirName(path));

    JSONValue root = ["devices": JSONValue(new JSONValue[0])];
    foreach (dev; devices) {
        JSONValue entry = [
            "udid":       JSONValue(dev.udid),
            "deviceName": JSONValue(dev.deviceName),
            "pairedAt":   JSONValue(dev.pairedAt.toISOExtString()),
        ];
        root["devices"].array ~= entry;
    }
    write(path, root.toPrettyString());
}

void savePairedDevice(string configDir, PairedDevice device) {
    auto devices = loadPairedDevices(configDir);
    foreach (ref existing; devices) {
        if (existing.udid == device.udid) {
            existing = device;
            savePairedDevices(configDir, devices);
            return;
        }
    }
    devices ~= device;
    savePairedDevices(configDir, devices);
}

bool removePairedDevice(string configDir, string udid) {
    auto devices = loadPairedDevices(configDir);
    size_t before = devices.length;
    import std.algorithm : filter;
    import std.array : array;
    devices = devices.filter!(d => d.udid != udid).array;
    if (devices.length == before)
        return false;
    savePairedDevices(configDir, devices);
    return true;
}

unittest {
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;

    string dir = buildPath(tempDir(), "sideloader_test_paired_devices");
    scope (exit) {
        if (exists(dir)) rmdirRecurse(dir);
    }

    assert(loadPairedDevices(dir) == []);

    SysTime now = SysTime(DateTime(2026, 5, 1, 10, 0, 0), UTC());
    PairedDevice dev = {
        udid: "AABB-1234",
        deviceName: "Eric's iPhone",
        pairedAt: now,
    };
    savePairedDevice(dir, dev);

    auto loaded = loadPairedDevices(dir);
    assert(loaded.length == 1);
    assert(loaded[0].udid == "AABB-1234");
    assert(loaded[0].deviceName == "Eric's iPhone");
    assert(loaded[0].pairedAt == now);

    // Update existing
    dev.deviceName = "Eric's iPhone 16";
    savePairedDevice(dir, dev);
    loaded = loadPairedDevices(dir);
    assert(loaded.length == 1);
    assert(loaded[0].deviceName == "Eric's iPhone 16");

    // Add second device
    PairedDevice dev2 = {
        udid: "CCDD-5678",
        deviceName: "iPad",
        pairedAt: now,
    };
    savePairedDevice(dir, dev2);
    assert(loadPairedDevices(dir).length == 2);

    // Remove
    assert(removePairedDevice(dir, "AABB-1234"));
    assert(loadPairedDevices(dir).length == 1);
    assert(!removePairedDevice(dir, "nonexistent"));
}
