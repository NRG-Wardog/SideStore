#include "bounded_fault_diagnostics.h"
#include <cassert>
#include <iostream>
using namespace bounded_fault_diagnostics;
static void emit(Snapshot value) {
    char out[wire_capacity] = {};
    assert(encode(value, out));
    std::cout << out << '\n';
}
int main() {
    char out[wire_capacity] = {};
    assert(!encode({}, out) && out[0] == 0);
    Snapshot value; value.available = true;
    emit(value); // Canonical unavailable observation.
    value.access = Access::ReadProtection; value.width = 8; value.region = Region::Heap;
    value.pc_library = 0; value.pc_offset = 100; value.guard = Guard::Intact;
    value.assets[0].known = true; value.assets[1].known = true;
    for (size_t i = 0; i < 32; ++i) { value.assets[0].bytes[i] = uint8_t(i); value.assets[1].bytes[i] = uint8_t(255 - i); }
    emit(value);
    value.access = Access::WriteProtection; value.width = 1; value.region = Region::LowGuard;
    value.pc_library = 65535; value.pc_offset = 805306367; value.guard = Guard::Changed; emit(value);
    value.access = Access::FetchProtection; value.width = 256; value.region = Region::Other; emit(value);
    value.access = static_cast<Access>(99); emit(value);
    value.access = Access::ReadProtection; value.width = 257; emit(value);
    value.width = 4; value.region = static_cast<Region>(99); emit(value);
    value.pc_offset = 805306368; emit(value);
    value.pc_library = -1; value.pc_offset = 0; emit(value);
    value.pc_library = 0; value.pc_offset = -1; emit(value);
    value.pc_library = 65536; value.pc_offset = 0; emit(value);
    value.guard = static_cast<Guard>(99); emit(value);
}
