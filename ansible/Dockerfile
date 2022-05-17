FROM ubuntu:20.04
RUN apt-get update && apt-get install -y software-properties-common && add-apt-repository --yes --update ppa:ansible/ansible
RUN apt-get install -y ansible python3-pip
RUN pip install docker
# RUN ansible-galaxy collection install community.docker
