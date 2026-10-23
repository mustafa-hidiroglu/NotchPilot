// SPSCRingBuffer.hpp — bounded, preallocated single-producer/single-consumer ring of
// interleaved PCM frames.
//
// Concurrency contract
//   * Exactly one producer thread at a time calls write()/note_rejected().
//   * Exactly one consumer thread at a time calls read().
//   * Any thread may call the const observers (available_*, stats()); they return a
//     snapshot that can be stale by the time it is used.
//   "One thread at a time" means calls on the same side must be ordered by
//   happens-before (e.g. a serial dispatch queue), not that they share an OS thread.
//
// Why it is lock-free
//   head_ (frames ever written) is stored only by the producer and tail_ (frames ever read)
//   only by the consumer. Each side publishes with a release store after touching the
//   sample memory and observes the other side with an acquire load, so the consumer never
//   reads samples the producer has not finished writing and the producer never
//   overwrites samples the consumer has not finished reading. Both are 64-bit monotonic
//   counters (they would take ~6 million years to wrap at 48 kHz), so full and empty are
//   unambiguous: used = head - tail, 0 <= used <= capacity. The static_asserts below
//   make the lock-free claim a compile-time property of the target.
//
// Real-time behaviour
//   write()/read() perform no allocation, locking, system calls or logging: two
//   memcpy segments and a handful of atomic operations. Storage is allocated once in the
//   constructor (never on the audio path).
//
// Overflow / underrun policy
//   * Overflow: write() stores as many whole frames as fit and drops the newest
//     remainder; dropped frames and overflow events are counted. Old audio is never
//     overwritten, so the consumer's view stays contiguous.
//   * Underrun: read() returns fewer frames than requested when not enough are buffered
//     and counts an underrun event; it never blocks or pads.

#pragma once

#include <atomic>
#include <bit>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <type_traits>

namespace np {

struct RingStats {
    std::uint64_t framesWritten;
    std::uint64_t framesRead;
    std::uint64_t framesDropped;    // frames rejected because the ring was full
    std::uint64_t overflowEvents;   // write() calls that dropped at least one frame
    std::uint64_t underrunEvents;   // read() calls that returned fewer frames than asked
    std::uint64_t framesRejected;   // frames the producer refused before writing (bad format)
    std::uint32_t lastRejectReason; // producer-defined code of the most recent rejection, 0 = none
};

template <typename Sample>
class SPSCRingBuffer {
    static_assert(std::is_trivially_copyable_v<Sample>, "samples are moved with memcpy");
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                  "SPSCRingBuffer requires lock-free 64-bit atomics on this target");

public:
    static constexpr std::size_t kMaxCapacityFrames = std::size_t{1} << 24;
    static constexpr std::uint32_t kMaxChannels = 64;

    // Capacity is clamped to [1, kMaxCapacityFrames] and rounded up to a power of two so the
    // index mask is a single AND. Storage is allocated with nothrow new: on failure (or
    // channels outside [1, kMaxChannels]) the ring is constructed invalid instead of
    // throwing, and valid() returns false. Callers must check valid() before use.
    SPSCRingBuffer(std::size_t minCapacityFrames, std::uint32_t channels) noexcept
        : capacity_(std::bit_ceil(clampCapacity(minCapacityFrames))),
          mask_(capacity_ - 1),
          channels_(channels),
          storage_(channels >= 1 && channels <= kMaxChannels
                       ? new (std::nothrow) Sample[capacity_ * channels]()
                       : nullptr) {}

    bool valid() const noexcept { return storage_ != nullptr; }

    SPSCRingBuffer(const SPSCRingBuffer&) = delete;
    SPSCRingBuffer& operator=(const SPSCRingBuffer&) = delete;

    std::size_t capacityFrames() const noexcept { return capacity_; }
    std::uint32_t channels() const noexcept { return channels_; }

    // Producer side. `frames` interleaved frames are read from `src`.
    // Returns the number of frames stored (== frames unless the ring was full).
    std::size_t write(const Sample* src, std::size_t frames) noexcept {
        OwnershipGuard guard(producerActive_);
        const std::uint64_t head = head_.load(std::memory_order_relaxed);   // own index
        const std::uint64_t tail = tail_.load(std::memory_order_acquire);   // pairs with read()'s release
        const std::size_t freeFrames = capacity_ - static_cast<std::size_t>(head - tail);
        const std::size_t n = frames < freeFrames ? frames : freeFrames;

        if (n > 0) {
            copyIn(static_cast<std::size_t>(head) & mask_, src, n);
            head_.store(head + n, std::memory_order_release);               // publish samples
        }
        if (n < frames) {
            framesDropped_.fetch_add(frames - n, std::memory_order_relaxed);
            overflowEvents_.fetch_add(1, std::memory_order_relaxed);
        }
        framesWritten_.fetch_add(n, std::memory_order_relaxed);
        return n;
    }

    // Producer side: account for input the producer discarded before write(). `reason` is
    // an opaque producer-defined code; the consumer polls it through stats(), so the
    // real-time path never has to call out to report a problem.
    void noteRejected(std::size_t frames, std::uint32_t reason) noexcept {
        OwnershipGuard guard(producerActive_);
        lastRejectReason_.store(reason, std::memory_order_relaxed);
        framesRejected_.fetch_add(frames, std::memory_order_release);
    }

    // Consumer side. Copies up to `frames` interleaved frames into `dst`.
    std::size_t read(Sample* dst, std::size_t frames) noexcept {
        OwnershipGuard guard(consumerActive_);
        const std::uint64_t tail = tail_.load(std::memory_order_relaxed);   // own index
        const std::uint64_t head = head_.load(std::memory_order_acquire);   // pairs with write()'s release
        const std::size_t used = static_cast<std::size_t>(head - tail);
        const std::size_t n = frames < used ? frames : used;

        if (n > 0) {
            copyOut(static_cast<std::size_t>(tail) & mask_, dst, n);
            tail_.store(tail + n, std::memory_order_release);               // hand slots back
        }
        if (n < frames) {
            underrunEvents_.fetch_add(1, std::memory_order_relaxed);
        }
        framesRead_.fetch_add(n, std::memory_order_relaxed);
        return n;
    }

    // Observers: safe from any thread, results are snapshots.
    std::size_t availableToRead() const noexcept {
        const std::uint64_t tail = tail_.load(std::memory_order_acquire);
        const std::uint64_t head = head_.load(std::memory_order_acquire);
        return static_cast<std::size_t>(head - tail);
    }

    // Clamped: an observer on a third thread loads the two indices non-atomically as a
    // pair, so the producer may advance between the loads and head - tail can briefly
    // exceed the capacity.
    std::size_t availableToWrite() const noexcept {
        const std::size_t used = availableToRead();
        return used < capacity_ ? capacity_ - used : 0;
    }

    RingStats stats() const noexcept {
        return RingStats{
            framesWritten_.load(std::memory_order_relaxed),
            framesRead_.load(std::memory_order_relaxed),
            framesDropped_.load(std::memory_order_relaxed),
            overflowEvents_.load(std::memory_order_relaxed),
            underrunEvents_.load(std::memory_order_relaxed),
            framesRejected_.load(std::memory_order_acquire),
            lastRejectReason_.load(std::memory_order_relaxed),
        };
    }

private:
    static constexpr std::size_t clampCapacity(std::size_t frames) noexcept {
        return frames == 0 ? 1 : (frames > kMaxCapacityFrames ? kMaxCapacityFrames : frames);
    }

    // Debug-only detector for a second concurrent producer or consumer. Compiles to nothing
    // unless NP_RING_DEBUG_OWNERSHIP is defined (debug builds and the C++ test binary).
    struct OwnershipGuard {
#if defined(NP_RING_DEBUG_OWNERSHIP) && NP_RING_DEBUG_OWNERSHIP
        explicit OwnershipGuard(std::atomic<bool>& flag) noexcept : flag_(flag) {
            const bool wasActive = flag_.exchange(true, std::memory_order_acquire);
            assert(!wasActive && "SPSCRingBuffer: concurrent calls on the same side");
            (void)wasActive;
        }
        ~OwnershipGuard() { flag_.store(false, std::memory_order_release); }
        std::atomic<bool>& flag_;
#else
        explicit OwnershipGuard(std::atomic<bool>&) noexcept {}
#endif
    };

    void copyIn(std::size_t startFrame, const Sample* src, std::size_t frames) noexcept {
        const std::size_t first = frames < capacity_ - startFrame ? frames : capacity_ - startFrame;
        std::memcpy(storage_.get() + startFrame * channels_, src, first * channels_ * sizeof(Sample));
        if (first < frames) {
            std::memcpy(storage_.get(), src + first * channels_, (frames - first) * channels_ * sizeof(Sample));
        }
    }

    void copyOut(std::size_t startFrame, Sample* dst, std::size_t frames) const noexcept {
        const std::size_t first = frames < capacity_ - startFrame ? frames : capacity_ - startFrame;
        std::memcpy(dst, storage_.get() + startFrame * channels_, first * channels_ * sizeof(Sample));
        if (first < frames) {
            std::memcpy(dst + first * channels_, storage_.get(), (frames - first) * channels_ * sizeof(Sample));
        }
    }

    // Keep producer- and consumer-owned indices on separate cache lines to avoid false sharing.
    static constexpr std::size_t kCacheLine = 64;

    const std::size_t capacity_;
    const std::size_t mask_;
    const std::uint32_t channels_;
    const std::unique_ptr<Sample[]> storage_;

    alignas(kCacheLine) std::atomic<std::uint64_t> head_{0};
    alignas(kCacheLine) std::atomic<std::uint64_t> tail_{0};

    // Producer-written counters.
    alignas(kCacheLine) std::atomic<std::uint64_t> framesWritten_{0};
    std::atomic<std::uint64_t> framesDropped_{0};
    std::atomic<std::uint64_t> overflowEvents_{0};
    std::atomic<std::uint64_t> framesRejected_{0};
    std::atomic<std::uint32_t> lastRejectReason_{0};
    std::atomic<bool> producerActive_{false};

    // Consumer-written counters.
    alignas(kCacheLine) std::atomic<std::uint64_t> framesRead_{0};
    std::atomic<std::uint64_t> underrunEvents_{0};
    std::atomic<bool> consumerActive_{false};
};

}  // namespace np
