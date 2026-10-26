const std = @import("std");
const phantom = @import("phantom");

/// A minimal service module used by `-Dbackground-service=true`. Real apps can
/// wait on a daemon connection here and call `service.showNotification` when
/// an application event arrives.
pub fn run(service: *phantom.android.BackgroundService) !void {
    while (!service.shouldStop()) {
        try service.io().sleep(.fromMilliseconds(100), .awake);
    }
}
