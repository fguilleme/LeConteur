#!/usr/bin/env python3
"""Generate the Xcode project without external project-generation dependencies."""
import hashlib, pathlib, plistlib, json, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
# Keep the signing choices made in Xcode when regenerating this project.
existing_signing = {}
project_file = ROOT/'LeConteur.xcodeproj/project.pbxproj'
if project_file.exists():
    previous = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project_file)]))
    previous_objects = previous['objects']
    signing_keys = {'DEVELOPMENT_TEAM', 'CODE_SIGN_STYLE', 'CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE_SPECIFIER', 'PROVISIONING_PROFILE'}
    for entry in previous_objects.values():
        if entry.get('isa') not in {'PBXProject', 'PBXNativeTarget'}:
            continue
        name = 'Project' if entry['isa'] == 'PBXProject' else {'LeConteur':'App', 'ConteurShare':'Share', 'LeConteurTests':'Test'}.get(entry.get('name'))
        if name is None:
            continue
        for config_id in previous_objects[entry['buildConfigurationList']]['buildConfigurations']:
            config = previous_objects[config_id]
            existing_signing[(name, config['name'])] = {k:v for k,v in config['buildSettings'].items() if k.split('[')[0] in signing_keys}
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(identity, isa, **values):
    key = uid(identity); objects[key] = dict(isa=isa, **values); return key
def ref(path, kind): return obj('file:'+path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='SOURCE_ROOT')
def build_file(path, kind, target): return obj('build:'+target+path, 'PBXBuildFile', fileRef=ref(path,kind))
def configs(name, settings):
    refs=[]
    for mode in ['Debug','Release']:
        local = dict(settings)
        if name=='Project':
            local.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode=='Debug' else 'dwarf-with-dsym')
            if mode=='Debug': local.update(ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ONLY_ACTIVE_ARCH='YES')
        local.update(existing_signing.get((name, mode), {}))
        if name == 'Project':
            # Share extensions and tests inherit the app's team unless configured explicitly.
            team = existing_signing.get(('App', mode), {}).get('DEVELOPMENT_TEAM')
            if team:
                local['DEVELOPMENT_TEAM'] = team
        refs.append(obj(name+mode,'XCBuildConfiguration',name=mode,buildSettings=local))
    return obj(name+'ConfigList','XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
def phase(identity, isa, files, **extra): return obj(identity,isa,buildActionMask=2147483647,files=files,runOnlyForDeploymentPostprocessing=0,**extra)
app_id=uid('AppTarget'); share_id=uid('ShareTarget'); test_id=uid('TestTarget')
products=[]
for name,typ in [('LeConteur.app','wrapper.application'),('ConteurShare.appex','wrapper.app-extension'),('LeConteurTests.xctest','wrapper.cfbundle')]:
    products.append(obj(name,'PBXFileReference',explicitFileType=typ,path=name,sourceTree='BUILT_PRODUCTS_DIR'))
packages=[]; dep_products=[]; frameworks=[]
for name,url,version in [('sherpa-onnx','https://github.com/k2-fsa/sherpa-onnx.git','1.13.8'),('ZIPFoundation','https://github.com/weichsel/ZIPFoundation.git','0.9.19')]:
    package=obj('package'+name,'XCRemoteSwiftPackageReference',repositoryURL=url,requirement={'kind':'exactVersion','version':version}); packages.append(package)
    product=obj('product'+name,'XCSwiftPackageProductDependency',package=package,productName=name); dep_products.append(product)
    frameworks.append(obj('link'+name,'PBXBuildFile',productRef=product))
qwen_package=obj('packageConteurQwen','XCLocalSwiftPackageReference',relativePath='Packages/ConteurQwen'); packages.append(qwen_package)
qwen_product=obj('productConteurQwen','XCSwiftPackageProductDependency',productName='ConteurQwen'); dep_products.append(qwen_product)
frameworks.append(obj('linkConteurQwen','PBXBuildFile',productRef=qwen_product))
shared=['Shared/SharedInbox.swift']
app_sources=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'LeConteur').rglob('*.swift'))]+shared
share_sources=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'ConteurShare').glob('*.swift'))]+shared
test_sources=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'LeConteurTests').glob('*.swift'))]
app_resources=[('LeConteur/Resources/VoiceAssets','folder'),('LeConteur/Resources/Assets.xcassets','folder.assetcatalog'),('LeConteur/Resources/ThirdPartyNotices.txt','text'),('LeConteur/Resources/QwenModelManifest.json','text.json'),('Shared/PrivacyInfo.xcprivacy','text.xml')]
app_phases=[phase('AppSources','PBXSourcesBuildPhase',[build_file(p,'sourcecode.swift','App') for p in app_sources]),phase('AppResources','PBXResourcesBuildPhase',[build_file(p,k,'App') for p,k in app_resources]),phase('AppFrameworks','PBXFrameworksBuildPhase',frameworks)]
embed=obj('embedShare','PBXBuildFile',fileRef=products[1],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
app_phases.append(phase('EmbedExtensions','PBXCopyFilesBuildPhase',[embed],dstPath='',dstSubfolderSpec=13,name='Embed App Extensions'))
share_phases=[phase('ShareSources','PBXSourcesBuildPhase',[build_file(p,'sourcecode.swift','Share') for p in share_sources]),phase('ShareResources','PBXResourcesBuildPhase',[build_file('Shared/PrivacyInfo.xcprivacy','text.xml','Share')]),phase('ShareFrameworks','PBXFrameworksBuildPhase',[])]
test_phases=[phase('TestSources','PBXSourcesBuildPhase',[build_file(p,'sourcecode.swift','Test') for p in test_sources]),phase('TestFrameworks','PBXFrameworksBuildPhase',[]),phase('TestResources','PBXResourcesBuildPhase',[build_file('LeConteurTests/Fixtures','folder','Test')])]
project_id=uid('Project')
def dependency(name,target):
    proxy=obj(name+'Proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=target,remoteInfo=name)
    return obj(name+'Dependency','PBXTargetDependency',target=target,targetProxy=proxy)
common={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'18.0','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'1.0','CLANG_ENABLE_MODULES':'YES','SWIFT_EMIT_LOC_STRINGS':'YES'}
app_settings=dict(common, PRODUCT_BUNDLE_IDENTIFIER='com.guilleme.conteur', PRODUCT_NAME='LeConteur',INFOPLIST_FILE='LeConteur/Info.plist',CODE_SIGN_ENTITLEMENTS='LeConteur/LeConteur.entitlements',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'])
share_settings=dict(common, PRODUCT_BUNDLE_IDENTIFIER='com.guilleme.conteur.share',PRODUCT_NAME='ConteurShare',INFOPLIST_FILE='ConteurShare/Info.plist',CODE_SIGN_ENTITLEMENTS='ConteurShare/ConteurShare.entitlements',APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'])
test_settings=dict(common,PRODUCT_BUNDLE_IDENTIFIER='com.guilleme.conteur.tests',PRODUCT_NAME='LeConteurTests',GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/LeConteur.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LeConteur',BUNDLE_LOADER='$(TEST_HOST)',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'])
obj('AppTarget','PBXNativeTarget',name='LeConteur',productName='LeConteur',productType='com.apple.product-type.application',productReference=products[0],buildConfigurationList=configs('App',app_settings),buildPhases=app_phases,buildRules=[],dependencies=[dependency('Share',share_id)],packageProductDependencies=dep_products)
obj('ShareTarget','PBXNativeTarget',name='ConteurShare',productName='ConteurShare',productType='com.apple.product-type.app-extension',productReference=products[1],buildConfigurationList=configs('Share',share_settings),buildPhases=share_phases,buildRules=[],dependencies=[])
obj('TestTarget','PBXNativeTarget',name='LeConteurTests',productName='LeConteurTests',productType='com.apple.product-type.bundle.unit-test',productReference=products[2],buildConfigurationList=configs('Test',test_settings),buildPhases=test_phases,buildRules=[],dependencies=[dependency('App',app_id)])
product_group=obj('Products','PBXGroup',name='Products',sourceTree='<group>',children=products)
file_refs=sorted(set(uid('file:'+p) for p in app_sources+share_sources+test_sources+[p for p,k in app_resources]))
main_group=obj('Main','PBXGroup',sourceTree='<group>',children=file_refs+[product_group])
obj('Project','PBXProject',attributes={'LastUpgradeCheck':'1600','TargetAttributes':{app_id:{'CreatedOnToolsVersion':'16.0'},share_id:{'CreatedOnToolsVersion':'16.0'},test_id:{'CreatedOnToolsVersion':'16.0','TestTargetID':app_id}}},buildConfigurationList=configs('Project',{'CLANG_ENABLE_OBJC_ARC':'YES','ENABLE_STRICT_OBJC_MSGSEND':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','CLANG_CXX_LANGUAGE_STANDARD':'c++17','SWIFT_STRICT_CONCURRENCY':'targeted'}),compatibilityVersion='Xcode 14.0',developmentRegion='fr',knownRegions=['fr','en','Base'],mainGroup=main_group,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=[app_id,share_id,test_id],packageReferences=packages)
def emit(v,depth=0):
    if isinstance(v,dict): return '{\n'+''.join('\t'*(depth+1)+json.dumps(str(k))+ ' = '+emit(x,depth+1)+';\n' for k,x in v.items())+'\t'*depth+'}'
    if isinstance(v,list): return '('+', '.join(emit(x,depth) for x in v)+')'
    return str(v) if isinstance(v,int) else json.dumps(v)
project={'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project_id}
(ROOT/'LeConteur.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+emit(project)+'\n')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="LeConteur.app" BlueprintName="LeConteur" ReferencedContainer="container:LeConteur.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="LeConteurTests.xctest" BlueprintName="LeConteurTests" ReferencedContainer="container:LeConteur.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="LeConteur.app" BlueprintName="LeConteur" ReferencedContainer="container:LeConteur.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(ROOT/'LeConteur.xcodeproj/xcshareddata/xcschemes/LeConteur.xcscheme').write_text(scheme)
def plist(path,obj): (ROOT/path).write_bytes(plistlib.dumps(obj))
base={'CFBundleDevelopmentRegion':'fr','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'$(PRODUCT_NAME)','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)'}
plist('LeConteur/Info.plist',dict(base,CFBundleDisplayName='Le Conteur',CFBundlePackageType='APPL',LSRequiresIPhoneOS=True,UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},UILaunchScreen={},UIBackgroundModes=['audio'],UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'],LSSupportsOpeningDocumentsInPlace=True,CFBundleDocumentTypes=[{'CFBundleTypeName':'Livres et textes','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['org.idpf.epub-container','com.adobe.pdf','public.plain-text','net.daringfireball.markdown']}],UTImportedTypeDeclarations=[{'UTTypeIdentifier':'org.idpf.epub-container','UTTypeDescription':'EPUB','UTTypeConformsTo':['public.data','public.content'],'UTTypeTagSpecification':{'public.filename-extension':['epub'],'public.mime-type':['application/epub+zip']}}]))
predicate='SUBQUERY(extensionItems, $item, SUBQUERY($item.attachments, $attachment, ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "org.idpf.epub-container" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.adobe.pdf" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.plain-text" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url").@count == 1).@count == 1'
plist('ConteurShare/Info.plist',dict(base,CFBundleDisplayName='Le Conteur',CFBundlePackageType='XPC!',NSExtension={'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':predicate}}))
plist('LeConteur/LeConteur.entitlements', {'com.apple.security.application-groups':['group.com.guilleme.conteur'], 'com.apple.developer.kernel.increased-memory-limit': True})
plist('ConteurShare/ConteurShare.entitlements', {'com.apple.security.application-groups':['group.com.guilleme.conteur']})
plist('Shared/PrivacyInfo.xcprivacy',{'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyCollectedDataTypes':[],'NSPrivacyAccessedAPITypes':[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryUserDefaults','NSPrivacyAccessedAPITypeReasons':['CA92.1']}]})
print('Generated LeConteur.xcodeproj')
