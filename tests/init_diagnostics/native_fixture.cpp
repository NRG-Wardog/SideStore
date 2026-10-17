#include "vm_initialization_diagnostics.h"
#include <iostream>
#include <vector>
using namespace vm_initialization_diagnostics;
int main() {
    const std::vector<ConstructorFailure> cases = {
        {Kind::DTInit, Reason::EngineError, 13, 0, 0},
        {Kind::DTInit, Reason::EngineError, -1, -1, 0},
        {Kind::DTInit, Reason::UnsupportedInterrupt, 0, 1, 0},
        {Kind::DTInit, Reason::UnexpectedReturn, 0, 65535, 0},
        {Kind::DTInitArray, Reason::EngineError, 255, 65535, 65535},
        {Kind::DTInitArray, Reason::EngineError, -1, -1, -1},
        {Kind::DTInitArray, Reason::UnsupportedInterrupt, -1, -1, -1},
        {Kind::DTInitArray, Reason::UnsupportedInterrupt, 255, 0, 1},
        {Kind::DTInitArray, Reason::UnexpectedReturn, 0, 2, 3},
        {Kind::DTInitArray, Reason::UnexpectedReturn, 0, -1, -1},
        {Kind::ArrayEntryRead, Reason::EntryRead, 6, 2, 4},
        {Kind::ArrayEntryRead, Reason::EntryRead, -1, -1, -1},
        {Kind::ArrayEntryRead, Reason::EntryRead, 255, 65535, 65535},
        {Kind::Unknown, Reason::Unknown, -1, -1, -1},
        {Kind::Unknown, Reason::InvalidVM, -1, -1, -1},
        {Kind::Unknown, Reason::PreviouslyFailed, -1, -1, -1},
        // The real producer normalizes invalid inputs before Swift receives them.
        {Kind::DTInit, Reason::EngineError, 256, 65536, 0},
        {Kind::DTInitArray, Reason::UnsupportedInterrupt, -1000, 70000, 70000},
        {Kind::DTInit, Reason::UnexpectedReturn, 13, 0, 0},
        {Kind::DTInit, Reason::EngineError, 13, 0, 1},
        {static_cast<Kind>(999), static_cast<Reason>(999), 999, 999, 999}
    };
    for (const auto &failure : cases) std::cout << description(failure) << '\n';
}
