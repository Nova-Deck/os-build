-- Display profile for novadeck's internal AMOLED panels.
--
-- WHY ONE PROFILE FOR ALL OF THEM. The boards run three distinct panel_descs behind one chipone
-- ICNA35XX driver -- icna3512 (Pocket EVO, Pocket DS, Odin 2 Portal), icna3520 (Thor, Thor Lite),
-- and mangmi,pocket-max-panel (Pocket Max) -- which differ in physical size and mode list. None of
-- those differences are things a display profile carries. What a profile carries is colorimetry,
-- transfer function and peak luminance, and on that they agree: 1080x1920 wide-gamut AMOLED, no
-- hardware colour management, so gamma 2.2 rather than PQ. The one value that genuinely differs is
-- the peak, and that is per-board data which already has a home.
--
-- So the peak is NOT hardcoded here. It is read from NOVADECK_PANEL_HDR_NITS, which novadeck-session
-- exports from the device conf -- the same single fact that arms gamescope's HDR flags and the
-- client's HDR toggle. Adding an HDR board is therefore a one-line device conf change and no edit
-- to this file, and there is no second copy of the number to drift out of step.
--
-- Refresh rates are deliberately not declared: each connector's own kernel mode list is already
-- correct (60/120, or 60/90/120/144 on the Pocket Max), and inventing a dynamic modegen risks
-- generating timings the DSI link cannot drive.
--
-- Steam owns the HDR toggle at runtime. This only states what the panel can do.

local nits = tonumber(os.getenv("NOVADECK_PANEL_HDR_NITS") or "") or 0
local primary = os.getenv("NOVADECK_PRIMARY_CONNECTOR") or ""

-- Registering an hdr block with a bogus peak would be worse than registering nothing, so a board
-- that reaches this file without a usable peak simply gets no profile and stays SDR. In practice
-- this cannot trigger from the session -- it only exports GAMESCOPE_INTERNAL_DEVICE_ID when the
-- peak is non-zero, so an unmatched profile and an absent one look the same -- but the file is also
-- readable by anyone running gamescope by hand, and it should not invent a number for them.
if nits > 0 then
    gamescope.config.known_displays.novadeck_internal_amoled = {
        pretty_name = "novadeck internal AMOLED",
        -- ASSUMED, NOT MEASURED. Wide-gamut AMOLED primaries as characterised for this DDIC family
        -- by the upstream authors of the display-profile patch. Nobody has put a colorimeter on any
        -- of our panels. This is still much better than the alternative: the synthesized EDID
        -- declares plain sRGB, and telling gamescope a wide-gamut panel is sRGB makes HDR content
        -- visibly oversaturated. Symptom that this is wrong: skin tones and saturated reds look off
        -- in HDR while SDR looks fine. If one board ever needs its own primaries, give it a separate
        -- profile with a higher match priority rather than forking this one.
        colorimetry = {
            r = { x = 0.6800, y = 0.3200 },
            g = { x = 0.2650, y = 0.6900 },
            b = { x = 0.1500, y = 0.0600 },
            w = { x = 0.3127, y = 0.3290 },
        },
        hdr = {
            supported = true,
            -- Gamma 2.2, not PQ: the DPU has no hardware colour management, so gamescope composites
            -- HDR through the Vulkan path and encodes to the panel's native transfer function.
            eotf = gamescope.eotf.gamma22,
            max_content_light_level = nits,
            -- Same value as MaxCLL, matching how this DDIC family is profiled upstream. Note a
            -- vendor "peak" is usually a small-window figure, so a full-frame average is very likely
            -- optimistic here. Symptom: the panel visibly dims on large bright areas.
            max_frame_average_luminance = nits,
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

            -- THE DUAL-SCREEN CLAUSE. Three of the boards that declare a peak carry two panels --
            -- Thor and Thor Lite pair this AMOLED with a small ch13726a secondary, and the Pocket DS
            -- has its own lower panel -- and on all of them BOTH panels are internal and EDID-less.
            -- Without this check the secondary matches too and gets told it is a wide-gamut HDR
            -- panel at the primary's peak, which it is not.
            --
            -- It is not enough to say gamescope only scans out --prefer-output. That is the happy
            -- path, not the only one: connector selection FALLS BACK when the preferred name is not
            -- found, and this project has already lit the wrong panel that way -- the Thor Lite was
            -- configured DSI-2 by reasoning from the Thor, and gamescope duly brought up the small
            -- secondary while the main screen stayed black. In that state we would now also be
            -- feeding it HDR metadata belonging to a different panel.
            --
            -- The connector name is read from the environment, NOT hardcoded here, so it stays the
            -- single fact in the device conf -- the same treatment as the peak above. An empty value
            -- means the board lets gamescope auto-pick, so there is nothing to compare against and
            -- any internal EDID-less panel is accepted.
            if primary ~= "" and display.connector ~= primary then
                return -1
            end

            return 6000
        end,
    }
end
