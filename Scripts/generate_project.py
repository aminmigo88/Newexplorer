from pathlib import Path
from hashlib import sha1
import json
import os
from xml.etree.ElementTree import Element, SubElement, indent, ElementTree
p=Path(__file__).resolve().parents[1]
def ID(s):return sha1(s.encode()).hexdigest()[:24].upper()
objs={}
def obj(key,isa,**attrs):
    objs[ID(key)]={'isa':isa,**attrs}
    return ID(key)
def group(key,nodes,**kw):return obj(key,'PBXGroup',children=nodes,sourceTree='<group>',**kw)
def lst(k,settings):
    ls=[]
    for env in ['Debug','Release']:
        d=settings.copy()
        if k=='root':
            d.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if env=='Debug' else '-O',ENABLE_TESTABILITY='YES' if env=='Debug' else 'NO', ONLY_ACTIVE_ARCH='YES' if env=='Debug' else 'NO',
                     DEBUG_INFORMATION_FORMAT='dwarf' if env=='Debug' else 'dwarf-with-dsym')
        ls.append(obj(k+env,'XCBuildConfiguration',name=env,buildSettings=d))
    return obj(k+'cfg','XCConfigurationList',buildConfigurations=ls,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
rootCfg=lst('root',dict(SDKROOT='iphoneos',IPHONEOS_DEPLOYMENT_TARGET='17.0',SWIFT_VERSION='5.0',CLANG_ENABLE_MODULES='YES',TARGETED_DEVICE_FAMILY='1',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',SUPPORTS_MACCATALYST='NO'))
packs=[]
for n,url,v in [('AMSMB2','amosavian/AMSMB2','4.0.3'),('ZIPFoundation','weichsel/ZIPFoundation','0.9.20'),('LibArchive','kmworks/libarchive-swift','0.1.6')]:
    ref=obj(n+'ref','XCRemoteSwiftPackageReference',repositoryURL='https://github.com/'+url+'.git',requirement={'kind':'exactVersion','version':v})
    packs.append(ref)
    dep=obj(n+'prod','XCSwiftPackageProductDependency',package=ref,productName=n)
    obj(n+'link','PBXBuildFile',productRef=dep)
# The bundle ID must be the App ID in your signing profile (README, Signing).
# BUNDLE_ID=your.app.id python3 Scripts/generate_project.py
bundle_id=os.environ.get('BUNDLE_ID') or 'com.example.newexplorer'
# Open CASCADE Technology toolkits for the STEP and IGES reader (App/CADMesh.cpp). Scripts/build_occt.sh builds them
# into Vendor/occt; the linker takes only the parts the reader uses.
occt=['TKDESTEP','TKDEIGES','TKXCAF','TKVCAF','TKV3d','TKHLR','TKService','TKMesh','TKCAF','TKLCAF','TKCDF','TKBool','TKBO',
      'TKPrim','TKXSBase','TKShHealing','TKTopAlgo','TKGeomAlgo','TKDE','TKBRep','TKGeomBase','TKG3d','TKG2d','TKMath','TKernel']
products=[]; groups=[]
targets = [('Newexplorer','App','.app','application'),('NewexplorerTests','Tests','.xctest','bundle.unit-test'),
           ('NewexplorerUITests','UITests','.xctest','bundle.ui-testing')]
for target,folder,ext,typ in targets:
    app=folder=='App'
    prod=obj(target+'prod','PBXFileReference',explicitFileType='wrapper.application' if app else 'wrapper.cfbundle',path=target+ext,sourceTree='BUILT_PRODUCTS_DIR')
    products.append(prod)
    files=[]; builds=[]
    for f in sorted((p/folder).glob('*.swift')):
        files.append(obj(f.name,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=f.name,sourceTree='<group>'))
        builds.append(obj(f.name+'build','PBXBuildFile',fileRef=files[-1]))
    if app:
        # C++ files see the Open CASCADE headers; Swift and the rest of the app don't.
        for f in sorted((p/folder).glob('*.cpp')):
            files.append(obj(f.name,'PBXFileReference',lastKnownFileType='sourcecode.cpp.cpp',path=f.name,sourceTree='<group>'))
            builds.append(obj(f.name+'build','PBXBuildFile',fileRef=files[-1],settings={'COMPILER_FLAGS':'-I$(SRCROOT)/Vendor/occt/include'}))
        for f in sorted((p/folder).glob('*.h')):
            files.append(obj(f.name,'PBXFileReference',lastKnownFileType='sourcecode.c.h',path=f.name,sourceTree='<group>'))
    resources = []
    if app:
        asset = obj("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
        notice = obj("notice", "PBXFileReference", lastKnownFileType="text", path="ThirdPartyNotices.txt", sourceTree="<group>")
        files += [asset, notice]
        resources = [obj("assetsbuild", "PBXBuildFile", fileRef=asset), obj("noticebuild", "PBXBuildFile", fileRef=notice)]
    groups.append(group(folder,files,path=folder))
    resourcePhase = obj(target+"resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
    sources=obj(target+'src','PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
    fw=obj(target+'fw','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[ID(n+'link') for n in ['AMSMB2','ZIPFoundation','LibArchive']] if app else [],runOnlyForDeploymentPostprocessing=0)
    suffix = {'App': '', 'Tests': '.tests', 'UITests': '.uitests'}[folder]
    cfg={'PRODUCT_BUNDLE_IDENTIFIER':bundle_id+suffix,'PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'],'MARKETING_VERSION':'0.12.0','CURRENT_PROJECT_VERSION':'17'}
    phases=[sources,fw,resourcePhase]
    deps=[]
    if app:
        embed=obj("SMBEmbedBuild","PBXBuildFile",productRef=ID("AMSMB2prod"),settings={"ATTRIBUTES":["CodeSignOnCopy","RemoveHeadersOnCopy"]})
        phases.append(obj("embed","PBXCopyFilesBuildPhase",buildActionMask=2147483647,dstPath="",dstSubfolderSpec=10,files=[embed],name="Embed Frameworks",runOnlyForDeploymentPostprocessing=0))
        cfg.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", INFOPLIST_FILE="App/Info.plist")
        cfg.update({'SWIFT_OBJC_BRIDGING_HEADER':'App/Newexplorer-Bridging-Header.h','CLANG_CXX_LANGUAGE_STANDARD':'c++17',
                    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]':['$(inherited)','$(SRCROOT)/Vendor/occt/iphoneos/lib'],
                    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]':['$(inherited)','$(SRCROOT)/Vendor/occt/iphonesimulator/lib'],
                    'OTHER_LDFLAGS':['$(inherited)']+['-l'+tk for tk in occt]+['-lc++'],'DEAD_CODE_STRIPPING':'YES'})
        cfg.update(INFOPLIST_KEY_CFBundleDisplayName='Newexplorer',INFOPLIST_KEY_UILaunchScreen_Generation='YES',INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES',INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone='UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',INFOPLIST_KEY_NSPhotoLibraryUsageDescription='Browse and copy the photos and videos you choose.',INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription='Save the pictures and videos you paste into Photos.',INFOPLIST_KEY_NSLocalNetworkUsageDescription='Find computers and drives that share files on your Wi-Fi, and connect to the share you choose.',INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace='YES')
    else:
        if folder == 'UITests':
            cfg.update(TEST_TARGET_NAME='Newexplorer')
        else:
            cfg.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/Newexplorer.app/Newexplorer',BUNDLE_LOADER='$(TEST_HOST)')
        proxy=obj(target+'proxy','PBXContainerItemProxy',containerPortal=ID('project'),proxyType=1,remoteGlobalIDString=ID('Newexplorer'),remoteInfo='Newexplorer')
        deps=[obj(target+'dep','PBXTargetDependency',target=ID('Newexplorer'),targetProxy=proxy)]
    obj(target,'PBXNativeTarget',name=target,productName=target,productReference=prod,productType='com.apple.product-type.'+typ,buildPhases=phases,dependencies=deps,buildRules=[],packageProductDependencies=[ID(n+'prod') for n in ['AMSMB2','ZIPFoundation','LibArchive']] if app else [],buildConfigurationList=lst(target,cfg))
productGroup=group('products',products,name='Products')
obj('project','PBXProject',mainGroup=group('main',groups+[productGroup]),productRefGroup=productGroup,buildConfigurationList=rootCfg,compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],hasScannedForEncodings=0,projectDirPath='',projectRoot='',packageReferences=packs,targets=[ID(name) for name,_,_,_ in targets])
def emit(v,i=0):
    if isinstance(v,dict):return '{\n'+''.join('\t'*(i+1)+json.dumps(k)+' = '+emit(w,i+1)+';\n' for k,w in v.items())+'\t'*i+'}'
    if isinstance(v,list):return '('+''.join(emit(w,i)+',' for w in v)+')'
    return json.dumps(v)
(p/'Newexplorer.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+emit(dict(archiveVersion=1,classes={},objectVersion=56,objects=objs,rootObject=ID('project')))+'\n')
scheme=Element('Scheme',LastUpgradeVersion='1600',version='1.7')
def ref(parent,name,ext):SubElement(parent,'BuildableReference',BuildableIdentifier='primary',BlueprintIdentifier=ID(name),BuildableName=name+ext,BlueprintName=name,ReferencedContainer='container:Newexplorer.xcodeproj')
build=SubElement(scheme,'BuildAction',parallelizeBuildables='YES',buildImplicitDependencies='YES')
ref(SubElement(SubElement(build,'BuildActionEntries'),'BuildActionEntry',buildForTesting='YES',buildForRunning='YES',buildForProfiling='YES',buildForArchiving='YES',buildForAnalyzing='YES'),'Newexplorer','.app')
test=SubElement(scheme,'TestAction',buildConfiguration='Debug',shouldUseLaunchSchemeArgsEnv='YES')
testables=SubElement(test,'Testables')
for name in ['NewexplorerTests','NewexplorerUITests']:
    ref(SubElement(testables,'TestableReference',skipped='NO'),name,'.xctest')
launch=SubElement(scheme,'LaunchAction',buildConfiguration='Debug',launchStyle='0',useCustomWorkingDirectory='NO')
ref(SubElement(launch,'BuildableProductRunnable',runnableDebuggingMode='0'),'Newexplorer','.app')
indent(scheme)
ElementTree(scheme).write(p/'Newexplorer.xcodeproj/xcshareddata/xcschemes/Newexplorer.xcscheme',encoding='utf-8',xml_declaration=True)
