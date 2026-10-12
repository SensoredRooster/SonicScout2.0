# ArtTuneDB reference comparison

October 12, 2026. Read-only comparison; no installed audio devices, drivers, profiles or working ArtTuneDB files changed. The user reports the original installation, setup and playback worked well on the same system. That physical reference result is user-reported, not remeasured in this review.

Reference available locally: C:\Users\brand\OneDrive\Documents\ArtTuneDB-main\ArtTuneDB-stale. This contains the database/library and PowerShell installer; it does not contain the full ArtTuneKit application source or its relay engine. The original working mixer/relay and APO mode still need to be established.

## Confirmed code differences and failures

1. **Channel image destroyed by relay adaptation.** SonicPass ChannelAdaptingSampleProvider groups adjacent channels when reducing 8 to 2. Input [L,R,C,LFE,BL,BR,SL,SR] maps the first four entirely to left and last four entirely to right, averaging each group. A real-class impulse test found both front-left and front-right become stereo [0.25,0]. This is inappropriate for preserving processed binaural stereo; no arbitrary replacement/downmix has been shipped in this review. Evidence: channel-mapping-reproduction.txt.

2. **Routing architecture changed.** ArtTuneDB README describes Art Tune Unified Output as the cable capture endpoint consumed by the user's audio app. SonicScout passes the selected render endpoint ID directly to SonicPass; ResolveInput returns that endpoint, and the engine uses render loopback capture. No evidence yet establishes equivalence of this new path to the original working mixer/processing path.

3. **Game processing and headphone EQ have separate, incompletely coordinated configuration paths.** The installer seeds prehesuvi.txt/posthesuvi.txt/16chConfig.txt with comments, then config.txt includes those managed files. The C# profile path writes Documents/HAudioApp/active_profile.txt and EnsureApoLink appends its Include to config.txt; it does not invoke the PowerShell game-profile selector that populates the managed tune files. A selected headphone profile alone therefore does not prove the full game tune was activated.

4. **Device scope can be inherited incorrectly.** When both cable endpoint GUIDs exist, the initial config ends in the 16-channel Device section. EnsureApoLink appends the headphone-profile Include without its own Device selector. The Include can inherit that last endpoint scope instead of the intended 8-channel game route. The actual physical-PC config.txt is not in the support ZIP, so runtime scope remains to be inspected.

5. **Readiness messages overstate implemented behavior.** ProvisionSonicScoutRouteAsync discovers/selects an existing virtual endpoint but describes it as cloning the physical output. WriteSonicScoutBackgroundProfileAsync writes only comments, including a claim of proprietary processing being enabled. Successful file writing is not evidence that tuning runs. APO CONNECTED is based on the profile Include link, not measured APO processing or LFX/GFX mode.

6. **Latency is unmeasured.** Default render buffer selection is 100 ms, with a capture FIFO capacity of max(4*buffer,200) ms (400 ms at default) and subsequent conversion. Capacity is not measured latency; no queue-age ceiling/drop-to-live mechanism or end-to-end latency measurement establishes acceptable game response. The user's report of unacceptable delay remains a failed physical-PC audio test.

7. **Known asset files did not change.** BO7 V0 pre/post tune files and EAC_Default.wav are byte-identical between the local ArtTuneDB reference and SonicScout. This narrows the investigation toward activation, routing and relay implementation. It does not prove every library asset/profile is identical. BO7 V0 source headers warn that its chain is in development and not for production; selection labels should not imply all versions are production-ready.

8. **APO-mode equivalence remains unverified.** ArtTuneDB's installer/documentation explicitly leaves APO/mixer routing to the original guided/manual workflow. SonicScout's registration check confirms a DLL binding but not the intended LFX/GFX/SFX/MFX placement, original-APO preservation or audible processing. Do not force a mode on the user's system without recovering and testing the original route.

## Required repair and acceptance order

Recover the working original relay/mixer and APO configuration; reproduce that path in the QA environment. Define the processed channel format and preserve L/R without arbitrary averaging. Make one device-scoped authoritative processing chain for the selected game/version, headphone EQ and boost. Replace readiness claims with actual validation. Measure stable streaming, channel isolation and latency against a bypass baseline before packaging the graphical installer around it. Do not distribute this build to testers or ask the user to keep changing drivers/settings in place.

The original working mixer question was sent to the user while this review continued; its answer is pending. No new audio build was recommended in this comparison.
