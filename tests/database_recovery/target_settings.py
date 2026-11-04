"""Resolve the actual SideStore target Release language mode, never another target."""
import hashlib
import json
import pathlib
import subprocess

PROJECT = 'AltStore.xcodeproj/project.pbxproj'

def settings_from_objects(project):
    objects = project['objects']
    targets = [row for row in objects.values()
               if row.get('isa') == 'PBXNativeTarget' and row.get('name') == 'SideStore']
    if len(targets) != 1:
        raise ValueError('Exactly one SideStore native target is required.')
    config_list = objects[targets[0]['buildConfigurationList']]
    if config_list.get('isa') != 'XCConfigurationList':
        raise ValueError('SideStore configuration list is invalid.')
    releases = [objects[key] for key in config_list['buildConfigurations']
                if objects[key].get('name') == 'Release' and
                objects[key].get('isa') == 'XCBuildConfiguration']
    if len(releases) != 1:
        raise ValueError('Exactly one SideStore Release configuration is required.')
    declared = releases[0]['buildSettings'].get('SWIFT_VERSION')
    # No downgrade/fallback: follow the declared target mode, or fail if the
    # target begins using a mode this fixture has not been reviewed to handle.
    modes = {'5.0': '5', '6.0': '6'}
    if declared not in modes:
        raise ValueError('Unsupported or inherited SideStore Swift language mode.')
    return {'target': 'SideStore', 'configuration': 'Release',
            'declared': declared, 'swiftc_argument': modes[declared]}

def inspect_project(root: pathlib.Path):
    path = root / PROJECT
    if not path.is_file() or path.is_symlink():
        raise ValueError('Regular source-owned Xcode project is required.')
    before = path.read_bytes()
    parsed = json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(path)], text=True, timeout=30))
    if path.read_bytes() != before:
        raise ValueError('Xcode project changed during mode inspection.')
    result = settings_from_objects(parsed)
    result['project_sha256'] = hashlib.sha256(before).hexdigest()
    return result
