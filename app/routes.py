from flask import Blueprint, render_template, request

bp = Blueprint('main', __name__)

@bp.route('/', methods=['GET'])
def index():
    environments = ['Standard', 'Autopilot']
    # Remove regions list since we don't need it anymore
    return render_template('form.html', environments=environments)

@bp.route('/generate', methods=['POST'])
def generate_helm_commands():
    data = request.form
    
    # Check if this is an uninstall request
    if data.get('uninstall') == 'true':
        base_command = "curl -s https://raw.githubusercontent.com/kclancc/helmguide/main/scripts/falcon-helm-deploy.sh | bash -s --"
        return render_template('result.html', 
                             command=f"{base_command} --uninstall",
                             is_uninstall=True)

    # Validate inputs
    if data.get('cluster_name') and ' ' in data.get('cluster_name'):
        return render_template('form.html', error="Cluster name cannot contain spaces")
    
    if data.get('tags') and ' ' in data.get('tags'):
        return render_template('form.html', error="Tags cannot contain spaces")
    
    # Base curl command using your public GitHub script
    base_command = "curl -s https://raw.githubusercontent.com/kclancc/helmguide/main/scripts/falcon-helm-deploy.sh | bash -s --"
    
    params = []
    
    # Required parameters
    if data.get('client_id'):
        params.append(f"--client-id {data.get('client_id')}")
    if data.get('client_secret'):
        params.append(f"--client-secret {data.get('client_secret')}")
    if data.get('cluster_name'):
        cluster_name = data.get('cluster_name').strip()
        if ' ' in cluster_name:
            return render_template('form.html', error="Cluster name cannot contain spaces")
        params.append(f"--cluster-name {cluster_name}")
    
    # Optional parameters
    if data.get('environment') == 'Autopilot':
        params.append("--autopilot")
    if data.get('tags'):
        tags = data.get('tags').strip()
        if ' ' in tags:
            return render_template('form.html', error="Tags cannot contain spaces")
        params.append(f"--tags {tags}")
    
    # Custom registry parameters
    if data.get('custom_registry'):
        params.append(f"--custom-registry {data.get('custom_registry')}")
        if data.get('sensor_tag'):
            params.append(f"--sensor-tag {data.get('sensor_tag')}")
        if data.get('kac_tag'):
            params.append(f"--kac-tag {data.get('kac_tag')}")
        if data.get('iar_tag'):
            params.append(f"--iar-tag {data.get('iar_tag')}")
    
    # Component flags
    if not data.get('deploy_sensor'):
        params.append("--skip-sensor")
    if not data.get('deploy_kac'):
        params.append("--skip-kac")
    if not data.get('deploy_iar'):
        params.append("--skip-iar")
    if not data.get('deploy_container'):
        params.append("--skip-container")
    
    final_command = f"{base_command} {' '.join(params)}"
    return render_template('result.html', 
                         command=final_command,
                         is_uninstall=False)
