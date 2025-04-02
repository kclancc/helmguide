from flask import Blueprint, render_template, request, jsonify
import subprocess
import json
import base64

# Create blueprint
bp = Blueprint('main', __name__)

def parse_image_path(image_path):
    """Parse repository and tag from full image path"""
    try:
        repo, tag = image_path.rsplit(':', 1)
        return {
            'full_path': image_path,
            'repository': repo,
            'tag': tag
        }
    except Exception as e:
        print(f"Error parsing image path: {str(e)}")
        return None

def get_common_info(client_id, client_secret):
    """Get common information (CID and pull token) that can be reused across sensor types"""
    try:
        # Get CID
        cid_cmd = [
            './falcon-container-sensor-pull.sh',
            '--client-id', client_id,
            '--client-secret', client_secret,
            '--type', 'falcon-sensor',  # Explicitly set type
            '--get-cid'
        ]
        cid_result = subprocess.run(cid_cmd, capture_output=True, text=True)
        
        # Get pull token
        token_cmd = [
            './falcon-container-sensor-pull.sh',
            '--client-id', client_id,
            '--client-secret', client_secret,
            '--type', 'falcon-sensor',  # Explicitly set type
            '--get-pull-token'
        ]
        token_result = subprocess.run(token_cmd, capture_output=True, text=True)
        
        return {
            'cid': cid_result.stdout.strip(),
            'pull_token': token_result.stdout.strip()
        }
    except Exception as e:
        print(f"Error getting common info: {str(e)}")
        return {'error': str(e)}

def get_sensor_info_by_type(client_id, client_secret, sensor_type, common_info=None):
    """Get sensor information for a specific type"""
    try:
        # Reuse common info if provided
        if common_info is None:
            common_info = get_common_info(client_id, client_secret)
        
        # Get image path only
        image_path_cmd = [
            './falcon-container-sensor-pull.sh',
            '--client-id', client_id,
            '--client-secret', client_secret,
            '--type', sensor_type,
            '--get-image-path'
        ]
        image_result = subprocess.run(image_path_cmd, capture_output=True, text=True)
        image_info = parse_image_path(image_result.stdout.strip())
        
        return {
            'image_path': image_info['full_path'] if image_info else '',
            'repository': image_info['repository'] if image_info else '',
            'tag': image_info['tag'] if image_info else '',
            'pull_token': common_info.get('pull_token', ''),  # Use common pull token
            'cid': common_info.get('cid', ''),               # Use common CID
            'sensor_type': sensor_type
        }
    except Exception as e:
        print(f"Error getting {sensor_type} info: {str(e)}")
        return {'error': str(e)}


def generate_sensor_command(environment, sensor_info, custom_registry_info=None):
    """Generate appropriate Helm command based on environment"""
    command_parts = [
        "helm upgrade --install falcon-helm crowdstrike/falcon-sensor \\",
        "    -n falcon-system --create-namespace \\",
    ]
    
    if environment == 'Autopilot':
        command_parts.append("    --set node.gke.autopilot=true \\")

    # Use custom registry info if provided, otherwise use sensor_info
    if custom_registry_info:
        repository = f"{custom_registry_info['registry']}/{custom_registry_info['repo']}"
        tag = custom_registry_info['sensor_tag']
    else:
        repository = sensor_info['repository']
        tag = sensor_info['tag']
    
    command_parts.extend([
        f"    --set falcon.cid={sensor_info['cid']} \\",
        f"    --set node.image.repository={repository} \\",
        f"    --set node.image.tag={tag}"
    ])
    
    # Only add registryConfigJSON if not using custom registry
    if not custom_registry_info:
        command_parts[-1] = command_parts[-1] + " \\"  # Add backslash to previous line
        command_parts.append(f"    --set node.image.registryConfigJSON='{sensor_info.get('pull_token', '')}'")
    
    return '\n'.join(command_parts)

def generate_kac_command(environment, sensor_info, custom_registry_info=None):
    """Generate KAC helm command"""
    command_parts = [
        "helm install falcon-kac crowdstrike/falcon-kac \\",
        "    -n falcon-kac --create-namespace \\",
    ]

    # Use custom registry info if provided, otherwise use sensor_info
    if custom_registry_info:
        repository = f"{custom_registry_info['registry']}/{custom_registry_info['repo']}"
        tag = custom_registry_info['kac_tag']
    else:
        repository = sensor_info['repository']
        tag = sensor_info['tag']

    command_parts.extend([
        f"    --set falcon.cid={sensor_info['cid']} \\",
        f"    --set image.repository={repository} \\",
        f"    --set image.tag={tag}"
    ])

    # Only add registryConfigJSON if not using custom registry
    if not custom_registry_info:
        command_parts[-1] = command_parts[-1] + " \\"  # Add backslash to previous line
        command_parts.append(f"    --set image.registryConfigJSON='{sensor_info.get('pull_token', '')}'")

    return '\n'.join(command_parts)

def generate_iar_command(environment, sensor_info, custom_registry_info=None, form_data=None):
    """Generate IAR helm command"""
    command_parts = [
        "helm install falcon-image-analyzer crowdstrike/falcon-image-analyzer \\",
        "    -n falcon-system --create-namespace \\",
    ]

    # Use custom registry info if provided, otherwise use sensor_info
    if custom_registry_info:
        repository = f"{custom_registry_info['registry']}/{custom_registry_info['repo']}"
        tag = custom_registry_info['iar_tag']
    else:
        repository = sensor_info['repository']
        tag = sensor_info['tag']

    command_parts.append(f"    --set crowdstrikeConfig.cid={sensor_info['cid']} \\")

    # Add IAR specific configuration if form_data is provided and IAR is selected
    if form_data and form_data.get('deploy_iar') == 'on':
        if form_data.get('cluster_name'):
            command_parts.append(f"    --set crowdstrikeConfig.clusterName={form_data.get('cluster_name')} \\")
        
        if form_data.get('agent_region'):
            command_parts.append(f"    --set crowdstrikeConfig.agentRegion={form_data.get('agent_region')} \\")

        # Add cloud provider specific settings
        cloud_provider = form_data.get('cloud_provider')
        if cloud_provider == 'gcp':
            command_parts.append("    --set gcp.enabled=true \\")
        elif cloud_provider == 'azure':
            command_parts.append("    --set azure.enabled=true \\")

    command_parts.extend([
        f"    --set image.repository={repository} \\",
        f"    --set image.tag={tag}"
    ])

    # Only add registryConfigJSON if not using custom registry
    if not custom_registry_info and sensor_info.get('pull_token'):
        command_parts[-1] = command_parts[-1] + " \\"  # Add backslash to previous line
        command_parts.append(f"    --set image.registryConfigJSON='{sensor_info['pull_token']}'")

    return '\n'.join(command_parts)


@bp.route('/', methods=['GET'])
def index():
    environments = ['Standard','Autopilot']
    return render_template('form.html', environments=environments)

def generate_copy_command(client_id, client_secret, sensor_type, custom_registry_info):
    """Generate image copy command for a specific sensor type"""
    if not custom_registry_info or not custom_registry_info.get('registry') or not custom_registry_info.get('repo'):
        return None

    # Get the appropriate tag based on sensor type
    tag_mapping = {
        'falcon-sensor': 'sensor_tag',
        'falcon-kac': 'kac_tag',
        'falcon-imageanalyzer': 'iar_tag'
    }
    
    custom_tag = custom_registry_info.get(tag_mapping.get(sensor_type))
    registry_path = f"{custom_registry_info['registry']}/{custom_registry_info['repo']}"

    copy_command = (
        f"curl https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/"
        f"falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- "
        f"-t {sensor_type} "
        f"-u {client_id} "
        f"-s {client_secret} "
        f"-c {registry_path} "
        f"--copy-omit-image-name "
        f"--copy-custom-tag {custom_tag}"
    )
    
    return copy_command

@bp.route('/generate', methods=['POST'])
def generate_helm_commands():
    data = request.form
    commands = {}
    copy_commands = {}
    
    # Check if using custom registry
    using_custom_registry = bool(data.get('custom_registry') and data.get('custom_repo'))
    
    if using_custom_registry:
        # When using custom registry, we only need CID
        custom_registry_info = {
            'registry': data.get('custom_registry'),
            'repo': data.get('custom_repo'),
            'sensor_tag': data.get('sensor_tag'),
            'kac_tag': data.get('kac_tag'),
            'iar_tag': data.get('iar_tag')
        }
        
        # Only get CID
        try:
            cid_cmd = [
                './falcon-container-sensor-pull.sh',
                '--client-id', data.get('client_id'),
                '--client-secret', data.get('client_secret'),
                '--type', 'falcon-sensor',
                '--get-cid'
            ]
            cid_result = subprocess.run(cid_cmd, capture_output=True, text=True)
            common_info = {'cid': cid_result.stdout.strip()}
        except Exception as e:
            print(f"Error getting CID: {str(e)}")
            return render_template('result.html', error=f"Error getting CID: {str(e)}")

        # Generate copy commands for selected components
        if data.get('deploy_sensor') == 'on':
            copy_commands['sensor'] = generate_copy_command(
                data.get('client_id'),
                data.get('client_secret'),
                'falcon-sensor',
                custom_registry_info
            )
            # Generate helm command with custom registry info
            commands['sensor'] = generate_sensor_command(
                data.get('environment'),
                {'cid': common_info['cid']},  # Only pass CID
                custom_registry_info
            )
            
        if data.get('deploy_kac') == 'on':
            copy_commands['kac'] = generate_copy_command(
                data.get('client_id'),
                data.get('client_secret'),
                'falcon-kac',
                custom_registry_info
            )
            commands['kac'] = generate_kac_command(
                data.get('environment'),
                {'cid': common_info['cid']},  # Only pass CID
                custom_registry_info
            )
            
        if data.get('deploy_iar') == 'on':
            copy_commands['iar'] = generate_copy_command(
                data.get('client_id'),
                data.get('client_secret'),
                'falcon-imageanalyzer',
                custom_registry_info
            )
            commands['iar'] = generate_iar_command(
                data.get('environment'),
                {'cid': common_info['cid']},  # Only pass CID
                custom_registry_info,
                data
            )
    
    else:
        # Original flow for non-custom registry
        if data.get('deploy_sensor') == 'on' or data.get('deploy_kac') == 'on' or data.get('deploy_iar') == 'on':
            common_info = get_common_info(data.get('client_id'), data.get('client_secret'))
        
            if data.get('deploy_sensor') == 'on':
                sensor_info = get_sensor_info_by_type(data.get('client_id'), data.get('client_secret'), 
                                                    'falcon-sensor', common_info)
                commands['sensor'] = generate_sensor_command(data.get('environment'), sensor_info)
            
            if data.get('deploy_kac') == 'on':
                kac_info = get_sensor_info_by_type(data.get('client_id'), data.get('client_secret'), 
                                                  'falcon-kac', common_info)
                commands['kac'] = generate_kac_command(data.get('environment'), kac_info)
            
            if data.get('deploy_iar') == 'on':
                iar_info = get_sensor_info_by_type(data.get('client_id'), data.get('client_secret'), 
                                                  'falcon-imageanalyzer', common_info)
                # Pass None for custom_registry_info in standard flow
                commands['iar'] = generate_iar_command(
                    environment=data.get('environment'),
                    sensor_info=iar_info,
                    custom_registry_info=None,
                    form_data=data
                )
    
    return render_template('result.html', 
                         commands=commands, 
                         copy_commands=copy_commands,
                         using_custom_registry=using_custom_registry)
