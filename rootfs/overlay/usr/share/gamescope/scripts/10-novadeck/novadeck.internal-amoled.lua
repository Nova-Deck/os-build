-- Display profile for novadeck's internal AMOLED panels.
--
-- WHY ONE PROFILE FOR ALL OF THEM. Our panels carry no EDID; gamescope synthesizes a plain sRGB,
-- SDR one (packages/gamescope/patches/0038), and this profile is what tells it the truth. What a
-- profile carries is colorimetry, transfer function and peak luminance. The one value that
-- genuinely differs between our boards is the peak, and that is per-board data which already has
-- a home.
--
-- So the peak is NOT hardcoded here. It is read from NOVADECK_PANEL_HDR_NITS, which novadeck-session
-- exports from the device conf -- the same single fact that turns on the client's HDR toggle.
-- Adding an HDR board is therefore a one-line device conf change and no edit to this file, and
-- there is no second copy of the number to drift out of step.
--
-- Refresh rates are deliberately not declared: each connector's own kernel mode list is already
-- correct, and inventing a dynamic modegen risks generating timings the DSI link cannot drive.
--
-- Steam owns the HDR toggle at runtime. This only states what the panel can do.

local nits = tonumber(os.getenv("NOVADECK_PANEL_HDR_NITS") or "") or 0
local primary = os.getenv("NOVADECK_PRIMARY_CONNECTOR") or ""
-- Full-frame average: the device conf's NOVADECK_PANEL_HDR_FALL, else half the peak. An OLED dims
-- large bright areas, so the small-window peak is not a full-frame figure; armada profiles most of
-- these panels at half. A value above the peak is nonsense and falls back the same way.
local fall = tonumber(os.getenv("NOVADECK_PANEL_HDR_FALL") or "") or 0
if fall <= 0 or fall > nits then
    fall = math.floor(nits / 2 + 0.5)
end

-- Registering an hdr block with a bogus peak would be worse than registering nothing, so a board
-- that reaches this file without a usable peak gets no profile and stays SDR. From the session this
-- cannot trigger -- it only exports GAMESCOPE_INTERNAL_DEVICE_ID when the peak is non-zero -- but the
-- file is also read by anyone running gamescope by hand, and it should not invent a number for them.
if nits > 0 then
    gamescope.config.known_displays.novadeck_internal_amoled = {
        pretty_name = "novadeck internal AMOLED",
        -- ASSUMED, NOT MEASURED. Wide-gamut AMOLED primaries as characterised for this DDIC family
        -- by the upstream authors of the display-profile patch. Nobody has put a colorimeter on any
        -- of our panels. Still better than the alternative: the synthesized EDID declares sRGB, and
        -- telling gamescope a wide-gamut panel is sRGB makes HDR content visibly oversaturated.
        -- Symptom that this is wrong: skin tones and saturated reds look off in HDR while SDR looks
        -- fine. If one board ever needs its own primaries, give it a separate profile with a higher
        -- match priority rather than forking this one.
        colorimetry = {
            r = { x = 0.6800, y = 0.3200 },
            g = { x = 0.2650, y = 0.6900 },
            b = { x = 0.1500, y = 0.0600 },
            w = { x = 0.3127, y = 0.3290 },
        },
        hdr = {
            supported = true,
            -- Gamma 2.2, not PQ: these DSI panels take no HDR signalling, so gamescope encodes to
            -- the panel's native transfer function. On a DPU with per-plane colour pipelines
            -- (kernel 0394, 0398 on SM8250) each scanned-out layer gets that mapping in its own plane LUTs.
            eotf = gamescope.eotf.gamma22,
            max_content_light_level = nits,
            -- See `fall` above. Symptom of a figure that is too high: the panel visibly dims on
            -- large bright areas.
            max_frame_average_luminance = fall,
            min_content_light_level = 0.002,
        },
        matches = function(display)
            -- An internal panel with no PHYSICAL EDID, on a board that named itself. The session
            -- sets GAMESCOPE_INTERNAL_DEVICE_ID only for a board declaring a peak, so that check
            -- does the per-board gating and this file needs no board list.
            --
            -- The has_edid clause matters: if a panel revision ever ships a real EDID, that EDID
            -- should win rather than be overridden by these assumed numbers.
            if display.device_id == ""
                or not display.internal
                or display.has_edid then
                return -1
            end

            -- THE DUAL-SCREEN CLAUSE. On a dual-screen board both panels are internal and
            -- EDID-less, so without this the secondary would be told it is a wide-gamut HDR panel
            -- at the primary's peak. gamescope only scanning out --prefer-output is the happy
            -- path, not the only one: connector selection FALLS BACK when the preferred name is
            -- not found, and this project has already lit the wrong panel that way.
            --
            -- The connector name is read from the environment, so it stays a single fact in the
            -- device conf. Empty means the board lets gamescope auto-pick, so there is nothing to
            -- compare against and any internal EDID-less panel is accepted.
            if primary ~= "" and display.connector ~= primary then
                return -1
            end

            return 6000
        end,
    }
end
