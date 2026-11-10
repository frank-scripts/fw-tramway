# fw-trams

Install the resource as `fw-trams` and add `ensure fw-trams` to your `server.cfg`.

A modified and improved tramway system for FiveM, based on glitchdetector's [original tramway resource](https://github.com/glitchdetector/fivem-aerial-tramway). Uses ox\_lib zones to reduce the performance impact of the original resource and improve tramway cable car syncing.

# Features

* Two synchronized Pala Springs aerial trams, both with map blips enabled.
* **Walk-on / walk-off cabins**: board through the open doors at either station.
* Stand, walk, and move around while the tram travels; no seat attachment or controls lock.
* Each client's own ped is moved by the cabin's per-frame displacement to avoid slipping/falling behind.
* Multiple passengers may share a tram; there are no reserved seats or boarding prompts.
* Door, departure, arrival, and running audio preserved.
* ox\_lib zone streaming, synchronization, and station return safety preserved.

# Usage and setup

* Install the folder as `fw-trams` and add `ensure ox\\\_lib` then `ensure fw-trams` to `server.cfg`.
* Trams spawn when near the line. **Simply step into the cabin at a station**. No target or text UI is required.
* `Config.Blip.enabled = true` shows both station blips by default.
* If you use a different cabin model, adjust `Config.WalkableTrams` to match the floor and walkable bounds.
* Important: the cabin model needs working collision on the inside floor for on-foot players.
* While aboard, players remain free to walk. Leaving the cabin bounds stops carry; do not step through doors mid-flight.

# Dependencies

* [ox\_lib](https://github.com/overextended/ox_lib) (used for zones and math)

# Credits

* [glitchdetector](https://github.com/glitchdetector) for their original work on this resource

