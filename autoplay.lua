-- autoplay.lua: endless similar-track playback for cliamp.
--
-- When the queue is about to run out, autoplay asks Last.fm for tracks similar
-- to what is playing, finds each one on Spotify, and queues it, so the music
-- keeps going like Spotify's own autoplay.
--
-- Why Last.fm: Spotify removed /v1/recommendations and related-artists for
-- apps registered after 2024-11-27, so an own-client-id setup cannot ask
-- Spotify what is similar. Last.fm's track.getSimilar needs only a free API
-- key and covers regional catalogues well.
--
-- How it talks to cliamp: through the `cliamp remote call` CLI. Searching and
-- queueing both run inside the player, with its own Spotify login, so this
-- plugin never reads your credentials. (cliamp.queue.add() cannot queue
-- spotify: URIs, which is why it goes through the CLI.)
--
-- Setup, in ~/.config/cliamp/config.toml:
--
--   [plugins]
--   allowed_binaries = "cliamp"   # lets the plugin run `cliamp remote call`
--
--   [plugins.autoplay]
--   api_key = "..."   # free: https://www.last.fm/api/account/create
--   keep    = "5"     # top up when fewer than this many tracks remain
--   add     = "3"     # how many tracks to queue per top-up
--   enabled = "true"
--   binary  = "cliamp"  # full path if cliamp is not on the player's $PATH
--
-- Ctrl+T turns it on or off. Logs go to plugins.log in your cliamp config dir.

local p = plugin.register({
    name        = "autoplay",
    type        = "hook",
    version     = "1.2.0",
    description = "Endless similar-track playback via Last.fm, streamed from Spotify",
    permissions = { "keymap", "exec" },
})

-- p:config(key) returns a single string (or nil) — it is not a table getter.
local API_KEY = p:config("api_key") or ""
local KEEP    = tonumber(p:config("keep") or "5") or 5
local ADD     = tonumber(p:config("add") or "3") or 3
local enabled = (p:config("enabled") or "true") ~= "false"

local BINARY  = p:config("binary") or "cliamp"

-- A deadline, not a flag. The host hard-kills an event callback at 5s
-- (hookTimeout, luaplugin/hooks.go) and that kill can skip the line that
-- would clear a plain boolean, wedging autoplay off for the rest of the
-- session — which is exactly what "it worked a few times then stopped"
-- looked like. An expiring stamp self-heals no matter how the kill lands.
local busy_until = 0
local BUSY_TTL = 180 -- a round queues tracks one by one, ~10s each
-- Enqueues already fired but not yet landed. A track.queue call takes ~10s to
-- come back, while queue.change re-runs the check within a second, so without
-- counting these the plugin sees a queue that "still needs tracks" and fires
-- again, and again — the runaway that produced 7 rounds of duplicates in 8
-- seconds. Pending counts as queued for the purposes of deciding to top up.
local pending = 0
-- Floor between rounds, as a second guard for when a pending count leaks
-- (a killed callback that never runs on_exit, say).
local last_round = 0
local COOLDOWN = 12
-- When a round finds nothing new to add, back off hard instead of retrying
-- every COOLDOWN. A seed yields only ~9 Last.fm candidates, so a deep keep
-- target on a narrow catalogue can be unreachable — without this the plugin
-- would call Last.fm every 12s forever trying to close a gap it cannot.
local idle_until = 0
local IDLE_BACKOFF = 90

cliamp.log.info("autoplay: loaded (keep=" .. KEEP .. " add=" .. ADD ..
    " key=" .. (API_KEY ~= "" and "set" or "MISSING") .. ")")

-- ── helpers ──────────────────────────────────────────────────────────────

local function urlencode(s)
    s = tostring(s or ""):gsub("\n", "\r\n")
    return (s:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- cliamp reports joined credits such as "Calvin Harris, Dua Lipa". Last.fm
-- sometimes needs just the first name for those. It is only a fallback: many
-- real artist names contain a comma or "&" ("Earth, Wind & Fire", "Tyler, The
-- Creator", "Simon & Garfunkel"), and cutting those finds a different artist
-- or nothing. Callers try the full name first.
local function first_artist(a)
    a = tostring(a or "")
    local head = a:match("^(.-)%s*[,;&]") or a:match("^(.-)%s+feat%.") or a
    return (head:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function key_of(artist, title)
    return tostring(artist or ""):lower() .. "\t" .. tostring(title or ""):lower()
end

local function store_get(k, dflt)
    local v = cliamp.store.get(k)
    if v == nil then return dflt end
    return v
end

-- Recently played or queued, so suggestions don't repeat back-to-back.
--
-- Time-stamped, not a permanent set. A seed yields only ~9 Last.fm
-- candidates; remembering them forever means that seed can never suggest
-- anything again, which is how autoplay ended up with "0 added" and nothing
-- to play. An hour is long enough to not hear the same track twice in a
-- sitting and short enough that a narrow catalogue recovers.
local SEEN_TTL = 3600

local function mark_seen(artist, title)
    local seen = store_get("seen", {})
    local now = os.time()
    -- Prune expired entries on write; keeps the store bounded without the
    -- old "wipe everything at 500" cliff.
    for k, t in pairs(seen) do
        if type(t) ~= "number" or (now - t) > SEEN_TTL then seen[k] = nil end
    end
    seen[key_of(artist, title)] = now
    cliamp.store.set("seen", seen)
end

local function is_seen(artist, title)
    local t = store_get("seen", {})[key_of(artist, title)]
    -- Older versions stored `true`; treat anything non-numeric as expired.
    if type(t) ~= "number" then return false end
    return (os.time() - t) < SEEN_TTL
end

-- Undo a mark_seen when the enqueue it was optimistically recorded for turns
-- out to have failed. Without this, a run of failures silently burns through
-- the candidate pool and later rounds find nothing left to suggest.
local function unmark_seen(artist, title)
    local seen = store_get("seen", {})
    if seen[key_of(artist, title)] == nil then return end
    seen[key_of(artist, title)] = nil
    cliamp.store.set("seen", seen)
end

-- id -> "artist\ttitle" for tracks this plugin queued, so a URI-titled track
-- can still seed the next round.
local function remember(id, artist, title)
    local meta = store_get("meta", {})
    local n = 0
    for _ in pairs(meta) do n = n + 1 end
    if n > 500 then meta = {} end
    meta[id] = artist .. "\t" .. title
    cliamp.store.set("meta", meta)
end

local function recall(id)
    local v = store_get("meta", {})[id]
    if not v then return nil end
    local a, t = v:match("^(.-)\t(.*)$")
    return a, t
end

-- ── Last.fm ──────────────────────────────────────────────────────────────

local function similar(artist, title, limit)
    local url = "https://ws.audioscrobbler.com/2.0/"
        .. "?method=track.getsimilar&format=json&autocorrect=1"
        .. "&artist=" .. urlencode(artist)
        .. "&track="  .. urlencode(title)
        .. "&limit="  .. tostring(limit)
        .. "&api_key=" .. urlencode(API_KEY)

    -- The second result says whether Last.fm answered "not found" (error 6),
    -- which is the only case where retrying with a shorter artist name helps.
    -- A failed request says nothing about the name.
    local body, status = cliamp.http.get(url)
    if status ~= 200 or not body then
        cliamp.log.warn("autoplay: last.fm HTTP " .. tostring(status))
        return {}, false
    end
    local ok, d = pcall(cliamp.json.decode, body)
    if not ok or not d then return {}, false end
    if d.error then
        cliamp.log.warn("autoplay: last.fm error " .. tostring(d.error) .. " " .. tostring(d.message))
        return {}, tonumber(d.error) == 6
    end
    local list = d.similartracks and d.similartracks.track
    if not list then return {}, false end
    if list.name then list = { list } end

    local out = {}
    for _, t in ipairs(list) do
        local a = t.artist and t.artist.name
        if a and t.name then out[#out + 1] = { artist = a, title = t.name } end
    end
    return out
end

-- Regional and long-tail tracks often have no track.getSimilar data at all
-- (track.getSimilar often returns nothing for them). Fall back to similar
-- artists, then take each one's top tracks.
local function similar_by_artist(artist, limit)
    local function call(method, extra)
        local url = "https://ws.audioscrobbler.com/2.0/?method=" .. method
            .. "&format=json&autocorrect=1&artist=" .. urlencode(artist)
            .. (extra or "") .. "&api_key=" .. urlencode(API_KEY)
        local body, status = cliamp.http.get(url)
        if status ~= 200 or not body then return nil end
        local ok, d = pcall(cliamp.json.decode, body)
        return ok and d or nil
    end

    local d = call("artist.getsimilar", "&limit=6")
    local artists = {}
    local al = d and d.similarartists and d.similarartists.artist
    if al then
        if al.name then al = { al } end
        for _, a in ipairs(al) do
            if a.name then artists[#artists + 1] = a.name end
        end
    end
    -- Nothing similar? At least draw more from the same artist.
    if #artists == 0 then artists = { artist } end

    local out = {}
    for _, a in ipairs(artists) do
        if #out >= limit then break end
        local saved = artist
        artist = a
        local td = call("artist.gettoptracks", "&limit=4")
        artist = saved
        local tl = td and td.toptracks and td.toptracks.track
        if tl then
            if tl.name then tl = { tl } end
            for _, t in ipairs(tl) do
                if t.name then out[#out + 1] = { artist = a, title = t.name } end
            end
        end
    end
    return out
end

-- ── ranking ──────────────────────────────────────────────────────────────

-- Both similar() and similar_by_artist() return a flat list, but
-- similar_by_artist's is built depth-first: up to 4 tracks from similar
-- artist #1, then artist #2, and so on. Walking it in order and stopping at
-- ADD would take every top-up from artist #1, even though artist.getSimilar
-- returns plenty of other good artists.
--
-- diversify() regroups a flat candidate list by artist (order preserved
-- within each group) and interleaves — one track per artist per pass — so
-- the first ADD candidates are ADD different artists whenever that many
-- distinct artists exist at all. It works on the output of either tier
-- without either needing to know about grouping, since every candidate
-- already carries its own artist field. The seed artist's own group (which
-- only similar_by_artist's "nothing similar, draw from the same artist"
-- last resort produces) is demoted to last, so it only surfaces once every
-- other artist has had a turn.
--
-- This is deliberately NOT "never repeat an artist" — a repeat within a
-- batch is a normal radio pick and forcing zero repeats would throw away
-- good candidates on a seed with few distinct similar artists. The bug
-- avoided is specifically the whole batch coming from one artist when
-- other artists were available and simply never reached.
local function diversify(cands, seed_artist)
    local seed = tostring(seed_artist or ""):lower()
    local groups, index, seed_group = {}, {}, nil
    for _, c in ipairs(cands) do
        local k = tostring(c.artist):lower()
        local g = index[k]
        if not g then
            g = { artist = c.artist, tracks = {} }
            index[k] = g
            if k == seed then seed_group = g else groups[#groups + 1] = g end
        end
        g.tracks[#g.tracks + 1] = c.title
    end
    if seed_group then groups[#groups + 1] = seed_group end

    local out, pass = {}, 1
    while #out < #cands do
        local added = 0
        for _, g in ipairs(groups) do
            local title = g.tracks[pass]
            if title then
                out[#out + 1] = { artist = g.artist, title = title }
                added = added + 1
            end
        end
        if added == 0 then break end
        pass = pass + 1
    end
    return out
end

-- ── talking to cliamp ────────────────────────────────────────────────────

-- run_cli calls an IPC operation on the running player through the cliamp CLI
-- and hands done(ok, result) the finished job's result. It returns at once:
-- a call can take ~10s and the host kills event callbacks at 5s, so the
-- answer always arrives later, in on_exit.
local function run_cli(op, params, done)
    local out = {}
    local handle, err = cliamp.exec.run(BINARY,
        { "remote", "call", op, "--wait", "--params", cliamp.json.encode(params) }, {
        timeout = 30,
        on_stdout = function(line) out[#out + 1] = line end,
        on_stderr = function(line)
            if line and line ~= "" then
                cliamp.log.warn("autoplay: " .. op .. ": " .. tostring(line))
            end
        end,
        on_exit = function(code)
            if code ~= 0 then
                cliamp.log.error("autoplay: " .. op .. " exited " .. tostring(code))
                return done(false)
            end
            local ok, d = pcall(cliamp.json.decode, table.concat(out, "\n"))
            if not ok or not d or not d.ok or not d.job or d.job.state ~= "succeeded" then
                cliamp.log.error("autoplay: " .. op .. " did not succeed")
                return done(false)
            end
            done(true, d.job.result)
        end,
    })
    if not handle then
        cliamp.log.error("autoplay: cannot run " .. BINARY .. ": " .. tostring(err)
            .. " (add it to allowed_binaries under [plugins])")
        done(false)
    end
end

-- queue_candidates works through the ranked candidates one at a time: find
-- each on Spotify, queue the first match, and stop after ADD tracks. One
-- subprocess at a time keeps well under the host's per-plugin cap.
-- remaining is defined with the other queue helpers below; declared here so
-- the top-up can size itself.
local remaining

-- want is how many tracks this round should add: enough to bring the queue
-- back up to KEEP in one go, and never fewer than ADD. Topping up by a fixed
-- ADD needed two back-to-back rounds (and overshot) on an empty queue.
local function want_now()
    local rem = remaining and remaining() or 0
    return math.max(ADD, KEEP - rem)
end

local function queue_candidates(cands, want)
    local added, i = 0, 0
    pending = want

    local function finish()
        pending = 0
        busy_until = 0
        if added > 0 then
            idle_until = 0
            cliamp.message("Autoplay: queued " .. added .. " similar", 3)
            cliamp.log.info("autoplay: queued " .. added .. " tracks")
        else
            idle_until = os.time() + IDLE_BACKOFF
            cliamp.log.info("autoplay: nothing new to queue; backing off " .. IDLE_BACKOFF .. "s")
        end
    end

    local step
    step = function()
        if added >= want then return finish() end
        i = i + 1
        local c = cands[i]
        if not c then return finish() end
        if is_seen(c.artist, c.title) then return step() end
        mark_seen(c.artist, c.title)

        -- Double quotes would end the field filter early, so drop them.
        local function field(v) return (tostring(v):gsub('"', "")) end
        local query = 'artist:"' .. field(c.artist) .. '" track:"' .. field(c.title) .. '"'
        run_cli("provider.search", { provider = "spotify", query = query, limit = 1 }, function(ok, r)
            local t = ok and r and r.tracks and r.tracks[1]
            if not t or not t.path then return step() end
            run_cli("track.queue", {
                track = { path = t.path, title = t.title, artist = t.artist, album = t.album },
            }, function(qok)
                if qok then
                    local id = tostring(t.path):match("^spotify:track:(%w+)$")
                    if id then remember(id, t.artist or c.artist, t.title or c.title) end
                    added = added + 1
                    pending = math.max(0, want - added)
                else
                    unmark_seen(c.artist, c.title)
                end
                step()
            end)
        end)
    end
    step()
end

-- ── top-up ───────────────────────────────────────────────────────────────

-- top_up_body does the actual work; top_up (below) is the only caller and
-- guarantees busy is reset even if this errors or is cut off by the host's
-- hookTimeout, so one bad run can't wedge autoplay off for the rest of the
-- session (busy stuck true forever, silently no-oping every future call).
local function top_up_body(artist, title)
    artist = tostring(artist):gsub("^%s+", ""):gsub("%s+$", "")
    local short = first_artist(artist)
    cliamp.log.info("autoplay: seeding from " .. artist .. " — " .. title)

    -- Over-fetch: many suggestions won't resolve on Spotify or were played.
    -- Full artist name first; the cut-down name only if Last.fm had nothing.
    local want = want_now()
    local cands, unknown = similar(artist, title, want * 3)
    if #cands == 0 and unknown and short ~= artist then
        cands = similar(short, title, want * 3)
    end
    cliamp.log.info("autoplay: last.fm returned " .. #cands .. " candidates")

    -- Count how many are actually usable, not just how many came back. A
    -- seed whose whole candidate list was queued earlier is as useless as an
    -- empty one, and the artist path returns a different, wider pool — so
    -- fall through to it in both cases rather than adding nothing.
    local fresh = 0
    for _, c in ipairs(cands) do
        if not is_seen(c.artist, c.title) then fresh = fresh + 1 end
    end
    if fresh == 0 then
        cliamp.log.info("autoplay: no fresh track similarity (" .. #cands
            .. " candidates, all recent); falling back to similar artists")
        cands = similar_by_artist(artist, want * 2)
        if #cands == 0 and unknown and short ~= artist then
            cands = similar_by_artist(short, want * 2)
        end
        cliamp.log.info("autoplay: artist fallback returned " .. #cands .. " candidates")
    end
    if #cands == 0 then
        cliamp.message("Autoplay: no similar tracks found", 4)
        return
    end

    -- Round-robin by artist before consuming — see diversify() above. This is
    -- the fix for the "queues the same artist three times" bug.
    cands = diversify(cands, artist)

    -- No "allow repeats when everything is seen" escape hatch: queueing fires
    -- queue.change, which would re-run this and queue the same handful again.
    -- Adding nothing is right when there is nothing new; the next track
    -- change brings a fresh seed.
    queue_candidates(cands, want)
    return true
end

local function top_up(artist, title)
    if not enabled or os.time() < busy_until then return end
    if API_KEY == "" then return end
    if not artist or artist == "" or not title or title == "" then
        cliamp.log.warn("autoplay: no seed track available; skipping")
        return
    end

    busy_until = os.time() + BUSY_TTL
    local ok, started = pcall(top_up_body, artist, title)
    -- A started round clears busy itself when its last track is queued.
    if not (ok and started) then busy_until = 0 end
    if not ok then
        cliamp.log.error("autoplay: top_up aborted: " .. tostring(err))
    end
end

-- Work out what to seed from. A track this plugin queued has the bare URI as
-- its title and no artist, so fall back to what we recorded when queueing it.
local function seed_from(t)
    local artist = t and t.artist or ""
    local title  = t and t.title or ""
    local path   = (t and t.path) or title or ""

    local id = tostring(path):match("^spotify:track:(%w+)$")
    if id then
        local a, ti = recall(id)
        if a then return a, ti end
    end
    if artist ~= "" and title ~= "" and not tostring(title):match("^spotify:") then
        return artist, title
    end
    -- Last resort: whatever seeded the previous round.
    local last = store_get("last_seed", nil)
    if last then
        local a, ti = tostring(last):match("^(.-)\t(.*)$")
        if a and a ~= "" then return a, ti end
    end
    return nil, nil
end

remaining = function()
    local count = cliamp.queue.count() or 0
    local cur   = cliamp.queue.current() or 0
    return count - cur - 1
end

-- Whether a top-up is actually warranted. Counts in-flight enqueues as if
-- they had already landed: they take ~10s to appear while queue.change
-- re-runs this within a second, and ignoring them is what let the plugin
-- fire seven rounds of duplicates before the first one arrived.
local function needs_topup()
    local rem, now = remaining(), os.time()
    local why
    if pending > 0 and (rem + pending) >= KEEP then
        why = "enough in flight"
    elseif now < idle_until then
        why = "idle backoff " .. (idle_until - now) .. "s left"
    elseif now - last_round < COOLDOWN then
        why = "cooldown " .. (COOLDOWN - (now - last_round)) .. "s left"
    elseif (rem + pending) >= KEEP then
        why = "queue deep enough"
    end
    if why then
        cliamp.log.info("autoplay: skip top-up (" .. why .. "; remaining=" .. rem
            .. " pending=" .. pending .. " keep=" .. KEEP .. ")")
        return false
    end
    return true
end

-- ── wiring ───────────────────────────────────────────────────────────────

-- Event callbacks are hard-killed after 5 seconds (hookTimeout in
-- luaplugin/hooks.go). A top-up is a Last.fm call plus up to ADD Spotify
-- lookups and queue calls, which is far more than that. Timer callbacks
-- have no deadline, so every hook below only schedules and returns at once.
local function schedule(artist, title)
    if not enabled or os.time() < busy_until or API_KEY == "" then return end
    if not artist or artist == "" then return end
    -- On a player that reports radio sessions (cliamp.player.radio), only top
    -- up those: a loaded playlist already says what plays next. Without that
    -- API, autoplay tops up whenever the queue is about to run out.
    if cliamp.player.radio and not cliamp.player.radio() then
        cliamp.log.info("autoplay: skip top-up (not a radio context)")
        return
    end
    if not needs_topup() then return end
    last_round = os.time()
    cliamp.timer.after(0.1, function()
        local ok, err = pcall(top_up, artist, title)
        if not ok then
            busy_until = 0
            cliamp.log.error("autoplay: top_up failed: " .. tostring(err))
        end
    end)
end

p:on("track.change", function(t)
    if not enabled then return end
    local artist, title = seed_from(t)
    if artist then
        cliamp.store.set("last_seed", artist .. "\t" .. title)
        mark_seen(artist, title)
    end
    schedule(artist, title)
end)

p:on("queue.change", function(q)
    if not enabled then return end
    local count = tonumber(q and q.count) or 0
    if count > 0 then
        local artist, title = seed_from(nil)
        if artist then schedule(artist, title) end
    end
end)

p:bind("ctrl+t", "Toggle autoplay", function()
    enabled = not enabled
    cliamp.message("Autoplay " .. (enabled and "on" or "off"), 3)
    cliamp.log.info("autoplay: toggled " .. tostring(enabled))
    if enabled then
        local artist, title = seed_from(nil)
        schedule(artist, title)
    end
end)

p:on("app.start", function()
    cliamp.log.info("autoplay: app.start received")
    if API_KEY == "" then
        cliamp.log.warn("autoplay: no api_key in [plugins.autoplay]; idle")
    end
end)

-- Manual trigger, for debugging without waiting for the queue to run low:
--   cliamp plugins call autoplay test ["Artist" "Title"]
-- Commands need no permission and get a 5-minute budget, unlike the 5s hooks.
p:command("test", function(args)
    local a = args and args[1]
    local t = args and args[2]
    if not a then
        local last = store_get("last_seed", nil)
        if last then a, t = tostring(last):match("^(.-)\t(.*)$") end
    end
    if not a or a == "" then return "no seed: play something first, or pass artist and title" end
    busy_until = 0
    local ok, err = pcall(top_up, a, t)
    if not ok then
        busy_until = 0
        return "top_up error: " .. tostring(err)
    end
    return "started: tracks are queued over the next ~30s (see plugins.log)"
end)
