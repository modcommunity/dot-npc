extends RefCounted

## dot-npc's API level. The rule for bumping it is on [DotAddonApi].
## LEVEL rises for anything new a game could call; OLDEST rises when something callable is
## removed or changes meaning, since older packs no longer compile.

# 1: before this file existed. 2: DotNpcInstance.seed, spawner seed_base/seed_source/seed_for().
# 3: DotNpcProfiles, DotNpcDef.from_profile, extra, menu. 4: profile_schemas. 5: DotNpcLimbs, DotNpcGibs, limb_specs.
# 6: DotNpcInstance.blind_for/blind_until, add_sight_blocker. 7: DotNpcDrive, brain.drive, _npc_driven.
const LEVEL := 7
const OLDEST := 1
