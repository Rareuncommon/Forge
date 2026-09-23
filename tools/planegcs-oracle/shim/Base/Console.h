// Shim for FreeCAD's Base::Console / Base::TimeElapsed as used by planegcs (logging and
// timing only; the oracle discards the log).
#pragma once
#include <chrono>
namespace Base {
struct ConsoleShim {
    template <typename... A> void log(const char*, A...) {}
    template <typename... A> void warning(const char*, A...) {}
    template <typename... A> void error(const char*, A...) {}
};
inline ConsoleShim& Console() { static ConsoleShim c; return c; }
struct TimeElapsed {
    std::chrono::steady_clock::time_point t = std::chrono::steady_clock::now();
    static double diffTimeF(const TimeElapsed& a, const TimeElapsed& b) {
        return std::chrono::duration<double>(b.t - a.t).count();
    }
};
}  // namespace Base
