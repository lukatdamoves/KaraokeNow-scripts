-- karaoke.lua v3 - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, WAV I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- v3: Full-song support. Phase 1+2 do 30s fast-start as before.
--     Phase 3 decodes the full song in background, renders it,
--     and swaps to the full version. The 30s file is NOT cached;
--     only the full song goes to cache.

local SAMPLE_RATE = 44100
local FIRST_CHUNK_SECONDS = 15
local FAST_START_SECONDS = 30

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
    -- OPTIMIZATION: Decode only 30s for fast startup (not the full song).
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

    -- Phase 2: render the rest of the 30s partial in the background.
    -- Write to a TEMP file (not cache) — the 30s version is just for fast startup.
    karaoke:fireProgress(0.50, "Finishing first part...")
    karaoke:log("Phase 2: rendering remaining partial (30s)...")
    karaoke:renderUntil(renderer, pcmLen - 1)
    if karaoke:shouldStop() then return nil end

    local out = karaoke:getOutput(renderer)
    karaoke:applyBackgroundVocal(out, pcm, bgLevel)
    local temp30Path = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-30s.wav"
    if not karaoke:writeWav(out, temp30Path) then
        karaoke:logError("failed to write 30s WAV")
        return nil
    end
    karaoke:deleteFile(partialPath)

    karaoke:log("30s version ready: " .. temp30Path)
    karaoke:fireProgress(0.70, "Loading full song...")
    karaoke:fireComplete(temp30Path)
    if karaoke:shouldStop() then return temp30Path end

    -- If first chunk never fired (very short audio?), fire now.
    if not firstChunkFired then
        karaoke:fireFirstChunk(temp30Path)
    end

    -- Phase 3: Full song in background.
    -- The 30s version is playing. Now decode the FULL song, render it,
    -- and swap to the full version. Only the full song goes to cache.
    karaoke:log("Phase 3: decoding full song in background...")
    local fullPcm = karaoke:decodeAudio(audioPath)
    if fullPcm == nil then
        karaoke:logError("FAILED at decodeAudio (full), keeping 30s version")
        return temp30Path
    end
    local fullLen = karaoke:pcmLength(fullPcm)
    karaoke:log("decoded full: " .. fullLen .. " samples (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s)")
    if karaoke:shouldStop() then return temp30Path end

    -- If the full song is barely longer than 30s, just keep the 30s version.
    if fullLen <= pcmLen + SAMPLE_RATE * 5 then
        karaoke:log("full song not much longer than 30s (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s), keeping 30s version")
        -- Promote the 30s to cache so we don't redo this next time.
        local key = karaoke:cacheKey(videoId, bgLevel)
        local cachePath = karaoke:cacheDir() .. "/" .. key
        karaoke:deleteFile(cachePath)
        -- Note: no rename API, so we leave the 30s temp file. Next run will redo Phase 3.
        -- This is a rare edge case (songs < 35s), acceptable.
        karaoke:fireProgress(1.0, "Done")
        return temp30Path
    end

    karaoke:fireProgress(0.80, "Removing vocals (full song)...")
    karaoke:log("Phase 3: rendering full song (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s)...")
    local fullRenderer = karaoke:createRenderer(fullPcm)
    
    -- Render progressively with progress updates.
    -- We render in chunks to give progress feedback and allow cancellation.
    local chunkSize = SAMPLE_RATE * 30  -- 30s chunks
    local rendered = 0
    while rendered < fullLen - 1 do
        if karaoke:shouldStop() then
            karaoke:log("Phase 3 cancelled, keeping 30s version")
            return temp30Path
        end
        local target = math.min(rendered + chunkSize, fullLen - 1)
        rendered = karaoke:renderUntil(fullRenderer, target)
        local progress = 0.80 + 0.15 * (rendered / fullLen)
        karaoke:fireProgress(progress, "Removing vocals (full song)... " .. string.format("%.0f", 100 * rendered / fullLen) .. "%")
        karaoke:log("Phase 3 progress: " .. string.format("%.1f", rendered / SAMPLE_RATE) .. "s / " .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s")
        if rendered >= fullLen - 1 then break end
    end

    local fullOut = karaoke:getOutput(fullRenderer)
    karaoke:applyBackgroundVocal(fullOut, fullPcm, bgLevel)
    
    -- Write to the cache key (this is the permanent full-song version).
    local key = karaoke:cacheKey(videoId, bgLevel)
    local cachePath = karaoke:cacheDir() .. "/" .. key
    karaoke:log("Phase 3: writing full song to cache: " .. cachePath)
    if not karaoke:writeWav(fullOut, cachePath) then
        karaoke:logError("failed to write full song WAV, keeping 30s version")
        return temp30Path
    end

    -- Clean up temp files.
    karaoke:deleteFile(temp30Path)
    karaoke:deleteFile(audioPath)

    karaoke:log("FULL SONG COMPLETE: " .. cachePath .. " (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s)")
    karaoke:fireProgress(1.0, "Done")
    karaoke:fireComplete(cachePath)

    return cachePath
end
