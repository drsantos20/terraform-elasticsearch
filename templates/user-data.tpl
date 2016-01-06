#!/bin/bash
set -e

# Configure elasticsearch
cat <<'EOF' >/tmp/elasticsearch_vars
export CLUSTER_NAME="${es_cluster}"
export DATA_DIR="${elasticsearch_data_dir}"
export SECURITY_GROUPS="${security_groups}"
export ES_ENV="${es_environment}"
export AVAILABILITY_ZONES="${availability_zones}"
export AWS_REGION="${aws_region}"
EOF
sudo mv /tmp/elasticsearch_vars /etc/elasticsearch/configurable/elasticsearch_vars
# the following have been installed via packer
sudo cp /etc/elasticsearch/configurable/elasticsearch /etc/init.d/
sudo chmod u+x /etc/init.d/elasticsearch
sudo cp /etc/elasticsearch/configurable/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml

sudo mkfs -t ext4 ${volume_name}
sudo mkdir -p ${elasticsearch_data_dir}
sudo mount ${volume_name} ${elasticsearch_data_dir}
sudo echo "${volume_name} ${elasticsearch_data_dir} ext4 defaults,nofail 0 2" >> /etc/fstab
sudo chown -R elasticsearch:elasticsearch ${elasticsearch_data_dir}

# Configure the consul agent
cat <<EOF >/tmp/consul.json
{
    "addresses"                   : {
        "http" : "0.0.0.0"
    },
    "recursor"                    : "${dns_server}",
    "disable_anonymous_signature" : true,
    "disable_update_check"        : true,
    "data_dir"                    : "/mnt/consul/data"
}
EOF
sudo mv /tmp/consul.json /etc/consul.d/consul.json

# Setup the consul agent init script
cat <<'EOF' >/tmp/upstart
description "Consul agent"

start on runlevel [2345]
stop on runlevel [!2345]

respawn

env PIDFILE=/var/run/consul.pid

script
  # Make sure to use all our CPUs, because Consul can block a scheduler thread
  export GOMAXPROCS=`nproc`

  # Get the IP
  BIND=`ifconfig eth0 | grep "inet addr" | awk '{ print substr($2,6) }'`

  echo $$ > $${PIDFILE}
  exec /usr/local/bin/consul agent \
    -config-dir="/etc/consul.d" \
    -bind=$${BIND} \
    -node="elasticsearch-$${BIND}" \
    -dc="${consul_dc}" \
    -atlas=${atlas} \
    -atlas-join \
    -atlas-token="${atlas_token}" \
    >>/var/log/consul.log 2>&1
end script

# to gracefully remove agents
pre-stop script
    [ -e $PIDFILE ] && kill -INT $(cat $PIDFILE)
    rm -f $PIDFILE
end script
EOF
sudo mv /tmp/upstart /etc/init/consul.conf

# Setup the consul agent config
# This uses the check.py script uploaded by packer
cat <<'EOF' >/tmp/elasticsearch-consul.json
{
    "service": {
        "name": "elasticsearch",
        "leave_on_terminate": true,
        "tags": [
            "http", "index"
        ],
        "port": 9200,
        "checks": [{
            "id": "1",
            "name": "Elasticsearch HTTP",
            "notes": "Use curl to check the web service every 10 seconds",
            "script": "curl localhost:9200 >/dev/null 2>&1",
            "interval": "10s"
        }, {
            "id": "2",
            "name": "Cluster health",
            "notes": "Check cluster health every 30 seconds",
            "script": "python /etc/consul.d/check.py",
            "interval": "30s"
        }]
    }
}
EOF
sudo mv /tmp/elasticsearch-consul.json /etc/consul.d/elasticsearch.json

# Start Elasticsearch
sudo chkconfig --add elasticsearch
sudo service elasticsearch start

# Start Consul
sudo start consul
