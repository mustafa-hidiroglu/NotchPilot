// Standalone C++ tests for np::SPSCRingBuffer, run by scripts/test.sh under
// ThreadSanitizer and AddressSanitizer+UBSan. No framework: each check aborts with a message.

#include "SPSCRingBuffer.hpp"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            std::abort();                                                        \
        }                                                                        \
    } while (0)

using Ring = np::SPSCRingBuffer<float>;

static void testCapacityRoundsToPowerOfTwo() {
    Ring r(100, 2);
    CHECK(r.capacityFrames() == 128);
    CHECK(r.availableToRead() == 0);
    CHECK(r.availableToWrite() == 128);
}

static void testEmptyReadIsUnderrun() {
    Ring r(8, 1);
    float out[4] = {};
    CHECK(r.read(out, 4) == 0);
    CHECK(r.stats().underrunEvents == 1);
    CHECK(r.read(out, 0) == 0);
    CHECK(r.stats().underrunEvents == 1);  // a zero-frame read is not an underrun
}

static void testFullRingDropsNewestAndCounts() {
    Ring r(4, 2);
    const float in[12] = {1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6};
    CHECK(r.write(in, 6) == 4);
    CHECK(r.availableToWrite() == 0);
    auto s = r.stats();
    CHECK(s.framesDropped == 2 && s.overflowEvents == 1 && s.framesWritten == 4);

    float out[8] = {};
    CHECK(r.read(out, 4) == 4);
    for (int i = 0; i < 8; ++i) CHECK(out[i] == static_cast<float>(i / 2 + 1));  // oldest kept
}

static void testWraparoundPreservesOrder() {
    Ring r(8, 2);
    float next = 0, expect = 0;
    std::vector<float> buf(2 * 5);
    for (int round = 0; round < 100; ++round) {
        for (float& v : buf) v = next++;
        CHECK(r.write(buf.data(), 5) == 5);
        std::vector<float> out(2 * 5);
        CHECK(r.read(out.data(), 5) == 5);
        for (float v : out) CHECK(v == expect++);
    }
    CHECK(r.stats().framesWritten == 500 && r.stats().framesRead == 500);
    CHECK(r.stats().overflowEvents == 0 && r.stats().underrunEvents == 0);
}

static void testPartialReadCountsUnderrun() {
    Ring r(8, 1);
    const float in[3] = {7, 8, 9};
    r.write(in, 3);
    float out[5] = {};
    CHECK(r.read(out, 5) == 3);
    CHECK(out[0] == 7 && out[2] == 9);
    CHECK(r.stats().underrunEvents == 1);
}

static void testConcurrentProducerConsumer() {
    constexpr std::uint64_t kFrames = 2'000'000;
    constexpr std::size_t kChunk = 37;  // deliberately not a divisor of the capacity
    Ring r(256, 2);

    std::thread producer([&] {
        std::uint64_t sent = 0;
        float chunk[kChunk * 2];
        while (sent < kFrames) {
            const std::size_t want = static_cast<std::size_t>(std::min<std::uint64_t>(kChunk, kFrames - sent));
            const std::size_t space = r.availableToWrite();
            const std::size_t n = want < space ? want : space;  // never overflow: test ordering
            if (n == 0) { std::this_thread::yield(); continue; }
            for (std::size_t i = 0; i < n; ++i) {
                chunk[2 * i] = static_cast<float>((sent + i) % 1'000'000);
                chunk[2 * i + 1] = -chunk[2 * i];
            }
            CHECK(r.write(chunk, n) == n);
            sent += n;
        }
    });

    std::uint64_t received = 0;
    float out[64 * 2];
    while (received < kFrames) {
        const std::size_t avail = r.availableToRead();
        if (avail == 0) { std::this_thread::yield(); continue; }
        const std::size_t n = r.read(out, avail < 64 ? avail : 64);
        for (std::size_t i = 0; i < n; ++i) {
            const float expected = static_cast<float>((received + i) % 1'000'000);
            CHECK(out[2 * i] == expected);
            CHECK(out[2 * i + 1] == -expected);
        }
        received += n;
    }
    producer.join();
    const auto s = r.stats();
    CHECK(s.framesWritten == kFrames && s.framesRead == kFrames && s.framesDropped == 0);
}

static void testConcurrentOverflowAccounting() {
    // Producer writes blindly; every frame must be either delivered or counted as dropped.
    constexpr std::uint64_t kFrames = 500'000;
    Ring r(64, 1);
    std::atomic<bool> done{false};
    std::thread producer([&] {
        float chunk[16];
        for (std::uint64_t sent = 0; sent < kFrames; sent += 16) {
            for (float& v : chunk) v = 1.0f;
            r.write(chunk, 16);
        }
        done.store(true, std::memory_order_release);
    });
    std::uint64_t received = 0;
    float out[32];
    while (!done.load(std::memory_order_acquire) || r.availableToRead() > 0) {
        received += r.read(out, 32);
    }
    producer.join();
    const auto s = r.stats();
    CHECK(received == s.framesWritten);
    CHECK(s.framesWritten + s.framesDropped == kFrames);
}

static void testInvalidConstructionReportsInvalid() {
    CHECK(Ring(8, 0).valid() == false);
    CHECK(Ring(8, Ring::kMaxChannels + 1).valid() == false);
    CHECK(Ring(0, 1).valid() && Ring(0, 1).capacityFrames() == 1);
    CHECK(Ring(~std::size_t{0}, 1).capacityFrames() == Ring::kMaxCapacityFrames);  // clamped, no UB
}

int main() {
    testInvalidConstructionReportsInvalid();
    testCapacityRoundsToPowerOfTwo();
    testEmptyReadIsUnderrun();
    testFullRingDropsNewestAndCounts();
    testWraparoundPreservesOrder();
    testPartialReadCountsUnderrun();
    testConcurrentProducerConsumer();
    testConcurrentOverflowAccounting();
    std::puts("ring_buffer_tests: all passed");
    return 0;
}
