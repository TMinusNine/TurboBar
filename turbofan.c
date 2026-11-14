// turbofan: holds a manual fan speed for TurboBar, then hands the fans back to macOS.
//
// TurboBar starts this as root only while a manual speed is selected, so nothing privileged
// runs in Auto. The fans return to Auto when TurboBar closes the pipe, quits or crashes,
// when this process is told to stop, or when the Mac gets too hot at a reduced speed.

#include "smc.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static const int kCheckIntervalMs = 3000;
static const int kConnectTimeoutSeconds = 10;
static const double kHotLimitCelsius = 90.0;

static volatile sig_atomic_t gStop;

static void RequestStop(int signal) {
    (void)signal;
    gStop = 1;
}

// A sensor that can't be read counts as hot, so a failure ends manual control.
static double Temperature(const char *name) {
    double celsius;
    return SMCReadCelsius(FourCC(name), &celsius) ? celsius : kHotLimitCelsius;
}

// At 100% the fans can't do any better, so there is nothing to protect against.
static bool TooHot(int percent) {
    if (percent == 100) return false;
    return Temperature("TCMX") >= kHotLimitCelsius || Temperature("TGDD") >= kHotLimitCelsius;
}

static void SetManual(int percent) {
    uint8_t manual = 1;
    for (int i = 0; i < gFanCount; i++) {
        const Fan *fan = &gFans[i];
        float rpm = fan->min + (fan->max - fan->min) * (float)percent / 100.0f;
        SMCWrite(FanKey(fan->index, "Md"), &manual, sizeof manual);
        SMCWrite(FanKey(fan->index, "Tg"), &rpm, sizeof rpm);
    }
}

static void SetAuto(void) {
    uint8_t automatic = 0;
    for (int i = 0; i < gFanCount; i++) {
        SMCWrite(FanKey(gFans[i].index, "Md"), &automatic, sizeof automatic);
    }
}

int main(int argc, char **argv) {
    if (argc != 2 || geteuid() != 0) return 1;

    OpenFans();
    if (gFanCount == 0) return 1;

    // Whatever launched us may have left signals blocked, and a stop request must still work.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);

    struct sigaction stop = {.sa_handler = RequestStop};
    sigaction(SIGTERM, &stop, NULL);
    sigaction(SIGINT, &stop, NULL);
    sigaction(SIGHUP, &stop, NULL);

    // Blocks until TurboBar connects. The alarm ends this process if it never does.
    alarm(kConnectTimeoutSeconds);
    int commands = open(argv[1], O_RDONLY);
    alarm(0);
    if (commands < 0) return 1;
    fcntl(commands, F_SETFL, O_NONBLOCK);

    int percent = kFanAuto;
    while (!gStop) {
        // poll() wakes us for new commands, but on macOS it never reports the pipe closing.
        // A read does, so every pass tries one.
        struct pollfd pending = {.fd = commands, .events = POLLIN};
        poll(&pending, 1, kCheckIntervalMs);
        if (gStop) break;

        char line[16];
        ssize_t length = read(commands, line, sizeof line - 1);
        if (length == 0) break;  // TurboBar quit or crashed.
        if (length < 0 && errno != EAGAIN && errno != EINTR) break;

        if (length > 0) {
            line[length] = '\0';
            int requested = atoi(line);
            if (requested < kFanMinPercent || requested > 100) break;  // Includes the Auto command.
            percent = requested;
            SetManual(percent);
        }

        if (percent != kFanAuto) {
            if (TooHot(percent)) break;
            if (!FansAreManual()) SetManual(percent);  // Sleep can reset the fans to Auto.
        }
    }

    SetAuto();
    return 0;
}
