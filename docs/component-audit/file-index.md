# File coverage index

Code-audit snapshot: 2026-09-25, base `2cfb859` plus the then-uncommitted work.
The file inventory includes the documentation reorganization and contribution
guide addition; it does not represent a new code audit. It lists every
present Git-visible tracked/untracked non-ignored repository file outside
`docs/component-audit/`. It excludes private `.local/`, dependency/build caches
and ignored intermediate assets. Binary assets are inventoried, not reviewed as
source code. A report assignment means coverage responsibility, not that every
branch was tested or every asset matches the original game. Feature status,
specific comments and pending tasks are in the linked reports. Shared behavior
may be discussed in more than one report; one primary owner is listed here.

**610 files indexed; 610 assigned; 0 unassigned.**

| Primary report | Files |
| --- | ---: |
| [App / gameplay / plugins](app-gameplay-and-plugins.md) | 60 |
| [Character / Maker / mods](character-and-mods.md) | 108 |
| [Studio / IK / animation](studio.md) | 89 |
| [Renderer / foundation / assets](renderer-and-foundation.md) | 283 |
| [Toolchain / verification / historical docs](toolchain-and-verification.md) | 70 |

| File role | Files |
| --- | ---: |
| App resource metadata / icon | 16 |
| Build / repository configuration | 5 |
| Conversion / recovery / verification tool | 80 |
| Documentation / historical evidence | 52 |
| Generated asset / catalog / fixture | 205 |
| Reference host / controlled fixture | 15 |
| Runtime / shared shader declaration | 137 |
| Test / validation | 100 |

## App / gameplay / plugins

Feature assessment: [app-gameplay-and-plugins.md](app-gameplay-and-plugins.md).

| File | Role |
| --- | --- |
| [Apps/IkkokuCreator/AppIcons.xcassets/AccentColor.colorset/Contents.json](../../Apps/IkkokuCreator/AppIcons.xcassets/AccentColor.colorset/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/AppIcons.xcassets/AppIcon.appiconset/Contents.json](../../Apps/IkkokuCreator/AppIcons.xcassets/AppIcon.appiconset/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/AppIcons.xcassets/Contents.json](../../Apps/IkkokuCreator/AppIcons.xcassets/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/AppState+OriginalFrameProbe.swift](../../Apps/IkkokuCreator/AppState+OriginalFrameProbe.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/AppState+PluginExecution.swift](../../Apps/IkkokuCreator/AppState+PluginExecution.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/AppState.swift](../../Apps/IkkokuCreator/AppState.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Assets.xcassets/AccentColor.colorset/Contents.json](../../Apps/IkkokuCreator/Assets.xcassets/AccentColor.colorset/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/Contents.json](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_128x128@1x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_128x128@1x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_16x16@1x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_16x16@1x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_256x256@1x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_256x256@1x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_32x32@1x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_32x32@1x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png](../../Apps/IkkokuCreator/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png) | App resource metadata / icon |
| [Apps/IkkokuCreator/Assets.xcassets/Contents.json](../../Apps/IkkokuCreator/Assets.xcassets/Contents.json) | App resource metadata / icon |
| [Apps/IkkokuCreator/ContentView.swift](../../Apps/IkkokuCreator/ContentView.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/EngineHost.swift](../../Apps/IkkokuCreator/EngineHost.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/IkkokuApp.swift](../../Apps/IkkokuCreator/IkkokuApp.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/ViewportView.swift](../../Apps/IkkokuCreator/ViewportView.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift](../../Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceFixedEventScheduler.swift](../../Packages/Engine/Sources/Gameplay/SourceFixedEventScheduler.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceIRProgram.swift](../../Packages/Engine/Sources/Gameplay/SourceIRProgram.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceMuteInBackgroundPlugin.swift](../../Packages/Engine/Sources/Gameplay/SourceMuteInBackgroundPlugin.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceNativePluginPackage.swift](../../Packages/Engine/Sources/Gameplay/SourceNativePluginPackage.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourcePluginPackage.swift](../../Packages/Engine/Sources/Gameplay/SourcePluginPackage.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourcePluginRuntime.swift](../../Packages/Engine/Sources/Gameplay/SourcePluginRuntime.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Gameplay/SourceTranslatedBehaviour.swift](../../Packages/Engine/Sources/Gameplay/SourceTranslatedBehaviour.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Tests/EngineTests/SourceGameplayCycleTests.swift](../../Packages/Engine/Tests/EngineTests/SourceGameplayCycleTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceGameplayExecutionTests.swift](../../Packages/Engine/Tests/EngineTests/SourceGameplayExecutionTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMuteInBackgroundTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMuteInBackgroundTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceNativePluginPackageTests.swift](../../Packages/Engine/Tests/EngineTests/SourceNativePluginPackageTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourcePluginRuntimeTests.swift](../../Packages/Engine/Tests/EngineTests/SourcePluginRuntimeTests.swift) | Test / validation |
| [Tools/reverse/analysis/accessory_names_oracle.py](../../Tools/reverse/analysis/accessory_names_oracle.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/gameplay_contract.py](../../Tools/reverse/analysis/gameplay_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/gameplay_execution_contract.py](../../Tools/reverse/analysis/gameplay_execution_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/mute_plugin_oracle.py](../../Tools/reverse/analysis/mute_plugin_oracle.py) | Conversion / recovery / verification tool |
| [Tools/reverse/fixtures/AccessoryNamesOracle/Host.cs](../../Tools/reverse/fixtures/AccessoryNamesOracle/Host.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/AccessoryNamesOracle/Program.cs](../../Tools/reverse/fixtures/AccessoryNamesOracle/Program.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/MutePluginOracle/Host.cs](../../Tools/reverse/fixtures/MutePluginOracle/Host.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/MutePluginOracle/Program.cs](../../Tools/reverse/fixtures/MutePluginOracle/Program.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/OriginalLifecycleProbe.cs](../../Tools/reverse/fixtures/OriginalLifecycleProbe.cs) | Reference host / controlled fixture |
| [Tools/reverse/original_lifecycle_probe.py](../../Tools/reverse/original_lifecycle_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/test_gameplay_contract.py](../../Tools/reverse/test_gameplay_contract.py) | Test / validation |
| [Tools/reverse/test_gameplay_execution_contract.py](../../Tools/reverse/test_gameplay_execution_contract.py) | Test / validation |
| [Tools/translation/fixtures/LifecycleFixture.cs](../../Tools/translation/fixtures/LifecycleFixture.cs) | Reference host / controlled fixture |
| [Tools/translation/fixtures/StudioMotionFixture.cs](../../Tools/translation/fixtures/StudioMotionFixture.cs) | Reference host / controlled fixture |
| [Tools/translation/frontend/Program.cs](../../Tools/translation/frontend/Program.cs) | Conversion / recovery / verification tool |
| [Tools/translation/frontend/Translation.csproj](../../Tools/translation/frontend/Translation.csproj) | Conversion / recovery / verification tool |
| [Tools/translation/frontend/UnitySurface.txt](../../Tools/translation/frontend/UnitySurface.txt) | Conversion / recovery / verification tool |
| [Tools/translation/native_adapters.py](../../Tools/translation/native_adapters.py) | Conversion / recovery / verification tool |
| [Tools/translation/plugin.py](../../Tools/translation/plugin.py) | Conversion / recovery / verification tool |
| [Tools/translation/studio_execution_probe.py](../../Tools/translation/studio_execution_probe.py) | Conversion / recovery / verification tool |
| [Tools/translation/tests/test_native_adapters.py](../../Tools/translation/tests/test_native_adapters.py) | Test / validation |
| [Tools/translation/tests/test_translation.py](../../Tools/translation/tests/test_translation.py) | Test / validation |
| [Tools/translation/translate.py](../../Tools/translation/translate.py) | Conversion / recovery / verification tool |

## Character / Maker / mods

Feature assessment: [character-and-mods.md](character-and-mods.md).

| File | Role |
| --- | --- |
| [Apps/IkkokuCreator/Maker/Controls.swift](../../Apps/IkkokuCreator/Maker/Controls.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Maker/MakerModel.swift](../../Apps/IkkokuCreator/Maker/MakerModel.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Maker/MakerPanels.swift](../../Apps/IkkokuCreator/Maker/MakerPanels.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Maker/MakerView.swift](../../Apps/IkkokuCreator/Maker/MakerView.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Maker/SourceRigPanel.swift](../../Apps/IkkokuCreator/Maker/SourceRigPanel.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/ModLibraryView.swift](../../Apps/IkkokuCreator/ModLibraryView.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/JSONValue.swift](../../Packages/Engine/Sources/Assets/JSONValue.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/SourceMessagePack.swift](../../Packages/Engine/Sources/Assets/SourceMessagePack.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/SourceModCatalog.swift](../../Packages/Engine/Sources/Assets/SourceModCatalog.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/SourceModPackage.swift](../../Packages/Engine/Sources/Assets/SourceModPackage.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/SourceModProfile.swift](../../Packages/Engine/Sources/Assets/SourceModProfile.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/AssetLibrary.swift](../../Packages/Engine/Sources/Character/AssetLibrary.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/BodyCoverage.swift](../../Packages/Engine/Sources/Character/BodyCoverage.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/CardIO.swift](../../Packages/Engine/Sources/Character/CardIO.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/Catalog.swift](../../Packages/Engine/Sources/Character/Catalog.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/CharacterCard.swift](../../Packages/Engine/Sources/Character/CharacterCard.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/CharacterInstance.swift](../../Packages/Engine/Sources/Character/CharacterInstance.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/HairDynamics.swift](../../Packages/Engine/Sources/Character/HairDynamics.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/LiveAnimation.swift](../../Packages/Engine/Sources/Character/LiveAnimation.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/Presets.swift](../../Packages/Engine/Sources/Character/Presets.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SliderRegistry.swift](../../Packages/Engine/Sources/Character/SliderRegistry.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceAnimation.swift](../../Packages/Engine/Sources/Character/SourceAnimation.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceAppearanceBindings.swift](../../Packages/Engine/Sources/Character/SourceAppearanceBindings.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceBodyShapeOperations.swift](../../Packages/Engine/Sources/Character/SourceBodyShapeOperations.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceBodyShapePose.swift](../../Packages/Engine/Sources/Character/SourceBodyShapePose.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceBoneModifiers.swift](../../Packages/Engine/Sources/Character/SourceBoneModifiers.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCardAppearance.swift](../../Packages/Engine/Sources/Character/SourceCardAppearance.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCardModReferences.swift](../../Packages/Engine/Sources/Character/SourceCardModReferences.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCardResolverDestinations.swift](../../Packages/Engine/Sources/Character/SourceCardResolverDestinations.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCardTokenDocument.swift](../../Packages/Engine/Sources/Character/SourceCardTokenDocument.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCharacterCard.swift](../../Packages/Engine/Sources/Character/SourceCharacterCard.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceCharacterCardEditing.swift](../../Packages/Engine/Sources/Character/SourceCharacterCardEditing.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceColorComposition.swift](../../Packages/Engine/Sources/Character/SourceColorComposition.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceDynamicBone.swift](../../Packages/Engine/Sources/Character/SourceDynamicBone.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceExpressionPlayback.swift](../../Packages/Engine/Sources/Character/SourceExpressionPlayback.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceExpressions.swift](../../Packages/Engine/Sources/Character/SourceExpressions.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceFaceShapePose.swift](../../Packages/Engine/Sources/Character/SourceFaceShapePose.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceMakerAssemblyOptions.swift](../../Packages/Engine/Sources/Character/SourceMakerAssemblyOptions.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceMakerLibrary.swift](../../Packages/Engine/Sources/Character/SourceMakerLibrary.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceMaterialCompositor.swift](../../Packages/Engine/Sources/Character/SourceMaterialCompositor.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourcePreviewAppearance.swift](../../Packages/Engine/Sources/Character/SourcePreviewAppearance.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceRigCustomization.swift](../../Packages/Engine/Sources/Character/SourceRigCustomization.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceRigPreview.swift](../../Packages/Engine/Sources/Character/SourceRigPreview.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceShapeChannels.swift](../../Packages/Engine/Sources/Character/SourceShapeChannels.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Character/SourceShapePoseBaseline.swift](../../Packages/Engine/Sources/Character/SourceShapePoseBaseline.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Tests/EngineTests/CharacterTests.swift](../../Packages/Engine/Tests/EngineTests/CharacterTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceAnimationTests.swift](../../Packages/Engine/Tests/EngineTests/SourceAnimationTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceAppearanceSafetyTests.swift](../../Packages/Engine/Tests/EngineTests/SourceAppearanceSafetyTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceBodyMaskTests.swift](../../Packages/Engine/Tests/EngineTests/SourceBodyMaskTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceBodyShapePoseTests.swift](../../Packages/Engine/Tests/EngineTests/SourceBodyShapePoseTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceBoneModifierTests.swift](../../Packages/Engine/Tests/EngineTests/SourceBoneModifierTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceCardAppearanceTests.swift](../../Packages/Engine/Tests/EngineTests/SourceCardAppearanceTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceCardModReferenceTests.swift](../../Packages/Engine/Tests/EngineTests/SourceCardModReferenceTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceCardResolverDestinationTests.swift](../../Packages/Engine/Tests/EngineTests/SourceCardResolverDestinationTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceCharacterCardEditingTests.swift](../../Packages/Engine/Tests/EngineTests/SourceCharacterCardEditingTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceCharacterCardTests.swift](../../Packages/Engine/Tests/EngineTests/SourceCharacterCardTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceColorCompositionTests.swift](../../Packages/Engine/Tests/EngineTests/SourceColorCompositionTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceExpressionPlaybackTests.swift](../../Packages/Engine/Tests/EngineTests/SourceExpressionPlaybackTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceExpressionTests.swift](../../Packages/Engine/Tests/EngineTests/SourceExpressionTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceFaceShapePoseTests.swift](../../Packages/Engine/Tests/EngineTests/SourceFaceShapePoseTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceIrisHighlightTests.swift](../../Packages/Engine/Tests/EngineTests/SourceIrisHighlightTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMakerAssemblyOptionsTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMakerAssemblyOptionsTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMakerLibraryTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMakerLibraryTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMaterialExpansionTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMaterialExpansionTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMessagePackTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMessagePackTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceModCatalogTests.swift](../../Packages/Engine/Tests/EngineTests/SourceModCatalogTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceModPackageTests.swift](../../Packages/Engine/Tests/EngineTests/SourceModPackageTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceModProfileTests.swift](../../Packages/Engine/Tests/EngineTests/SourceModProfileTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourcePreviewAppearanceTests.swift](../../Packages/Engine/Tests/EngineTests/SourcePreviewAppearanceTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceRigPreviewTests.swift](../../Packages/Engine/Tests/EngineTests/SourceRigPreviewTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceShapeChannelsTests.swift](../../Packages/Engine/Tests/EngineTests/SourceShapeChannelsTests.swift) | Test / validation |
| [Tools/mods/library.py](../../Tools/mods/library.py) | Conversion / recovery / verification tool |
| [Tools/mods/test_library.py](../../Tools/mods/test_library.py) | Test / validation |
| [Tools/mods/test_zipmod.py](../../Tools/mods/test_zipmod.py) | Test / validation |
| [Tools/mods/zipmod.py](../../Tools/mods/zipmod.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/abmx_contract.py](../../Tools/reverse/analysis/abmx_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/body_shape_contract.py](../../Tools/reverse/analysis/body_shape_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/card_contract.py](../../Tools/reverse/analysis/card_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/card_roundtrip.py](../../Tools/reverse/analysis/card_roundtrip.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/character_contracts.py](../../Tools/reverse/analysis/character_contracts.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/expression_contract.py](../../Tools/reverse/analysis/expression_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/maker_roundtrip.py](../../Tools/reverse/analysis/maker_roundtrip.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/mod_catalog_contract.py](../../Tools/reverse/analysis/mod_catalog_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/resolver_contract.py](../../Tools/reverse/analysis/resolver_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/build_preview_appearance.py](../../Tools/reverse/build_preview_appearance.py) | Conversion / recovery / verification tool |
| [Tools/reverse/card_appearance_bindings.py](../../Tools/reverse/card_appearance_bindings.py) | Conversion / recovery / verification tool |
| [Tools/reverse/clothed_material_contract.py](../../Tools/reverse/clothed_material_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/head_material_contract.py](../../Tools/reverse/head_material_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_assembly_variants.py](../../Tools/reverse/maker_assembly_variants.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_asset_library.py](../../Tools/reverse/maker_asset_library.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_asset_materials.py](../../Tools/reverse/maker_asset_materials.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_coverage.py](../../Tools/reverse/maker_coverage.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_material_contract.py](../../Tools/reverse/maker_material_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/maker_selection_fixture.py](../../Tools/reverse/maker_selection_fixture.py) | Conversion / recovery / verification tool |
| [Tools/reverse/male_avatar.py](../../Tools/reverse/male_avatar.py) | Conversion / recovery / verification tool |
| [Tools/reverse/test_abmx_contract.py](../../Tools/reverse/test_abmx_contract.py) | Test / validation |
| [Tools/reverse/test_card_appearance_bindings.py](../../Tools/reverse/test_card_appearance_bindings.py) | Test / validation |
| [Tools/reverse/test_card_contract.py](../../Tools/reverse/test_card_contract.py) | Test / validation |
| [Tools/reverse/test_card_roundtrip.py](../../Tools/reverse/test_card_roundtrip.py) | Test / validation |
| [Tools/reverse/test_clothed_material_contract.py](../../Tools/reverse/test_clothed_material_contract.py) | Test / validation |
| [Tools/reverse/test_face_rig_parity.py](../../Tools/reverse/test_face_rig_parity.py) | Test / validation |
| [Tools/reverse/test_head_material_contract.py](../../Tools/reverse/test_head_material_contract.py) | Test / validation |
| [Tools/reverse/test_maker_assembly_variants.py](../../Tools/reverse/test_maker_assembly_variants.py) | Test / validation |
| [Tools/reverse/test_maker_asset_library.py](../../Tools/reverse/test_maker_asset_library.py) | Test / validation |
| [Tools/reverse/test_maker_roundtrip.py](../../Tools/reverse/test_maker_roundtrip.py) | Test / validation |
| [Tools/reverse/test_male_avatar.py](../../Tools/reverse/test_male_avatar.py) | Test / validation |
| [Tools/reverse/test_male_body_parity.py](../../Tools/reverse/test_male_body_parity.py) | Test / validation |
| [Tools/reverse/test_resolver_contract.py](../../Tools/reverse/test_resolver_contract.py) | Test / validation |

## Studio / IK / animation

Feature assessment: [studio.md](studio.md).

| File | Role |
| --- | --- |
| [Apps/IkkokuCreator/Studio/StudioModel+Benchmark.swift](../../Apps/IkkokuCreator/Studio/StudioModel+Benchmark.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Studio/StudioModel+Plugins.swift](../../Apps/IkkokuCreator/Studio/StudioModel+Plugins.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Studio/StudioModel+Voice.swift](../../Apps/IkkokuCreator/Studio/StudioModel+Voice.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Studio/StudioModel.swift](../../Apps/IkkokuCreator/Studio/StudioModel.swift) | Runtime / shared shader declaration |
| [Apps/IkkokuCreator/Studio/StudioView.swift](../../Apps/IkkokuCreator/Studio/StudioView.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/IK.swift](../../Packages/Engine/Sources/Scene/IK.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/SourceTrigonometricIK.swift](../../Packages/Engine/Sources/Scene/SourceTrigonometricIK.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/Gizmo.swift](../../Packages/Engine/Sources/Studio/Gizmo.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/KoikatsuBinary.swift](../../Packages/Engine/Sources/Studio/KoikatsuBinary.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/KoikatsuLayoutImporter.swift](../../Packages/Engine/Sources/Studio/KoikatsuLayoutImporter.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/KoikatsuSceneRecordReader.swift](../../Packages/Engine/Sources/Studio/KoikatsuSceneRecordReader.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/KoikatsuSceneRecords.swift](../../Packages/Engine/Sources/Studio/KoikatsuSceneRecords.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/Poses.swift](../../Packages/Engine/Sources/Studio/Poses.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceFullBodyBiped.swift](../../Packages/Engine/Sources/Studio/SourceFullBodyBiped.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceSceneEditing.swift](../../Packages/Engine/Sources/Studio/SourceSceneEditing.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceSceneExportValidation.swift](../../Packages/Engine/Sources/Studio/SourceSceneExportValidation.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioAccessoryNamesPlugin.swift](../../Packages/Engine/Sources/Studio/SourceStudioAccessoryNamesPlugin.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioAnimation.swift](../../Packages/Engine/Sources/Studio/SourceStudioAnimation.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioAttachments.swift](../../Packages/Engine/Sources/Studio/SourceStudioAttachments.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioAudioBus.swift](../../Packages/Engine/Sources/Studio/SourceStudioAudioBus.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioCamera.swift](../../Packages/Engine/Sources/Studio/SourceStudioCamera.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioCharacterPreview.swift](../../Packages/Engine/Sources/Studio/SourceStudioCharacterPreview.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioDynamics.swift](../../Packages/Engine/Sources/Studio/SourceStudioDynamics.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioGuide.swift](../../Packages/Engine/Sources/Studio/SourceStudioGuide.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioIK.swift](../../Packages/Engine/Sources/Studio/SourceStudioIK.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioIKEditing.swift](../../Packages/Engine/Sources/Studio/SourceStudioIKEditing.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioPluginSession.swift](../../Packages/Engine/Sources/Studio/SourceStudioPluginSession.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioPluginWorld.swift](../../Packages/Engine/Sources/Studio/SourceStudioPluginWorld.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioPose.swift](../../Packages/Engine/Sources/Studio/SourceStudioPose.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/SourceStudioVoice.swift](../../Packages/Engine/Sources/Studio/SourceStudioVoice.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/StudioDocument.swift](../../Packages/Engine/Sources/Studio/StudioDocument.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Studio/Timeline.swift](../../Packages/Engine/Sources/Studio/Timeline.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Tests/EngineTests/KoikatsuBinaryTests.swift](../../Packages/Engine/Tests/EngineTests/KoikatsuBinaryTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/KoikatsuLayoutTests.swift](../../Packages/Engine/Tests/EngineTests/KoikatsuLayoutTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/KoikatsuSceneDocumentTests.swift](../../Packages/Engine/Tests/EngineTests/KoikatsuSceneDocumentTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceDynamicBoneParityTests.swift](../../Packages/Engine/Tests/EngineTests/SourceDynamicBoneParityTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceDynamicBoneTests.swift](../../Packages/Engine/Tests/EngineTests/SourceDynamicBoneTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceFullBodyBipedTests.swift](../../Packages/Engine/Tests/EngineTests/SourceFullBodyBipedTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceOriginalAnimatorTests.swift](../../Packages/Engine/Tests/EngineTests/SourceOriginalAnimatorTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceSceneEditingTests.swift](../../Packages/Engine/Tests/EngineTests/SourceSceneEditingTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceSceneExportValidationTests.swift](../../Packages/Engine/Tests/EngineTests/SourceSceneExportValidationTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioAccessoryNamesTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioAccessoryNamesTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioAnimationTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioAnimationTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioCharacterPreviewTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioCharacterPreviewTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioDynamicsTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioDynamicsTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioExpansionTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioExpansionTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioGuideTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioGuideTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioIKEditingTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioIKEditingTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioIKTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioIKTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioPoseTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioPoseTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioRoundtripTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioRoundtripTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceStudioVoiceTests.swift](../../Packages/Engine/Tests/EngineTests/SourceStudioVoiceTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceTrigonometricIKTests.swift](../../Packages/Engine/Tests/EngineTests/SourceTrigonometricIKTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/StudioHierarchyTests.swift](../../Packages/Engine/Tests/EngineTests/StudioHierarchyTests.swift) | Test / validation |
| [Tools/reverse/analysis/animation_playback_contract.py](../../Tools/reverse/analysis/animation_playback_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/dynamics_reference.py](../../Tools/reverse/analysis/dynamics_reference.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/original_animation_reference.py](../../Tools/reverse/analysis/original_animation_reference.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/scene_editing_oracle.py](../../Tools/reverse/analysis/scene_editing_oracle.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/studio_animation_contract.py](../../Tools/reverse/analysis/studio_animation_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/studio_fullbody_oracle.py](../../Tools/reverse/analysis/studio_fullbody_oracle.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/studio_ik_bindings.py](../../Tools/reverse/analysis/studio_ik_bindings.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/studio_pose_contract.py](../../Tools/reverse/analysis/studio_pose_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/studio_scene_contract.py](../../Tools/reverse/analysis/studio_scene_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/test_animation_playback_contract.py](../../Tools/reverse/analysis/test_animation_playback_contract.py) | Test / validation |
| [Tools/reverse/analysis/test_dynamics_reference.py](../../Tools/reverse/analysis/test_dynamics_reference.py) | Test / validation |
| [Tools/reverse/analysis/trigonometric_ik_contract.py](../../Tools/reverse/analysis/trigonometric_ik_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/animation_assets.py](../../Tools/reverse/animation_assets.py) | Conversion / recovery / verification tool |
| [Tools/reverse/compare_dynamics_probe.py](../../Tools/reverse/compare_dynamics_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/dynamics_contract.py](../../Tools/reverse/dynamics_contract.py) | Conversion / recovery / verification tool |
| [Tools/reverse/fixtures/FinalIKOracle/Program.cs](../../Tools/reverse/fixtures/FinalIKOracle/Program.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/FinalIKOracle/RecoverySurface.cs](../../Tools/reverse/fixtures/FinalIKOracle/RecoverySurface.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/FinalIKOracle/UnityShim.cs](../../Tools/reverse/fixtures/FinalIKOracle/UnityShim.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/OriginalAnimationProbe.cs](../../Tools/reverse/fixtures/OriginalAnimationProbe.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/OriginalDynamicsProbe.cs](../../Tools/reverse/fixtures/OriginalDynamicsProbe.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/dynamics-reference.json](../../Tools/reverse/fixtures/dynamics-reference.json) | Reference host / controlled fixture |
| [Tools/reverse/original_animation_probe.py](../../Tools/reverse/original_animation_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/original_dynamics_probe.py](../../Tools/reverse/original_dynamics_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/studio_animation.py](../../Tools/reverse/studio_animation.py) | Conversion / recovery / verification tool |
| [Tools/reverse/studio_attachments.py](../../Tools/reverse/studio_attachments.py) | Conversion / recovery / verification tool |
| [Tools/reverse/studio_dynamics_fixture.py](../../Tools/reverse/studio_dynamics_fixture.py) | Conversion / recovery / verification tool |
| [Tools/reverse/studio_selection_fixture.py](../../Tools/reverse/studio_selection_fixture.py) | Conversion / recovery / verification tool |
| [Tools/reverse/studio_voice.py](../../Tools/reverse/studio_voice.py) | Conversion / recovery / verification tool |
| [Tools/reverse/test_animation_assets.py](../../Tools/reverse/test_animation_assets.py) | Test / validation |
| [Tools/reverse/test_compare_dynamics_probe.py](../../Tools/reverse/test_compare_dynamics_probe.py) | Test / validation |
| [Tools/reverse/test_dynamics_contract.py](../../Tools/reverse/test_dynamics_contract.py) | Test / validation |
| [Tools/reverse/test_studio_animation.py](../../Tools/reverse/test_studio_animation.py) | Test / validation |
| [Tools/reverse/test_studio_pose_contract.py](../../Tools/reverse/test_studio_pose_contract.py) | Test / validation |
| [Tools/reverse/test_studio_scene_contract.py](../../Tools/reverse/test_studio_scene_contract.py) | Test / validation |
| [Tools/reverse/test_trigonometric_ik_contract.py](../../Tools/reverse/test_trigonometric_ik_contract.py) | Test / validation |

## Renderer / foundation / assets

Feature assessment: [renderer-and-foundation.md](renderer-and-foundation.md).

| File | Role |
| --- | --- |
| [Assets/Accessories/acc_bag.glb](../../Assets/Accessories/acc_bag.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_cat_ears.glb](../../Assets/Accessories/acc_cat_ears.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_glasses.glb](../../Assets/Accessories/acc_glasses.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_hairpin.glb](../../Assets/Accessories/acc_hairpin.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_hat_beret.glb](../../Assets/Accessories/acc_hat_beret.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_headband.glb](../../Assets/Accessories/acc_headband.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_necklace.glb](../../Assets/Accessories/acc_necklace.glb) | Generated asset / catalog / fixture |
| [Assets/Accessories/acc_ribbon.glb](../../Assets/Accessories/acc_ribbon.glb) | Generated asset / catalog / fixture |
| [Assets/Characters/body_f.glb](../../Assets/Characters/body_f.glb) | Generated asset / catalog / fixture |
| [Assets/Characters/body_m.glb](../../Assets/Characters/body_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_jeans.glb](../../Assets/Clothes/bottom_jeans.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_jeans_bm.png](../../Assets/Clothes/bottom_jeans_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_jeans_cm.png](../../Assets/Clothes/bottom_jeans_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_shorts.glb](../../Assets/Clothes/bottom_shorts.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_shorts_bm.png](../../Assets/Clothes/bottom_shorts_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_shorts_cm.png](../../Assets/Clothes/bottom_shorts_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_skirt_pleated.glb](../../Assets/Clothes/bottom_skirt_pleated.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_skirt_pleated_bm.png](../../Assets/Clothes/bottom_skirt_pleated_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_skirt_pleated_cm.png](../../Assets/Clothes/bottom_skirt_pleated_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_trousers_m.glb](../../Assets/Clothes/bottom_trousers_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_trousers_m_bm.png](../../Assets/Clothes/bottom_trousers_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bottom_trousers_m_cm.png](../../Assets/Clothes/bottom_trousers_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bra_plain.glb](../../Assets/Clothes/bra_plain.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/bra_plain_bm.png](../../Assets/Clothes/bra_plain_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/bra_plain_cm.png](../../Assets/Clothes/bra_plain_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short.glb](../../Assets/Clothes/gloves_short.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short_bm.png](../../Assets/Clothes/gloves_short_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short_cm.png](../../Assets/Clothes/gloves_short_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short_m.glb](../../Assets/Clothes/gloves_short_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short_m_bm.png](../../Assets/Clothes/gloves_short_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/gloves_short_m_cm.png](../../Assets/Clothes/gloves_short_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/pantyhose_black.glb](../../Assets/Clothes/pantyhose_black.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/pantyhose_black_bm.png](../../Assets/Clothes/pantyhose_black_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/pantyhose_black_cm.png](../../Assets/Clothes/pantyhose_black_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers.glb](../../Assets/Clothes/shoes_in_loafers.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers_bm.png](../../Assets/Clothes/shoes_in_loafers_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers_cm.png](../../Assets/Clothes/shoes_in_loafers_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers_m.glb](../../Assets/Clothes/shoes_in_loafers_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers_m_bm.png](../../Assets/Clothes/shoes_in_loafers_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_in_loafers_m_cm.png](../../Assets/Clothes/shoes_in_loafers_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers.glb](../../Assets/Clothes/shoes_out_sneakers.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers_bm.png](../../Assets/Clothes/shoes_out_sneakers_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers_cm.png](../../Assets/Clothes/shoes_out_sneakers_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers_m.glb](../../Assets/Clothes/shoes_out_sneakers_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers_m_bm.png](../../Assets/Clothes/shoes_out_sneakers_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/shoes_out_sneakers_m_cm.png](../../Assets/Clothes/shoes_out_sneakers_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle.glb](../../Assets/Clothes/socks_ankle.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle_bm.png](../../Assets/Clothes/socks_ankle_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle_cm.png](../../Assets/Clothes/socks_ankle_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle_m.glb](../../Assets/Clothes/socks_ankle_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle_m_bm.png](../../Assets/Clothes/socks_ankle_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_ankle_m_cm.png](../../Assets/Clothes/socks_ankle_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee.glb](../../Assets/Clothes/socks_knee.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee_bm.png](../../Assets/Clothes/socks_knee_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee_cm.png](../../Assets/Clothes/socks_knee_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee_m.glb](../../Assets/Clothes/socks_knee_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee_m_bm.png](../../Assets/Clothes/socks_knee_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/socks_knee_m_cm.png](../../Assets/Clothes/socks_knee_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_blazer.glb](../../Assets/Clothes/top_blazer.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_blazer_bm.png](../../Assets/Clothes/top_blazer_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_blazer_cm.png](../../Assets/Clothes/top_blazer_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_croptop.glb](../../Assets/Clothes/top_croptop.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_croptop_bm.png](../../Assets/Clothes/top_croptop_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_croptop_cm.png](../../Assets/Clothes/top_croptop_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_dress_camisole.glb](../../Assets/Clothes/top_dress_camisole.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_dress_camisole_bm.png](../../Assets/Clothes/top_dress_camisole_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_dress_camisole_cm.png](../../Assets/Clothes/top_dress_camisole_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_sailor.glb](../../Assets/Clothes/top_sailor.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_sailor_bm.png](../../Assets/Clothes/top_sailor_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_sailor_cm.png](../../Assets/Clothes/top_sailor_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_shirt_m.glb](../../Assets/Clothes/top_shirt_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_shirt_m_bm.png](../../Assets/Clothes/top_shirt_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_shirt_m_cm.png](../../Assets/Clothes/top_shirt_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_tshirt.glb](../../Assets/Clothes/top_tshirt.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_tshirt_bm.png](../../Assets/Clothes/top_tshirt_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/top_tshirt_cm.png](../../Assets/Clothes/top_tshirt_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain.glb](../../Assets/Clothes/underwear_plain.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain_bm.png](../../Assets/Clothes/underwear_plain_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain_cm.png](../../Assets/Clothes/underwear_plain_cm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain_m.glb](../../Assets/Clothes/underwear_plain_m.glb) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain_m_bm.png](../../Assets/Clothes/underwear_plain_m_bm.png) | Generated asset / catalog / fixture |
| [Assets/Clothes/underwear_plain_m_cm.png](../../Assets/Clothes/underwear_plain_m_cm.png) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_bob.glb](../../Assets/Hair/hair_bob.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_long_straight.glb](../../Assets/Hair/hair_long_straight.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_messy_m.glb](../../Assets/Hair/hair_messy_m.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_afro01.glb](../../Assets/Hair/hair_mh_afro01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_bob01.glb](../../Assets/Hair/hair_mh_bob01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_bob02.glb](../../Assets/Hair/hair_mh_bob02.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_braid01.glb](../../Assets/Hair/hair_mh_braid01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_long01.glb](../../Assets/Hair/hair_mh_long01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_ponytail01.glb](../../Assets/Hair/hair_mh_ponytail01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_short01.glb](../../Assets/Hair/hair_mh_short01.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_short02.glb](../../Assets/Hair/hair_mh_short02.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_short03.glb](../../Assets/Hair/hair_mh_short03.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_mh_short04.glb](../../Assets/Hair/hair_mh_short04.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_ponytail.glb](../../Assets/Hair/hair_ponytail.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_short_m.glb](../../Assets/Hair/hair_short_m.glb) | Generated asset / catalog / fixture |
| [Assets/Hair/hair_twintails.glb](../../Assets/Hair/hair_twintails.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_bed.glb](../../Assets/Items/item_bed.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_chair.glb](../../Assets/Items/item_chair.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_cube.glb](../../Assets/Items/item_cube.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_cylinder.glb](../../Assets/Items/item_cylinder.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_desk.glb](../../Assets/Items/item_desk.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_plane.glb](../../Assets/Items/item_plane.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_room_bedroom.glb](../../Assets/Items/item_room_bedroom.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_room_classroom.glb](../../Assets/Items/item_room_classroom.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_room_street.glb](../../Assets/Items/item_room_street.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_sky_dome.glb](../../Assets/Items/item_sky_dome.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_sofa.glb](../../Assets/Items/item_sofa.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_sphere.glb](../../Assets/Items/item_sphere.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_stairs.glb](../../Assets/Items/item_stairs.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_table.glb](../../Assets/Items/item_table.glb) | Generated asset / catalog / fixture |
| [Assets/Items/item_torus.glb](../../Assets/Items/item_torus.glb) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_highlight_0.png](../../Assets/Textures/eye_highlight_0.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_highlight_1.png](../../Assets/Textures/eye_highlight_1.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_highlight_2.png](../../Assets/Textures/eye_highlight_2.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_iris_0.png](../../Assets/Textures/eye_iris_0.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_iris_1.png](../../Assets/Textures/eye_iris_1.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_iris_2.png](../../Assets/Textures/eye_iris_2.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eye_white.png](../../Assets/Textures/eye_white.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eyebrow_0.png](../../Assets/Textures/eyebrow_0.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eyebrow_1.png](../../Assets/Textures/eyebrow_1.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eyelash_0.png](../../Assets/Textures/eyelash_0.png) | Generated asset / catalog / fixture |
| [Assets/Textures/eyelash_1.png](../../Assets/Textures/eyelash_1.png) | Generated asset / catalog / fixture |
| [Assets/Textures/face_overlay_blush.png](../../Assets/Textures/face_overlay_blush.png) | Generated asset / catalog / fixture |
| [Assets/Textures/face_overlay_eyeshadow.png](../../Assets/Textures/face_overlay_eyeshadow.png) | Generated asset / catalog / fixture |
| [Assets/Textures/face_overlay_lip.png](../../Assets/Textures/face_overlay_lip.png) | Generated asset / catalog / fixture |
| [Assets/Textures/hair_strand.png](../../Assets/Textures/hair_strand.png) | Generated asset / catalog / fixture |
| [Assets/Textures/pattern_dots.png](../../Assets/Textures/pattern_dots.png) | Generated asset / catalog / fixture |
| [Assets/Textures/pattern_lace.png](../../Assets/Textures/pattern_lace.png) | Generated asset / catalog / fixture |
| [Assets/Textures/pattern_plaid.png](../../Assets/Textures/pattern_plaid.png) | Generated asset / catalog / fixture |
| [Assets/Textures/pattern_plain.png](../../Assets/Textures/pattern_plain.png) | Generated asset / catalog / fixture |
| [Assets/Textures/pattern_stripes.png](../../Assets/Textures/pattern_stripes.png) | Generated asset / catalog / fixture |
| [Assets/Textures/skin_f_base.png](../../Assets/Textures/skin_f_base.png) | Generated asset / catalog / fixture |
| [Assets/Textures/skin_f_detail.png](../../Assets/Textures/skin_f_detail.png) | Generated asset / catalog / fixture |
| [Assets/Textures/skin_m_base.png](../../Assets/Textures/skin_m_base.png) | Generated asset / catalog / fixture |
| [Assets/Textures/skin_m_detail.png](../../Assets/Textures/skin_m_detail.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_bag.png](../../Assets/Thumbs/acc_bag.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_cat_ears.png](../../Assets/Thumbs/acc_cat_ears.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_glasses.png](../../Assets/Thumbs/acc_glasses.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_hairpin.png](../../Assets/Thumbs/acc_hairpin.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_hat_beret.png](../../Assets/Thumbs/acc_hat_beret.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_headband.png](../../Assets/Thumbs/acc_headband.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_necklace.png](../../Assets/Thumbs/acc_necklace.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/acc_ribbon.png](../../Assets/Thumbs/acc_ribbon.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_bottom_jeans.png](../../Assets/Thumbs/cloth_bottom_jeans.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_bottom_shorts.png](../../Assets/Thumbs/cloth_bottom_shorts.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_bottom_skirt_pleated.png](../../Assets/Thumbs/cloth_bottom_skirt_pleated.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_bottom_trousers_m.png](../../Assets/Thumbs/cloth_bottom_trousers_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_bra_plain.png](../../Assets/Thumbs/cloth_bra_plain.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_gloves_short.png](../../Assets/Thumbs/cloth_gloves_short.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_gloves_short_m.png](../../Assets/Thumbs/cloth_gloves_short_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_pantyhose_black.png](../../Assets/Thumbs/cloth_pantyhose_black.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_shoes_in_loafers.png](../../Assets/Thumbs/cloth_shoes_in_loafers.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_shoes_in_loafers_m.png](../../Assets/Thumbs/cloth_shoes_in_loafers_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_shoes_out_sneakers.png](../../Assets/Thumbs/cloth_shoes_out_sneakers.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_shoes_out_sneakers_m.png](../../Assets/Thumbs/cloth_shoes_out_sneakers_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_socks_ankle.png](../../Assets/Thumbs/cloth_socks_ankle.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_socks_ankle_m.png](../../Assets/Thumbs/cloth_socks_ankle_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_socks_knee.png](../../Assets/Thumbs/cloth_socks_knee.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_socks_knee_m.png](../../Assets/Thumbs/cloth_socks_knee_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_blazer.png](../../Assets/Thumbs/cloth_top_blazer.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_croptop.png](../../Assets/Thumbs/cloth_top_croptop.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_dress_camisole.png](../../Assets/Thumbs/cloth_top_dress_camisole.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_sailor.png](../../Assets/Thumbs/cloth_top_sailor.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_shirt_m.png](../../Assets/Thumbs/cloth_top_shirt_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_top_tshirt.png](../../Assets/Thumbs/cloth_top_tshirt.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_underwear_plain.png](../../Assets/Thumbs/cloth_underwear_plain.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/cloth_underwear_plain_m.png](../../Assets/Thumbs/cloth_underwear_plain_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_bob.png](../../Assets/Thumbs/hair_bob.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_long_straight.png](../../Assets/Thumbs/hair_long_straight.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_messy_m.png](../../Assets/Thumbs/hair_messy_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_afro01.png](../../Assets/Thumbs/hair_mh_afro01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_bob01.png](../../Assets/Thumbs/hair_mh_bob01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_bob02.png](../../Assets/Thumbs/hair_mh_bob02.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_braid01.png](../../Assets/Thumbs/hair_mh_braid01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_long01.png](../../Assets/Thumbs/hair_mh_long01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_ponytail01.png](../../Assets/Thumbs/hair_mh_ponytail01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_short01.png](../../Assets/Thumbs/hair_mh_short01.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_short02.png](../../Assets/Thumbs/hair_mh_short02.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_short03.png](../../Assets/Thumbs/hair_mh_short03.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_mh_short04.png](../../Assets/Thumbs/hair_mh_short04.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_ponytail.png](../../Assets/Thumbs/hair_ponytail.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_short_m.png](../../Assets/Thumbs/hair_short_m.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/hair_twintails.png](../../Assets/Thumbs/hair_twintails.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_bed.png](../../Assets/Thumbs/item_bed.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_chair.png](../../Assets/Thumbs/item_chair.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_cube.png](../../Assets/Thumbs/item_cube.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_cylinder.png](../../Assets/Thumbs/item_cylinder.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_desk.png](../../Assets/Thumbs/item_desk.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_plane.png](../../Assets/Thumbs/item_plane.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_room_bedroom.png](../../Assets/Thumbs/item_room_bedroom.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_room_classroom.png](../../Assets/Thumbs/item_room_classroom.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_room_street.png](../../Assets/Thumbs/item_room_street.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_sky_dome.png](../../Assets/Thumbs/item_sky_dome.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_sofa.png](../../Assets/Thumbs/item_sofa.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_sphere.png](../../Assets/Thumbs/item_sphere.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_stairs.png](../../Assets/Thumbs/item_stairs.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_table.png](../../Assets/Thumbs/item_table.png) | Generated asset / catalog / fixture |
| [Assets/Thumbs/item_torus.png](../../Assets/Thumbs/item_torus.png) | Generated asset / catalog / fixture |
| [Assets/catalog.json](../../Assets/catalog.json) | Generated asset / catalog / fixture |
| [Assets/fixtures/garment_fixture.bin](../../Assets/fixtures/garment_fixture.bin) | Generated asset / catalog / fixture |
| [Assets/fixtures/garment_fixture.gltf](../../Assets/fixtures/garment_fixture.gltf) | Generated asset / catalog / fixture |
| [Assets/fixtures/rig_fixture.bin](../../Assets/fixtures/rig_fixture.bin) | Generated asset / catalog / fixture |
| [Assets/fixtures/rig_fixture.gltf](../../Assets/fixtures/rig_fixture.gltf) | Generated asset / catalog / fixture |
| [Packages/Engine/Sources/Assets/AssetModel.swift](../../Packages/Engine/Sources/Assets/AssetModel.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/GLBLoader.swift](../../Packages/Engine/Sources/Assets/GLBLoader.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/GLTFSchema.swift](../../Packages/Engine/Sources/Assets/GLTFSchema.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Assets/GLTFValidation.swift](../../Packages/Engine/Sources/Assets/GLTFValidation.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/CoreMath/Projection.swift](../../Packages/Engine/Sources/CoreMath/Projection.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/CoreMath/Quaternion.swift](../../Packages/Engine/Sources/CoreMath/Quaternion.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/CoreMath/Ray.swift](../../Packages/Engine/Sources/CoreMath/Ray.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/CoreMath/Transform.swift](../../Packages/Engine/Sources/CoreMath/Transform.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/CoreMath/UnityCoordinates.swift](../../Packages/Engine/Sources/CoreMath/UnityCoordinates.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/GPU/FrameRing.swift](../../Packages/Engine/Sources/GPU/FrameRing.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/GPU/GPUContext.swift](../../Packages/Engine/Sources/GPU/GPUContext.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/OriginalFrameDiagnostics.swift](../../Packages/Engine/Sources/Renderer/OriginalFrameDiagnostics.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/OriginalFrameProbe.swift](../../Packages/Engine/Sources/Renderer/OriginalFrameProbe.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/OriginalProbeTextureLoader.swift](../../Packages/Engine/Sources/Renderer/OriginalProbeTextureLoader.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/Pipelines.swift](../../Packages/Engine/Sources/Renderer/Pipelines.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/RenderBenchmark.swift](../../Packages/Engine/Sources/Renderer/RenderBenchmark.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/RenderFrame.swift](../../Packages/Engine/Sources/Renderer/RenderFrame.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/RenderTargets.swift](../../Packages/Engine/Sources/Renderer/RenderTargets.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/Renderer.swift](../../Packages/Engine/Sources/Renderer/Renderer.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/ResourceStore.swift](../../Packages/Engine/Sources/Renderer/ResourceStore.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Renderer/TranslatedSourceShaderProbe.swift](../../Packages/Engine/Sources/Renderer/TranslatedSourceShaderProbe.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/Camera.swift](../../Packages/Engine/Sources/Scene/Camera.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/Light.swift](../../Packages/Engine/Sources/Scene/Light.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/Rig.swift](../../Packages/Engine/Sources/Scene/Rig.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/Skeleton.swift](../../Packages/Engine/Sources/Scene/Skeleton.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/SourceAvatar.swift](../../Packages/Engine/Sources/Scene/SourceAvatar.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/SourceRig.swift](../../Packages/Engine/Sources/Scene/SourceRig.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/Scene/SourceRigBounds.swift](../../Packages/Engine/Sources/Scene/SourceRigBounds.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h](../../Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/ShaderTypes/shim.c](../../Packages/Engine/Sources/ShaderTypes/shim.c) | Runtime / shared shader declaration |
| [Packages/Engine/Tests/CoreMathTests/CoreMathTests.swift](../../Packages/Engine/Tests/CoreMathTests/CoreMathTests.swift) | Test / validation |
| [Packages/Engine/Tests/CoreMathTests/UnityCoordinatesTests.swift](../../Packages/Engine/Tests/CoreMathTests/UnityCoordinatesTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/DeformationSafetyTests.swift](../../Packages/Engine/Tests/EngineTests/DeformationSafetyTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/GLTFImportTests.swift](../../Packages/Engine/Tests/EngineTests/GLTFImportTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/GLTFTests.swift](../../Packages/Engine/Tests/EngineTests/GLTFTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/MaterialImportTests.swift](../../Packages/Engine/Tests/EngineTests/MaterialImportTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/RigTests.swift](../../Packages/Engine/Tests/EngineTests/RigTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceAvatarTests.swift](../../Packages/Engine/Tests/EngineTests/SourceAvatarTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMaleAvatarTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMaleAvatarTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceMorphGPUTests.swift](../../Packages/Engine/Tests/EngineTests/SourceMorphGPUTests.swift) | Test / validation |
| [Packages/Engine/Tests/EngineTests/SourceRigBoundsTests.swift](../../Packages/Engine/Tests/EngineTests/SourceRigBoundsTests.swift) | Test / validation |
| [Shaders/Common.h](../../Shaders/Common.h) | Runtime / shared shader declaration |
| [Shaders/Deform.metal](../../Shaders/Deform.metal) | Runtime / shared shader declaration |
| [Shaders/Outline.metal](../../Shaders/Outline.metal) | Runtime / shared shader declaration |
| [Shaders/Overlay.metal](../../Shaders/Overlay.metal) | Runtime / shared shader declaration |
| [Shaders/Post.metal](../../Shaders/Post.metal) | Runtime / shared shader declaration |
| [Shaders/Shadow.metal](../../Shaders/Shadow.metal) | Runtime / shared shader declaration |
| [Shaders/Toon.metal](../../Shaders/Toon.metal) | Runtime / shared shader declaration |
| [Tools/assets/.gitignore](../../Tools/assets/.gitignore) | Conversion / recovery / verification tool |
| [Tools/assets/README.md](../../Tools/assets/README.md) | Documentation / historical evidence |
| [Tools/assets/build_body.py](../../Tools/assets/build_body.py) | Conversion / recovery / verification tool |
| [Tools/assets/build_clothes.py](../../Tools/assets/build_clothes.py) | Conversion / recovery / verification tool |
| [Tools/assets/build_hair.py](../../Tools/assets/build_hair.py) | Conversion / recovery / verification tool |
| [Tools/assets/build_items.py](../../Tools/assets/build_items.py) | Conversion / recovery / verification tool |
| [Tools/assets/catalog.py](../../Tools/assets/catalog.py) | Conversion / recovery / verification tool |
| [Tools/assets/common.py](../../Tools/assets/common.py) | Conversion / recovery / verification tool |
| [Tools/assets/deform.py](../../Tools/assets/deform.py) | Conversion / recovery / verification tool |
| [Tools/assets/landmarks.py](../../Tools/assets/landmarks.py) | Conversion / recovery / verification tool |
| [Tools/assets/rig.py](../../Tools/assets/rig.py) | Conversion / recovery / verification tool |
| [Tools/assets/run_all.sh](../../Tools/assets/run_all.sh) | Conversion / recovery / verification tool |
| [Tools/assets/textures.py](../../Tools/assets/textures.py) | Conversion / recovery / verification tool |
| [Tools/assets/verify.py](../../Tools/assets/verify.py) | Conversion / recovery / verification tool |
| [Tools/reverse/compare_original_frame.py](../../Tools/reverse/compare_original_frame.py) | Conversion / recovery / verification tool |
| [Tools/reverse/export_prefab.py](../../Tools/reverse/export_prefab.py) | Conversion / recovery / verification tool |
| [Tools/reverse/fixtures/OriginalCharacterProbe.cs](../../Tools/reverse/fixtures/OriginalCharacterProbe.cs) | Reference host / controlled fixture |
| [Tools/reverse/fixtures/OriginalShaderProbe.cs](../../Tools/reverse/fixtures/OriginalShaderProbe.cs) | Reference host / controlled fixture |
| [Tools/reverse/original_character_probe.py](../../Tools/reverse/original_character_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/original_shader_probe.py](../../Tools/reverse/original_shader_probe.py) | Conversion / recovery / verification tool |
| [Tools/reverse/original_texture_mips.py](../../Tools/reverse/original_texture_mips.py) | Conversion / recovery / verification tool |
| [Tools/reverse/rig_inventory.py](../../Tools/reverse/rig_inventory.py) | Conversion / recovery / verification tool |
| [Tools/reverse/source_shader_translation.py](../../Tools/reverse/source_shader_translation.py) | Conversion / recovery / verification tool |
| [Tools/reverse/test_avatar_parity.py](../../Tools/reverse/test_avatar_parity.py) | Test / validation |
| [Tools/reverse/test_compare_original_frame.py](../../Tools/reverse/test_compare_original_frame.py) | Test / validation |
| [Tools/reverse/test_export_prefab.py](../../Tools/reverse/test_export_prefab.py) | Test / validation |
| [Tools/reverse/test_original_shader_probe.py](../../Tools/reverse/test_original_shader_probe.py) | Test / validation |
| [Tools/reverse/test_rig_inventory.py](../../Tools/reverse/test_rig_inventory.py) | Test / validation |
| [Tools/reverse/test_rig_parity.py](../../Tools/reverse/test_rig_parity.py) | Test / validation |
| [Tools/reverse/test_source_shader_translation.py](../../Tools/reverse/test_source_shader_translation.py) | Test / validation |

## Toolchain / verification / historical docs

Feature assessment: [toolchain-and-verification.md](toolchain-and-verification.md).

| File | Role |
| --- | --- |
| [.gitignore](../../.gitignore) | Build / repository configuration |
| [CONTRIBUTING.md](../../CONTRIBUTING.md) | Documentation / historical evidence |
| [Ikkoku.xcodeproj/project.pbxproj](../../Ikkoku.xcodeproj/project.pbxproj) | Build / repository configuration |
| [Ikkoku.xcodeproj/project.xcworkspace/contents.xcworkspacedata](../../Ikkoku.xcodeproj/project.xcworkspace/contents.xcworkspacedata) | Build / repository configuration |
| [Ikkoku.xcodeproj/xcshareddata/xcschemes/IkkokuCreator.xcscheme](../../Ikkoku.xcodeproj/xcshareddata/xcschemes/IkkokuCreator.xcscheme) | Build / repository configuration |
| [Packages/Engine/Package.swift](../../Packages/Engine/Package.swift) | Build / repository configuration |
| [Packages/Engine/Sources/IkkokuInspect/BlinkTrace.swift](../../Packages/Engine/Sources/IkkokuInspect/BlinkTrace.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/GameplayExecutionInspection.swift](../../Packages/Engine/Sources/IkkokuInspect/GameplayExecutionInspection.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/GameplayTrace.swift](../../Packages/Engine/Sources/IkkokuInspect/GameplayTrace.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/SourceAnimationReport.swift](../../Packages/Engine/Sources/IkkokuInspect/SourceAnimationReport.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/StudioPoseInspection.swift](../../Packages/Engine/Sources/IkkokuInspect/StudioPoseInspection.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/StudioSceneInspection.swift](../../Packages/Engine/Sources/IkkokuInspect/StudioSceneInspection.swift) | Runtime / shared shader declaration |
| [Packages/Engine/Sources/IkkokuInspect/main.swift](../../Packages/Engine/Sources/IkkokuInspect/main.swift) | Runtime / shared shader declaration |
| [README.md](../../README.md) | Documentation / historical evidence |
| [Tools/reverse/README.md](../../Tools/reverse/README.md) | Documentation / historical evidence |
| [Tools/reverse/analysis/decompile_studio.py](../../Tools/reverse/analysis/decompile_studio.py) | Conversion / recovery / verification tool |
| [Tools/reverse/analysis/recover_managed.py](../../Tools/reverse/analysis/recover_managed.py) | Conversion / recovery / verification tool |
| [Tools/reverse/catalog.py](../../Tools/reverse/catalog.py) | Conversion / recovery / verification tool |
| [Tools/reverse/inventory.ps1](../../Tools/reverse/inventory.ps1) | Conversion / recovery / verification tool |
| [Tools/reverse/requirements.txt](../../Tools/reverse/requirements.txt) | Conversion / recovery / verification tool |
| [Tools/reverse/test_recover_managed.py](../../Tools/reverse/test_recover_managed.py) | Test / validation |
| [Tools/reverse/vm_source.py](../../Tools/reverse/vm_source.py) | Conversion / recovery / verification tool |
| [docs/README.md](../../docs/README.md) | Documentation / historical evidence |
| [docs/architecture.md](../../docs/architecture.md) | Documentation / historical evidence |
| [docs/archive/2026-09-09-plan.md](../../docs/archive/2026-09-09-plan.md) | Documentation / historical evidence |
| [docs/archive/2026-09-25-expansion.md](../../docs/archive/2026-09-25-expansion.md) | Documentation / historical evidence |
| [docs/archive/2026-09-25-rebuild.md](../../docs/archive/2026-09-25-rebuild.md) | Documentation / historical evidence |
| [docs/archive/README.md](../../docs/archive/README.md) | Documentation / historical evidence |
| [docs/archive/design-research.md](../../docs/archive/design-research.md) | Documentation / historical evidence |
| [docs/guides/build-and-test.md](../../docs/guides/build-and-test.md) | Documentation / historical evidence |
| [docs/guides/mod-library.md](../../docs/guides/mod-library.md) | Documentation / historical evidence |
| [docs/guides/using-the-app.md](../../docs/guides/using-the-app.md) | Documentation / historical evidence |
| [docs/reference/animation/animator.md](../../docs/reference/animation/animator.md) | Documentation / historical evidence |
| [docs/reference/animation/dynamics-parity.md](../../docs/reference/animation/dynamics-parity.md) | Documentation / historical evidence |
| [docs/reference/animation/dynamics.md](../../docs/reference/animation/dynamics.md) | Documentation / historical evidence |
| [docs/reference/animation/expression-playback.md](../../docs/reference/animation/expression-playback.md) | Documentation / historical evidence |
| [docs/reference/animation/trigonometric-ik.md](../../docs/reference/animation/trigonometric-ik.md) | Documentation / historical evidence |
| [docs/reference/character/body-shape.md](../../docs/reference/character/body-shape.md) | Documentation / historical evidence |
| [docs/reference/character/card-appearance.md](../../docs/reference/character/card-appearance.md) | Documentation / historical evidence |
| [docs/reference/character/cards.md](../../docs/reference/character/cards.md) | Documentation / historical evidence |
| [docs/reference/character/contracts.md](../../docs/reference/character/contracts.md) | Documentation / historical evidence |
| [docs/reference/character/expressions.md](../../docs/reference/character/expressions.md) | Documentation / historical evidence |
| [docs/reference/character/face-shape.md](../../docs/reference/character/face-shape.md) | Documentation / historical evidence |
| [docs/reference/character/head-materials.md](../../docs/reference/character/head-materials.md) | Documentation / historical evidence |
| [docs/reference/character/head-rig.md](../../docs/reference/character/head-rig.md) | Documentation / historical evidence |
| [docs/reference/character/maker-assets.md](../../docs/reference/character/maker-assets.md) | Documentation / historical evidence |
| [docs/reference/character/maker-coverage.md](../../docs/reference/character/maker-coverage.md) | Documentation / historical evidence |
| [docs/reference/character/male.md](../../docs/reference/character/male.md) | Documentation / historical evidence |
| [docs/reference/character/material-expansion.md](../../docs/reference/character/material-expansion.md) | Documentation / historical evidence |
| [docs/reference/character/rigs.md](../../docs/reference/character/rigs.md) | Documentation / historical evidence |
| [docs/reference/gameplay/adv.md](../../docs/reference/gameplay/adv.md) | Documentation / historical evidence |
| [docs/reference/gameplay/cycle.md](../../docs/reference/gameplay/cycle.md) | Documentation / historical evidence |
| [docs/reference/managed-recovery.md](../../docs/reference/managed-recovery.md) | Documentation / historical evidence |
| [docs/reference/mods/abmx.md](../../docs/reference/mods/abmx.md) | Documentation / historical evidence |
| [docs/reference/mods/api-substitution.md](../../docs/reference/mods/api-substitution.md) | Documentation / historical evidence |
| [docs/reference/mods/card-references.md](../../docs/reference/mods/card-references.md) | Documentation / historical evidence |
| [docs/reference/mods/catalog.md](../../docs/reference/mods/catalog.md) | Documentation / historical evidence |
| [docs/reference/mods/native-adapters.md](../../docs/reference/mods/native-adapters.md) | Documentation / historical evidence |
| [docs/reference/mods/overview.md](../../docs/reference/mods/overview.md) | Documentation / historical evidence |
| [docs/reference/mods/plugin-execution.md](../../docs/reference/mods/plugin-execution.md) | Documentation / historical evidence |
| [docs/reference/native-assets.md](../../docs/reference/native-assets.md) | Documentation / historical evidence |
| [docs/reference/renderer.md](../../docs/reference/renderer.md) | Documentation / historical evidence |
| [docs/reference/studio/animation.md](../../docs/reference/studio/animation.md) | Documentation / historical evidence |
| [docs/reference/studio/binary-contracts.md](../../docs/reference/studio/binary-contracts.md) | Documentation / historical evidence |
| [docs/reference/studio/full-body-ik.md](../../docs/reference/studio/full-body-ik.md) | Documentation / historical evidence |
| [docs/reference/studio/item-catalog.md](../../docs/reference/studio/item-catalog.md) | Documentation / historical evidence |
| [docs/reference/studio/pose.md](../../docs/reference/studio/pose.md) | Documentation / historical evidence |
| [docs/reference/studio/scene-editing.md](../../docs/reference/studio/scene-editing.md) | Documentation / historical evidence |
| [docs/reference/studio/scene-records.md](../../docs/reference/studio/scene-records.md) | Documentation / historical evidence |
| [docs/reference/studio/voice.md](../../docs/reference/studio/voice.md) | Documentation / historical evidence |

## Audit deliverables

The audit folder is excluded from its own source snapshot to avoid a recursive
inventory. Its deliverables are `README.md`, `app-gameplay-and-plugins.md`,
`character-and-mods.md`, `studio.md`, `renderer-and-foundation.md`,
`toolchain-and-verification.md`, and this `file-index.md`.

When source files are added or removed, update the owning feature table and this
index together. Historical documents are indexed as evidence to reconcile, not
as current completion claims. See T-T05 for the diagnostic/documentation cleanup.
