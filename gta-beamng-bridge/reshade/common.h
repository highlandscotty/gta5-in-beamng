// Shared-memory frame pipe: GTA add-on writes, BeamNG add-on reads (same user session, plain CPU copy).
// Three slots written in rotation: the reader always takes the newest finished one, so a frame is never lost to a half-written buffer
// (with one buffer and GTA at 100+ fps about half the reads were torn and dropped, which made Michael look like stop motion).
#pragma once
#include <stdint.h>
#define PIPE_NAME "Local\\GtaBeamFrame3"
#define PIPE_MAX_BYTES (1920u * 1200u * 4u)
#define PIPE_SLOTS 3
struct PipeSlot {
	volatile uint32_t seq;     // odd while GTA is writing this slot, even when it is complete (seqlock)
	uint32_t width, height;
	uint32_t bgr;              // 1: source pixels are B,G,R,A order
	uint32_t frame;            // capture counter of the frame in this slot
	uint32_t tick;             // the BeamNG frame (PipeHeader::beamTick) that set GTA off drawing this one; 0 = GTA was not running in step
	uint32_t pad[2];
};
struct PipeHeader {
	volatile uint32_t latest;  // index of the newest complete slot
	volatile uint32_t frame;   // capture counter of that slot (0 = nothing yet)
	volatile uint32_t beamTick;// written by the BeamNG add-on: one more every BeamNG frame. GTA draws one frame per tick (see TICK_EVENT)
	uint32_t pad[5];
	PipeSlot slot[PIPE_SLOTS];
};
// Auto-reset event the BeamNG add-on sets every frame, right after it has taken GTA's newest picture: GTA's add-on holds each finished
// frame until then. So GTA draws exactly one frame per BeamNG frame, always at the same moment of it: every picture is one BeamNG frame
// old, no more and no less, and none is drawn that is never shown. (Free-running at its own 60 fps against BeamNG's 40-55, the age of the
// picture, and how far his animation had moved on, changed from frame to frame.)
#define TICK_EVENT "Local\\GtaBeamTick"
#define PIPE_SIZE (sizeof(PipeHeader) + (size_t)PIPE_SLOTS * PIPE_MAX_BYTES)
#define PIPE_PIXELS(hdr, i) ((uint8_t *)((hdr) + 1) + (size_t)(i) * PIPE_MAX_BYTES)
