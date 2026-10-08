-- karaoke.lua v9 - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, PCM I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- To update karaoke logic: edit this file, no app rebuild needed.
-- The app downloads the latest version on startup.
--
-- v9: Continuous streaming renderer (fixes playback stuttering).
--     - ONE MdxRenderer pass over the whole song (no per-segment resets).
--     - Kotlin decodes the audio sequentially on a background thread
--       (StreamingDecodeSource) while the GPU renders: decode is ~6x
--       realtime, inference ~1.3x realtime, so decoding NEVER serializes
--       with inference (it used to add ~16% on the same thread) and never
--       gates the pipeline.
--     - Each finalized block is appended to the growing PCM file the moment
--       it is rendered (karaoke:renderAppend) - playback sees a
--       continuously growing stream.
--     - No per-segment renderer warm-up: the per-10s Hann fade dimple and
--       the seek-boundary discontinuities of v8 are gone.
--     - Replay cache: a finished render is marked with a .done file, so
--       repeat plays start instantly with no re-render at all.
--
-- Rate math (TECNO KL8, ~3.4s GPU per window, stride = 4.44s of audio):
--   4.44 / 3.4 = ~1.3x realtime -> the audio buffer GROWS while playing.
-- (v8 reset a fresh renderer per 10s segment: 3 GPU windows per 10s audio
--  plus a 1.6s decode between segments = ~0.8x realtime -> stutter.)

local SAMPLE_RATE = 44100
-- First chunk threshold: fires after the 2nd window (8.89s of audio,
-- ~4.5s wall) - enough buffer that playback never starves afterwards.
local FIRST_CHUNK_SECONDS = 8

--- Main entry point. Called from Kotlin.
--- @param videoId string YouTube video ID
--- @param audioUrl string Direct audio stream URL
--- @param bgLevel number Background vocal mix 0.0-0.5
--- @return string|nil Path to the PCM file, or nil on failure
function prepare(videoId, audioUrl, bgLevel)
    karaoke:log("prepare() videoId=" .. videoId .. " bgLevel=" .. bgLevel)

    -- 0. Replay cache: a fully rendered stream from a previous play.
    local stream = karaoke:streamCache(videoId, bgLevel)
    if stream ~= "" then
        karaoke:log("stream cache HIT: " .. stream)
        karaoke:fireProgress(1.0, "Done")
        karaoke:fireFirstChunk(stream)
        karaoke:fireComplete(stream)
        return stream
    end

    -- Full-WAV cache (written by older full-song builds), if present.
    local cached = karaoke:cachedKaraoke(videoId, bgLevel)
    if cached ~= "" then
        karaoke:log("cache HIT: " .. cached)
        karaoke:fireProgress(1.0, "Done")
        karaoke:fireFirstChunk(cached)
        karaoke:fireComplete(cached)
        return cached
    end

    -- 1. Ensure model loaded.
    karaoke:fireProgress(0.05, "Loading AI model...")
    if not karaoke:ensureModel() then
        karaoke:logError("FAILED at ensureModel")
        return nil
    end
    if karaoke:shouldStop() then return nil end

    -- 2. Download audio.
    karaoke:fireProgress(0.10, "Downloading audio...")
    local audioPath = karaoke:downloadAudio(audioUrl, videoId)
    if audioPath == "" then
        karaoke:logError("FAILED at downloadAudio")
        return nil
    end
    karaoke:log("audio downloaded: " .. audioPath)
    if karaoke:shouldStop() then
        karaoke:deleteFile(audioPath)
        return nil
    end

    -- 3. Fresh growing PCM file for this render.
    local pcmPath = karaoke:cacheDir() .. "/" .. karaoke:streamKey(videoId, bgLevel)
    if not karaoke:createPcmFile(pcmPath) then
        karaoke:logError("FAILED at createPcmFile")
        return nil
    end

    -- 4. One continuous renderer; the decoder runs ahead on its own thread.
    karaoke:fireProgress(0.15, "Preparing AI engine...")
    local handle = karaoke:createStreamRenderer(audioPath)
    if handle == nil then
        karaoke:logError("FAILED at createStreamRenderer")
        return nil
    end
    if karaoke:shouldStop() then return nil end

    -- 5. Phase 1: render + append until there is enough audio to start.
    karaoke:fireProgress(0.20, "Removing vocals...")
    local frontier = karaoke:renderAppend(handle, pcmPath, FIRST_CHUNK_SECONDS * SAMPLE_RATE, bgLevel)
    if karaoke:shouldStop() then return nil end

    if frontier >= SAMPLE_RATE or karaoke:isStreamComplete(handle) then
        karaoke:log("first chunk ready: " .. string.format("%.1f", frontier / SAMPLE_RATE) .. "s")
        karaoke:fireProgress(0.50, "Starting playback...")
        karaoke:fireFirstChunk(pcmPath)
    else
        karaoke:logError("frontier too small: " .. frontier)
        return nil
    end

    -- 6. Phase 2: render the rest of the song, appending block by block.
    if not karaoke:isStreamComplete(handle) then
        karaoke:fireProgress(0.60, "Finishing song...")
        karaoke:renderAppend(handle, pcmPath, -1, bgLevel)
        if karaoke:shouldStop() then return nil end
    end

    if not karaoke:isStreamComplete(handle) then
        karaoke:logError("render did not complete")
        return nil
    end

    -- 7. Mark for instant replay, clean up, done.
    karaoke:markStreamComplete(videoId, bgLevel)
    karaoke:deleteFile(audioPath)
    karaoke:log("STREAMING COMPLETE: " .. pcmPath)
    karaoke:fireProgress(1.0, "Done")
    karaoke:fireComplete(pcmPath)
    return pcmPath
end
