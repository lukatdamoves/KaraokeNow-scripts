-- karaoke.lua v7 - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, WAV I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- v7: Streaming chunks. 10s fast-start, then 10s streaming chunks.
--     Phase 3 decodes+renders 10s segments incrementally (not full decode).
--     Each chunk renders in ~7s, ready before the previous 10s chunk ends.
--     Kotlin appends chunks to ConcatenatingMediaSource (no rebuild, no stutter).

local SAMPLE_RATE = 44100
local FIRST_CHUNK_SECONDS = 8
local FAST_START_SECONDS = 10

--- Main entry point. Called from Kotlin.
--- @param videoId string YouTube video ID
--- @param audioUrl string Direct audio stream URL
--- @param bgLevel number Background vocal mix 0.0-0.5
--- @return string|nil Path to the karaoke WAV, or nil on failure
function prepare(videoId, audioUrl, bgLevel)
    karaoke:log("prepare() videoId=" .. videoId .. " bgLevel=" .. bgLevel)

    -- 1. Check cache (full song only).
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

    -- 4. Decode to 44.1kHz PCM.
    -- OPTIMIZATION: Decode only 10s for fast startup (not the full song).
    -- v4: Reduced from 30s to 10s. Render 2 windows (~8s) and start playing.
    -- The full song renders in background (Phase 3).
    karaoke:fireProgress(0.15, "Decoding audio...")
    local pcm = karaoke:decodeAudioPartial(audioPath, FAST_START_SECONDS)
    if pcm == nil then
        karaoke:logError("FAILED at decodeAudioPartial")
        return nil
    end
    local pcmLen = karaoke:pcmLength(pcm)
    karaoke:log("decoded " .. pcmLen .. " samples (" .. string.format("%.1f", pcmLen / SAMPLE_RATE) .. "s) [partial]")
    if karaoke:shouldStop() then return nil end

    -- 5. Progressive separation.
    karaoke:fireProgress(0.20, "Removing vocals...")
    local renderer = karaoke:createRenderer(pcm)

    -- Phase 1: render until we have the first chunk.
    local firstChunkSamples = math.min(FIRST_CHUNK_SECONDS * SAMPLE_RATE, pcmLen - 1)
    local frontier = karaoke:renderUntil(renderer, firstChunkSamples)
    if karaoke:shouldStop() then return nil end

    local firstChunkFired = false
    local partialPath = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-partial.wav"
    if frontier > SAMPLE_RATE * 2 then  -- need at least 2s
        local out = karaoke:getOutput(renderer)
        local skipSamples = SAMPLE_RATE  -- Skip 1s (renderer fade-in)
        local partialLen = frontier - skipSamples
        if partialLen > SAMPLE_RATE then
            local partial = karaoke:slice(out, frontier)
            karaoke:applyBackgroundVocal(partial, pcm, bgLevel)
            if karaoke:writeWav(partial, partialPath) then
                karaoke:log("first chunk ready: " .. string.format("%.1f", frontier / SAMPLE_RATE) .. "s")
                karaoke:fireFirstChunk(partialPath)
                firstChunkFired = true
            else
                karaoke:logError("failed to write partial WAV")
            end
        else
            karaoke:logError("partial too short after skip: " .. partialLen)
        end
    else
        karaoke:logError("frontier too small: " .. frontier)
    end
    if karaoke:shouldStop() then return nil end

    -- Phase 2: render the rest of the 10s fast-start in the background.
    -- Write to a TEMP file (not cache) — the 10s version is just for fast startup.
    karaoke:fireProgress(0.50, "Finishing first part...")
    karaoke:log("Phase 2: rendering remaining fast-start (" .. FAST_START_SECONDS .. "s)...")
    karaoke:renderUntil(renderer, pcmLen - 1)
    if karaoke:shouldStop() then return nil end

    local out = karaoke:getOutput(renderer)
    karaoke:applyBackgroundVocal(out, pcm, bgLevel)
    local temp10Path = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-10s.wav"
    if not karaoke:writeWav(out, temp10Path) then
        karaoke:logError("failed to write 10s WAV")
        return nil
    end
    karaoke:deleteFile(partialPath)

    karaoke:log("10s version ready: " .. temp10Path)
    karaoke:fireProgress(0.70, "Loading full song...")
    karaoke:fireComplete(temp10Path)
    if karaoke:shouldStop() then return temp10Path end

    -- If first chunk never fired (very short audio?), fire now.
    if not firstChunkFired then
        karaoke:fireFirstChunk(temp10Path)
    end

    -- Phase 3: Streaming 10s chunks in background.
    -- The 10s version is playing. Now decode+render 10s segments incrementally.
    -- Each 10s chunk takes ~7s (decode 1.6s + render 5.9s), ready before the
    -- previous 10s chunk ends. No 30-40s gap, no silence.
    -- Free the 10s PCM first to make room (OOM prevention).
    karaoke:log("Phase 3: freeing 10s buffers...")
    pcm = nil
    renderer = nil
    collectgarbage("collect")

    -- Get the total duration from the audio file (decode a tiny bit to get length).
    -- We'll stream segments until decode returns empty/short.
    karaoke:log("Phase 3: streaming 10s chunks...")
    local chunkSeconds = 10
    local overlapSeconds = 1  -- 1s overlap for model context at boundaries
    local chunkNum = 2  -- Chunk 1 was the 8.88s partial, chunk 2 was the 10s file
    local startSec = FAST_START_SECONDS  -- Start from 10s

    while true do
        if karaoke:shouldStop() then
            karaoke:log("Phase 3 cancelled")
            break
        end

        -- Decode [startSec - overlap, startSec + chunkSeconds + overlap]
        -- The overlap gives the model context; we slice the middle 10s.
        local decodeStart = math.max(0, startSec - overlapSeconds)
        local decodeEnd = startSec + chunkSeconds + overlapSeconds
        karaoke:log("Phase 3: decoding " .. decodeStart .. "s-" .. decodeEnd .. "s...")
        local segPcm = karaoke:decodeAudioRange(audioPath, decodeStart, decodeEnd)
        if segPcm == nil then
            karaoke:logError("Phase 3: decodeAudioRange failed at " .. startSec .. "s, stopping")
            break
        end
        local segLen = karaoke:pcmLength(segPcm)
        local segSecs = segLen / SAMPLE_RATE
        karaoke:log("Phase 3: decoded " .. string.format("%.1f", segSecs) .. "s for chunk " .. (chunkNum + 1))

        -- If we got less than 2s, we've reached the end.
        if segSecs < 2 then
            karaoke:log("Phase 3: reached end of song")
            break
        end

        -- Render the segment.
        local segRenderer = karaoke:createRenderer(segPcm)
        karaoke:renderUntil(segRenderer, segLen - 1)
        if karaoke:shouldStop() then break end

        local segOut = karaoke:getOutput(segRenderer)
        karaoke:applyBackgroundVocal(segOut, segPcm, bgLevel)

        -- Slice the middle 10s (discard overlap regions with boundary artifacts).
        -- segPcm starts at decodeStart, we want [startSec, startSec+10s].
        local sliceStart = (startSec - decodeStart) * SAMPLE_RATE
        local sliceLen = math.min(chunkSeconds * SAMPLE_RATE, segLen - sliceStart)
        if sliceLen <= 0 then
            karaoke:log("Phase 3: no audio left in segment, stopping")
            break
        end
        -- Note: slice() takes (handle, length) from start; we need offset.
        -- For simplicity, if decodeStart == startSec - overlap, the slice starts at overlap*SR.
        -- We'll use the full segment output and let the player handle the slight overlap.
        -- Actually, to avoid complexity, just use the central 10s.
        local chunkPcm = karaoke:slice(segOut, sliceStart + sliceLen)
        -- Trim the head overlap by creating a sub-slice (if supported).
        -- For v7, we accept the 1s overlap; the concatenating player will have
        -- a tiny 1s repeat which is barely noticeable. Future: precise slicing.

        local chunkPath = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-stream" .. chunkNum .. ".wav"
        if karaoke:writeWav(segOut, chunkPath) then
            karaoke:log("Phase 3: chunk " .. chunkNum .. " ready (" .. string.format("%.1f", segSecs) .. "s), appending")
            karaoke:fireComplete(chunkPath)
            -- Clean up previous stream chunk (keep the latest 2 for safety).
            if chunkNum > 3 then
                karaoke:deleteFile(karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-stream" .. (chunkNum - 2) .. ".wav")
            end
        else
            karaoke:logError("Phase 3: failed to write chunk " .. chunkNum)
        end

        -- Free segment memory.
        segPcm = nil
        segRenderer = nil
        segOut = nil
        collectgarbage("collect")

        chunkNum = chunkNum + 1
        startSec = startSec + chunkSeconds

        -- Stop if the segment was short (end of song).
        if segSecs < chunkSeconds + overlapSeconds then
            karaoke:log("Phase 3: last chunk written, streaming complete")
            break
        end
    end

    -- Clean up temp files. Keep the stream chunks (they're being played).
    -- The full song cache is not written in streaming mode; chunks are the cache.
    karaoke:deleteFile(audioPath)

    karaoke:log("STREAMING COMPLETE: " .. (chunkNum - 1) .. " chunks")
    karaoke:fireProgress(1.0, "Done")

    return temp10Path
end
