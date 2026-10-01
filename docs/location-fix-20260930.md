# Browser location acquisition fix

The previous web path made one getCurrentPosition request and rejected a coarse first response immediately. The revised path uses a bounded high-accuracy watch with maximumAge zero, keeps the most accurate valid fresh result, stops early at 10 m, and stops after 20 seconds otherwise. Concurrent callers share acquisition. The watch is cancelled after completion; this is not background tracking.

Callers still enforce their accuracy requirements: account/weather context allows up to 10 km; boundary capture requires 25 m. Invalid or older-than-two-minute fixes are rejected. Errors now distinguish invalid values, coarse accuracy, stale data, permission denial and provider failure. Settings displays the actual error. Failed refresh preserves the prior stored fix. Boundary and Settings timestamps are compatible.

Focused Chrome diagnosis after the change obtained a 113 m fix, resolved South Africa, confirmed registration sync and displayed weather from Device location. Evidence: evidence/location-20260930/chrome-location.png. This does not establish physical walking accuracy.

The broader mapping/mini-app audit was stopped at the user's request. A four-corner 17.77 ha fixture farm was saved before that stop. Supplied icons are included in the PWA build. The temporary email-verification preview is implemented and enabled only in the isolated local QA realm; it has not been enabled in the public realm.
