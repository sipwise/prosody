# DOCKER_NAME=prosody-bookworm
FROM docker.mgm.sipwise.com/sipwise-bookworm:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT 2023-06-26

RUN apt-get update && apt-get install --assume-yes lua-check

RUN echo './t/testrunner' >>/root/.bash_history

WORKDIR /code/

################################################################################
# Instructions for usage
# ----------------------
# When you want to build the base image from scratch
# jump to the next section if you don't want to build yourself!:
#
# % docker build --tag="prosody-bookworm" -f t/Dockerfile .
# % docker run --rm -i -t -v $(pwd):/code:rw prosody-bookworm:latest bash
#
# Use the existing docker image:
# % docker pull docker.mgm.sipwise.com/prosody-bookworm
# NOTE: run the following command from root folder of git repository:
# % docker run --rm -i -t -v $(pwd):/code:rw docker.mgm.sipwise.com/prosody-bookworm:latest bash
#
# Inside docker (the command is in history, just press UP button):
#   ./t/testrunner
#
################################################################################
