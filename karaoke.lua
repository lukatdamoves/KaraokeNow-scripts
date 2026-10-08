-- karaoke.lua v8 - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, WAV I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- v8: Growing PCM streaming.
--     - Single growing raw PCM file (16-bit mono 44.1kHz, no header).
--     - Lua appends PCM data as chunks are rendered via karaoke:appendPcm().
--     - Kotlin reads via GrowingPcmDataSource (blocks briefly at EOF if not complete).
--     - Player sees one continuous audio stream. No chunk boundaries, no desync.
--     - onFirstChunk(pcmPath): fired after first chunk appended (player starts).
--     - onComplete(pcmPath): fired when full song done (player gets EOF).

local SAMPLE_RATE = 44100
local FIRST_CHUNK_SECONDS = 8
local FAST_START_SECONDS = 10
local STREAM_CHUNK_SECONDS = 10

--- Main entry point. Called from Kotlin.
--- @param videoId string YouTube video ID
--- @param audioUrl string Direct audio stream URL
--- @param bgLevel number Background vocal mix 0.0-0.5
--- @return string|nil Path to the PCM file, or nil on failure
function prepare(videoId, audioUrl, bgLevel)
    karaoke:log("prepare() videoId=" .. videoId .. " bgLevel=" .. bgLevel)

    -- 1. Check cache (full song WAV only, for non-streaming fallback).
    local cached = karaoke:cachedKaraoke(videoId, bgLevel)
    if cached ~= "" then
        karaoke:log("cache HIT (full song): " .. cached)
        karaoke:fireProgress(1.0, "Done")
        karaoke:fireFirstChunk(cached)
        karaoke:fireComplete(cached)
        return cached
    end

    -- 2. Ensure model loaded.
    karaoke:fireProgress(0.05, "Loading AI model...")
    if not karaoke:ensureModel() then
        karaoke:logError("FAILED at ensureModel")
        return nil
    end
    if karaoke:shouldStop() then return nil end

    -- 3. Download audio.
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

    -- 4. Create the growing PCM file.
    local pcmPath = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-stream.pcm"
    if not karaoke:createPcmFile(pcmPath) then
        karaoke:logError("FAILED at createPcmFile")
        return nil
    end
    karaoke:log("PCM file created: " .. pcmPath)

    -- 5. Decode 10s for fast startup.
    karaoke:fireProgress(0.15, "Decoding audio...")
    local pcm = karaoke:decodeAudioPartial(audioPath, FAST_START_SECONDS)
    if pcm == nil then
        karaoke:logError("FAILED at decodeAudioPartial")
        return nil
    end
    local pcmLen = karaoke:pcmLength(pcm)
    karaoke:log("decoded " .. pcmLen .. " samples (" .. string.format("%.1f", pcmLen / SAMPLE_RATE) .. "s) [partial]")
    if karaoke:shouldStop() then return nil end

    -- 6. Render first chunk and append to PCM file.
    karaoke:fireProgress(0.20, "Removing vocals...")
    local renderer = karaoke:createRenderer(pcm)
    local firstChunkSamples = math.min(FIRST_CHUNK_SECONDS * SAMPLE_RATE, pcmLen - 1)
    local frontier = karaoke:renderUntil(renderer, firstChunkSamples)
    if karaoke:shouldStop() then return nil end

    if frontier > SAMPLE_RATE * 2 then
        local out = karaoke:getOutput(renderer)
        local skipSamples = SAMPLE_RATE  -- Skip 1s (renderer fade-in)
        local chunk = karaoke:slice(out, frontier)
        -- Remove the 1s skip by slicing (we need offset support; for now use full)
        karaoke:applyBackgroundVocal(chunk, pcm, bgLevel)
        if karaoke:appendPcm(chunk, pcmPath) then
            karaoke:log("first chunk appended: " .. string.format("%.1f", frontier / SAMPLE_RATE) .. "s")
            karaoke:fireProgress(0.50, "Starting playback...")
            karaoke:fireFirstChunk(pcmPath)
        else
            karaoke:logError("failed to append first chunk PCM")
            return nil
        end
    else
        karaoke:logError("frontier too small: " .. frontier)
        return nil
    end
    if karaoke:shouldStop() then return nil end

    -- 7. Render the rest of the 10s and append the REMAINDER.
    -- Phase 1 appended up to `frontier` (8.88s). Now append from frontier to pcmLen (10s).
    karaoke:fireProgress(0.60, "Rendering 10s...")
    local frontierBefore = frontier
    karaoke:renderUntil(renderer, pcmLen - 1)
    if karaoke:shouldStop() then return nil end
    local out10 = karaoke:getOutput(renderer)
    karaoke:applyBackgroundVocal(out10, pcm, bgLevel)
    -- Slice the new samples (from frontierBefore to pcmLen) and append.
    local remainderLen = pcmLen - frontierBefore
    if remainderLen > 0 then
        local remainder = karaoke:sliceOffset(out10, frontierBefore, remainderLen)
        if karaoke:appendPcm(remainder, pcmPath) then
            karaoke:log("10s remainder appended: " .. string.format("%.1f", remainderLen / SAMPLE_RATE) .. "s")
        else
            karaoke:logError("failed to append 10s remainder")
        end
    end

    -- Free 10s buffers.
    pcm = nil
    renderer = nil
    collectgarbage("collect")

    -- 8. Stream 10s chunks: decode range, render, append PCM.
    -- Each chunk takes ~7s (decode 1.6s + render 5.9s).
    -- The player reads the growing file; no per-chunk callback needed.
    karaoke:log("Phase 3: streaming 10s chunks to PCM file...")
    local startSec = FAST_START_SECONDS
    local chunkNum = 2

    while true do
        if karaoke:shouldStop() then
            karaoke:log("Phase 3 cancelled")
            break
        end

        local decodeEnd = startSec + STREAM_CHUNK_SECONDS
        karaoke:log("Phase 3: decoding " .. startSec .. "s-" .. decodeEnd .. "s...")
        local segPcm = karaoke:decodeAudioRange(audioPath, startSec, decodeEnd)
        if segPcm == nil then
            karaoke:logError("Phase 3: decodeAudioRange failed at " .. startSec .. "s")
            break
        end
        local segLen = karaoke:pcmLength(segPcm)
        local segSecs = segLen / SAMPLE_RATE

        if segSecs < 2 then
            karaoke:log("Phase 3: reached end of song")
            break
        end

        -- Render the segment.
        karaoke:fireProgress(0.70, "Removing vocals... chunk " .. chunkNum)
        local segRenderer = karaoke:createRenderer(segPcm)
        karaoke:renderUntil(segRenderer, segLen - 1)
        if karaoke:shouldStop() then break end

        local segOut = karaoke:getOutput(segRenderer)
        karaoke:applyBackgroundVocal(segOut, segPcm, bgLevel)

        -- Append PCM to the growing file.
        if karaoke:appendPcm(segOut, pcmPath) then
            karaoke:log("Phase 3: chunk " .. chunkNum .. " appended (" .. string.format("%.1f", segSecs) .. "s)")
        else
            karaoke:logError("Phase 3: failed to append chunk " .. chunkNum)
            break
        end

        -- Free segment memory.
        segPcm = nil
        segRenderer = nil
        segOut = nil
        collectgarbage("collect")

        chunkNum = chunkNum + 1
        startSec = startSec + STREAM_CHUNK_SECONDS

        if segSecs < STREAM_CHUNK_SECONDS - 1 then
            karaoke:log("Phase 3: last chunk appended")
            break
        end
    end

    -- 9. Done. Signal EOF.
    karaoke:deleteFile(audioPath)
    karaoke:log("STREAMING COMPLETE: PCM file ready: " .. pcmPath)
    karaoke:fireProgress(1.0, "Done")
    karaoke:fireComplete(pcmPath)

    return pcmPath
end
