extends RefCounted

## dot-npc's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed (an absent file reads as 1).
# 2: DotNpcInstance.seed, DotNpcSpawner.seed_base / seed_source / seed_for().
# 3: DotNpcProfiles, DotNpcDef.from_profile, DotNpcDef.extra and menu.
# 4: DotNpcProfiles.profile_schemas.
# 5: DotNpcLimbs, DotNpcGibs, DotNpcNetSync.limb_specs.
const LEVEL := 5
const OLDEST := 1
