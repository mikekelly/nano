Delegated findings and briefs

## fix-low
Low: Ops.processes/0 double walk of Process.list/0; Registry.lookup ArgumentError when Registry down (whereis/resolve should return nil); StateStore.delete/1 skips seq for id-less entry.

## fix-m2
M2: suspended dashboard user blocks every live-render ~1s (Nano.User.call/2 timeout in Components.refresh_inbox/1). Fix non-blocking; test.

## fix-m3
M3: NanoAgent event/2 and append/2 right-append O(n) and never trim; halted agents queue pending forever. Make appends amortized O(1), bound pending; keep transcript API-valid.
