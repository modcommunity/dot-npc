extends RefCounted

## dot-npc's API level. The rule for bumping it is on [DotAddonApi].
## LEVEL rises for anything new a game could call; OLDEST rises when something callable is
## removed or changes meaning, since older packs no longer compile.

# 1: before this file existed (absent reads as 1). 2: DotNpcInstance.seed, DotNpcSpawner seed_base/seed_source/seed_for().
# 3: DotNpcProfiles, DotNpcDef.from_profile, DotNpcDef.extra and menu. 4: DotNpcProfiles.profile_schemas.
# 5: DotNpcLimbs, DotNpcGibs, DotNpcNetSync.limb_specs.
# 6: DotNpcInstance.blind_for/blind_until, DotNpcSenses sight blockers (add_sight_blocker).
const LEVEL := 6
const OLDEST := 1
