// Behavioral reconstruction of the UX3407RA BIOS 312 embedded controller.
//
// This is an analysis model, not replacement firmware and not a flasher.  It
// encodes only behavior proven from the SHA-locked 312 EC RISC-V image.  Keep
// guessed behavior out of this file until its instruction path is documented.

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <span>

namespace ux3407ra::ec312 {

enum class FnRow : std::uint8_t {
    ActionKeysPrimary = 0,
    FunctionKeysPrimary = 1,
};

enum class DispatchResult {
    Rejected,
    Accepted,
    Queued,
};

struct State {
    // Recovered EC RAM locations are included so the model remains auditable.
    std::uint8_t fn_switch_flags_00803049{};
    std::uint8_t service_busy_00800410{};
    std::uint16_t service_flags_0080041a{};

    // D0/8F auxiliary timed state. Hardware testing disproved this as a
    // sufficient Fn-switch prerequisite; its public purpose is still unknown.
    std::uint8_t d0_8f_flags_008012a0{};
    std::uint8_t d0_8f_mode_008012a1{};
    std::uint16_t d0_8f_counter_008012a2{};

    // Public names for these two recovered paths are still unknown. The
    // neutral names encode only their proven instruction-level effects.
    std::uint8_t channel_3a{};
    std::uint8_t flags_00803024{};

    std::uint8_t keyboard_backlight_0080304a{};

    [[nodiscard]] FnRow fn_row() const {
        return (fn_switch_flags_00803049 & 0x02) != 0
                   ? FnRow::FunctionKeysPrimary
                   : FnRow::ActionKeysPrimary;
    }

    [[nodiscard]] bool fn_service_ready() const {
        return service_busy_00800410 == 0 &&
               (service_flags_0080041a & 0x0080) != 0;
    }
};

class Controller {
  public:
    explicit Controller(State state = {}) : state_(state) {}

    [[nodiscard]] const State &state() const { return state_; }
    [[nodiscard]] State &state() { return state_; }

    DispatchResult set_feature(std::span<const std::uint8_t> report) {
        if (report.size() < 4 || report[0] != 0x5a)
            return DispatchResult::Rejected;

        switch (report[1]) {
        case 0xd0:
            return dispatch_d0(report);
        case 0xba:
            return dispatch_backlight(report);
        default:
            return DispatchResult::Rejected;
        }
    }

    bool service_fn_switch() {
        // EC 0xf850: requests remain queued until both gates allow service.
        if (!state_.fn_service_ready())
            return false;

        auto &flags = state_.fn_switch_flags_00803049;
        if ((flags & 0x04) != 0) {
            // EC 0xf870: clears current-state bit and request bits 0..2.
            flags &= static_cast<std::uint8_t>(~0x07u);
            return true;
        }
        if ((flags & 0x08) != 0) {
            // EC 0xf888: clears bits 0/3 and sets current-state bit 1.
            flags &= static_cast<std::uint8_t>(~0x09u);
            flags |= 0x02;
            return true;
        }

        flags &= static_cast<std::uint8_t>(~0x01u);
        return false;
    }

  private:
    DispatchResult dispatch_d0(std::span<const std::uint8_t> report) {
        const auto selector = report[2];
        const auto value = report[3];

        if (selector == 0x4e) {
            if (value == 0) {
                // EC 0xf82c.
                state_.fn_switch_flags_00803049 |= 0x04;
                return DispatchResult::Queued;
            }
            if (value == 1) {
                // EC 0xf83e.
                state_.fn_switch_flags_00803049 |= 0x08;
                return DispatchResult::Queued;
            }
            return DispatchResult::Rejected;
        }

        if (selector == 0x7c && value <= 1) {
            // EC 0x10230 / 0x10226 call channel 0x3a with the inverted value.
            state_.channel_3a = static_cast<std::uint8_t>(value == 0);
            return DispatchResult::Accepted;
        }

        if (selector == 0x85 && report.size() >= 5 && value == 0xff &&
            report[4] == 0x80) {
            // EC 0xd350. The public feature name is not yet established.
            state_.flags_00803024 |= 0x80;
            return DispatchResult::Accepted;
        }

        if (selector == 0x8f && value == 1) {
            // EC 0x10310 followed by 0x102f8.
            state_.d0_8f_flags_008012a0 |= 0x80;
            state_.d0_8f_flags_008012a0 &=
                static_cast<std::uint8_t>(~0x40u);
            state_.d0_8f_mode_008012a1 = 0;
            state_.d0_8f_counter_008012a2 = 0;
            return DispatchResult::Accepted;
        }

        return DispatchResult::Rejected;
    }

    DispatchResult dispatch_backlight(std::span<const std::uint8_t> report) {
        if (report.size() < 5 || report[2] != 0xc5 || report[3] != 0xc4)
            return DispatchResult::Rejected;

        // EC 0xffdc is a four-way switch, not an 8-bit PWM assignment.
        switch (report[4]) {
        case 0:
            state_.keyboard_backlight_0080304a = 0x00;
            break;
        case 1:
            state_.keyboard_backlight_0080304a = 0x43;
            break;
        case 2:
            state_.keyboard_backlight_0080304a = 0x87;
            break;
        case 3:
            state_.keyboard_backlight_0080304a = 0xcc;
            break;
        default:
            // The real function falls through to the level-zero assignment.
            state_.keyboard_backlight_0080304a = 0x00;
            break;
        }
        return DispatchResult::Accepted;
    }

    State state_;
};

} // namespace ux3407ra::ec312

int main() {
    using namespace ux3407ra::ec312;

    Controller ec;
    constexpr std::array<std::uint8_t, 4> d0_8f{0x5a, 0xd0, 0x8f, 0x01};
    assert(ec.set_feature(d0_8f) == DispatchResult::Accepted);
    assert((ec.state().d0_8f_flags_008012a0 & 0x80) != 0);

    constexpr std::array<std::uint8_t, 4> channel_on{0x5a, 0xd0, 0x7c, 0x00};
    constexpr std::array<std::uint8_t, 4> channel_off{0x5a, 0xd0, 0x7c, 0x01};
    assert(ec.set_feature(channel_on) == DispatchResult::Accepted);
    assert(ec.state().channel_3a == 1);
    assert(ec.set_feature(channel_off) == DispatchResult::Accepted);
    assert(ec.state().channel_3a == 0);

    constexpr std::array<std::uint8_t, 5> d0_85_enable{
        0x5a, 0xd0, 0x85, 0xff, 0x80};
    assert(ec.set_feature(d0_85_enable) == DispatchResult::Accepted);
    assert((ec.state().flags_00803024 & 0x80) != 0);

    constexpr std::array<std::uint8_t, 4> fkeys{0x5a, 0xd0, 0x4e, 0x01};
    assert(ec.set_feature(fkeys) == DispatchResult::Queued);
    assert(!ec.service_fn_switch()); // Gate bit 7 is initially clear.
    ec.state().service_flags_0080041a |= 0x80;
    assert(ec.service_fn_switch());
    assert(ec.state().fn_row() == FnRow::FunctionKeysPrimary);

    constexpr std::array<std::uint8_t, 4> actions{0x5a, 0xd0, 0x4e, 0x00};
    assert(ec.set_feature(actions) == DispatchResult::Queued);
    assert(ec.service_fn_switch());
    assert(ec.state().fn_row() == FnRow::ActionKeysPrimary);

    constexpr std::array<std::uint8_t, 5> light3{0x5a, 0xba, 0xc5, 0xc4, 3};
    constexpr std::array<std::uint8_t, 5> light255{0x5a, 0xba, 0xc5, 0xc4, 255};
    assert(ec.set_feature(light3) == DispatchResult::Accepted);
    assert(ec.state().keyboard_backlight_0080304a == 0xcc);
    assert(ec.set_feature(light255) == DispatchResult::Accepted);
    assert(ec.state().keyboard_backlight_0080304a == 0x00);

    std::cout << "UX3407RA 312 EC behavioral checks passed\n";
}
