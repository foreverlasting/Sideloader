module utils;

private string _appleCABundlePath = null;

string appleCABundle() {
    import std.file : write, tempDir, exists;
    import std.path : buildPath;
    import constants : appleRootCA, appleAuthCA;

    if (_appleCABundlePath !is null && _appleCABundlePath.exists)
        return _appleCABundlePath;

    auto path = tempDir.buildPath("sideloader-apple-ca.pem");
    write(path, appleRootCA ~ "\n" ~ cast(string) appleAuthCA);
    _appleCABundlePath = path;
    return path;
}

T orDefault(T)(T obj, lazy T default_) {
    return obj == null ? default_ : obj;
}

import std.datetime: dur, SysTime;
auto stripMilliseconds(return SysTime time) {
    time.fracSecs = dur!"msecs"(0);
    return time;
}

string locale() {
    import core.stdc.locale;
    import std.string;
    string locale = cast(string) setlocale(LC_CTYPE, null).fromStringz().split('@')[0].split('.')[0];
    if (locale == "C" || locale == "POSIX") {
        locale = "en_US";
    }
    return locale;
}

private struct Delegate(alias U)
{
    import std.traits;
    import std.typecons;

    static if (is(typeof(&U) == delegate))
    {
        enum del = &U;
    }
    else
    {
        alias del = U;
    }

    typeof(del) delegate_ = del;

    extern(C) static auto assemble(Parameters!U params, void* context)
    {
        return (cast(Delegate*) context).delegate_(params);
    }

    pragma(inline, true)
    Tuple!(typeof(&assemble), void*) internalExpand()
    {
        return tuple(&assemble, cast(void*) &this);
    }
    alias expand = internalExpand.expand;
    alias expand this;
    // alias opCall = internalExpand.expand;
}

pragma(inline, true)
auto c(alias U)()
{
    return new Delegate!U().internalExpand;
}

pragma(inline, true)
string toForwardSlashes(string s) {
    version (Windows) {
        char[] str = s.dup;
        foreach (ref c; str) {
            if (c == '\\') {
                c = '/';
            }
        }
        return cast(string) str;
    } else {
        return s;
    }
}

auto maybeParallel(R)(R range, bool isMultithreaded) {
    import std.parallelism;
    import std.range.primitives;
    struct RangeApplier {
        R range;
        this(R range) {
            this.range = range;
        }

        int opApply(int delegate(size_t index, ElementType!R) dg) {
            if (isMultithreaded) {
                foreach (index, elem; range.parallel) {
                    int i = dg(index, elem);
                    if (i != 0) {
                        return i;
                    }
                }
            } else {
                size_t index = 0;
                foreach (ElementType!R elem; range) {
                    int i = dg(index, elem);
                    if (i != 0) {
                        return i;
                    }
                    index += 1;
                }
            }
            return 0;
        } 

        int opApply(int delegate(ElementType!R) dg) {
            if (isMultithreaded) {
                foreach (elem; range.parallel) {
                    int i = dg(elem);
                    if (i != 0) {
                        return i;
                    }
                }
            } else {
                foreach (elem; range) {
                    int i = dg(elem);
                    if (i != 0) {
                        return i;
                    }
                }
            }
            return 0;
        }
    }

    return RangeApplier(range);
}
