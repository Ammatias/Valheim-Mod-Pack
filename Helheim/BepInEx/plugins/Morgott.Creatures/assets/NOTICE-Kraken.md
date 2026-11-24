# vaettir_creatures_gpl (Kraken models)

`vaettir_creatures_gpl` is a Unity asset bundle with the Kraken creature of Vaettir (`VT_Kraken`): the kraken head and
tentacle meshes, skeleton and textures of **Elite Creatures Pack** 0.12.5 by MilkyTeam (Gerald Glasgow), licensed under the
GNU General Public License version 3 (`LICENSE-GPL-3.0.txt`, the pack's own licence file).

- Original work: <https://thunderstore.io/c/valheim/p/MilkyTeam/EliteCreaturesPack/>,
  source <https://github.com/geraldjglasgow/ValheimMods/tree/main/EliteCreaturesPack>
- Changes made for Vaettir (2026-10-23): head and six tentacles put together into one skinned model, triangles reduced to
  three levels of detail (15000 / 7500 / 3750), textures re-compressed (512 px), animation clips of our own added (swim,
  bite, tentacle lash, slam, hit, death; the original has no clips). No code of the pack is included.
- How it is built (preferred form for modification): `art/tools/build_creatures.ps1` with `art/creatures.json`
  (entry `Kraken`) and `unity/Assets/Editor/VaettirCreatureBuild.cs` in the Vaettir repository, from the pack's own
  bundles.

This bundle is a separate work shipped next to Vaettir (`Vaettir.dll` loads it at start, aggregation); it is
distributed under the GPL-3.0 on its own. Without it Vaettir runs without the Kraken.
