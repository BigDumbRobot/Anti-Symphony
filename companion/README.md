# Anti-Symphony Companion module

This Companion connection controls an Apogee Symphony I/O Mk1 using the OSC
API provided by Anti-Symphony's `symphonyd`. It exposes native actions and
feedbacks, so users do not need to configure OSC messages manually.

## Setup

1. Install and run Anti-Symphony on the Mac connected to the Symphony.
2. Install the custom module package if it is not already installed, then
   restart Companion.
3. In **Connections**, add an **Anti-Symphony** connection. Open that
   connection's configuration (gear) to edit **Target IP**, **Target Port**,
   and **Project ID**.
4. Set **Target IP** to the Mac running `symphonyd` and **Target Port** to its
   OSC port (`7100` by default).
5. Optionally enter a **Project ID**. It is saved with the Companion
   connection and exposed as the `project_id` variable; it is a label for
   Companion use and is not sent to `symphonyd`.
6. If Companion runs on another computer, configure `symphonyd` to bind to
   that Mac's network interface (or `0.0.0.0`) and permit UDP port 7100 on a
   trusted LAN. The OSC API has no authentication; do not expose it to the
   public internet.

The module communicates with the `symphonyd` OSC service, not directly with
the Symphony Control window. On the same Mac, use `127.0.0.1:7100`. The
Companion status indicates whether the OSC service is reachable; hardware
attachment is shown by the `Symphony is connected` feedback.

The module subscribes to state updates and renews its subscription every 20
seconds. It uses those updates for feedbacks and variables.

## Troubleshooting

- **Companion runs on the same Mac:** set the address to `127.0.0.1`.
- **Companion runs on another computer:** `symphonyd` defaults to listening
  only on `127.0.0.1`, which rejects connections from other computers. Start
  it with `--osc-bind 0.0.0.0` (and optionally `--osc-port 7100`), allow
  incoming UDP on that port, and set the module address to the Symphony Mac's
  LAN IP.
- **The module is connected but the Symphony feedback is off:** OSC is
  responding, but `symphonyd` currently reports that no Symphony is attached.
  Check the service and USB connection. Companion's connection status reports
  OSC reachability; the `Symphony is connected` feedback reports hardware state.
- **No OSC reply:** verify the target IP, UDP port, daemon bind address, and
  firewall. The module reports a timeout if the daemon does not answer.

## Actions

- Set or adjust main and headphone levels.
- Set or toggle main/headphone mute, dim, and mono.
- Set mixer input/return/master fader, pan, mute and solo.
- Route every output, Mac-record, headphone-feed and mixer-input destination.
- Set analog reference levels, Soft Limit, optical mode, and sample rate.
- Set headphone mirror feeds, save/load/delete profiles, refresh state, subscribe
  to meters, and identify the interface.

## Feedbacks and variables

Feedbacks report Symphony connection state, monitor mute/dim/mono, and mixer
input mute/solo. Variables include the configured Project ID, main/headphone
levels, all 32 input meters, connection state, available profiles, and the
last OSC error. The preset library contains ready-to-add buttons grouped by
monitoring, each mixer, routing destination, headphone feed, analog I/O, clock,
and system/profile operations.

## Build a Companion module package

From this directory, install dependencies and run:

```sh
npm install
npm run package
```

The package can then be loaded into Companion as a custom module. The module
currently targets Companion's Node 22 runtime.
