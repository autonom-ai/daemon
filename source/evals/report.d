module evals.report;

import core.time : MonoTime;
import std.stdio : stdout;

public:

class Eval
{
private:
    MonoTime last;
    bool _passed = true;

public:
    this()
    {
        last = MonoTime.currTime;
    }

    ref const(bool) passed() const
        => _passed;

    bool check(string name, bool passed, string observed = null)
    {
        MonoTime now = MonoTime.currTime;
        _passed = _passed && passed;
        stdout.writefln(
            "%s %-48s %6.1fs%s",
            passed ? "PASS" : "FAIL",
            name,
            (now - last).total!"msecs" / 1000.0,
            observed.length ? "  "~observed : ""
        );
        stdout.flush();
        last = now;
        return passed;
    }
}
