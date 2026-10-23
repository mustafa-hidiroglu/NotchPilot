// NPRingBuffer.h — the only C++ surface Swift imports.
//
// A deliberately small, stable bridge over np::SPSCRingBuffer<float>: an opaque handle
// plus free functions. Swift never sees templates, atomics or std:: types, which keeps
// the interop boundary independent of libc++ ABI details and Swift's evolving support for
// importing non-copyable C++ classes.
//
// Ownership: np_ring_create() returns a heap object that must be released with exactly
// one np_ring_destroy() after both producer and consumer are finished with it. The Swift
// wrapper (RingBuffer.swift) enforces this with ARC.
//
// Threading: see SPSCRingBuffer.hpp. np_ring_write/np_ring_note_rejected are producer-only,
// np_ring_read is consumer-only, everything else is callable from any thread.

#pragma once

#ifndef __cplusplus
#error "NPRingBuffer.h must be compiled as C++. Enable Swift C++ interoperability: SwiftPM `.interoperabilityMode(.Cxx)` or Xcode 'C++ and Objective-C Interoperability' = 'C++ / Objective-C++' (-cxx-interoperability-mode=default)."
#endif

#include <cstddef>
#include <cstdint>

/// Opaque ring-buffer handle (imported into Swift as OpaquePointer).
struct NPRing;

/// Counter snapshot. All counts are cumulative since creation.
struct NPRingStats {
    std::uint64_t framesWritten;
    std::uint64_t framesRead;
    std::uint64_t framesDropped;
    std::uint64_t overflowEvents;
    std::uint64_t underrunEvents;
    std::uint64_t framesRejected;
    std::uint32_t lastRejectReason;
};

/// Creates a ring holding at least `minCapacityFrames` frames of `channels` interleaved
/// Float32 samples (capacity is rounded up to a power of two). Allocates; call off the
/// real-time path. Returns nullptr for invalid arguments (channels outside 1...64, capacity
/// outside 1...2^24 frames) or allocation failure; never throws.
NPRing *_Nullable np_ring_create(std::size_t minCapacityFrames, std::uint32_t channels) noexcept;

/// Destroys a ring created by np_ring_create. Passing nullptr is a no-op.
void np_ring_destroy(NPRing *_Nullable ring) noexcept;

/// Producer: copies up to `frames` interleaved frames in. Returns frames stored; the rest
/// are dropped and counted as overflow. Real-time safe.
std::size_t np_ring_write(NPRing *_Nonnull ring, const float *_Nonnull interleaved, std::size_t frames) noexcept;

/// Producer: records frames discarded before writing (e.g. unsupported format) together
/// with a non-zero reason code the consumer can read from np_ring_stats. Real-time safe.
void np_ring_note_rejected(NPRing *_Nonnull ring, std::size_t frames, std::uint32_t reason) noexcept;

/// Consumer: copies up to `frames` interleaved frames out. Returns frames copied; a short
/// read is counted as an underrun. Real-time safe.
std::size_t np_ring_read(NPRing *_Nonnull ring, float *_Nonnull interleaved, std::size_t frames) noexcept;

std::size_t np_ring_available_read(const NPRing *_Nonnull ring) noexcept;
std::size_t np_ring_available_write(const NPRing *_Nonnull ring) noexcept;
std::size_t np_ring_capacity_frames(const NPRing *_Nonnull ring) noexcept;
std::uint32_t np_ring_channels(const NPRing *_Nonnull ring) noexcept;
NPRingStats np_ring_stats(const NPRing *_Nonnull ring) noexcept;
