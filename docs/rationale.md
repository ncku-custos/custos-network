# Rationale — why the stack is shaped this way

> **Provenance convention.** `[documented]` marks decisions **explicitly made and reasoned
> through during architecture design** and since implemented in this repo — the on-disk sources
> are the `custos_network` role, the README, and this file, which together are the standing
> decision record. `[inferred]` marks my reading of the design that was *not* explicitly
> settled. Items with no recoverable reason are recorded as **open**, not invented.

## The central tension

One shared, lossy, bandwidth-limited 5 GHz link must carry three traffic classes whose needs
conflict — low-latency command/telemetry, high-bandwidth video, and structured ROS 2 data —
all under flight-safety and radio-regulatory constraints. Almost every decision below is a
response to that single web of forces: converge the traffic, prioritize it, keep it stateless
so loss is cheap, and make the aircraft safe on its own when the link is gone.

## Load-bearing decisions

**Converge all three planes onto one 5 GHz link.** **[documented]** — chosen deliberately over
separate radios for SWaP and simplicity. The known cost was accepted with eyes open: a single
link is all-or-nothing, so the manual fallback is not a real safety net and the failsafe role
moves to PX4 autonomy (see Behavior, scenario 2). This trade *is* the architecture.

**Drone is the access point; ground is the station.** **[documented]** — the companion runs
`hostapd`; the ground associates to it. This sidesteps single-PHY AP+STA concurrency on the
MT7922 (which would be needed if the drone instead joined campus WiFi), keeps the flight link
dedicated, and eliminates roaming/handoff dropouts mid-flight.

**Static IP, no DHCP anywhere.** **[documented]** — the reconnect speed people expect from a
"tolerant" link comes almost entirely from *removing* state, not adding recovery logic. With
static addressing, the instant the 802.11 association returns, L3 is already valid and packets
resume on the next frame; DHCP would insert a multi-step lease exchange after every blip.

**DDS confined to localhost; only Zenoh crosses the air.** **[documented]** — DDS multicast
discovery over a lossy wireless link is a known failure mode, so the full ROS graph stays on
the companion and `zenoh-bridge-ros2dds` ships only selected topics off-board. Zenoh is
purpose-built for constrained, intermittent links and re-establishes its session transparently.

**Connectionless transports for C2 and video; TCP avoided.** **[documented]** — UDP has no
session, so there is nothing to "reconnect": the link goes quiet and then flows again. TCP would
read the loss as congestion, back off, and retransmit stale control commands — exactly the wrong
behavior for a control link.

**QoS (DSCP→WMM) is configured last, not first.** **[documented]** — on a converged link,
control packets must survive video saturating the air. But priority can only be tuned and
verified against *real* contending load, which doesn't exist until all three planes are running
— so QoS is deliberately the final phase, measured adversarially, not guessed up front.

**Fixed non-DFS channel and Wi-Fi power-save off.** **[documented]** — a DFS channel can force
the radio off-air for a CAC period if it detects radar, i.e. link loss mid-flight; power-save
adds 100 ms-class latency/jitter as the radio naps between beacons. Both are unacceptable for a
flight link, so both are removed at the physical/link layer. The specific channel is **149**
(U-NII-3, 5745 MHz): non-DFS *and* outdoor-legal under TW NCC. An earlier draft used ch36, but
that is U-NII-1 (5150–5250 MHz), typically indoor-only — wrong for an outdoor drone.

**Network bring-up lives as config-as-code — this repo's Ansible role, not baked firmware.**
**[documented]** — kept maximally editable for iteration speed (a baked image means re-flash; a
config layer means edit-and-reapply). The role is cleanly *separable* but not extracted as a
standalone reusable role: the rule-of-three threshold (a real second consumer) has not been met,
so it stays here with a sharp interface until it is.

**Your ROS 2 application nodes are the only code written from scratch.** **[inferred]** — this
is my reading of the craft/steal split as a deliberate posture rather than an accident: every
engine (DDS, the bridge, mavlink-router, GStreamer, hostapd) is stolen and only *configured*,
which concentrates original effort on the one part that is actually the drone. We discussed the
split but did not state it as a governing principle, so I tag it inferred.

## Open decisions (reasoning not yet settled)

- **Exact QoS class boundaries** — the DSCP values and WMM access-category mapping per plane are
  not yet pinned; only the ordering (C2 > video > ROS > internet) is decided.
- **Zenoh topic allow-list and per-topic rates** — which topics cross and at what frequency caps
  is undefined; it depends on application nodes that don't exist yet.
- **Whether the ground needs custom GCS nodes at all** — RViz + QGroundControl may be the entire
  ground UI early on; undecided.

## Provenance health

Nearly all rationale here is *decided-in-design and now implemented* rather than hard
`[inferred]` — the project reasoned before it built, and the bare link plus its Ansible role
shipped to that reasoning. The main gaps are implementation specifics (QoS values, topic lists)
that are correctly deferred to the phases where real load makes them measurable. This file is
the standing decision record — update it in the same change that alters a decision.
