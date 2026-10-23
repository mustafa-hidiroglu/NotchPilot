#include "NPRingBuffer.h"

#include "SPSCRingBuffer.hpp"

#include <new>

struct NPRing {
    NPRing(std::size_t capacity, std::uint32_t channels) noexcept : buffer(capacity, channels) {}
    np::SPSCRingBuffer<float> buffer;
};

NPRing *np_ring_create(std::size_t minCapacityFrames, std::uint32_t channels) noexcept {
    using Buffer = np::SPSCRingBuffer<float>;
    if (channels == 0 || channels > Buffer::kMaxChannels || minCapacityFrames == 0 ||
        minCapacityFrames > Buffer::kMaxCapacityFrames) {
        return nullptr;
    }
    // Both allocations are nothrow: this function is noexcept and must report failure
    // with nullptr rather than terminating the process.
    NPRing *ring = new (std::nothrow) NPRing(minCapacityFrames, channels);
    if (ring != nullptr && !ring->buffer.valid()) {
        delete ring;
        return nullptr;
    }
    return ring;
}

void np_ring_destroy(NPRing *ring) noexcept { delete ring; }

std::size_t np_ring_write(NPRing *ring, const float *interleaved, std::size_t frames) noexcept {
    return ring->buffer.write(interleaved, frames);
}

void np_ring_note_rejected(NPRing *ring, std::size_t frames, std::uint32_t reason) noexcept {
    ring->buffer.noteRejected(frames, reason);
}

std::size_t np_ring_read(NPRing *ring, float *interleaved, std::size_t frames) noexcept {
    return ring->buffer.read(interleaved, frames);
}

std::size_t np_ring_available_read(const NPRing *ring) noexcept { return ring->buffer.availableToRead(); }
std::size_t np_ring_available_write(const NPRing *ring) noexcept { return ring->buffer.availableToWrite(); }
std::size_t np_ring_capacity_frames(const NPRing *ring) noexcept { return ring->buffer.capacityFrames(); }
std::uint32_t np_ring_channels(const NPRing *ring) noexcept { return ring->buffer.channels(); }

NPRingStats np_ring_stats(const NPRing *ring) noexcept {
    const np::RingStats s = ring->buffer.stats();
    return NPRingStats{s.framesWritten, s.framesRead, s.framesDropped,
                       s.overflowEvents, s.underrunEvents, s.framesRejected,
                       s.lastRejectReason};
}
