-- karaoke:lua - KaraokeNow vocal removal pipeline
-- This script orchestrates the karaoke preparation flow.
-- Heavy lifting (download, decode, AI inference, WAV I/O) is done by
-- the Kotlin bridge exposed as the global `karaoke`.
--
-- To update karaoke logic: edit this file, no app rebuild needed.
-- The app downloads the latest version on startup.

local SAMPLE_RATE = 44100
local FIRST_CHUNK_SECONDS = 15

--- Main entry point. Called from Kotlin.
--- @param videoId string YouTube video ID
--- @param audioUrl string Direct audio stream URL
--- @param bgLevel number Background vocal mix 0.0-0.5
--- @return string|nil Path to the full karaoke WAV, or nil on failure
function prepare(videoId, audioUrl, bgLevel)
    karaoke:log("prepare() videoId=" .. videoId .. " bgLevel=" .. bgLevel)

    -- 1. Check cache.
    local cached = karaoke:cachedKaraoke(videoId, bgLevel)
    if cached ~= "" then
        karaoke:log("cache HIT: " .. cached)
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

    -- 4. Decode to 44.1kHz mono PCM.
    karaoke:fireProgress(0.15, "Decoding audio...")
    local pcm = karaoke:decodeAudio(audioPath)
    if pcm == nil then
        karaoke:logError("FAILED at decodeAudio")
        return nil
    end
    local pcmLen = karaoke:pcmLength(pcm)
    karaoke:log("decoded " .. pcmLen .. " samples (" .. string.format("%.1f", pcmLen / SAMPLE_RATE) .. "s)")
    if karaoke:shouldStop() then return nil end

    -- 5. Progressive separation.
    karaoke:fireProgress(0.20, "Removing vocals...")
    local renderer = karaoke:createRenderer(pcm)

    -- Phase 1: render until we have the first chunk.
    local firstChunkSamples = math.min(FIRST_CHUNK_SECONDS * SAMPLE_RATE, pcmLen - 1)
    local frontier = karaoke:renderUntil(renderer, firstChunkSamples)
    if karaoke:shouldStop() then return nil end

    local firstChunkFired = false
    if frontier > SAMPLE_RATE * 2 then  -- need at least 2s
        local out = karaoke:getOutput(renderer)
        -- Skip first 1s (renderer fade-in), take up to frontier
        local skipSamples = SAMPLE_RATE  -- 1s
        local partialLen = frontier - skipSamples
        if partialLen > SAMPLE_RATE then
            -- Slice and shift: create a new handle with the solid portion
            local partial = karaoke:slice(out, frontier)
            -- Zero out the first second to avoid fade-in artifacts
            -- (we'll implement a proper trim in the bridge later)
            karaoke:applyBackgroundVocal(partial, pcm, bgLevel)
            local partialPath = karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-partial.wav"
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

    -- Phase 2: render the rest in the background.
    karaoke:fireProgress(0.80, "Finishing...")
    karaoke:renderUntil(renderer, pcmLen - 1)
    if karaoke:shouldStop() then return nil end

    -- Write the full WAV.
    local out = karaoke:getOutput(renderer)
    karaoke:applyBackgroundVocal(out, pcm, bgLevel)
    local key = karaoke:cacheKey(videoId, bgLevel)
    local outPath = karaoke:cacheDir() .. "/" .. key
    if not karaoke:writeWav(out, outPath) then
        karaoke:logError("failed to write full WAV")
        return nil
    end

    -- Clean up the partial file.
    karaoke:deleteFile(karaoke:cacheDir() .. "/" .. videoId .. "-karaoke-partial.wav")

    karaoke:log("COMPLETE: " .. outPath)
    karaoke:fireProgress(1.0, "Done")
    karaoke:fireComplete(outPath)

    -- If first chunk never fired (very short audio?), fire now.
    if not firstChunkFired then
        karaoke:fireFirstChunk(outPath)
    end

    return outPath
end
