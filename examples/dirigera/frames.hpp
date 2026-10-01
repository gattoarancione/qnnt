// What travels on the bridge's topics, as the station reads it.
//
// The counterpart of examples/dirigera/frames.zig, and the two must agree FIELD BY FIELD.
// Neither side errors when they do not: TLD ignores a key the receiving struct does not
// declare, and the macros below leave a member the frame did not carry exactly as its
// constructor left it. A renamed field therefore produces plausible data -- a light that
// reports itself uncontrollable, a sensor with no room -- rather than a failure.
//
// examples/cpp_logic_test.cpp pins the agreement against a golden frame packed by the Zig
// side, so drift on either side fails a test instead of reaching a screen.

#ifndef QNNT_DIRIGERA_FRAMES_HPP
#define QNNT_DIRIGERA_FRAMES_HPP

#include "qnnt_tld.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace dirigera {

/// Mirrors DeviceFrame in examples/dirigera/bridge.zig. TLD matches on field names, so the
/// two have to agree; the optionals are genuinely optional -- a motion sensor has no
/// brightness, and null says so rather than a zero the consumer must know to disbelieve.
struct DeviceFrame {
    std::string id;
    std::string type;
    std::string name;
    std::string room;
    std::string model;
    bool reachable{};
    std::optional<bool> is_on;
    std::optional<std::uint8_t> light_level;
    std::optional<std::uint16_t> color_temperature;
    std::optional<std::uint8_t> battery;
    std::optional<bool> is_detected;
    std::optional<std::uint32_t> illuminance;
    bool controllable{};
    bool can_set_on{};
    bool can_set_level{};
    bool can_set_temperature{};
    std::optional<std::uint16_t> temperature_min;
    std::optional<std::uint16_t> temperature_max;
    std::string relation;
    TLD_DEFINE_MAP(id, type, name, room, model, reachable, is_on, light_level,
                   color_temperature, battery, is_detected, illuminance, controllable,
                   can_set_on, can_set_level, can_set_temperature, temperature_min,
                   temperature_max, relation)
};

struct InventoryFrame {
    std::uint64_t t_us{};
    std::string hub;
    std::uint32_t count{};
    std::vector<DeviceFrame> devices;
    TLD_DEFINE_MAP(t_us, hub, count, devices)
};

struct StateFrame {
    std::uint64_t seq{};
    std::uint64_t t_us{};
    std::string event;
    bool identified{};
    DeviceFrame device;
    TLD_DEFINE_MAP(seq, t_us, event, identified, device)
};

struct StatusFrame {
    std::uint64_t t_us{};
    std::string hub;
    std::string firmware;
    bool api_link{};
    bool event_link{};
    std::uint32_t devices{};
    std::uint64_t events_received{};
    std::uint64_t events_unparsed{};
    std::uint64_t dropped_fragments{};
    std::uint64_t commands_sent{};
    std::uint64_t commands_failed{};
    std::uint64_t commands_refused{};
    std::uint64_t reconnects{};
    /// A bearer token is in hand. False means the bridge is up but unpaired, and a
    /// controller should offer to pair rather than show an empty house.
    bool paired{};
    /// An exchange is under way and the hub is waiting for its action button.
    bool pairing{};
    /// The last thing that exchange said, meant for whoever is standing at the hub.
    std::string pair_detail;
    TLD_DEFINE_MAP(t_us, hub, firmware, api_link, event_link, devices, events_received,
                   events_unparsed, dropped_fragments, commands_sent, commands_failed,
                   commands_refused, reconnects, paired, pairing, pair_detail)
};

/// A request to pair, sent by the pairing panel. The bridge runs the exchange.
struct PairRequest {
    std::string name{"qnnt-bridge"};
    bool cancel{};
    TLD_DEFINE_MAP(name, cancel)
};

/// What goes on the command topic. Optional throughout, so dimming a light does not also
/// restate its colour -- and so the bridge sends the hub only what was actually asked for.
struct LightCommand {
    std::string id;
    std::optional<bool> on;
    std::optional<std::uint8_t> level;
    std::optional<std::uint16_t> kelvin;
    TLD_DEFINE_MAP(id, on, level, kelvin)
};

} // namespace dirigera

#endif
