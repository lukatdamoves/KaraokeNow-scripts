-- karaoke.lua v4 - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, WAV I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- v4: Fast startup. Decode 10s (not 30s), render 2 windows (~8s),
--     start playing. Full song renders in background (Phase 3).
--     Like the Chrome extension: small chunks, continuous background work.

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

    -- Phase 3: Full song in background.
    -- The 10s version is playing. Now decode the FULL song, render it,
    -- and swap to the full version. Only the full song goes to cache.
    karaoke:log("Phase 3: decoding full song in background...")
    local fullPcm = karaoke:decodeAudio(audioPath)
    if fullPcm == nil then
        karaoke:logError("FAILED at decodeAudio (full), keeping 10s version")
        return temp10Path
    end
    local fullLen = karaoke:pcmLength(fullPcm)
    karaoke:log("decoded full: " .. fullLen .. " samples (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s)")
    if karaoke:shouldStop() then return temp10Path end

    -- If the full song is barely longer than 10s, just keep the 10s version.
    if fullLen <= pcmLen + SAMPLE_RATE * 5 then
        karaoke:log("full song not much longer than 10s (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s), keeping 10s version")
        local key = karaoke:cacheKey(videoId, bgLevel)
        local cachePath = karaoke:cacheDir() .. "/" .. key
        karaoke:deleteFile(cachePath)
        karaoke:fireProgress(1.0, "Done")
        return temp10Path
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
            karaoke:log("Phase 3 cancelled, keeping 10s version")
            return temp10Path
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
        karaoke:logError("failed to write full song WAV, keeping 10s version")
        return temp10Path
    end

    -- Clean up temp files.
    karaoke:deleteFile(temp10Path)
    karaoke:deleteFile(audioPath)

    karaoke:log("FULL SONG COMPLETE: " .. cachePath .. " (" .. string.format("%.1f", fullLen / SAMPLE_RATE) .. "s)")
    karaoke:fireProgress(1.0, "Done")
    karaoke:fireComplete(cachePath)

    return cachePath
end
