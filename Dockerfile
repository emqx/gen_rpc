FROM erlang:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
ENV TERM=xterm-256color

RUN apt update && apt install net-tools
ADD . /gen_rpc
WORKDIR "/gen_rpc"
RUN make
