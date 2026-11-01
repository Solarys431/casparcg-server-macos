#pragma once

namespace caspar {

// Opt out of App Nap and timer coalescing, and keep the system from idle sleep, for the life of the
// process. macOS naps a process whose windows are hidden or occluded, which for a playout server
// with no visible output (NDI, DeckLink, ffmpeg) would stretch its timers. Returns false if the
// activity could not be started.
bool disable_process_power_throttling();

} // namespace caspar
