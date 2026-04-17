import re

with open('/root/horde/deployments/roles/horde_alloy/templates/config.alloy.j2', 'r') as f:
    config = f.read()

addition = """
{% if horde_alloy_collect_metrics | default(false) | bool %}
// Host Metrics via integrated node_exporter
prometheus.exporter.unix "horde_host" { }

prometheus.scrape "horde_host_metrics" {
    targets         = prometheus.exporter.unix.horde_host.targets
    forward_to      = [prometheus.remote_write.mimir.receiver]
    scrape_interval = "15s"
}

prometheus.remote_write "mimir" {
    endpoint {
        url = "{{ horde_alloy_mimir_endpoint }}"
        {% if horde_alloy_basic_auth_username | default('') != '' %}
        basic_auth {
            username = "{{ horde_alloy_basic_auth_username }}"
            password = "{{ horde_alloy_basic_auth_password }}"
        }
        {% endif %}
    }
}
{% endif %}
"""

if addition.strip() not in config:
    config += "\n" + addition
    with open('/root/horde/deployments/roles/horde_alloy/templates/config.alloy.j2', 'w') as f:
        f.write(config)

