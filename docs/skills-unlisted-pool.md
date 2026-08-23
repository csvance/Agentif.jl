# Skills: let the loader reach a registered skill the catalog does not name

`skill_loader` can currently only fetch what `<available_skills>` already listed, and its own
description says so. That makes the catalog a hard ceiling on the tool, and it forces a harness with
many skills into a bad trade. This adds a second, uncatalogued tier to `SkillRegistry` that the
loader resolves and no prompt pays for.

Backward compatible: a caller that never populates the new tier behaves exactly as before, and the
two-argument `SkillRegistry(skills, loaded)` form still constructs.

## The problem

A description is paid on every turn. A body is paid only when loaded. Measured on one harness with
28 bundles, a description averages about 620 characters, roughly 155 tokens, while bodies run 6 KB to
31 KB.

So a harness with a long tail of skills chooses between paying every description forever and making
those pages unreachable. Routing rules are how people usually resolve it, and the effect is that a
skill exists, is installed, is relevant, and cannot be loaded by the agent that needs it. The saving
is about 155 tokens per turn. The cost is the whole page. That asymmetry is the motivation.

Worth noting that the two halves are *already* decoupled in this codebase:
`build_available_skills_xml` takes its own `skills` argument and never consults a registry, and
`skill_loader(name::String)` has no enum, so the only gate on loading is `registry.skills`. A harness
could therefore already register more than it lists. Three things stop that from being a real answer,
and they are what this PR addresses:

1. **The tool tells the model not to.** "Must match a name from `<available_skills>` exactly." A
   model following its own tool description will not try a name it cannot see, so the capability is
   unusable even where it technically works.
2. **`reload_skills!` destroys it.** It calls `empty!(registry.skills)` and refills from `paths`, so
   any entry a harness merged in by hand disappears on the next reload, silently.
3. **It is a convention, not a contract.** Nothing names the two tiers, so nothing stops the next
   change from collapsing them.

## The change

`Agentif/src/skills.jl` only.

**`SkillRegistry` gains `pool::Dict{String, SkillMetadata}`**, the unlisted tier, plus a
two-argument constructor so existing positional callers are untouched. `skills_middleware` renders
`values(registry.skills)`, so the pool is excluded from `<available_skills>` with no middleware
change at all.

**`load_skill` resolves `skills`, then `pool`.** A name in both resolves to `skills`, matching the
precedence rule already used for path order in `discover_skills`: the more deliberate placement wins.

**`create_skill_registry` gains `pool_paths`**, and a bundle found under both is listed only, never
duplicated into the pool, so `pool` holds exactly the names no catalog will mention.

**`reload_skills!` gains `pool_paths`.** Omitted, it leaves the pool intact, which is what fixes
point 2 above; passed, it rebuilds it. Either way a name that has just become listed is dropped from
the pool.

**The loader tool's description is corrected**, which is the load-bearing half. It now says that
`<available_skills>` is not necessarily the whole set, that a harness may keep further skills
loadable but uncatalogued and is then expected to name them some other way, and that absence from
the catalog is not proof a skill does not exist. It also says not to guess names.

## The obligation this puts on the harness

The pool is only usable if the model can learn a pooled name, and nothing in the prompt will supply
one. The harness owes it some route, and an **index skill in the listed tier** is the natural form:
one description that names the tail and says what each page owns.

That is worth stating in the docs rather than leaving implicit, because a pool with no index is a
strictly worse configuration than no pool at all. In the harness this came from, the index costs 338
characters and stands in for 14,483.

This also reads as a continuation of the standard rather than a departure from it. Progressive
disclosure is already the skills model: metadata at startup, the body on activation, resources when
required. The pool extends the same idea one step earlier, to an index at startup and metadata on
activation, for harnesses whose tail is long enough that startup metadata is itself the cost.

## Tests

Four testsets in `Agentif/test/runtests.jl`, 18 assertions: the pool loads and stays out of the
rendered catalog, the loader tool reaches it and not just the direct call, listed-wins precedence and
dedup, that a reload without `pool_paths` does not empty the pool and one with it rebuilds, that the
two-argument constructor still works, and that a registry with no pool behaves as before.

**They have not been run in CI here.** This checkout cannot precompile `HTTP` (`Reseau` fails a TLS
handshake, "certificate has expired", valid range ending 2026-08-06), so the full suite does not
start for reasons unrelated to this change. I exercised `skills.jl` in isolation against stubs for
the four symbols it reaches outside itself, and all 18 pass. Please run the real suite before
merging.

## Not included

No change to `discover_skills`, `parse_skill_metadata`, the frontmatter parser, or
`build_available_skills_xml`. No new frontmatter field: the tier is decided by which path a bundle
was discovered under, not by anything written inside it, which keeps the same `SKILL.md` usable by
consumers that know nothing about pools.
